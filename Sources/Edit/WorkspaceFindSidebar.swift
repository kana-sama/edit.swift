import AppKit
import CoreServices

@MainActor
final class WorkspaceFindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Match: Hashable {
        let file: URL
        let range: NSRange
    }

    private struct Navigation {
        let match: Match
        let focusEditor: Bool
        let previewReplace: Bool
    }

    private struct Dismissed {
        let text: String
        var ranges: Set<NSRange>
    }

    private struct Terms: Equatable {
        let query: String
        let options: FindOptions
    }

    private typealias Row = SidebarGroupedResultRow<Match>
    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private let onReturnFocus: () -> Void
    private let focusFind: () -> Void
    private let availabilityChanged: () -> Void
    private let ignore = NSButton()
    private let include = FindInput(name: "Files to include", singleLine: true)
    private lazy var exclude = FindInput(name: "Files to exclude", options: [ignore], singleLine: true)
    private let table = WorkspaceFindTable()
    private let scroll = SidebarActionResultScrollView()
    private let status = NSTextField(labelWithString: "")
    let resultView = NSStackView()
    var filterViews: [NSView] { [include, exclude] }
    var includeInput: NSView { include.input }
    var excludeInput: NSView { exclude.input }
    var resultResponder: NSView { table }
    var hasResultPresentation: Bool {
        (terms == currentTerms && (valid || queryError != nil)) || (!rows.isEmpty && !scroll.isHidden)
    }

    private var root: URL?
    private var filters = WorkspaceFindFilters()
    private var terms: Terms?
    private var files: [WorkspaceFindSearch.File] = []
    private var filesByPath: [String: WorkspaceFindSearch.File] = [:]
    private var matches: [Match] = []
    private var rows: [Row] = []
    private var collapsed: Set<URL> = []
    private var dismissed: [URL: Dismissed] = [:]
    private var selected: Match?
    private var navigation: Navigation?
    private var presented: Match?
    private var showsPreview = false
    private var activatingSelection = false
    private var editingRows = false
    private var valid = false
    private var dirty = true
    private var limited = false
    private var running = false
    private var queryError: String?
    private var operationError: String?
    private var search: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    private var repositoryLookup: Task<Void, Never>?
    private var fileEvents: FileSystemEvents?
    private var opening: Task<Void, Never>?
    private weak var pendingFocus: NSResponder?
    private var queuedStep: Int?
    private var undo: [[WorkspaceFindReplacement.Change]] = []
    private var redo: [[WorkspaceFindReplacement.Change]] = []
    private var visible: Bool { document.findScope == .workspace && document.isSearchSidebarVisible }
    private var currentTerms: Terms { Terms(query: document.findSettings.query, options: document.findSettings.options) }

    init(document: DocumentWindow, app: Edit, onReturnFocus: @escaping () -> Void,
         focusFind: @escaping () -> Void, availabilityChanged: @escaping () -> Void) {
        self.document = document
        self.app = app
        self.onReturnFocus = onReturnFocus
        self.focusFind = focusFind
        self.availabilityChanged = availabilityChanged
        super.init()
        configure()
    }

    deinit {
        search?.cancel()
        settle?.cancel()
        repositoryLookup?.cancel()
        opening?.cancel()
    }

    private func configure() {
        ignore.setButtonType(.pushOnPushOff)
        ignore.bezelStyle = .accessoryBar
        ignore.controlSize = .small
        ignore.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
        ignore.imagePosition = .imageOnly
        ignore.toolTip = "Respect .gitignore"
        ignore.setAccessibilityLabel("Respect .gitignore")
        ignore.target = self
        ignore.action = #selector(changeIgnore)
        ignore.isHidden = true
        for field in [include, exclude] {
            field.input.toolTip = "Enter workspace-relative paths or glob patterns separated by commas."
            field.onReturn = { [weak self] in self?.focusFirstResult() }
            field.onEscape = { [weak self] in self?.onReturnFocus() }
        }
        include.onChange = { [weak self] in self?.filterEdited(include: true) }
        exclude.onChange = { [weak self] in self?.filterEdited(include: false) }

        table.install(in: scroll, column: .init("WorkspaceFindResult"), accessibilityLabel: "Workspace Search Results")
        table.dataSource = self
        table.delegate = self
        table.isFileHeader = { [weak self] row in
            if case .file = self?.row(at: row) { return true }
            return false
        }
        table.onClickGroup = { [weak self] row in
            guard let self, valid, case .folder(let folder, _, _) = self.row(at: row) else { return false }
            table.window?.makeFirstResponder(table)
            toggle(folder)
            return true
        }
        table.onHorizontalNavigation = { [weak self] expand in
            guard let self, valid, case .folder(let folder, _, _) = row(at: table.selectedRow) else { return false }
            if collapsed.contains(folder) == expand { toggle(folder) }
            return true
        }
        table.onClickSelectedRow = { [weak self] row in
            guard let self, let match = match(at: row) else { return }
            reveal(match, focusEditor: false)
        }
        table.onDoubleClickResult = { [weak self] row in
            guard let self, let match = match(at: row) else { return }
            reveal(match, focusEditor: true)
        }
        table.onReturn = { [weak self] in self?.activate(replace: true) }
        table.onSpace = { [weak self] in self?.activate(replace: false) }
        table.onEscape = { [weak self] in self?.clearSelection() }
        table.canUndoChanges = { [weak self] isRedo in
            guard let self, !running else { return false }
            return !(isRedo ? redo : undo).isEmpty
        }
        table.onUndoChanges = { [weak self] isRedo in self?.undoChanges(redoing: isRedo) }

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        status.heightAnchor.constraint(equalToConstant: SidebarResults.rowHeight).isActive = true
        resultView.orientation = .vertical
        resultView.alignment = .centerX
        resultView.spacing = 0
        resultView.addArrangedSubview(status)
        resultView.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: resultView.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: resultView.widthAnchor, constant: -2 * SidebarResults.panelInset).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func setRoot(_ folder: URL?) {
        guard folder?.path != root?.path else { return }
        root = folder
        cancelSearch()
        fileEvents = nil
        suspendNavigation()
        repositoryLookup?.cancel()
        repositoryLookup = nil
        ignore.isHidden = true
        dismissed.removeAll()
        collapsed.removeAll()
        undo.removeAll()
        redo.removeAll()
        selected = nil
        presented = nil
        terms = nil
        files = []
        filesByPath = [:]
        valid = false
        dirty = true
        limited = false
        queryError = nil
        operationError = nil
        scroll.isHidden = false
        rebuildRows()
        guard let folder else { return }
        syncFilters()
        repositoryLookup = Task { [weak self] in
            let lookup = Task.detached { WorkspaceFindSearch.Repository.containing(folder) }
            let repository = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
            guard let self, !Task.isCancelled, root?.path == folder.path else { return }
            ignore.isHidden = repository == nil
        }
    }

    func syncFilters() {
        guard let root else { return }
        let latest = app.workspaceFindPreferences[root]
        if filters != latest {
            cancelSearch()
            dirty = true
            valid = false
            dismissed.removeAll()
        }
        filters = latest
        include.value = filters.include
        exclude.value = filters.exclude
        ignore.state = filters.respectsIgnoreFiles ? .on : .off
        ignore.contentTintColor = filters.respectsIgnoreFiles ? .controlAccentColor : nil
    }

    func findIn(_ directory: URL) {
        guard let root else { return }
        let path = WorktreeFileOperations.path(directory)
        let rootPath = WorktreeFileOperations.path(root)
        guard let relative = DocumentWindow.worktreePathSuffix(from: root, to: directory),
              path == rootPath || !relative.isEmpty else { return }
        syncFilters()
        var updated = filters
        updated.include = relative.isEmpty ? "" : WorkspaceFindGlob.folder(relative)
        guard updated != filters else { return }
        app.workspaceFindPreferences[root] = updated
        syncFilters()
        invalidate(resetDismissals: true)
    }

    private func filterEdited(include updatingInclude: Bool) {
        guard let root else { return }
        var latest = app.workspaceFindPreferences[root]
        if updatingInclude { latest.include = include.value }
        else { latest.exclude = exclude.value }
        filters = latest
        app.workspaceFindPreferences[root] = filters
        invalidate(resetDismissals: true, after: .milliseconds(65))
    }

    @objc private func changeIgnore() {
        guard let root else { return }
        filters = app.workspaceFindPreferences[root]
        filters.respectsIgnoreFiles = ignore.state == .on
        app.workspaceFindPreferences[root] = filters
        ignore.contentTintColor = filters.respectsIgnoreFiles ? .controlAccentColor : nil
        invalidate(resetDismissals: true)
    }

    func invalidate(resetDismissals: Bool = false, after delay: Duration = .zero) {
        if resetDismissals {
            dismissed.removeAll()
            selected = nil
            pendingFocus = nil
            queuedStep = nil
            operationError = nil
        }
        dirty = true
        valid = false
        if visible && !running { requestSearch(after: delay) }
        else { cancelSearch() }
    }

    func searchWhenShown() {
        syncFilters()
        if terms != currentTerms { dirty = true }
        if dirty && !running && search == nil { requestSearch() }
        else { refreshDecorations() }
    }

    private func cancelSearch() {
        search?.cancel()
        search = nil
        settle?.cancel()
        settle = nil
        pendingFocus = nil
        queuedStep = nil
    }

    private func requestSearch(after delay: Duration = .zero) {
        guard let root else { return }
        search?.cancel()
        suspendNavigation()
        dirty = false
        valid = false
        queryError = nil
        availabilityChanged()
        let terms = currentTerms
        if self.terms != terms {
            dismissed.removeAll()
            selected = nil
            presented = nil
            operationError = nil
            self.terms = terms
        }
        let filters = self.filters
        if terms.query.isEmpty {
            cancelSearch()
            publish(.matches([], limited: false))
            return
        }
        if fileEvents == nil {
            fileEvents = FileSystemEvents(directory: root) { [weak self] events in
                let content = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
                if events.contains(where: { event in
                    event.requiresRescan || (event.flags & content != 0 && !WorkspaceFindSearch.isMetadataPath(event.path, in: root))
                }) {
                    // Refresh on the next use of the cached search. File events do not reload visible rows.
                    self?.dirty = true
                }
            }
        }
        if rows.isEmpty || scroll.isHidden {
            updateStatus("Searching…")
        } else if settle == nil {
            suspendVisibleRowActions()
            settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(170))
                guard let self, !Task.isCancelled, search != nil else { return }
                scroll.isHidden = true
                updateStatus("Searching…")
                availabilityChanged()
            }
        }
        let snapshots: [String: String]
        if document.hasEditableTextDocument, let file = document.fileURL, WorktreeFileOperations.contains(file, in: root) {
            snapshots = [file.path: document.editor.string]
        } else { snapshots = [:] }
        search = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            let worker = Task.detached(priority: .userInitiated) {
                WorkspaceFindSearch.run(root: root, query: terms.query, options: terms.options, filters: filters,
                                        repository: WorkspaceFindSearch.Repository.containing(root), openText: snapshots)
            }
            let outcome = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            #if EDIT_AGENT_CHECKS
            await document.beforePublishingWorkspaceFindForCheck?()
            guard !Task.isCancelled else { return }
            #endif
            search = nil
            settle?.cancel()
            settle = nil
            publish(outcome)
        }
    }

    private func suspendVisibleRowActions() {
        table.enumerateAvailableRowViews { rowView, _ in
            let view = rowView.view(atColumn: 0)
            (view as? SidebarActionResultCell)?.suspendActions()
            (view as? SidebarResultGroupHeader)?.setFileAction(nil)
        }
    }

    private func publish(_ outcome: WorkspaceFindSearch.Outcome) {
        switch outcome {
        case .matches(let files, let limited):
            self.files = files
            filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.url.path, $0) })
            self.limited = limited
            valid = true
        case .invalid(let message):
            files = []
            filesByPath = [:]
            limited = false
            queryError = message
        }
        rebuildRows()
        scroll.isHidden = false
        if let responder = pendingFocus, responder === document.window.firstResponder {
            pendingFocus = nil
            focusFirstResult()
        }
        if let step = queuedStep {
            queuedStep = nil
            move(by: step)
        }
        refreshDecorations()
    }

    func treeModeChanged() { rebuildRows() }

    private func retained(_ file: WorkspaceFindSearch.File) -> [FindHit] {
        guard let dismissed = dismissed[file.url], dismissed.text.utf8.elementsEqual(file.text.utf8) else { return file.hits }
        return file.hits.filter { !dismissed.ranges.contains($0.range) }
    }

    private func rebuildRows() {
        let groups = files.compactMap { file -> (URL, [Match])? in
            let hits = retained(file).map { Match(file: file.url, range: $0.range) }
            return hits.isEmpty ? nil : (file.url, hits)
        }
        matches = groups.flatMap(\.1)
        rows = Row.layout(groups, root: document.sidebar.searchTreeMode ? root : nil, collapsed: collapsed)
        editingRows = true
        table.reloadData()
        if let selected, let row = tableRow(for: selected) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        editingRows = false
        table.refreshHover()
        let message: String?
        if let operationError { message = operationError }
        else if let queryError { message = queryError }
        else if limited { message = "Result limit reached" }
        else if !valid && groups.isEmpty && !document.findSettings.query.isEmpty { message = "Searching…" }
        else if valid && groups.isEmpty && !document.findSettings.query.isEmpty { message = "No results" }
        else { message = nil }
        updateStatus(message)
        availabilityChanged()
    }

    private func updateStatus(_ message: String?) {
        status.stringValue = message?.components(separatedBy: "\n").first ?? ""
        status.toolTip = message
        status.isHidden = message == nil
    }

    private func row(at index: Int) -> Row? { rows.indices.contains(index) ? rows[index] : nil }

    private func match(at row: Int) -> Match? {
        if case .hit(let match, _) = self.row(at: row) { return match }
        return nil
    }

    private func tableRow(for match: Match) -> Int? { rows.indices.first { self.match(at: $0) == match } }

    private func toggle(_ folder: URL) {
        if !collapsed.insert(folder).inserted { collapsed.remove(folder) }
        selected = nil
        suspendNavigation()
        rebuildRows()
        if let row = rows.firstIndex(where: {
            if case .folder(let url, _, _) = $0 { return url == folder }
            return false
        }) {
            editingRows = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editingRows = false
            table.scrollRowToVisible(row)
        }
    }

    func canPerform(_ action: FindCommand) -> Bool {
        switch action {
        case .next, .previous: return queryError == nil && !running && !document.findSettings.query.isEmpty
        case .replaceAll: return visible && valid && !running && !limited && document.findSettings.showsReplacement && !matches.isEmpty
        case .replaceSelected: return visible && selected != nil && canReplaceMatch
        case .dismissSelected: return visible && valid && selected != nil && !running
        case .clearSelection: return visible && selected != nil
        default: return false
        }
    }

    private var canReplaceMatch: Bool { valid && !running && document.findSettings.showsReplacement }

    func perform(_ action: FindCommand) {
        switch action {
        case .next: move(by: 1)
        case .previous: move(by: -1)
        case .replaceAll: replace(matches, confirm: true)
        case .replaceSelected: if let selected { replace([selected]) }
        case .dismissSelected: if let selected { dismiss(selected) }
        case .clearSelection: clearSelection()
        default: break
        }
    }

    func replacementVisibilityChanged() {
        rebuildRows()
        refreshDecorations()
    }

    func focusFirstResult() {
        guard visible else { return }
        guard valid else {
            if search != nil { pendingFocus = document.window.firstResponder }
            return
        }
        guard let first = matches.first else { return }
        document.window.makeFirstResponder(table)
        reveal(first, focusEditor: false)
    }

    private func move(by step: Int) {
        guard !running else { return }
        if !valid || dirty {
            if dirty && search == nil { requestSearch() }
            if search != nil { queuedStep = step }
            return
        }
        guard !matches.isEmpty else { return }
        let start = selected.flatMap { matches.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        let match = matches[(start + step + matches.count) % matches.count]
        reveal(match, focusEditor: !visible, previewReplace: visible)
    }

    private func clearSelection() {
        selected = nil
        suspendNavigation()
        rebuildRows()
        focusFind()
    }

    func cancelPendingFocus() { pendingFocus = nil }

    func suspendNavigation() {
        opening?.cancel()
        opening = nil
        navigation = nil
        showsPreview = false
    }

    func editorInteracted() {
        guard !activatingSelection else { return }
        if showsPreview {
            showsPreview = false
            refreshDecorations()
        }
    }

    func switchedAway() {
        pendingFocus = nil
        queuedStep = nil
        suspendNavigation()
        refreshDecorations()
    }

    func bufferEdited() {
        if running { return }
        if navigation == nil { invalidate(after: .milliseconds(65)) }
    }

    func documentPresented() {
        if let navigation, document.fileURL?.path == navigation.match.file.path {
            install(navigation)
        } else {
            presented = nil
            refreshDecorations()
        }
    }

    private func reveal(_ match: Match, focusEditor: Bool, previewReplace: Bool = true) {
        guard valid, !running, root?.path == document.folderURL?.path, let snapshot = filesByPath[match.file.path]?.text else { return }
        selected = match
        if tableRow(for: match) == nil {
            collapsed = collapsed.filter { !WorktreeFileOperations.contains(match.file, in: $0) }
            rebuildRows()
        }
        if let row = tableRow(for: match) {
            editingRows = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editingRows = false
            table.scrollRowToVisible(row)
        }
        suspendNavigation()
        let destination = Navigation(match: match, focusEditor: focusEditor, previewReplace: previewReplace)
        navigation = destination
        if document.fileURL?.path == match.file.path {
            if document.isShowingMarkdownPreview { document.setMarkdownPreview(false, focus: false) }
            install(destination)
            return
        }
        opening = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    opening = nil
                    if navigation?.match == match { navigation = nil }
                }
            }
            do {
                let opened = try await app.openFile(match.file, in: document, focusEditor: false,
                                                    markdownLink: .init(showsPreview: false, fragment: nil),
                                                    matchingText: snapshot,
                                                    shouldOpen: { [weak self] in
                    guard let self else { return false }
                    return valid && navigation?.match == match && root?.path == document.folderURL?.path
                })
                if !Task.isCancelled, navigation?.match == match {
                    if opened != nil { install(destination) }
                    else { invalidate() }
                }
            } catch {
                if !Task.isCancelled { invalidate() }
            }
        }
    }

    private func install(_ destination: Navigation) {
        guard valid, document.fileURL?.path == destination.match.file.path,
              let file = filesByPath[destination.match.file.path],
              document.editor.string.utf8.elementsEqual(file.text.utf8) else {
            presented = nil
            if !running { invalidate() }
            return
        }
        navigation = nil
        presented = destination.match
        activatingSelection = true
        defer { activatingSelection = false }
        showsPreview = !destination.focusEditor && destination.previewReplace
        refreshDecorations()
        let editor = document.editor
        if destination.focusEditor {
            document.window.makeFirstResponder(editor)
            editor.setCaretSelections([NSRange(location: NSMaxRange(destination.match.range), length: 0)])
        }
        editor.scrollRangeToVisible(destination.match.range)
    }

    func refreshDecorations() {
        guard document.findScope == .workspace,
              !document.isSidebarVisible || document.sidebarMode != .references else { return }
        let decorations = document.resultDecorations
        // Keep the current buffer's matching highlights until the workspace snapshot arrives.
        if visible && !valid && (search != nil || dirty) { return }
        guard let url = document.fileURL, let file = filesByPath[url.path],
              valid, !document.isShowingMarkdownPreview else {
            decorations.update(snapshot: "", ranges: [], selected: nil, preview: nil)
            return
        }
        let hits = retained(file)
        let active = presented.flatMap { $0.file == file.url ? $0.range : nil }
        let preview = showsPreview && visible && document.findSettings.showsReplacement ? active.flatMap { range in
            hits.first(where: { $0.range == range }).map {
                (range, $0.replacement(using: document.findSettings.replacement, in: file.text as NSString,
                                       isRegex: document.findSettings.options.regularExpression))
            }
        } : nil
        decorations.update(snapshot: file.text, ranges: visible ? hits.map(\.range) : [],
                           selected: active, preview: preview)
    }

    private func activate(replace: Bool) {
        guard valid else { return }
        if case .folder(let folder, _, _) = row(at: table.selectedRow) { toggle(folder); return }
        guard let selected else { return }
        if replace && document.findSettings.showsReplacement { self.replace([selected]) }
        else { reveal(selected, focusEditor: true) }
    }

    private func dismiss(_ match: Match) {
        guard valid, let file = filesByPath[match.file.path], let index = matches.firstIndex(of: match) else { return }
        var record = dismissed[match.file] ?? Dismissed(text: file.text, ranges: [])
        if !record.text.utf8.elementsEqual(file.text.utf8) { record = Dismissed(text: file.text, ranges: []) }
        record.ranges.insert(match.range)
        dismissed[match.file] = record
        rebuildRows()
        if !matches.isEmpty { reveal(matches[min(index, matches.count - 1)], focusEditor: false) }
        else { clearSelection(); presented = nil; refreshDecorations() }
    }

    private func replace(_ matches: [Match], confirm: Bool = false) {
        guard visible, canReplaceMatch, !matches.isEmpty, let root, !confirm || !limited else { return }
        let chosen = Dictionary(grouping: matches, by: \.file).mapValues { Set($0.map(\.range)) }
        let inputs = files.compactMap { file -> (WorkspaceFindSearch.File, [FindHit])? in
            guard let ranges = chosen[file.url] else { return nil }
            return (file, retained(file).filter { ranges.contains($0.range) })
        }
        let replacement = document.findSettings.replacement
        let regex = document.findSettings.options.regularExpression
        running = true
        suspendNavigation()
        refreshDecorations()
        rebuildRows()
        Task { [weak self] in
            guard let self else { return }
            if confirm, await !confirmReplacement(matchCount: matches.count, fileCount: inputs.count) {
                finishOperation(in: root, report: nil)
                return
            }
            guard document.folderURL?.path == root.path else {
                finishOperation(in: root, report: nil)
                return
            }
            let changes = await Task.detached(priority: .userInitiated) {
                inputs.compactMap { WorkspaceFindReplacement.Change(file: $0.0, hits: $0.1, replacement: replacement, regex: regex) }
            }.value
            let report = await WorkspaceFindReplacement.apply(changes, in: app, root: root)
            if self.root?.path == root.path, !report.reversed.isEmpty {
                undo.append(report.reversed)
                redo.removeAll()
            }
            finishOperation(in: root, report: report)
        }
    }

    private func undoChanges(redoing: Bool) {
        guard !running, let root, let batch = redoing ? redo.popLast() : undo.popLast() else { return }
        running = true
        suspendNavigation()
        rebuildRows()
        Task { [weak self] in
            guard let self else { return }
            let report = await WorkspaceFindReplacement.apply(batch, in: app, root: root)
            if self.root?.path == root.path, !report.reversed.isEmpty {
                if redoing { undo.append(report.reversed) }
                else { redo.append(report.reversed) }
            }
            finishOperation(in: root, report: report)
        }
    }

    private func finishOperation(in root: URL, report: WorkspaceFindReplacement.Report?) {
        running = false
        guard self.root?.path == root.path else { if visible { searchWhenShown() }; return }
        guard let report else {
            if dirty && visible { requestSearch() }
            else { rebuildRows() }
            return
        }
        operationError = report.failed.isEmpty ? nil : "Could not update \(report.failed.count) file(s)\n" + report.failed.joined(separator: "\n")
        for change in report.reversed {
            let url = change.disk.url
            if let record = dismissed[url], record.text.utf8.elementsEqual(change.updated.utf8) {
                dismissed[url] = Dismissed(text: change.original, ranges: EditorTextEdit.moving(record.ranges, through: change.inverse))
            }
        }
        if visible { document.window.makeFirstResponder(table) }
        invalidate()
    }

    private func confirmReplacement(matchCount: Int, fileCount: Int) async -> Bool {
        #if EDIT_AGENT_CHECKS
        if let confirm = document.confirmWorkspaceReplaceForCheck { return await confirm(matchCount, fileCount) }
        #endif
        guard !app.isAgentCheck, document.window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Replace All in Workspace?"
        let matches = matchCount == 1 ? "1 match" : "\(matchCount) matches"
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        alert.informativeText = "Replace \(matches) in \(files)."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace All").hasDestructiveAction = true
        return await alert.beginSheetModal(for: document.window) == .alertSecondButtonReturn
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        valid && !running && table.isFileHeader?(row) == false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SidebarResults.rowHeight + (row > 0 && match(at: row - 1) != nil && match(at: row) == nil
                                  ? SidebarResults.fileGroupSpacing : 0)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !editingRows, valid else { return }
        if let match = match(at: table.selectedRow) { reveal(match, focusEditor: false) }
        else {
            selected = nil
            suspendNavigation()
            refreshDecorations()
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceFindRow")
        if let row = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultRow { return row }
        let view = SidebarResultRow()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .folder(let url, let count, let depth), .file(let url, let count, let depth):
            let identifier = NSUserInterfaceItemIdentifier("WorkspaceFindGroup")
            let header = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultGroupHeader
                ?? SidebarResultGroupHeader(name: "", detail: "")
            header.identifier = identifier
            if case .folder = rows[row] {
                header.updateFolder(url, expanded: !collapsed.contains(url))
                header.setFileAction(nil)
            } else {
                header.updateFile(url.lastPathComponent, url: url)
                if canReplaceMatch && !limited {
                    header.setFileAction { [weak self] in
                        guard let self else { return }
                        replace(matches.filter { $0.file == url })
                    }
                } else {
                    header.setFileAction(nil)
                }
            }
            header.setIndent(depth)
            header.updateCount(count, accessibilityLabel: count == 1 ? "1 match" : "\(count) matches")
            table.configureHover(for: header, row: row)
            return header
        case .hit(let match, let depth):
            guard let file = filesByPath[match.file.path] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("WorkspaceFindExcerpt")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarActionResultCell
                ?? SidebarActionResultCell(frame: .zero)
            cell.identifier = identifier
            cell.excerptLeading.constant = SidebarResults.excerptLeading + SidebarResults.indentation(at: depth)
            cell.configure(text: SidebarResults.excerpt(of: file.text as NSString, match: match.range),
                           replacementAvailable: document.findSettings.showsReplacement, acceptsActions: valid && !running,
                           selected: table.selectedRow == row,
                           apply: { [weak self] in self?.replace([match]) },
                           dismiss: { [weak self] in self?.dismiss(match) })
            table.configureHover(for: cell, row: row)
            return cell
        }
    }
}
