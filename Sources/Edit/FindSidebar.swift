import AppKit

enum FindCommand {
    case find, replace, next, previous, toggleSidebar
    case refresh, toggleReplace, toggleCase, toggleWholeWord, toggleRegex
    case replaceAll, replaceSelected, dismissSelected, clearSelection
}

@MainActor
final class FindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let document: DocumentWindow
    private let writesPreferences: Bool
    private var settings: FindSettings
    private let findInput = FindInput(name: "Find")
    private let replaceInput = FindInput(name: "Replace")
    private let findLabel = NSTextField(labelWithString: "Find")
    private let replaceLabel = NSTextField(labelWithString: "Replace")
    private let matchCase = NSButton(checkboxWithTitle: "Case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole Word", target: nil, action: nil)
    private let regex = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let replaceToggle = NSButton(title: "", target: nil, action: nil)
    private let replaceButton = NSButton(title: "All", target: nil, action: nil)
    private let resultFile = NSTextField(labelWithString: "Untitled")
    private let resultIcon = NSImageView()
    private let resultStatus = NSTextField(labelWithString: "No results")
    private let results = FindResultsTable()
    private let resultScroll = NSScrollView()
    private let replaceRow = NSStackView()
    private let split = NSSplitViewController()
    private let sidebar = NSViewController()
    private let editorController = NSViewController()
    private lazy var sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    private lazy var decorations = FindDecorations(editor: document.editor)
    private var installed = false
    private var bufferSnapshot: String
    private var resultSnapshot = ""
    private var baseMatches: [FindHit] = []
    private var matches: [FindHit] = []
    private var dismissed: Set<NSRange> = []
    private var selected: Int?
    private var editingResults = false
    private var previewRequested = false
    private var movingDismissalsForReplacement = false
    private var applyingEdits = false
    private var bufferSearchScheduled = false
    private var pending = false
    private var validResults = false
    private var generation: UInt64 = 0
    private var work: Task<FindSearch.Outcome, Never>?
    private var activity: Task<Void, Never>?
    private var preferenceWrite: Task<Void, Never>?
    private var queuedDirection: Int?
    private var advanceFrom: Int?

    init(document: DocumentWindow, settings: FindSettings, writesPreferences: Bool) {
        self.document = document
        self.settings = settings
        self.writesPreferences = writesPreferences
        bufferSnapshot = document.editor.string
        super.init()
        configure()
        if let storage = document.editor.textStorage {
            NotificationCenter.default.addObserver(self, selector: #selector(storageDidEdit(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
    }

    deinit {
        work?.cancel()
        activity?.cancel()
        preferenceWrite?.cancel()
    }

    func restoreVisibility() {
        guard settings.visible else { return }
        present(focusing: nil, animate: false)
        requestSearch()
    }

    func canPerform(_ action: FindCommand) -> Bool {
        switch action {
        case .find, .replace, .toggleSidebar:
            return true
        case .next, .previous:
            return !settings.query.isEmpty
        case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex:
            return settings.visible
        case .replaceAll:
            return settings.visible && settings.showsReplacement && validResults && !matches.isEmpty &&
                document.editor.isEditable && !document.editor.hasMarkedText()
        case .replaceSelected:
            return canPerform(.replaceAll) && selected != nil
        case .dismissSelected:
            return settings.visible && validResults && selected != nil
        case .clearSelection:
            return settings.visible && selected != nil
        }
    }

    func perform(_ action: FindCommand) {
        guard canPerform(action) else { return }
        switch action {
        case .find:
            openField(replace: false)
        case .replace:
            openField(replace: true)
        case .next:
            moveResult(by: 1)
        case .previous:
            moveResult(by: -1)
        case .toggleSidebar:
            if settings.visible {
                hide()
            } else {
                present(focusing: nil, animate: true)
                if !validResults && !pending { requestSearch() }
            }
        case .refresh:
            resetMatches()
        case .toggleReplace:
            setReplacementVisible(!settings.showsReplacement)
        case .toggleCase:
            matchCase.state = settings.options.caseSensitive ? .off : .on
            changeOptions(nil)
        case .toggleWholeWord:
            wholeWord.state = settings.options.wholeWord ? .off : .on
            changeOptions(nil)
        case .toggleRegex:
            regex.state = settings.options.regularExpression ? .off : .on
            changeOptions(nil)
        case .replaceAll:
            apply(matches, advance: false)
        case .replaceSelected:
            if let selected { apply([matches[selected]], advance: true) }
        case .dismissSelected:
            if let selected { dismiss(matches[selected].range) }
        case .clearSelection:
            clearResultFocus()
        }
    }

    func updateName() {
        resultFile.stringValue = document.window.title
        resultIcon.image = FileIcons.image(for: document.fileURL, appearance: sidebar.view.effectiveAppearance,
                                           language: document.manualSyntaxLanguage?.iconIdentifier)
    }

    func bufferReplaced() {
        dismissed.removeAll()
        advanceFrom = nil
        queuedDirection = nil
        bufferSnapshot = document.editor.string
        publish([])
        requestSearchIfNeeded()
    }

    @objc private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let text = storage.string
        if !movingDismissalsForReplacement && !dismissed.isEmpty {
            let range = storage.editedRange
            let oldLength = range.length - storage.changeInLength
            let edit: FindTextEdit
            let oldCount = bufferSnapshot.utf16.count
            if range.location != NSNotFound && NSMaxRange(range) <= storage.length &&
                oldLength >= 0 && oldLength <= oldCount && range.location <= oldCount - oldLength {
                edit = FindTextEdit(range: NSRange(location: range.location, length: oldLength),
                                    replacement: (text as NSString).substring(with: range))
            } else {
                edit = FindTextEdit.singleChange(from: bufferSnapshot as NSString, to: text as NSString)
            }
            dismissed = FindTextEdit.moving(dismissed, through: [edit])
        }
        bufferSnapshot = text
        generation &+= 1
        validResults = false
        work?.cancel()
        guard !bufferSearchScheduled else { return }
        bufferSearchScheduled = true
        // TextKit finishes its edit notification before decoration updates can lay out text.
        Task { @MainActor [weak self] in
            guard let self else { return }
            bufferSearchScheduled = false
            requestSearchIfNeeded()
        }
    }

    func editorInteracted() {
        guard !applyingEdits, previewRequested else { return }
        previewRequested = false
        refreshDecorations()
    }

    func persistSettings() {
        preferenceWrite?.cancel()
        guard writesPreferences else { return }
        settings.store(in: .standard)
    }

    private func schedulePreferencesWrite() {
        guard writesPreferences else { return }
        preferenceWrite?.cancel()
        preferenceWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.settings.store(in: .standard)
        }
    }

    private func configure() {
        let refresh = symbolButton("arrow.clockwise", label: "Refresh Search", action: #selector(refreshSearch(_:)))
        let header = horizontal([NSTextField(labelWithString: "Search"), NSView(), refresh])

        findInput.value = settings.query
        replaceInput.value = settings.replacement
        findInput.onChange = { [weak self] in self?.queryChanged() }
        replaceInput.onChange = { [weak self] in
            guard let self else { return }
            settings.replacement = replaceInput.value
            schedulePreferencesWrite()
            refreshDecorations()
        }
        findInput.onReturn = { [weak self] in self?.moveResult(by: 1) }
        replaceInput.onReturn = { [weak self] in self?.focusFirstResult() }
        findInput.onEscape = { [weak self] in self?.hide() }
        replaceInput.onEscape = { [weak self] in self?.hide() }

        replaceToggle.title = ""
        replaceToggle.target = self
        replaceToggle.action = #selector(toggleReplaceSection(_:))
        replaceToggle.toolTip = "Show or Hide Replace"
        replaceToggle.setAccessibilityLabel("Show or Hide Replace")
        replaceToggle.widthAnchor.constraint(equalToConstant: 30).isActive = true

        replaceButton.target = self
        replaceButton.action = #selector(replaceAllMatches(_:))
        replaceButton.toolTip = "Replace All"
        replaceButton.setAccessibilityLabel("Replace All")
        replaceButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let findRow = horizontal([findInput, replaceToggle])
        replaceRow.orientation = .horizontal
        replaceRow.alignment = .centerY
        replaceRow.spacing = 5
        replaceRow.addArrangedSubview(replaceInput)
        replaceRow.addArrangedSubview(replaceButton)
        for option in [matchCase, wholeWord, regex] {
            option.controlSize = .small
            option.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            option.target = self
            option.action = #selector(changeOptions(_:))
        }
        matchCase.state = settings.options.caseSensitive ? .on : .off
        wholeWord.state = settings.options.wholeWord ? .on : .off
        regex.state = settings.options.regularExpression ? .on : .off
        let options = horizontal([matchCase, wholeWord, regex])
        updateReplacementVisibility()

        resultFile.lineBreakMode = .byTruncatingMiddle
        resultFile.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultStatus.textColor = .secondaryLabelColor
        resultStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resultIcon.setAccessibilityElement(false)
        resultIcon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        let resultHeader = horizontal([resultIcon, resultFile, NSView(), resultStatus])
        setupResults()

        let controls = [header, findLabel, findRow, options, replaceLabel, replaceRow, resultHeader, resultScroll]
        let content = NSStackView(views: controls)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = FindSidebarSurface(frame: NSRect(x: 0, y: 0, width: settings.width, height: 500))
        view.appearanceChanged = { [weak self] in self?.updateName() }
        view.addSubview(content)
        sidebar.view = view
        updateName()
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        for control in [header, findRow, replaceRow, resultHeader, resultScroll] {
            control.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        resultScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        replaceButton.isEnabled = false
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
        let button = NSButton(image: image, target: self, action: action)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func setupResults() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SearchResult"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        results.addTableColumn(column)
        results.headerView = nil
        results.style = .sourceList
        results.rowSizeStyle = .small
        results.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        results.allowsEmptySelection = true
        results.setAccessibilityLabel("Search Results")
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(clickedResult(_:))
        results.onReturn = { [weak self] in self?.activateResult() }
        results.onEscape = { [weak self] in self?.clearResultFocus() }
        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.documentView = results
    }

    private func installIfNeeded() {
        guard !installed else { return }
        let window = document.window
        let previousSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let oldFrame = window.frame
        let scrollOrigin = document.scrollView.contentView.bounds.origin
        editorController.view = document.scrollView
        let editorItem = NSSplitViewItem(viewController: editorController)
        editorItem.minimumThickness = 128
        sidebarItem.minimumThickness = 185
        sidebarItem.maximumThickness = 650
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(settings.width) / max(previousSize.width, 1))
        sidebarItem.isCollapsed = true
        split.splitView.isVertical = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        split.view.setFrameSize(previousSize)
        window.contentViewController = split
        if window.frame != oldFrame { window.setFrame(oldFrame, display: window.isVisible) }
        window.initialFirstResponder = document.editor
        document.scrollView.contentView.scroll(to: scrollOrigin)
        document.scrollView.reflectScrolledClipView(document.scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        installed = true
    }

    @objc private func splitResized(_ notification: Notification) {
        guard installed else { return }
        settings.visible = !sidebarItem.isCollapsed
        let width = sidebar.view.frame.width
        if settings.visible && width >= sidebarItem.minimumThickness {
            settings.width = width
        }
        if !settings.visible {
            previewRequested = false
            if focusIsInSidebar { document.window.makeFirstResponder(document.editor) }
        }
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private var focusIsInSidebar: Bool {
        guard installed, let view = document.window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: sidebar.view)
    }

    private func present(focusing input: NSTextView?, animate: Bool) {
        let window = document.window
        let responder = window.firstResponder
        let desiredWidth = settings.width
        installIfNeeded()
        settings.visible = true
        if sidebarItem.isCollapsed {
            sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(desiredWidth) / max(split.view.bounds.width, 1))
            if animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                sidebarItem.animator().isCollapsed = false
            } else {
                sidebarItem.isCollapsed = false
                split.view.layoutSubtreeIfNeeded()
                split.splitView.setPosition(CGFloat(desiredWidth), ofDividerAt: 0)
            }
        }
        if let input {
            window.makeFirstResponder(input)
        } else if let responder, !focusIsInSidebar {
            window.makeFirstResponder(responder)
        }
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private func hide() {
        guard installed && settings.visible else { return }
        if focusIsInSidebar { document.window.makeFirstResponder(document.editor) }
        settings.visible = false
        previewRequested = false
        if document.window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarItem.animator().isCollapsed = true
        } else {
            sidebarItem.isCollapsed = true
        }
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private func openField(replace: Bool) {
        document.requestAutosave()
        var changedQuery = false
        if let editor = document.window.firstResponder as? EditorTextView, editor === document.editor {
            let selection = editor.selectedRange()
            let text = editor.string as NSString
            if selection.length > 0 && NSMaxRange(selection) <= text.length {
                let selectedText = text.substring(with: selection)
                let query = settings.options.regularExpression ? NSRegularExpression.escapedPattern(for: selectedText) : selectedText
                if query != settings.query {
                    changedQuery = true
                    settings.query = query
                    findInput.value = query
                    dismissed.removeAll()
                    selected = nil
                }
            }
        }
        if replace { setReplacementVisible(true) }
        present(focusing: replace ? replaceInput.input : findInput.input, animate: true)
        previewRequested = false
        if changedQuery || (!validResults && !pending) { requestSearch() }
        refreshDecorations()
    }

    private func setReplacementVisible(_ visible: Bool) {
        if !visible && document.window.firstResponder === replaceInput.input {
            document.window.makeFirstResponder(findInput.input)
        }
        settings.showsReplacement = visible
        updateReplacementVisibility()
        results.reloadData()
        if let selected { selectRow(selected, reveal: false, preview: visible && previewRequested) }
        refreshDecorations()
        updateReplaceAvailability()
        schedulePreferencesWrite()
    }

    private func updateReplacementVisibility() {
        replaceToggle.image = NSImage(systemSymbolName: settings.showsReplacement ? "chevron.down" : "chevron.right",
                                      accessibilityDescription: nil)
        replaceLabel.isHidden = !settings.showsReplacement
        replaceRow.isHidden = !settings.showsReplacement
    }

    @objc private func toggleReplaceSection(_ sender: Any?) { perform(.toggleReplace) }
    @objc private func replaceAllMatches(_ sender: Any?) { perform(.replaceAll) }
    @objc private func refreshSearch(_ sender: Any?) { perform(.refresh) }

    @objc private func changeOptions(_ sender: Any?) {
        settings.options = FindOptions(caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on,
                                       regularExpression: regex.state == .on)
        resetMatches()
        schedulePreferencesWrite()
    }

    private func queryChanged() {
        settings.query = findInput.value
        resetMatches()
        schedulePreferencesWrite()
    }

    private func resetMatches() {
        dismissed.removeAll()
        queuedDirection = nil
        advanceFrom = nil
        selected = nil
        previewRequested = false
        requestSearch()
    }

    private func requestSearchIfNeeded() {
        if settings.visible || queuedDirection != nil {
            requestSearch()
        } else {
            generation &+= 1
            work?.cancel()
            activity?.cancel()
            validResults = false
            pending = false
            refreshDecorations()
        }
    }

    private func requestSearch() {
        generation &+= 1
        let searchGeneration = generation
        work?.cancel()
        activity?.cancel()
        validResults = false
        pending = false
        updateReplaceAvailability()
        if settings.query.isEmpty {
            resultSnapshot = bufferSnapshot
            publish([])
            return
        }
        pending = true
        refreshDecorations()
        refreshVisibleRows()
        let snapshot = bufferSnapshot
        let query = settings.query
        let options = settings.options
        let worker = Task.detached(priority: .userInitiated) {
            FindSearch.match(query, in: snapshot, options: options)
        }
        work = worker
        activity = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, generation == searchGeneration, pending else { return }
            resultStatus.stringValue = "Searching…"
        }
        Task { [weak self] in
            let outcome = await worker.value
            guard let self, generation == searchGeneration else { return }
            activity?.cancel()
            pending = false
            resultSnapshot = snapshot
            switch outcome {
            case .matches(let found):
                publish(found)
            case .invalidExpression:
                publish([], invalid: true)
            }
        }
    }

    private func publish(_ found: [FindHit], invalid: Bool = false) {
        let previous = selected.flatMap { matches.indices.contains($0) ? matches[$0].range : nil }
        baseMatches = found
        matches = found.filter { !dismissed.contains($0.range) }
        validResults = !invalid && !settings.query.isEmpty
        let target = previous.flatMap { range in matches.firstIndex { $0.range == range } }
        selected = nil
        editingResults = true
        results.reloadData()
        editingResults = false
        resultStatus.stringValue = invalid ? "Invalid regex" : matches.isEmpty ? "No results"
            : matches.count == 1 ? "1 match" : "\(matches.count) matches"
        updateReplaceAvailability()
        if let advanceFrom {
            self.advanceFrom = nil
            if settings.visible, let next = matches.firstIndex(where: { $0.range.location >= advanceFrom }) {
                selectRow(next, reveal: true, preview: true)
            } else if settings.visible && document.window.firstResponder === results {
                document.window.makeFirstResponder(findInput.input)
            }
        } else if let queuedDirection {
            self.queuedDirection = nil
            moveResult(by: queuedDirection)
        } else if let target {
            selectRow(target, reveal: false, preview: previewRequested)
        } else {
            previewRequested = false
        }
        refreshDecorations()
        refreshVisibleRows()
    }

    private func moveResult(by direction: Int) {
        guard !settings.query.isEmpty else { return }
        guard validResults else {
            if pending {
                queuedDirection = direction
            } else if resultStatus.stringValue != "Invalid regex" {
                queuedDirection = direction
                requestSearch()
            }
            return
        }
        guard !matches.isEmpty else { return }
        let base = selected ?? (direction > 0 ? -1 : 0)
        selectRow((base + direction + matches.count) % matches.count, reveal: true, preview: focusIsInSidebar)
    }

    private func focusFirstResult() {
        guard validResults, !matches.isEmpty else { return }
        document.window.makeFirstResponder(results)
        selectRow(0, reveal: true, preview: true)
    }

    private func selectRow(_ index: Int, reveal: Bool, preview: Bool) {
        guard validResults, matches.indices.contains(index) else { return }
        let previous = selected
        selected = index
        previewRequested = preview && settings.showsReplacement && settings.visible
        editingResults = true
        results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        editingResults = false
        updateRowSelection(previous)
        updateRowSelection(index)
        if reveal {
            results.scrollRowToVisible(index)
            document.editor.scrollRangeToVisible(matches[index].range)
        }
        refreshDecorations()
    }

    private func clearResultFocus() {
        selected = nil
        previewRequested = false
        results.deselectAll(nil)
        document.window.makeFirstResponder(findInput.input)
        refreshDecorations()
    }

    @objc private func clickedResult(_ sender: Any?) {
        if results.clickedRow >= 0 { selectRow(results.clickedRow, reveal: true, preview: true) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !editingResults else { return }
        if results.selectedRow >= 0 {
            selectRow(results.selectedRow, reveal: true, preview: true)
        } else {
            updateRowSelection(selected)
            selected = nil
            previewRequested = false
            refreshDecorations()
        }
    }

    private func activateResult() {
        guard let selected, validResults else { return }
        if settings.showsReplacement {
            apply([matches[selected]], advance: true)
        } else {
            selectRow(selected, reveal: true, preview: false)
        }
    }

    private func dismiss(_ range: NSRange) {
        guard validResults, let index = matches.firstIndex(where: { $0.range == range }) else { return }
        dismissed.insert(range)
        publish(baseMatches)
        if matches.isEmpty {
            document.window.makeFirstResponder(findInput.input)
        } else {
            selectRow(min(index, matches.count - 1), reveal: true, preview: true)
        }
    }

    private func apply(_ hits: [FindHit], advance: Bool) {
        guard validResults, settings.visible, settings.showsReplacement,
              document.editor.isEditable, !document.editor.hasMarkedText(),
              let first = hits.first, let last = hits.last, document.editor.string == resultSnapshot else { return }
        let source = resultSnapshot as NSString
        let edits = hits.map { FindTextEdit(range: $0.range, replacement: $0.replacement(
            using: settings.replacement, in: source, isRegex: settings.options.regularExpression
        )) }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var start = span.location
        var output = ""
        for edit in edits {
            output += source.substring(with: NSRange(location: start, length: edit.range.location - start))
            output += edit.replacement
            start = NSMaxRange(edit.range)
        }

        advanceFrom = advance ? first.range.location + edits[0].replacement.utf16.count : nil
        if output == source.substring(with: span) {
            publish(baseMatches)
            return
        }
        let oldDismissed = dismissed
        dismissed = FindTextEdit.moving(dismissed, through: edits)
        movingDismissalsForReplacement = true
        applyingEdits = true
        let changed = document.editor.replaceFoundText(in: span, with: output)
        movingDismissalsForReplacement = false
        applyingEdits = false
        if changed {
            document.requestAutosave()
        } else {
            dismissed = oldDismissed
            advanceFrom = nil
        }
    }

    private func updateReplaceAvailability() { replaceButton.isEnabled = canPerform(.replaceAll) }

    func viewportChanged() { decorations.layout() }

    private func refreshDecorations() {
        let hit = validResults ? selected.map { matches[$0] } : nil
        let preview = previewRequested && settings.visible && settings.showsReplacement
            ? hit.map { ($0.range, $0.replacement(using: settings.replacement, in: resultSnapshot as NSString,
                                                  isRegex: settings.options.regularExpression)) }
            : nil
        decorations.update(snapshot: resultSnapshot, ranges: settings.visible && validResults ? matches.map(\.range) : [],
                           selected: hit?.range, preview: preview)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FindMatch")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FindResultCell
            ?? FindResultCell(frame: .zero)
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: FindResultCell, row: Int) {
        let range = matches[row].range
        cell.configure(text: excerpt(of: range), replacementAvailable: settings.showsReplacement,
                       acceptsActions: validResults, selected: selected == row,
                       apply: { [weak self] in
                           guard let self, let match = matches.first(where: { $0.range == range }) else { return }
                           apply([match], advance: true)
                       },
                       dismiss: { [weak self] in self?.dismiss(range) })
    }

    private func updateRowSelection(_ row: Int?) {
        guard let row, matches.indices.contains(row) else { return }
        (results.view(atColumn: 0, row: row, makeIfNecessary: false) as? FindResultCell)?.updateSelection(selected == row)
    }

    private func refreshVisibleRows() {
        let visible = results.rows(in: results.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<min(NSMaxRange(visible), matches.count) {
            if let cell = results.view(atColumn: 0, row: row, makeIfNecessary: false) as? FindResultCell {
                configure(cell, row: row)
            }
        }
    }

    private func excerpt(of range: NSRange) -> NSAttributedString {
        let source = resultSnapshot as NSString
        var start = 0
        var end = 0
        var contentEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                            for: NSRange(location: range.location, length: 0))
        let from = max(start, range.location - 36)
        let to = max(from, min(contentEnd, from + 150))
        let excerptRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
        let prefix = excerptRange.location > start ? "…" : ""
        let suffix = NSMaxRange(excerptRange) < contentEnd ? "…" : ""
        let text = source.substring(with: excerptRange)
        if text.isEmpty { return NSAttributedString(string: "↵") }
        let label = NSMutableAttributedString(string: prefix + text + suffix, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        ])
        let intersection = NSIntersectionRange(range, excerptRange)
        if intersection.length > 0 {
            label.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25),
                               range: NSRange(location: intersection.location - excerptRange.location + prefix.utf16.count,
                                              length: intersection.length))
        }
        return label
    }
}


@MainActor
private final class FindSidebarSurface: NSView {
    var appearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}
