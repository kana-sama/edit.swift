import AppKit

enum FindCommand {
    case find, replace, next, previous, toggleSidebar
    case refresh, toggleReplace, toggleCase, toggleWholeWord, toggleRegex
    case replaceAll, replaceSelected, dismissSelected, clearSelection
}

@MainActor
final class FindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let contentInset: CGFloat = 10
    private unowned let document: DocumentWindow
    private let onReturnFocus: () -> Void
    private var settings: FindSettings {
        get { document.findSettings }
        set { document.findSettings = newValue }
    }
    private let matchCase = NSButton(title: "Aa", target: nil, action: nil)
    private let wholeWord = NSButton(title: "ab", target: nil, action: nil)
    private let regex = NSButton(title: ".*", target: nil, action: nil)
    private lazy var findInput = FindInput(name: "Find", options: [matchCase, wholeWord, regex])
    private let replaceInput = FindInput(name: "Replace")
    private let replaceToggle = NSButton(title: "", target: nil, action: nil)
    private let replaceButton = NSButton(title: "", target: nil, action: nil)
    private let resultHeader = SidebarResultFileHeader(name: "Untitled", detail: "No results")
    private let results = FindResultsTable()
    private let resultScroll = FindResultsScrollView()
    private let replaceRow = NSStackView()
    private let surface = NSView()
    var view: NSView { surface }
    private let searchContent = NSStackView()
    private lazy var decorations = FindDecorations(editor: document.editor)

    var queryResponder: NSView { findInput.input }
    private var searchVisible: Bool { document.isSearchSidebarVisible }
    private var bufferSnapshot: String
    private var resultSnapshot = ""
    private var baseMatches: [FindHit] = []
    private var matches: [FindHit] = []
    private var dismissed: Set<NSRange> = []
    private var selected: Int?
    private var selectedMatchLocation: Int?
    private var editingResults = false
    private var previewRequested = false
    private var applyingEdits = false
    private var bufferSearchScheduled = false
    private var pending = false
    private var validResults = false
    private var generation: UInt64 = 0
    private var work: Task<FindSearch.Outcome, Never>?
    private var activity: Task<Void, Never>?
    private var queuedDirection: Int?
    private weak var pendingResultFocus: FindFieldTextView?
    private var advanceFrom: Int?

    init(document: DocumentWindow, onReturnFocus: @escaping () -> Void) {
        self.document = document
        self.onReturnFocus = onReturnFocus
        bufferSnapshot = document.editor.string
        super.init()
        configure()
        document.editor.onFindEditorInteraction = { [weak self] in self?.editorInteracted() }
        document.editor.onFindViewportChange = { [weak self] in self?.decorations.layout() }
        document.editor.onBufferEdit = { [weak self] storage, edits in
            self?.bufferDidEdit(storage, edits: edits)
        }
    }

    deinit {
        work?.cancel()
        activity?.cancel()
    }

    func canPerform(_ action: FindCommand) -> Bool {
        switch action {
        case .find, .replace, .toggleSidebar:
            return false
        case .next, .previous:
            return !settings.query.isEmpty
        case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex:
            return searchVisible
        case .replaceAll:
            return searchVisible && settings.showsReplacement && validResults && !matches.isEmpty &&
                document.editor.isEditable && !document.editor.hasMarkedText()
        case .replaceSelected:
            return canPerform(.replaceAll) && selected != nil
        case .dismissSelected:
            return searchVisible && validResults && selected != nil
        case .clearSelection:
            return searchVisible && selected != nil
        }
    }

    func perform(_ action: FindCommand) {
        guard canPerform(action) else { return }
        switch action {
        case .find, .replace, .toggleSidebar:
            return
        case .next:
            moveResult(by: 1)
        case .previous:
            moveResult(by: -1)
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
        resultHeader.updateFile(document.showsEmptyFolder ? "No File Open" : document.displayName,
                                url: document.displayedFileURL, language: document.manualSyntaxLanguage?.iconIdentifier)
    }

    func bufferReplaced() {
        dismissed.removeAll()
        selectedMatchLocation = nil
        advanceFrom = nil
        queuedDirection = nil
        pendingResultFocus = nil
        bufferSnapshot = document.editor.string
        publish([])
        requestSearchIfNeeded()
    }

    private func bufferDidEdit(_ storage: NSTextStorage, edits: [EditorTextEdit]?) {
        let text = storage.string
        if selectedMatchLocation != nil || !dismissed.isEmpty {
            let changes: [EditorTextEdit]
            if let edits {
                changes = edits
            } else {
                let range = storage.editedRange
                let oldLength = range.length - storage.changeInLength
                let oldCount = bufferSnapshot.utf16.count
                if range.location != NSNotFound && NSMaxRange(range) <= storage.length &&
                   oldLength >= 0 && oldLength <= oldCount && range.location <= oldCount - oldLength {
                    changes = [EditorTextEdit(range: NSRange(location: range.location, length: oldLength),
                                              text: (text as NSString).substring(with: range))]
                } else {
                    changes = [EditorTextEdit.singleChange(from: bufferSnapshot as NSString, to: text as NSString)]
                }
            }
            dismissed = EditorTextEdit.moving(dismissed, through: changes)
            if let location = selectedMatchLocation {
                selectedMatchLocation = EditorTextEdit.moving(location, through: changes)
            }
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

    private func configure() {
        for (option, label) in [(matchCase, "Match Case"), (wholeWord, "Whole Word"), (regex, "Regular Expression")] {
            option.setButtonType(.pushOnPushOff)
            option.bezelStyle = .accessoryBar
            option.controlSize = .small
            option.image = optionImage(option.title, underlined: option === wholeWord)
            option.imagePosition = .imageOnly
            option.target = self
            option.action = #selector(changeOptions(_:))
            option.toolTip = label
            option.setAccessibilityLabel(label)
            option.widthAnchor.constraint(equalToConstant: 23).isActive = true
            option.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        matchCase.state = settings.options.caseSensitive ? .on : .off
        wholeWord.state = settings.options.wholeWord ? .on : .off
        regex.state = settings.options.regularExpression ? .on : .off
        updateSearchOptionsAppearance()

        findInput.value = settings.query
        replaceInput.value = settings.replacement
        findInput.onChange = { [weak self] in self?.queryChanged() }
        replaceInput.onChange = { [weak self] in
            guard let self else { return }
            settings.replacement = replaceInput.value
            refreshDecorations()
        }
        findInput.onReturn = { [weak self] in self?.advanceFindFocus() }
        replaceInput.onReturn = { [weak self] in self?.focusFirstResult() }
        findInput.onEscape = { [weak self] in self?.onReturnFocus() }
        replaceInput.onEscape = { [weak self] in self?.onReturnFocus() }

        configureFieldAction(replaceToggle, label: "Show or Hide Replace", action: #selector(toggleReplaceSection(_:)))
        configureFieldAction(replaceButton, label: "Replace All", action: #selector(replaceAllMatches(_:)))
        replaceButton.image = optionImage("R*")
        let findRow = horizontal([findInput, replaceToggle])
        replaceRow.orientation = .horizontal
        replaceRow.alignment = .top
        replaceRow.spacing = 5
        replaceRow.addArrangedSubview(replaceInput)
        replaceRow.addArrangedSubview(replaceButton)
        updateReplacementVisibility()

        resultHeader.heightAnchor.constraint(equalToConstant: SidebarResults.rowHeight).isActive = true
        setupResults()

        let content = searchContent
        for control in [findRow, replaceRow, resultHeader, resultScroll] {
            content.addArrangedSubview(control)
        }
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 5
        content.setCustomSpacing(10, after: replaceRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        updateName()
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.safeAreaLayoutGuide.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        for control in [findRow, replaceRow, resultHeader] {
            control.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * Self.contentInset).isActive = true
        }
        resultScroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        resultScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        replaceButton.isEnabled = false
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 5
        return stack
    }

    private func optionImage(_ title: String, underlined: Bool = false) -> NSImage {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = NSSize(width: ceil(text.size().width), height: ceil(text.size().height))
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func configureFieldAction(_ button: NSButton, label: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func setupResults() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SearchResult"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        results.addTableColumn(column)
        SidebarResults.configure(results, in: resultScroll)
        results.setAccessibilityLabel("Search Results")
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.doubleAction = #selector(openClickedResult(_:))
        results.onClickSelectedRow = { [weak self] row in
            guard let self, settings.showsReplacement, !previewRequested else { return }
            selectRow(row, reveal: true, preview: true)
        }
        results.onReturn = { [weak self] in self?.activateResult() }
        results.onSpace = { [weak self] in
            guard let self, let selected else { return }
            openResult(at: selected)
        }
        results.onEscape = { [weak self] in self?.clearResultFocus() }
    }

    func focusSearch(reveal: (NSView, Bool) -> Void) {
        guard selectedMatchLocation != nil else {
            openField(replace: false, reveal: reveal)
            return
        }
        document.requestAutosave()
        previewRequested = settings.showsReplacement
        reveal(results, false)
        searchWhenShown()
        if validResults, let selected {
            selectRow(selected, reveal: true, preview: true)
        }
    }

    func openField(replace: Bool, reveal: (NSView, Bool) -> Void) {
        document.requestAutosave()
        var changedQuery = false
        if let editor = document.window.firstResponder as? EditorTextView, editor === document.editor {
            let selection = editor.selectedRange()
            let text = editor.string as NSString
            if selection.length > 0 && NSMaxRange(selection) <= text.length {
                let selectedText: String
                if let ranges = editor.focusRanges {
                    selectedText = ranges
                        .map { NSIntersectionRange($0, selection) }
                        .filter { $0.length > 0 }
                        .map { text.substring(with: $0) }
                        .joined(separator: editor.preferredLineEnding)
                } else {
                    selectedText = text.substring(with: selection)
                }
                let query = settings.options.regularExpression ? NSRegularExpression.escapedPattern(for: selectedText) : selectedText
                if !query.isEmpty && query != settings.query {
                    changedQuery = true
                    settings.query = query
                    findInput.value = query
                    dismissed.removeAll()
                    selected = nil
                    selectedMatchLocation = nil
                }
            }
        }
        reveal(replace ? replaceInput.input : findInput.input, replace)
        previewRequested = false
        if changedQuery || (!validResults && !pending) { requestSearch() }
        refreshDecorations()
    }

    func setReplacementVisible(_ visible: Bool) {
        if settings.showsReplacement != visible { pendingResultFocus = nil }
        if !visible && document.window.firstResponder === replaceInput.input {
            document.window.makeFirstResponder(findInput.input)
        }
        settings.showsReplacement = visible
        updateReplacementVisibility()
        if let selected { selectRow(selected, reveal: false, preview: visible && previewRequested) }
        refreshVisibleRows()
        refreshDecorations()
        updateReplaceAvailability()
    }

    private func updateReplacementVisibility() {
        replaceToggle.image = NSImage(systemSymbolName: settings.showsReplacement ? "chevron.down" : "chevron.right",
                                      accessibilityDescription: nil)
        replaceRow.isHidden = !settings.showsReplacement
    }

    @objc private func toggleReplaceSection(_ sender: Any?) { perform(.toggleReplace) }
    @objc private func replaceAllMatches(_ sender: Any?) { perform(.replaceAll) }
    func searchWhenShown() {
        if !validResults && !pending { requestSearch() }
    }

    func cancelPendingFocus() { pendingResultFocus = nil }

    func clearTransientFocus() {
        pendingResultFocus = nil
        previewRequested = false
    }

    func switchedAway() {
        clearTransientFocus()
        queuedDirection = nil
        requestSearchIfNeeded()
    }

    @objc private func changeOptions(_ sender: Any?) {
        settings.options = FindOptions(caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on,
                                       regularExpression: regex.state == .on)
        updateSearchOptionsAppearance()
        resetMatches()
    }

    private func updateSearchOptionsAppearance() {
        for option in [matchCase, wholeWord, regex] {
            option.contentTintColor = option.state == .on ? .controlAccentColor : nil
        }
    }

    private func queryChanged() {
        settings.query = findInput.value
        resetMatches()
    }

    private func resetMatches() {
        dismissed.removeAll()
        queuedDirection = nil
        pendingResultFocus = nil
        advanceFrom = nil
        selected = nil
        selectedMatchLocation = nil
        previewRequested = false
        requestSearch()
    }

    private func requestSearchIfNeeded() {
        if searchVisible || queuedDirection != nil {
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
        let ranges = document.editor.focusRanges
        let worker = Task.detached(priority: .userInitiated) {
            FindSearch.match(query, in: snapshot, options: options, ranges: ranges)
        }
        work = worker
        activity = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, generation == searchGeneration, pending else { return }
            resultHeader.detailText = "Searching…"
        }
        Task { [weak self] in
            let outcome = await worker.value
            guard let self, generation == searchGeneration, ranges == document.editor.focusRanges else { return }
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
        let previousLocation = selectedMatchLocation
        baseMatches = found
        matches = found.filter { !dismissed.contains($0.range) }
        validResults = !invalid && !settings.query.isEmpty
        let target = previousLocation.flatMap { location in
            matches.firstIndex { $0.range.location >= location } ?? matches.indices.first
        }
        let focusedResults = document.window.firstResponder === results
        selected = nil
        selectedMatchLocation = nil
        editingResults = true
        results.reloadData()
        results.deselectAll(nil)
        editingResults = false
        resultHeader.detailText = invalid ? "Invalid regex" : matches.isEmpty ? "No results"
            : matches.count == 1 ? "1 match" : "\(matches.count) matches"
        updateReplaceAvailability()
        if let advanceFrom {
            self.advanceFrom = nil
            if searchVisible, let next = matches.firstIndex(where: { $0.range.location >= advanceFrom }) {
                selectRow(next, reveal: true, preview: true)
            } else if searchVisible && document.window.firstResponder === results {
                document.window.makeFirstResponder(findInput.input)
            }
        } else if let queuedDirection {
            self.queuedDirection = nil
            moveResult(by: queuedDirection)
        } else if let target {
            selectRow(target, reveal: focusedResults, preview: previewRequested)
        } else {
            previewRequested = false
            if focusedResults { document.window.makeFirstResponder(findInput.input) }
        }
        if let input = pendingResultFocus {
            pendingResultFocus = nil
            if document.window.firstResponder === input { focusFirstResult() }
        }
        refreshDecorations()
        refreshVisibleRows()
    }

    private func moveResult(by direction: Int) {
        pendingResultFocus = nil
        guard !settings.query.isEmpty else { return }
        guard validResults else {
            if pending {
                queuedDirection = direction
            } else if resultHeader.detailText != "Invalid regex" {
                queuedDirection = direction
                requestSearch()
            }
            return
        }
        guard !matches.isEmpty else { return }
        let base = selected ?? (direction > 0 ? -1 : 0)
        let responder = document.window.firstResponder as? NSView
        selectRow((base + direction + matches.count) % matches.count, reveal: true,
                  preview: searchVisible && responder?.isDescendant(of: view) == true)
    }

    private func advanceFindFocus() {
        if settings.showsReplacement {
            document.window.makeFirstResponder(replaceInput.input)
        } else {
            focusFirstResult()
        }
    }

    private func focusFirstResult() {
        guard searchVisible else { return }
        let window = document.window
        if pending || bufferSearchScheduled {
            queuedDirection = nil
            pendingResultFocus = window.firstResponder as? FindFieldTextView
            return
        }
        guard validResults, !matches.isEmpty, window.makeFirstResponder(results) else { return }
        selectRow(0, reveal: true, preview: true)
    }

    private func selectRow(_ index: Int?, reveal: Bool, preview: Bool) {
        if let index {
            guard validResults, matches.indices.contains(index) else { return }
        }
        let previous = selected
        selected = index
        selectedMatchLocation = index.map { matches[$0].range.location }
        previewRequested = index != nil && preview && settings.showsReplacement && searchVisible
        if results.selectedRow != (index ?? -1) {
            editingResults = true
            if let index {
                results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                results.deselectAll(nil)
            }
            editingResults = false
        }
        updateRowSelection(previous)
        if previous != index { updateRowSelection(index) }
        if reveal, let index {
            results.scrollRowToVisible(index)
            document.editor.scrollRangeToVisible(matches[index].range)
        }
        refreshDecorations()
    }

    private func clearResultFocus() {
        selectRow(nil, reveal: false, preview: false)
        document.window.makeFirstResponder(findInput.input)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        validResults
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !editingResults else { return }
        let row = results.selectedRow
        selectRow(row >= 0 ? row : nil, reveal: true, preview: true)
    }

    @objc private func openClickedResult(_ sender: NSTableView) {
        openResult(at: sender.clickedRow)
    }

    private func openResult(at row: Int) {
        guard validResults, matches.indices.contains(row) else { return }
        selectRow(row, reveal: false, preview: false)
        let caret = NSRange(location: NSMaxRange(matches[row].range), length: 0)
        let editor = document.editor
        guard document.window.makeFirstResponder(editor) else { return }
        editor.setCaretSelections([caret])
        editor.scrollRangeToVisible(caret)
    }

    private func activateResult() {
        guard validResults, let selected, matches.indices.contains(selected) else { return }
        if settings.showsReplacement {
            apply([matches[selected]], advance: true)
        } else {
            openResult(at: selected)
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
        guard validResults, searchVisible, settings.showsReplacement,
              document.editor.isEditable, !document.editor.hasMarkedText(),
              let first = hits.first, let last = hits.last, document.editor.string == resultSnapshot else { return }
        let source = resultSnapshot as NSString
        let edits = hits.compactMap { hit -> EditorTextEdit? in
            let text = hit.replacement(using: settings.replacement, in: source, isRegex: settings.options.regularExpression)
            guard text != source.substring(with: hit.range) else { return nil }
            return EditorTextEdit(range: hit.range, text: text)
        }
        guard !edits.isEmpty else {
            publish(baseMatches)
            return
        }
        advanceFrom = advance ? EditorTextEdit.moving(NSMaxRange(first.range), through: edits) : nil
        let end = EditorTextEdit.moving(NSMaxRange(last.range), through: edits)
        decorations.clearPreview()
        applyingEdits = true
        let changed = document.editor.replaceFoundText(edits, caret: end)
        applyingEdits = false
        if changed {
            document.requestAutosave()
        } else {
            advanceFrom = nil
        }
    }

    private func updateReplaceAvailability() { replaceButton.isEnabled = canPerform(.replaceAll) }

    func refreshDecorations() {
        let hit = validResults ? selected.map { matches[$0] } : nil
        let preview = previewRequested && searchVisible && settings.showsReplacement
            ? hit.map { ($0.range, $0.replacement(using: settings.replacement, in: resultSnapshot as NSString,
                                                  isRegex: settings.options.regularExpression)) }
            : nil
        decorations.update(snapshot: resultSnapshot, ranges: searchVisible && validResults ? matches.map(\.range) : [],
                           selected: hit?.range, preview: preview)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("FindResultRow")
        if let row = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultRow { return row }
        let view = SidebarResultRow()
        view.identifier = identifier
        return view
    }

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
        let text = SidebarResults.excerpt(of: resultSnapshot as NSString, match: range, scope: matches[row].scope)
        cell.configure(text: text, replacementAvailable: settings.showsReplacement,
                       acceptsActions: validResults, selected: selected == row,
                       apply: { [weak self] in
                           guard let self, let match = matches.first(where: { $0.range == range }) else { return }
                           apply([match], advance: true)
                       },
                       dismiss: { [weak self] in self?.dismiss(range) })
        results.configureHover(for: cell, row: row)
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
}
