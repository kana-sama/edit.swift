import AppKit

enum FindCommand {
    case find, findWorkspace, replace, next, previous, toggleSidebar
    case refresh, toggleReplace, toggleCase, toggleWholeWord, toggleRegex
    case replaceAll, replaceSelected, dismissSelected, clearSelection
}

@MainActor
final class FindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let document: DocumentWindow
    private unowned let app: Edit
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
    private let resultHeader = SidebarResultGroupHeader(name: "Untitled", detail: "No results")
    private let results = SidebarActionResultTable()
    private let resultScroll = SidebarActionResultScrollView()
    private let replaceRow = NSStackView()
    private let surface = NSView()
    var view: NSView { surface }
    private let searchContent = NSStackView()
    private lazy var workspace = WorkspaceFindSidebar(document: document, app: app, onReturnFocus: onReturnFocus,
        focusFind: { [weak self] in self?.focusFindInput() },
        availabilityChanged: { [weak self] in
            self?.updateResultVisibility()
            self?.updateReplaceAvailability()
        })
    private let scopePicker = ModeSelector(["Current Buffer", "Workspace"], equalWidths: true)
    private var searchesWorkspace: Bool { document.findScope == .workspace }
    private var decorations: FindDecorations { document.resultDecorations }

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
    private var keepsBufferHighlights = false
    private var keepsBufferResults = false
    private var validResults = false
    private var generation: UInt64 = 0
    private var work: Task<FindSearch.Outcome, Never>?
    private var activity: Task<Void, Never>?
    private var queuedDirection: Int?
    private weak var pendingResultFocus: FindFieldTextView?
    private var advanceFrom: Int?

    init(document: DocumentWindow, app: Edit, onReturnFocus: @escaping () -> Void) {
        self.document = document
        self.app = app
        self.onReturnFocus = onReturnFocus
        bufferSnapshot = document.editor.string
        super.init()
        configure()
        document.editor.onBufferEdit = { [weak self] storage, edits in
            self?.bufferDidEdit(storage, edits: edits)
        }
    }

    deinit {
        work?.cancel()
        activity?.cancel()
    }

    func canPerform(_ action: FindCommand) -> Bool {
        if searchesWorkspace {
            switch action {
            case .find, .findWorkspace, .replace, .toggleSidebar: return false
            case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex: return searchVisible
            default: return workspace.canPerform(action)
            }
        }
        switch action {
        case .find, .findWorkspace, .replace, .toggleSidebar:
            return false
        case .next, .previous:
            return !settings.query.isEmpty
        case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex:
            return searchVisible
        case .replaceAll:
            return !document.isShowingMarkdownPreview && searchVisible && settings.showsReplacement && validResults && !matches.isEmpty &&
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
        if searchesWorkspace {
            switch action {
            case .next, .previous, .replaceAll, .replaceSelected, .dismissSelected, .clearSelection:
                workspace.perform(action)
                return
            default: break
            }
        }
        switch action {
        case .find, .findWorkspace, .replace, .toggleSidebar:
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
        bufferSearchScheduled = false
        validResults = false
        keepsBufferHighlights = false
        if searchesWorkspace {
            updateResultVisibility()
            return
        }
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
            guard let self, bufferSearchScheduled else { return }
            bufferSearchScheduled = false
            workspace.bufferEdited()
            if !searchesWorkspace { requestSearchIfNeeded() }
        }
    }

    func editorInteracted() {
        if searchesWorkspace { workspace.editorInteracted(); return }
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
        }
        matchCase.state = settings.options.caseSensitive ? .on : .off
        wholeWord.state = settings.options.wholeWord ? .on : .off
        regex.state = settings.options.regularExpression ? .on : .off
        updateSearchOptionsAppearance()

        findInput.load(settings.query)
        replaceInput.load(settings.replacement)
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
        scopePicker.setAccessibilityLabel("Search scope")
        scopePicker.onSelect = { [weak self] index in
            _ = self?.selectScope(index == 1 ? .workspace : .buffer)
        }

        let content = searchContent
        for control in [findRow, replaceRow, scopePicker] + workspace.filterViews + [resultHeader, resultScroll, workspace.resultView] {
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
        for control in [findRow, replaceRow, scopePicker] + workspace.filterViews {
            control.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * SidebarResults.panelInset).isActive = true
        }
        resultHeader.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * SidebarResults.rowMargin).isActive = true
        resultScroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        workspace.resultView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        resultScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        workspace.resultView.setContentHuggingPriority(.defaultLow, for: .vertical)
        replaceButton.isEnabled = false
        folderChanged()
    }

    func folderChanged() {
        workspace.setRoot(document.folderURL)
        if document.folderURL == nil { _ = selectScope(.buffer) }
        updateScopeVisibility()
        if searchVisible { searchWhenShown() }
    }

    func documentPresented() { if searchesWorkspace { workspace.documentPresented() } }

    func treeModeChanged() { workspace.treeModeChanged() }

    @discardableResult
    func selectScope(_ scope: FindScope, startsSearch: Bool = true) -> Bool {
        guard scope != document.findScope, scope == .buffer || document.folderURL != nil else { return false }
        if searchesWorkspace {
            workspace.switchedAway()
        } else if previewRequested {
            previewRequested = false
            refreshDecorations()
        }
        if pending {
            generation &+= 1
            work?.cancel()
            activity?.cancel()
            pending = false
        }
        previewRequested = false
        pendingResultFocus = nil
        queuedDirection = nil
        keepsBufferResults = scope == .workspace && !workspace.hasResultPresentation && validResults && !matches.isEmpty
        document.findScope = scope
        updateScopeVisibility()
        if keepsBufferResults { refreshVisibleRows() }
        if startsSearch && searchVisible {
            if searchesWorkspace { workspace.searchWhenShown() }
            else if validResults { refreshDecorations() }
            else { requestSearch(keepingHighlights: true) }
        }
        return true
    }

    func openWorkspace(in directory: URL?, reveal: (NSView, Bool) -> Void) {
        _ = selectScope(.workspace, startsSearch: false)
        if let directory { workspace.findIn(directory) }
        openField(replace: false, seedSelection: directory == nil, reveal: reveal)
    }

    private func updateScopeVisibility() {
        scopePicker.isHidden = document.folderURL == nil
        scopePicker.setSelection(searchesWorkspace ? 1 : 0)
        searchContent.setCustomSpacing(scopePicker.isHidden ? 10 : 5, after: replaceRow)
        for field in workspace.filterViews { field.isHidden = !searchesWorkspace }
        updateResultVisibility()
        updateKeyOrder()
        updateReplaceAvailability()
    }

    private func updateResultVisibility() {
        if workspace.hasResultPresentation || !validResults { keepsBufferResults = false }
        let showsWorkspaceResults = searchesWorkspace && !keepsBufferResults
        resultHeader.isHidden = showsWorkspaceResults
        resultScroll.isHidden = showsWorkspaceResults
        let changed = workspace.resultView.isHidden == showsWorkspaceResults
        workspace.resultView.isHidden = !showsWorkspaceResults
        if changed {
            updateKeyOrder()
            refreshVisibleRows()
        }
    }

    private func updateKeyOrder() {
        if searchesWorkspace {
            let views = [findInput.input] + (settings.showsReplacement ? [replaceInput.input] : []) +
                [scopePicker, workspace.includeInput, workspace.excludeInput] +
                (workspace.resultView.isHidden ? [] : [workspace.resultResponder])
            for (view, next) in zip(views, views.dropFirst()) { view.nextKeyView = next }
            views.last?.nextKeyView = views.first
        } else if document.folderURL != nil {
            findInput.input.nextKeyView = settings.showsReplacement ? replaceInput.input : scopePicker
            replaceInput.input.nextKeyView = scopePicker
            scopePicker.nextKeyView = results
            results.nextKeyView = findInput.input
        } else {
            findInput.input.nextKeyView = nil
            replaceInput.input.nextKeyView = nil
            results.nextKeyView = nil
            document.window.recalculateKeyViewLoop()
        }
    }

    private func focusFindInput() { document.window.makeFirstResponder(findInput.input) }

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
        results.install(in: resultScroll, column: .init("SearchResult"), accessibilityLabel: "Search Results")
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.doubleAction = #selector(openClickedResult(_:))
        results.onClickSelectedRow = { [weak self] row in
            guard let self, !searchesWorkspace, settings.showsReplacement, !previewRequested else { return }
            selectRow(row, reveal: true, preview: true)
        }
        results.onReturn = { [weak self] in self?.activateResult() }
        results.onSpace = { [weak self] in
            guard let self, let selected else { return }
            openResult(at: selected)
        }
        results.onEscape = { [weak self] in self?.clearResultFocus() }
    }

    func openField(replace: Bool, seedSelection: Bool = true, reveal: (NSView, Bool) -> Void) {
        document.requestAutosave()
        let seed = seedSelection ? selectedEditorText() : nil
        let field = replace ? replaceInput.input : findInput.input
        reveal(field, replace)
        if let seed {
            let query = settings.options.regularExpression ? NSRegularExpression.escapedPattern(for: seed) : seed
            findInput.input.replaceAllTextUndoably(with: query)
        }
        field.breakUndoCoalescing()
        field.selectAll(nil)
        if !searchesWorkspace { previewRequested = false }
        searchWhenShown()
        if !searchesWorkspace { refreshDecorations() }
    }

    private func selectedEditorText() -> String? {
        let editor = document.editor
        guard document.window.firstResponder === editor else { return nil }
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }
        guard let ranges = editor.focusRanges else { return text.substring(with: selection) }
        let visible = ranges.map { NSIntersectionRange($0, selection) }.filter { $0.length > 0 }
        guard !visible.isEmpty else { return nil }
        return visible.map { text.substring(with: $0) }.joined(separator: editor.preferredLineEnding)
    }

    func setReplacementVisible(_ visible: Bool) {
        let changed = settings.showsReplacement != visible
        if changed { pendingResultFocus = nil }
        if !visible && document.window.firstResponder === replaceInput.input {
            document.window.makeFirstResponder(findInput.input)
        }
        settings.showsReplacement = visible
        updateReplacementVisibility()
        if changed { workspace.replacementVisibilityChanged() }
        if searchesWorkspace { return }
        if let selected { selectRow(selected, reveal: false, preview: visible && previewRequested) }
        refreshVisibleRows()
        refreshDecorations()
        updateReplaceAvailability()
    }

    private func updateReplacementVisibility() {
        replaceToggle.image = NSImage(systemSymbolName: settings.showsReplacement ? "chevron.down" : "chevron.right",
                                      accessibilityDescription: nil)
        replaceRow.isHidden = !settings.showsReplacement
        updateKeyOrder()
    }

    @objc private func toggleReplaceSection(_ sender: Any?) { perform(.toggleReplace) }
    @objc private func replaceAllMatches(_ sender: Any?) { perform(.replaceAll) }
    func searchWhenShown() {
        if searchesWorkspace { workspace.searchWhenShown(); return }
        if !validResults && !pending { requestSearch() }
    }

    func cancelPendingFocus() { pendingResultFocus = nil; if searchesWorkspace { workspace.cancelPendingFocus() } }

    func clearTransientFocus() {
        pendingResultFocus = nil
        previewRequested = false
        if searchesWorkspace { workspace.switchedAway() }
    }

    func switchedAway() {
        clearTransientFocus()
        if searchesWorkspace { return }
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
        resetMatches(after: .milliseconds(65))
    }

    private func resetMatches(after delay: Duration = .zero) {
        resetBufferMatches()
        if searchesWorkspace { workspace.invalidate(resetDismissals: true, after: delay) }
        else { requestSearch() }
    }

    private func resetBufferMatches() {
        validResults = false
        keepsBufferHighlights = false
        dismissed.removeAll()
        queuedDirection = nil
        pendingResultFocus = nil
        advanceFrom = nil
        selected = nil
        selectedMatchLocation = nil
        previewRequested = false
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

    private func requestSearch(keepingHighlights: Bool = false) {
        generation &+= 1
        let searchGeneration = generation
        work?.cancel()
        activity?.cancel()
        validResults = false
        pending = false
        keepsBufferHighlights = keepingHighlights
        updateReplaceAvailability()
        if !document.hasTextDocument || settings.query.isEmpty {
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
        validResults = document.hasTextDocument && !invalid && !settings.query.isEmpty
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
        if invalid || matches.isEmpty {
            resultHeader.detailText = invalid ? "Invalid regex" : "No results"
        } else {
            resultHeader.updateCount(matches.count, accessibilityLabel: matches.count == 1 ? "1 match" : "\(matches.count) matches")
        }
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
        if searchesWorkspace { workspace.focusFirstResult(); return }
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
            if !document.isShowingMarkdownPreview { document.editor.scrollRangeToVisible(matches[index].range) }
        }
        refreshDecorations()
    }

    private func clearResultFocus() {
        selectRow(nil, reveal: false, preview: false)
        document.window.makeFirstResponder(findInput.input)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        validResults && !searchesWorkspace
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !editingResults, !searchesWorkspace else { return }
        let row = results.selectedRow
        selectRow(row >= 0 ? row : nil, reveal: true, preview: true)
    }

    @objc private func openClickedResult(_ sender: NSTableView) {
        openResult(at: sender.clickedRow)
    }

    private func openResult(at row: Int) {
        guard !searchesWorkspace, !document.isShowingMarkdownPreview, validResults, matches.indices.contains(row) else { return }
        selectRow(row, reveal: false, preview: false)
        let caret = NSRange(location: NSMaxRange(matches[row].range), length: 0)
        let editor = document.editor
        guard document.window.makeFirstResponder(editor) else { return }
        editor.setCaretSelections([caret])
        editor.scrollRangeToVisible(caret)
    }

    private func activateResult() {
        guard !searchesWorkspace, validResults, let selected, matches.indices.contains(selected) else { return }
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
        guard !document.isShowingMarkdownPreview, validResults, searchVisible, settings.showsReplacement,
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

    func updateReplaceAvailability() {
        let title = searchesWorkspace ? "Replace All in Workspace" : "Replace All"
        replaceButton.toolTip = title
        replaceButton.setAccessibilityLabel(title)
        replaceButton.isEnabled = canPerform(.replaceAll)
    }

    func refreshDecorations() {
        if searchesWorkspace { workspace.refreshDecorations(); return }
        guard !document.isSidebarVisible || document.sidebarMode != .references else { return }
        if pending && keepsBufferHighlights && searchVisible { return }
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
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarActionResultCell
            ?? SidebarActionResultCell(frame: .zero)
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: SidebarActionResultCell, row: Int) {
        cell.excerptLeading.constant = SidebarResults.excerptLeading
        let range = matches[row].range
        let text = SidebarResults.excerpt(of: resultSnapshot as NSString, match: range, scope: matches[row].scope)
        cell.configure(text: text, replacementAvailable: settings.showsReplacement,
                       acceptsActions: validResults && !searchesWorkspace, selected: selected == row,
                       apply: { [weak self] in
                           guard let self, !searchesWorkspace, let match = matches.first(where: { $0.range == range }) else { return }
                           apply([match], advance: true)
                       },
                       dismiss: { [weak self] in
                           guard let self, !searchesWorkspace else { return }
                           dismiss(range)
                       })
        results.configureHover(for: cell, row: row)
    }

    private func updateRowSelection(_ row: Int?) {
        guard let row, matches.indices.contains(row) else { return }
        (results.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarActionResultCell)?.updateSelection(selected == row)
    }

    private func refreshVisibleRows() {
        let visible = results.rows(in: results.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<min(NSMaxRange(visible), matches.count) {
            if let cell = results.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarActionResultCell {
                configure(cell, row: row)
            }
        }
    }
}
