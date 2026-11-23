import AppKit

@MainActor
final class SourceControlSidebar: NSObject {
    let view: NSView = SourceControlFocusView()
    let graphView = SourceControlGraphView()
    private(set) lazy var fileTree = SidebarFileTree(document: document, app: app, mode: .sourceControl)
    private unowned let document: DocumentWindow
    private unowned let app: Edit

    private let graphToggle = NSButton()
    private let changeToggle = NSButton()
    private let filterButton = NSButton()
    private let workingCopyButton = NSButton()
    private let operationsButton = NSButton()
    private let newButton = NSButton()
    private let actionsButton = NSButton()
    private static let collapsedChevron = disclosureImage("chevron.forward")
    private static let expandedChevron = disclosureImage("chevron.down")
    private let graphMessage = NSTextField(wrappingLabelWithString: "")
    private let graphLimit = NSTextField(labelWithString: "")
    private let detailTitle = NSButton()
    private let detailMetadata = SourceControlRevisionIdentity()
    private let fileCount = NSTextField(labelWithString: "")
    private let fileHeading = NSTextField(labelWithString: "Changed Files")
    private let fileMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var descriptionPopover = SourceControlDescriptionPopover(anchor: detailTitle) { [weak self] in self?.saveDescription($0) }
    private lazy var filter = SourceControlFilterPopover(anchor: filterButton,
        onScopeChange: { [weak self] in self?.setScope($0) },
        onQueryChange: { [weak self] in self?.setQuery($0) })
    private lazy var operations = SourceControlOperationPopover(
        anchor: operationsButton,
        prepare: { [weak self] direction in
            guard let self else { throw PanelError.noWorkspace }
            return try await preview(direction)
        },
        apply: { [weak self] preview in try await self?.apply(preview) ?? false }
    )

    private var folder: URL?
    private var workspace: JJWorkspace?
    private var active = false
    private var subscription: JJChangeMonitor.Subscription?
    private var discovery: Task<Void, Never>?
    private var graphRequest: Task<Void, Never>?
    private var detailRequest: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var busy = false
    private var stale = false
    private var scope: JJSourceControlScope = .log
    private var lastSuccessfulScope: JJSourceControlScope = .log
    private var includeWorkingCopy = false
    private var revealWorkingCopy = false
    private var query = ""
    private(set) var graph: JJSourceControlGraph?
    private(set) var selection: JJSourceControlRevision?
    private(set) var detail: JJSourceControlDetail?
    private var displayedFiles: [JJSourceControlFile] = []
    private var hasPresentedGraph = false
    private let graphBody = NSView()
    private let changeBody = NSView()
    private lazy var panes = SourceControlPanes(
        graphHeader: makeHeader(graphToggle, actions: [filterButton, workingCopyButton, operationsButton, newButton]),
        graph: graphBody, changeHeader: makeHeader(changeToggle, actions: [actionsButton]), change: changeBody
    )

    var focusResponder: NSView {
        graphView.table.isEnabled && !graphView.table.isHiddenOrHasHiddenAncestor ? graphView.table : view
    }

    private enum PanelError: LocalizedError {
        case noWorkspace
        var errorDescription: String? { "Open a Jujutsu workspace to use this sidebar." }
    }

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        super.init()
        configure()
        updateControls()
    }

    isolated deinit {
        discovery?.cancel()
        graphRequest?.cancel()
        detailRequest?.cancel()
        expiry?.cancel()
        if let subscription { app.jjChanges.unsubscribe(subscription) }
    }

    func update(folder: URL?) {
        guard folder != self.folder else { return }
        self.folder = folder
        stopObserving()
        workspace = nil
        graph = nil
        lastSuccessfulScope = .log
        hasPresentedGraph = false
        selection = nil
        detail = nil
        displayedFiles = []
        graphView.install([], selected: nil)
        fileTree.clearSourceControl()
        renderDetail()
        if active { discover() }
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        fileTree.setActive(active)
        if active {
            if let workspace { observe(workspace) } else { discover() }
        } else {
            stopObserving()
        }
    }

    func refresh() {
        guard active else { return }
        if workspace == nil { discover() } else { requestGraph() }
    }

    private func stopObserving() {
        discovery?.cancel()
        discovery = nil
        graphRequest?.cancel()
        graphRequest = nil
        detailRequest?.cancel()
        detailRequest = nil
        expiry?.cancel()
        expiry = nil
        app.jjChanges.unsubscribe(subscription)
        subscription = nil
        operations.close()
        filter.close()
        descriptionPopover.close()
    }

    private func discover() {
        guard discovery == nil else { return }
        guard let folder else {
            showGraphMessage("Open a folder in a Jujutsu workspace.")
            updateControls()
            return
        }
        guard JJRepository.executable != nil else {
            showGraphMessage("Jujutsu is unavailable. Install a compatible jj executable to show changes.")
            updateControls()
            return
        }
        showGraphMessage("Loading changes…")
        discovery = Task { [weak self] in
            let found = await JJRepository.discover(at: folder)
            guard let self, !Task.isCancelled, active, self.folder == folder else { return }
            discovery = nil
            workspace = found
            if let found { observe(found) }
            else {
                showGraphMessage("No usable Jujutsu workspace was found for this folder.")
                updateControls()
            }
        }
    }

    private func observe(_ workspace: JJWorkspace) {
        subscription = app.jjChanges.subscribe(to: workspace, liveSnapshots: true) { [weak self] contents in
            guard let self, active else { return }
            if let contents {
                guard contents.repository.operationID != graph?.operationID else { return }
                operations.invalidate()
                requestGraph()
            } else if graph != nil {
                operations.invalidate()
                requestGraph()
            }
        }
        if graphRequest == nil { requestGraph() }
    }

    private func requestGraph() {
        guard active, let workspace else { return }
        graphRequest?.cancel()
        detailRequest?.cancel()
        stale = true
        if graph == nil { showGraphMessage("Loading changes…") }
        updateControls()
        if expiry == nil {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, !Task.isCancelled, stale else { return }
                showGraphMessage("Updating changes…")
                fileMessage.stringValue = "Updating changed files…"
                fileMessage.isHidden = false
                fileTree.view.isHidden = true
            }
        }
        let scope = scope
        let includeWorkingCopy = includeWorkingCopy
        graphRequest = Task { [weak self] in
            do {
                let result = try await JJSourceControlRepository.graph(in: workspace, scope: scope, includeWorkingCopy: includeWorkingCopy)
                guard let self, !Task.isCancelled, active, self.workspace == workspace else { return }
                filter.setError(nil)
                publish(result, scope: scope)
            } catch {
                guard let self, !Task.isCancelled, active, self.workspace == workspace else { return }
                if case .revset = scope {
                    let current = try? await JJRepository.operation(in: workspace)
                    guard !Task.isCancelled else { return }
                    filter.setError(error.localizedDescription)
                    if let graph, current == graph.operationID {
                        finishGraphRequest()
                        displayGraph(forceDetail: false)
                        return
                    }
                    let fallback = lastSuccessfulScope == scope ? .log : lastSuccessfulScope
                    if let result = try? await JJSourceControlRepository.graph(in: workspace, scope: fallback, includeWorkingCopy: includeWorkingCopy) {
                        guard !Task.isCancelled else { return }
                        publish(result, scope: fallback)
                        return
                    }
                    guard !Task.isCancelled else { return }
                }
                finishGraphRequest()
                graph = nil
                selection = nil
                detail = nil
                displayedFiles = []
                graphView.install([], selected: nil)
                fileTree.clearSourceControl()
                renderDetail()
                showGraphMessage(error.localizedDescription)
                updateControls()
            }
        }
    }

    private func finishGraphRequest() {
        graphRequest = nil
        expiry?.cancel()
        expiry = nil
        stale = false
    }

    private func publish(_ result: JJSourceControlGraph, scope: JJSourceControlScope) {
        finishGraphRequest()
        let changedOperation = graph?.operationID != result.operationID
        graph = result
        lastSuccessfulScope = scope
        switch scope {
        case .log: filterButton.title = "Log"
        case .stack: filterButton.title = "Stack"
        case .revset: filterButton.title = "Revset"
        }
        if changedOperation { operations.invalidate() }
        displayGraph(forceDetail: changedOperation)
    }

    private func displayGraph(forceDetail: Bool) {
        guard let graph else { return }
        let rows = filtered(graph.revisions)
        graphLimit.isHidden = !graph.isTruncated || rows.isEmpty
        graphLimit.stringValue = "Showing the first \(graph.revisions.count) changes"
        let old = selection
        let next = if revealWorkingCopy {
            rows.first { $0.id == graph.workingCopy.id }
        } else {
            rows.first { $0.id == old?.id } ??
                rows.filter { $0.changeID == old?.changeID }.only ??
                rows.first { $0.id == graph.workingCopy.id } ?? rows.first
        }
        selection = next
        graphView.install(rows, selected: next?.id)
        if rows.isEmpty { showGraphMessage("No matching changes") }
        else {
            showGraphMessage(nil)
            if revealWorkingCopy || !hasPresentedGraph { graphView.select(next?.id, revealing: true) }
        }
        hasPresentedGraph = true
        revealWorkingCopy = false
        if next?.id != old?.id || forceDetail || detail == nil {
            requestDetail(keepingFiles: next?.changeID == old?.changeID && !fileTree.view.isHidden)
        }
        else { renderDetail() }
        updateControls()
    }

    private func filtered(_ revisions: [JJSourceControlRevision]) -> [JJSourceControlRevision] {
        guard !query.isEmpty else { return revisions }
        let visible = revisions.filter { revision in
            revision.description.localizedCaseInsensitiveContains(query) || revision.changeID.hasPrefix(query.lowercased()) ||
                revision.bookmarks.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        let ids = Set(visible.map(\.id))
        let source = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0.edges) })
        var elided: [String: [JJSourceControlEdge]] = [:]
        func nearest(_ edge: JJSourceControlEdge) -> [JJSourceControlEdge] {
            guard let target = edge.target, !ids.contains(target) else { return [edge] }
            if let stored = elided[target] { return stored }
            let parents = source[target, default: []]
            var visited: Set<String?> = []
            let crossings = parents.isEmpty ? [.init(target: nil, indirect: true)] : parents.flatMap(nearest)
                .filter { visited.insert($0.target).inserted }.map { JJSourceControlEdge(target: $0.target, indirect: true) }
            elided[target] = crossings
            return crossings
        }
        return visible.map { revision in
            var result = revision
            var targets: Set<String?> = []
            result.edges = revision.edges.flatMap(nearest).sorted { !$0.indirect && $1.indirect }.filter { targets.insert($0.target).inserted }
            return result
        }
    }

    private func choose(_ revision: JJSourceControlRevision) {
        guard !busy, !stale, revision.id != selection?.id else { return }
        selection = revision
        descriptionPopover.close()
        requestDetail()
    }

    private func requestDetail(keepingFiles: Bool = false) {
        detailRequest?.cancel()
        detail = nil
        if !keepingFiles { displayedFiles = [] }
        renderDetail()
        updateControls()
        guard let workspace, let graph, let revision = selection else { return }
        let operation = graph.operationID
        detailRequest = Task { [weak self] in
            do {
                let result = try await JJSourceControlRepository.detail(for: revision, in: workspace, at: operation)
                guard let self, !Task.isCancelled, selection?.id == revision.id, self.graph?.operationID == operation else { return }
                detail = result
                renderDetail()
                updateControls()
            } catch {
                guard let self, !Task.isCancelled else { return }
                displayedFiles = []
                renderFiles()
                fileMessage.stringValue = error.localizedDescription
                fileMessage.isHidden = false
            }
        }
    }

    private func renderDetail() {
        let revision = selection
        detailTitle.title = revision?.subject ?? "Select a change"
        detailTitle.image = revision.flatMap { Self.symbol($0.isImmutable ? "chevron.right" : "pencil", size: 10) }
        detailTitle.toolTip = revision.map { $0.isImmutable ? "View change description" : "Edit change description" }
        if let revision { detailMetadata.update(revision, showsBookmarks: false) }
        detailMetadata.isHidden = revision == nil
        fileHeading.isHidden = revision == nil
        renderFiles()
    }

    func updateLiveFile() {
        guard active, !stale, selection?.isWorkingCopy == true, detail != nil else { return }
        renderFiles()
    }

    private func renderFiles() {
        if let detail, let revision = selection, let workspace, let graph {
            let live = document.jjLiveFileStatus
            if revision.isWorkingCopy, let live, live.workspace == workspace,
               live.operationID == graph.operationID, live.commitID == revision.id {
                displayedFiles = live.applying(to: detail.files)
            } else {
                displayedFiles = detail.files
            }
            fileTree.updateSourceControl(revision: revision, workspace: workspace, operationID: graph.operationID, files: displayedFiles)
        }
        fileCount.stringValue = detail == nil && displayedFiles.isEmpty ? "" : String(displayedFiles.count)
        fileTree.view.isHidden = displayedFiles.isEmpty
        fileMessage.isHidden = selection == nil || !displayedFiles.isEmpty
        fileMessage.stringValue = detail == nil ? "Loading changed files…" : "No changed files"
    }

    private func showGraphMessage(_ text: String?) {
        graphMessage.isHidden = text == nil
        graphMessage.stringValue = text ?? ""
        graphView.view.isHidden = text != nil
        if text != nil { graphLimit.isHidden = true }
    }

    private func updateControls() {
        let canBrowse = active && workspace != nil
        let canAct = canBrowse && graph != nil && !stale && !busy
        filterButton.isEnabled = canBrowse
        operationsButton.isEnabled = canBrowse && !busy
        newButton.isEnabled = canAct
        workingCopyButton.isEnabled = canAct
        actionsButton.isEnabled = canAct && selection != nil
        detailTitle.isEnabled = canAct && selection != nil
        descriptionPopover.update(selection, canMutate: canAct)
        graphView.table.isEnabled = canAct
        fileTree.outline.isEnabled = canAct && detail != nil
        if document.window.firstResponder === view, focusResponder === graphView.table {
            document.window.makeFirstResponder(graphView.table)
        }
    }

    private func preview(_ direction: JJSourceControlOperations.Direction) async throws -> JJSourceControlOperations.Preview {
        guard let workspace else { throw PanelError.noWorkspace }
        return try await JJSourceControlOperations.preview(direction, in: workspace)
    }

    private func apply(_ preview: JJSourceControlOperations.Preview) async throws -> Bool {
        guard !busy, let workspace else { return false }
        busy = true
        updateControls()
        defer {
            busy = false
            updateControls()
            requestGraph()
        }
        return try await document.performSourceControlMutation(in: workspace) {
            try await JJSourceControlOperations.apply(preview, in: workspace)
        }
    }

    private func mutate(_ command: JJSourceControlMutation, selectingWorkingCopy: Bool = false, expectedOperation: String? = nil) async {
        guard !busy, let workspace else { return }
        let document = document
        guard !stale, let operationID = graph?.operationID, expectedOperation == nil || expectedOperation == operationID else {
            await document.showError("The Jujutsu Workspace Changed", detail: "Review the updated change before trying again.")
            return
        }
        busy = true
        updateControls()
        do {
            let ran = try await document.performSourceControlMutation(in: workspace) {
                try await JJSourceControlRepository.mutate(command, in: workspace, expectedOperation: operationID)
            }
            if ran {
                descriptionPopover.close()
                if selectingWorkingCopy {
                    includeWorkingCopy = true
                    revealWorkingCopy = true
                    query = ""
                    filter.setQuery("")
                }
            }
        } catch {
            await document.showError("Could Not Update Jujutsu Workspace", detail: error.localizedDescription)
        }
        busy = false
        updateControls()
        requestGraph()
    }

    private func edit(_ revision: JJSourceControlRevision) async {
        guard !revision.isWorkingCopy, let operation = graph?.operationID else { return }
        if revision.isImmutable {
            if await confirm("Start a new change here?", detail: "“\(revision.subject)” is immutable. Create a child and make it the working copy.", action: "New Change Here") {
                await mutate(.new(revision.id), selectingWorkingCopy: true, expectedOperation: operation)
            }
        } else {
            await mutate(.edit(revision.id), selectingWorkingCopy: true)
        }
    }

    private func confirm(_ title: String, detail: String, action: String, destructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = destructive ? .warning : .informational
        let apply = alert.addButton(withTitle: action)
        apply.hasDestructiveAction = destructive
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        if destructive { apply.keyEquivalent = "" }
        return await alert.beginSheetModal(for: document.window) == .alertFirstButtonReturn
    }

    private func menu(for revision: JJSourceControlRevision) -> NSMenu? {
        guard !stale, !busy else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.representedObject = revision.id
            item.target = self
            item.isEnabled = enabled
        }
        add("Edit Change", #selector(editItem(_:)), enabled: !revision.isImmutable && !revision.isWorkingCopy)
        add("New Change Here", #selector(newHere(_:)))
        add("Describe…", #selector(describe(_:)), enabled: !revision.isImmutable)
        menu.addItem(.separator())
        let parent = graph?.revisions.first { $0.id == revision.parents.first }
        let canSquash = revision.parents.count == 1 && !revision.isImmutable && parent?.isImmutable != true &&
            (detail == nil || detail?.mutableParent != nil)
        add("Squash into Parent", #selector(squash(_:)), enabled: canSquash)
        add("Abandon Change…", #selector(abandon(_:)), enabled: !revision.isImmutable)
        return menu
    }

    private func revision(for item: NSMenuItem) -> JJSourceControlRevision? {
        guard let selection, selection.id == item.representedObject as? String else { return nil }
        return selection
    }

    private func detailsForAction(_ revision: JJSourceControlRevision, operation: String) async -> JJSourceControlDetail? {
        guard let workspace, graph?.operationID == operation else { return nil }
        if selection?.id == revision.id, let detail { return detail }
        do {
            let result = try await JJSourceControlRepository.detail(for: revision, in: workspace, at: operation)
            guard self.workspace == workspace, graph?.operationID == operation else { return nil }
            return result
        } catch {
            await document.showError("Could Not Read Change Details", detail: error.localizedDescription)
            return nil
        }
    }

    @objc private func editItem(_ item: NSMenuItem) {
        guard let revision = revision(for: item) else { return }
        Task { await edit(revision) }
    }

    @objc private func newHere(_ item: NSMenuItem) {
        guard let revision = revision(for: item) else { return }
        Task { await mutate(.new(revision.id), selectingWorkingCopy: true) }
    }

    @objc private func describe(_ item: NSMenuItem) {
        guard revision(for: item) != nil else { return }
        showDescription(item)
    }

    @objc private func showDescription(_ sender: Any?) {
        guard let selection else { return }
        panes.setChangeExpanded(true)
        updateDisclosures()
        view.layoutSubtreeIfNeeded()
        descriptionPopover.show(selection)
    }

    private func saveDescription(_ text: String) {
        guard let selection, let draft = descriptionPopover.draft, selection.changeID == draft.changeID,
              selection.description == draft.description, let operation = graph?.operationID else { return }
        Task { await mutate(.describe(selection.id, text), expectedOperation: operation) }
    }

    @objc private func squash(_ item: NSMenuItem) {
        guard let revision = revision(for: item), let operation = graph?.operationID else { return }
        Task {
            guard let details = await detailsForAction(revision, operation: operation) else { return }
            guard let parent = details.mutableParent else {
                await document.showError("Could Not Squash Change", detail: "Squashing into a parent requires one mutable parent.")
                return
            }
            var description: String?
            if !revision.description.isEmpty, !parent.description.isEmpty {
                description = await combinedDescription(of: revision, and: parent)
                guard description != nil else { return }
            }
            await mutate(.squash(revision.id, description: description), expectedOperation: operation)
        }
    }

    private func combinedDescription(of change: JJSourceControlRevision, and parent: JJSourceControlRevision) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Describe the squashed change"
        alert.informativeText = "“\(change.subject)” will be folded into “\(parent.subject)”."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 116))
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.string = parent.description.trimmingCharacters(in: .newlines) + "\n\n" + change.description
        SourceControlDescriptionPopover.configureEditor(text, in: scroll)
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Squash into Parent")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return await alert.beginSheetModal(for: document.window) == .alertFirstButtonReturn ? text.string : nil
    }

    @objc private func abandon(_ item: NSMenuItem) {
        guard let revision = revision(for: item), let operation = graph?.operationID else { return }
        Task {
            guard let detail = await detailsForAction(revision, operation: operation) else { return }
            var messages = ["“\(revision.subject)” will be removed from the graph."]
            if detail.descendantCount > 0 {
                let names = detail.descendantSubjects.map { "“\($0)”" }.joined(separator: ", ")
                let remaining = detail.descendantCount - detail.descendantSubjects.count
                let suffix = remaining > 0 ? " and \(remaining) more" : ""
                messages.append("Rebase \(names)\(suffix).")
            }
            if !revision.localBookmarks.isEmpty { messages.append("Remove bookmarks \(revision.localBookmarks.joined(separator: ", ")).") }
            if revision.isWorkingCopy { messages.append("Jujutsu will create a new working-copy change.") }
            if await confirm("Abandon this change?", detail: messages.joined(separator: "\n"), action: "Abandon Change", destructive: true) {
                await mutate(.abandon(revision.id), selectingWorkingCopy: revision.isWorkingCopy, expectedOperation: operation)
            }
        }
    }

    @objc private func showActions(_ sender: NSButton) {
        guard let selection, let menu = menu(for: selection) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX - menu.size.width, y: sender.bounds.minY), in: sender)
    }

    @objc private func newChange(_ sender: Any?) {
        guard let working = graph?.workingCopy else { return }
        Task { await mutate(.new(working.id), selectingWorkingCopy: true) }
    }

    private func discard(_ restore: SourceControlFileRestore) async {
        guard active, !busy, !stale, workspace == restore.workspace else { return }
        let document = document
        busy = true
        updateControls()
        do {
            if try await restore.confirmAndDiscard(in: document) { requestGraph() }
        } catch {
            await document.showError("Could Not Discard File Changes", detail: error.localizedDescription)
            requestGraph()
        }
        busy = false
        updateControls()
    }

    @objc private func goToWorkingCopy(_ sender: Any?) {
        guard let graph else { return }
        panes.setGraphExpanded(true)
        updateDisclosures()
        revealWorkingCopy = true
        query = ""
        filter.setQuery("")
        if graph.revisions.contains(where: { $0.id == graph.workingCopy.id }) { displayGraph(forceDetail: false) }
        else {
            includeWorkingCopy = true
            requestGraph()
        }
        document.window.makeFirstResponder(graphView.table)
    }

    @objc private func toggleGraph(_ sender: Any?) {
        panes.setGraphExpanded(!panes.graphExpanded)
        updateDisclosures()
    }

    @objc private func toggleChange(_ sender: Any?) {
        panes.setChangeExpanded(!panes.changeExpanded)
        updateDisclosures()
    }

    private func updateDisclosures() {
        for (button, expanded) in [(graphToggle, panes.graphExpanded), (changeToggle, panes.changeExpanded)] {
            button.image = expanded ? Self.expandedChevron : Self.collapsedChevron
            button.setAccessibilityExpanded(expanded)
            button.setAccessibilityHelp("\(expanded ? "Collapse" : "Expand") \(button.title)")
        }
    }

    @objc private func showOperations(_ sender: Any?) { operations.show() }

    @objc private func showFilter(_ sender: NSButton) { filter.show() }

    private func setScope(_ scope: JJSourceControlScope) {
        self.scope = scope
        includeWorkingCopy = false
        requestGraph()
    }

    private func setQuery(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stale { displayGraph(forceDetail: false) }
    }

    private func configure() {
        configure(graphToggle, title: "Changes", action: #selector(toggleGraph(_:)))
        configure(changeToggle, title: "Change", action: #selector(toggleChange(_:)))
        for button in [graphToggle, changeToggle] {
            button.imagePosition = .imageTrailing
            button.imageHugsTitle = true
            button.alignment = .natural
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = .secondaryLabelColor
        }
        configure(filterButton, title: "Log", action: #selector(showFilter(_:)), symbol: "chevron.down", label: "Filter Changes")
        filterButton.imagePosition = .imageTrailing
        configure(workingCopyButton, title: "@", action: #selector(goToWorkingCopy(_:)), label: "Go to Working Copy")
        configure(operationsButton, action: #selector(showOperations(_:)), symbol: "clock.arrow.circlepath", label: "Repository Operations")
        configure(newButton, action: #selector(newChange(_:)), symbol: "plus", label: "New Change")
        configure(actionsButton, action: #selector(showActions(_:)), symbol: "ellipsis", label: "Change Actions")
        for button in [workingCopyButton, operationsButton, newButton, actionsButton] {
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        configureGraph()
        configureDetail()
        view.addSubview(panes)
        panes.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panes.leadingAnchor.constraint(equalTo: view.leadingAnchor), panes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panes.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), panes.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateDisclosures()
        renderDetail()
    }

    private func configureGraph() {
        graphView.onSelect = { [weak self] in self?.choose($0) }
        graphView.onEdit = { [weak self] revision in Task { await self?.edit(revision) } }
        graphView.menu = { [weak self] in self?.menu(for: $0) }
        graphMessage.textColor = .secondaryLabelColor
        graphMessage.font = .systemFont(ofSize: 12)
        graphLimit.textColor = .secondaryLabelColor
        graphLimit.font = .systemFont(ofSize: 10.5)
        graphLimit.isHidden = true
        let list = NSStackView(views: [graphView.view, graphLimit])
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 0
        list.setHuggingPriority(.defaultLow, for: .vertical)
        for child in [list, graphMessage] {
            graphBody.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: graphBody.leadingAnchor), list.trailingAnchor.constraint(equalTo: graphBody.trailingAnchor),
            list.topAnchor.constraint(equalTo: graphBody.topAnchor), list.bottomAnchor.constraint(equalTo: graphBody.bottomAnchor),
            graphMessage.leadingAnchor.constraint(equalTo: graphBody.leadingAnchor, constant: 12),
            graphMessage.trailingAnchor.constraint(equalTo: graphBody.trailingAnchor, constant: -12),
            graphMessage.topAnchor.constraint(equalTo: graphBody.topAnchor, constant: 8)
        ])
    }

    private func configureDetail() {
        configure(detailTitle, action: #selector(showDescription(_:)))
        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailTitle.alignment = .left
        detailTitle.imagePosition = .imageTrailing
        detailTitle.cell?.usesSingleLineMode = true
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailMetadata.heightAnchor.constraint(equalToConstant: 14).isActive = true
        for label in [fileHeading, fileCount, fileMessage] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
        }
        let fileHeader = NSStackView(views: [fileHeading, NSView(), fileCount])
        fileHeader.orientation = .horizontal
        let metadata = NSStackView(views: [detailTitle, detailMetadata, fileHeader, fileMessage])
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 2
        metadata.setCustomSpacing(9, after: detailMetadata)
        for child in metadata.arrangedSubviews { child.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true }
        fileTree.onDiscardSourceControlFile = { [weak self] restore in Task { await self?.discard(restore) } }
        let tree = fileTree.view
        for child in [metadata, tree] {
            changeBody.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let treeTop = tree.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 3)
        treeTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            metadata.leadingAnchor.constraint(equalTo: changeBody.leadingAnchor, constant: 12),
            metadata.trailingAnchor.constraint(equalTo: changeBody.trailingAnchor, constant: -12),
            metadata.topAnchor.constraint(equalTo: changeBody.topAnchor, constant: 3),
            tree.leadingAnchor.constraint(equalTo: changeBody.leadingAnchor), tree.trailingAnchor.constraint(equalTo: changeBody.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: changeBody.bottomAnchor), treeTop
        ])
    }

    private func configure(_ button: NSButton, title: String = "", action: Selector, symbol: String? = nil,
                           label: String? = nil) {
        button.title = title
        button.target = self
        button.action = action
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 11.5)
        if let symbol {
            button.image = Self.symbol(symbol, size: title.isEmpty ? 12 : 8)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageTrailing
        }
        if let label {
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    private static func disclosureImage(_ name: String) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) else { return nil }
        // Give both symbol shapes the same size and alignment for the button cell.
        let image = NSImage(size: NSSize(width: 14, height: 12), flipped: false) { bounds in
            glyph.draw(in: NSRect(x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeHeader(_ title: NSButton, actions: [NSButton]) -> NSView {
        let header = NSView()
        let row = NSStackView(views: actions)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        for child in [title, row] {
            header.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 11), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -9), row.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }
}

@MainActor
private final class SourceControlFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
