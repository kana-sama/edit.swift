import AppKit

@MainActor
final class SourceControlSidebar: NSObject {
    private struct DetailTarget: Equatable {
        let revision: JJSourceControlRevision
        let operationID: String
    }

    private struct DetailPresentation {
        let target: DetailTarget
        let result: Result<JJSourceControlDetail, Error>?
    }

    private static let presentationGrace: Duration = .milliseconds(750)

    let view: NSView = SourceControlFocusView()
    let graphView = SourceControlGraphView()
    private(set) lazy var fileTree = SidebarFileTree(document: document, app: app, mode: .sourceControl)
    private unowned let document: DocumentWindow
    private unowned let app: Edit

    private let graphToggle = NSButton()
    private let changeToggle = NSButton()
    private let revsetButton = NSButton()
    private let workingCopyButton = NSButton()
    private let operationsButton = NSButton()
    private let newButton = NSButton()
    private let actionsButton = SourceControlDetailButton()
    private static let collapsedChevron = disclosureImage("chevron.forward")
    private static let expandedChevron = disclosureImage("chevron.down")
    private let graphMessage = NSTextField(wrappingLabelWithString: "")
    private let detailTitle = SourceControlDetailButton()
    private let detailMetadata = SourceControlRevisionIdentity()
    private let fileMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var descriptionPopover = SourceControlDescriptionPopover(anchor: detailTitle) { [weak self] in self?.saveDescription($0) }
    private lazy var revsetPicker = SourceControlRevsetPicker(
        anchor: revsetButton,
        onSelect: { [weak self] id in
            guard let self, revsets.selected.id != id else { return }
            try updateRevsets { try $0.select(id) }
        },
        onSave: { [weak self] name, expression, id in try await self?.saveRevset(name: name, expression: expression, replacing: id) },
        onDelete: { [weak self] id in try self?.updateRevsets { $0.remove(id) } },
        onMove: { [weak self] id, next in try self?.updateRevsets { try $0.move(id, before: next) } },
        readDefault: { [weak self] in
            guard let workspace = await self?.workspace else { throw PanelError.noWorkspace }
            return try await JJSourceControlRepository.read(workspace, arguments: ["config", "get", "revsets.log"])
                .trimmingCharacters(in: .newlines)
        }
    )
    private lazy var operations = SourceControlOperationPopover(
        anchor: operationsButton,
        prepare: { [weak self] direction in
            guard let self else { throw PanelError.noWorkspace }
            return try await preview(direction)
        },
        apply: { [weak self] preview in try await self?.apply(preview) }
    )

    private var folder: URL?
    private var workspace: JJWorkspace?
    private var active = false
    private var subscription: JJChangeMonitor.Subscription?
    private var discovery: Task<Void, Never>?
    private var graphRequest: Task<Void, Never>?
    private var detailRequest: Task<Void, Never>?
    private var graphExpiry: Task<Void, Never>?
    private var detailExpiry: Task<Void, Never>?
    private var busy = false
    private var stale = false
    private var revsets = SourceControlRevsets()
    private var includeWorkingCopy = false
    private var revealWorkingCopy = false
    private(set) var graph: JJSourceControlGraph?
    private(set) var selection: JJSourceControlRevision?
    private var presentedDetail: DetailPresentation?
    private var hasPresentedGraph = false
    private let graphBody = NSView()
    private let changeBody = NSView()
    private lazy var panes = SourceControlPanes(
        graphHeader: makeHeader(graphToggle, actions: [revsetButton, workingCopyButton, operationsButton, newButton]),
        graph: graphBody, changeHeader: makeHeader(changeToggle, actions: [actionsButton]), change: changeBody
    )

    var focusResponder: NSView {
        graphView.table.isEnabled && !graphView.table.isHiddenOrHasHiddenAncestor ? graphView.table : view
    }

    var detail: JJSourceControlDetail? {
        guard let presentedDetail, presentedDetail.target == selectedDetailTarget,
              case .success(let detail) = presentedDetail.result else { return nil }
        return detail
    }

    private var selectedDetailTarget: DetailTarget? {
        guard let graph, let selection else { return nil }
        return DetailTarget(revision: selection, operationID: graph.operationID)
    }

#if EDIT_AGENT_CHECKS
    var operationsViewForCheck: NSView { operations.checkView }
    var descriptionViewForCheck: NSView { descriptionPopover.checkView }
    var revsetPickerForCheck: SourceControlRevsetPicker { revsetPicker }
    var detailReadDelayForCheck: Duration?
#endif

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
        graphExpiry?.cancel()
        detailExpiry?.cancel()
        if let subscription { app.jjChanges.unsubscribe(subscription) }
    }

    func update(folder: URL?) {
        guard folder != self.folder else { return }
        self.folder = folder
        stopObserving()
        workspace = nil
        graph = nil
        revsets = SourceControlRevsets()
        updateRevsetButton()
        includeWorkingCopy = false
        revealWorkingCopy = false
        hasPresentedGraph = false
        selection = nil
        graphView.install([], selected: nil)
        presentDetail(nil)
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
        graphExpiry?.cancel()
        graphExpiry = nil
        cancelDetailExpiry()
        app.jjChanges.unsubscribe(subscription)
        subscription = nil
        operations.close()
        revsetPicker.close()
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
            if let found {
                revsets = (try? app.sourceControlRevsets.read(for: found)) ?? SourceControlRevsets()
                updateRevsetButton()
                observe(found)
            } else {
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
        detailRequest = nil
        stale = true
        if graph == nil { showGraphMessage("Loading changes…") }
        updateControls()
        scheduleDetailExpiry()
        if graphExpiry == nil {
            graphExpiry = Task { [weak self] in
                try? await Task.sleep(for: Self.presentationGrace)
                guard let self, !Task.isCancelled, stale else { return }
                showGraphMessage("Updating changes…")
            }
        }
        let revset = revsets.selected
        let includeWorkingCopy = includeWorkingCopy
        graphRequest = Task { [weak self] in
            do {
                let result = try await JJSourceControlRepository.graph(
                    in: workspace, revset: revset.expression, includeWorkingCopy: includeWorkingCopy
                )
                guard let self, !Task.isCancelled, active, self.workspace == workspace else { return }
                publish(result)
            } catch {
                guard let self, !Task.isCancelled, active, self.workspace == workspace else { return }
                finishGraphRequest()
                graph = nil
                selection = nil
                graphView.install([], selected: nil)
                requestDetail()
                showGraphMessage(error.localizedDescription)
            }
        }
    }

    private func finishGraphRequest() {
        graphRequest = nil
        graphExpiry?.cancel()
        graphExpiry = nil
        stale = false
    }

    private func publish(_ result: JJSourceControlGraph) {
        finishGraphRequest()
        let changedOperation = graph?.operationID != result.operationID
        graph = result
        if changedOperation { operations.invalidate() }
        displayGraph()
    }

    private func displayGraph() {
        guard let graph else { return }
        let rows = graph.revisions
        graphView.table.setAccessibilityHelp(graph.isTruncated ? "Graph limited to \(rows.count) changes." : nil)
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
        requestDetail()
    }

    private func choose(_ revision: JJSourceControlRevision) {
        guard !busy, !stale, revision.id != selection?.id else { return }
        selection = revision
        descriptionPopover.close()
        requestDetail()
    }

    private func requestDetail() {
        detailRequest?.cancel()
        detailRequest = nil
        guard let workspace, let target = selectedDetailTarget else {
            cancelDetailExpiry()
            presentDetail(nil)
            updateControls()
            return
        }
        if detail != nil {
            cancelDetailExpiry()
            renderFiles()
            updateControls()
            return
        }
        if presentedDetail?.result == nil {
            presentDetail(DetailPresentation(target: target, result: nil))
        } else {
            scheduleDetailExpiry()
        }
        updateControls()
        detailRequest = Task { [weak self] in
            let result: Result<JJSourceControlDetail, Error>
            do {
#if EDIT_AGENT_CHECKS
                if let delay = self?.detailReadDelayForCheck { try await Task.sleep(for: delay) }
#endif
                result = .success(try await JJSourceControlRepository.detail(for: target.revision, in: workspace, at: target.operationID))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, active, self.workspace == workspace, selectedDetailTarget == target else { return }
            detailRequest = nil
            cancelDetailExpiry()
            presentDetail(DetailPresentation(target: target, result: result))
            updateControls()
        }
    }

    private func scheduleDetailExpiry() {
        guard detailExpiry == nil, presentedDetail?.result != nil else { return }
        detailExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.presentationGrace)
            guard let self, !Task.isCancelled, let target = selectedDetailTarget else { return }
            detailExpiry = nil
            presentDetail(DetailPresentation(target: target, result: nil))
            updateControls()
        }
    }

    private func cancelDetailExpiry() {
        detailExpiry?.cancel()
        detailExpiry = nil
    }

    private func presentDetail(_ presentation: DetailPresentation?) {
        presentedDetail = presentation
        let revision = presentation?.target.revision
        PanelLayout.withoutAnimation {
            detailTitle.title = revision?.subject ?? "Select a change"
            detailTitle.toolTip = revision.map { $0.isImmutable ? "View change description" : "Edit change description" }
            if let revision { detailMetadata.update(revision, showsAuthor: false) }
            detailMetadata.isHidden = revision == nil
            renderFiles()
        }
    }

    func updateLiveFile() {
        guard active, !stale, selection?.isWorkingCopy == true, detail != nil else { return }
        renderFiles()
    }

    private func renderFiles() {
        guard let presentedDetail, let workspace else {
            fileTree.clearSourceControl()
            showFiles()
            return
        }
        let target = presentedDetail.target
        let revision = target.revision
        switch presentedDetail.result {
        case .success(let detail):
            let live = document.jjLiveFileStatus
            let files: [JJSourceControlFile]
            if revision.isWorkingCopy, let live, live.workspace == workspace,
               live.operationID == target.operationID, live.commitID == revision.id {
                files = live.applying(to: detail.files)
            } else {
                files = detail.files
            }
            fileTree.updateSourceControl(revision: revision, workspace: workspace, operationID: target.operationID, files: files)
            showFiles(hasFiles: !files.isEmpty, message: files.isEmpty ? "No changed files" : nil)
        case .failure(let error):
            showFiles(message: error.localizedDescription)
        case nil:
            showFiles(message: "Loading changed files…")
        }
    }

    private func showFiles(hasFiles: Bool = false, message: String? = nil) {
        fileTree.view.isHidden = !hasFiles
        fileMessage.isHidden = message == nil
        fileMessage.stringValue = message ?? ""
    }

    private func showGraphMessage(_ text: String?) {
        graphMessage.isHidden = text == nil
        graphMessage.stringValue = text ?? ""
        graphView.view.isHidden = text != nil
    }

    private func updateControls() {
        let canBrowse = active && workspace != nil
        let canAct = canBrowse && graph != nil && !stale && !busy
        revsetButton.isEnabled = canBrowse
        operationsButton.isEnabled = canBrowse && !busy
        newButton.isEnabled = canAct
        workingCopyButton.isEnabled = canAct
        let showingSelection = selection != nil && presentedDetail?.target == selectedDetailTarget
        let canUseDetail = canAct && showingSelection
        let holdingPresentation = canBrowse && presentedDetail?.result != nil
        for button in [actionsButton, detailTitle] {
            button.isEnabled = canUseDetail || holdingPresentation
            button.blocksInput = !canUseDetail
        }
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

    private func apply(_ preview: JJSourceControlOperations.Preview) async throws {
        guard !busy, let workspace else { return }
        busy = true
        updateControls()
        defer {
            busy = false
            updateControls()
            requestGraph()
        }
        try await document.performSourceControlMutation(in: workspace) {
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
                }
            }
        } catch {
            await document.showError("Could Not Update Jujutsu Workspace", detail: error.localizedDescription)
        }
        busy = false
        updateControls()
        requestGraph()
    }

    private func activate(_ revision: JJSourceControlRevision) async {
        guard !stale, !busy, !revision.isWorkingCopy, let workspace, let operation = graph?.operationID else { return }
        let response = await Self.changeActivationAlert(for: revision).beginSheetModal(for: document.window)
        guard self.workspace == workspace else { return }
        switch response {
        case .alertFirstButtonReturn:
            guard !revision.parents.isEmpty else { return }
            await mutate(.edit(revision.id, ignoreImmutable: revision.isImmutable), selectingWorkingCopy: true, expectedOperation: operation)
        case .alertSecondButtonReturn:
            await mutate(.new(revision.id), selectingWorkingCopy: true, expectedOperation: operation)
        default:
            break
        }
    }

    static func changeActivationAlert(for revision: JJSourceControlRevision) -> NSAlert {
        let alert = NSAlert()
        let isRoot = revision.parents.isEmpty
        let subject = "“\(revision.subject)”"
        alert.messageText = "Edit this change or start a new one?"
        alert.informativeText = if isRoot {
            "\(subject) is the repository root. You can start a new change on top of it."
        } else if revision.isImmutable {
            "\(subject) is immutable. Edit Change overrides Jujutsu’s protection. Saving may rewrite this change and its descendants."
        } else {
            subject
        }
        alert.alertStyle = revision.isImmutable ? .warning : .informational
        let edit = alert.addButton(withTitle: "Edit Change")
        let child = alert.addButton(withTitle: "New Change Here")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        edit.isEnabled = !isRoot
        if revision.isImmutable {
            edit.keyEquivalent = ""
            child.keyEquivalent = "\r"
        }
        return alert
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
        guard let revision = revision(for: item), !revision.isImmutable, !revision.isWorkingCopy,
              let operation = graph?.operationID else { return }
        Task { await mutate(.edit(revision.id), selectingWorkingCopy: true, expectedOperation: operation) }
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
        guard !stale, !busy, let selection, presentedDetail?.target == selectedDetailTarget else { return }
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
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.string = parent.description.trimmingCharacters(in: .newlines) + "\n\n" + change.description
        text.setAccessibilityLabel("Change Description")
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
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
        guard let selection, presentedDetail?.target == selectedDetailTarget, let menu = menu(for: selection) else { return }
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
        if graph.revisions.contains(where: { $0.id == graph.workingCopy.id }) { displayGraph() }
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

    @objc private func showRevsets() {
        guard let workspace else { return }
        if let settings = try? app.sourceControlRevsets.read(for: workspace) { installRevsets(settings) }
        revsetPicker.show()
    }

    private func saveRevset(name: String, expression: String, replacing id: String?) async throws {
        guard let workspace else { throw PanelError.noWorkspace }
        if revsets.entries.first(where: { $0.id == id })?.isBuiltIn != true {
            try await JJSourceControlRepository.validateRevset(expression, in: workspace)
        }
        try Task.checkCancellation()
        guard active, self.workspace == workspace else { throw PanelError.noWorkspace }
        let settings = try app.sourceControlRevsets.update(for: workspace) {
            try $0.save(name: name, expression: expression, replacing: id)
        }
        installRevsets(settings)
    }

    private func updateRevsets(_ change: (inout SourceControlRevsets) throws -> Void) throws {
        guard let workspace else { throw PanelError.noWorkspace }
        installRevsets(try app.sourceControlRevsets.update(for: workspace, change))
    }

    private func installRevsets(_ settings: SourceControlRevsets) {
        let old = revsets.selected
        let next = settings.selected
        revsets = settings
        updateRevsetButton()
        if old.id != next.id || old.expression != next.expression {
            includeWorkingCopy = false
            revealWorkingCopy = false
            requestGraph()
        }
    }

    private func updateRevsetButton() {
        let selected = revsets.selected
        revsetButton.title = selected == .defaultLog ? "Log" : selected.name
        revsetButton.toolTip = "Revsets · \(selected.name)"
        revsetButton.setAccessibilityLabel("Revsets, \(selected.name)")
        revsetPicker.update(revsets)
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
        configure(revsetButton, title: "Log", action: #selector(showRevsets), symbol: "chevron.down")
        revsetButton.identifier = NSUserInterfaceItemIdentifier("JujutsuRevsets")
        revsetButton.imageHugsTitle = true
        revsetButton.lineBreakMode = .byTruncatingTail
        revsetButton.cell?.usesSingleLineMode = true
        revsetButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revsetButton.widthAnchor.constraint(lessThanOrEqualToConstant: 128).isActive = true
        updateRevsetButton()
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
        presentDetail(nil)
    }

    private func configureGraph() {
        graphView.onSelect = { [weak self] in self?.choose($0) }
        graphView.onEdit = { [weak self] revision in Task { await self?.activate(revision) } }
        graphView.menu = { [weak self] in self?.menu(for: $0) }
        graphMessage.textColor = .secondaryLabelColor
        graphMessage.font = .systemFont(ofSize: 12)
        let graph = graphView.view
        for child in [graph, graphMessage] {
            graphBody.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: graphBody.leadingAnchor), graph.trailingAnchor.constraint(equalTo: graphBody.trailingAnchor),
            graph.topAnchor.constraint(equalTo: graphBody.topAnchor), graph.bottomAnchor.constraint(equalTo: graphBody.bottomAnchor),
            graphMessage.leadingAnchor.constraint(equalTo: graphBody.leadingAnchor, constant: 12),
            graphMessage.trailingAnchor.constraint(equalTo: graphBody.trailingAnchor, constant: -12),
            graphMessage.topAnchor.constraint(equalTo: graphBody.topAnchor, constant: 8)
        ])
    }

    private func configureDetail() {
        configure(detailTitle, action: #selector(showDescription(_:)))
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitle.alignment = .left
        detailTitle.cell?.usesSingleLineMode = true
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailMetadata.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [detailTitle, detailMetadata, NSView()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 0
        titleRow.setCustomSpacing(7, after: detailTitle)
        fileMessage.textColor = .secondaryLabelColor
        fileMessage.font = .systemFont(ofSize: 11)
        let metadata = NSStackView(views: [titleRow, fileMessage])
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 2
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

@MainActor
private final class SourceControlDetailButton: NSButton {
    // Keep a displayed button’s paint stable while its details are stale.
    var blocksInput = false

    override var acceptsFirstResponder: Bool { !blocksInput && super.acceptsFirstResponder }
    override func hitTest(_ point: NSPoint) -> NSView? { blocksInput ? nil : super.hitTest(point) }
    override func isAccessibilityEnabled() -> Bool { !blocksInput && super.isAccessibilityEnabled() }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        !blocksInput && super.sendAction(action, to: target)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
