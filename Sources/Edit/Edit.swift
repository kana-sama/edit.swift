import AppKit
import UniformTypeIdentifiers

struct OpenFilePreview: Sendable {
    let url: URL
    let identity: FileIdentity?
    let reason: String
    let details: FilePreviewDetails
}

private enum OpenedFile: Sendable {
    case text(FileBuffer)
    case preview(OpenFilePreview)

    var url: URL {
        switch self {
        case .text(let file): file.url
        case .preview(let preview): preview.url
        }
    }

    var identity: FileIdentity? {
        switch self {
        case .text(let file): file.identity
        case .preview(let preview): preview.identity
        }
    }

    @MainActor
    func replaceBuffer(in document: DocumentWindow, focusEditor: Bool, scratch: ScratchFile? = nil) async -> Bool {
        switch self {
        case .text(let file):
            await document.replaceBuffer(with: file, focusEditor: focusEditor, scratch: scratch)
        case .preview(let preview):
            await document.replaceBuffer(withPreview: preview, focusEditor: focusEditor)
        }
    }
}

@main
@MainActor
final class Edit: NSObject, NSApplicationDelegate, NSUserInterfaceValidations, NSMenuDelegate {
    let isAgentCheck = CommandLine.arguments.dropFirst().first == "--agent-check"
    private lazy var sessionStore = SessionStore.application()
    lazy var syntaxOverrides = SyntaxLanguageOverrides(defaults: isAgentCheck ? nil : .standard)
    private weak var recentMenu: NSMenu?
    private var controlPanel: ControlPanel?
    private var titleClickMonitor: Any?
    private var openFilePanel: OpenFilePanel?
    private weak var openPanelDocument: DocumentWindow?
    private(set) lazy var recentFiles = RecentFiles(url: recentHistoryURL)
    lazy var scratchStore = ScratchStore(
        root: storageFolder.appending(path: "Scratches", directoryHint: .isDirectory),
        trashDirectoryForChecks: isAgentCheck ? storageFolder.appending(path: "ScratchTrash", directoryHint: .isDirectory) : nil
    )

    private var storageFolder: URL {
        isAgentCheck
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            : sessionStore.url.deletingLastPathComponent()
    }
    private var recentHistoryURL: URL { storageFolder.appendingPathComponent("recent-files.json") }
    private var startup: Task<Void, Never>?
    private var receivedInitialSession = false
    private var pendingFiles: [(urls: [URL], allowMissing: Bool, document: DocumentWindow?)] = []
    private var saveTargets: [URL: FileIdentity?] = [:]
    private var worktreeMutationPaths: [URL] = []
    private var worktreeMutationGeneration: UInt64 = 0
    private(set) var isPerformingScratchOperation = false
    private var lastPlacement: WindowPlacement?
    private var sessionReadFailed = false
    private var pendingFullScreen: [DocumentWindow] = []
    private weak var enteringFullScreen: DocumentWindow?

    private(set) var documents: [DocumentWindow] = []
    private(set) var isQuitting = false

    private var activeDocument: DocumentWindow? {
        let app = NSApplication.shared
        return documents.first { $0.window === app.keyWindow }
            ?? documents.first { $0.window === app.mainWindow }
            ?? documents.last
    }

    static func main() {
        if OpenFilePanelHelper.runIfRequested() { return }
        let app = NSApplication.shared
        let delegate = Edit()
        app.delegate = delegate
        app.setActivationPolicy(delegate.isAgentCheck ? .prohibited : .regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        installMenus(in: app)
        titleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return routeTitleClick(event)
        }
        let initial = makeDocument()
        if isAgentCheck {
            Task { @MainActor in
                do {
                    try EditorCheck.run(in: initial.window, editor: initial.editor, scrollView: initial.scrollView)
                    // The text editor check uses its own undo grouping and sample text.
                    initial.window.close()
                    makeDocument()
                    try await OpenFilePanelCheck.run()
                    let sample = try await FilesCheck.run(in: self)
                    try ControlPanel(app: self).checkHidden(in: sample)
                    try await ControlPanel(app: self).checkPins(in: sample)
                    try await SyntaxCheck.run(in: self)
                    try await FindCheck.run(in: self)
                    try await FocusCheck.run(in: self)
                    try checkWindow(sample.window, screenshot: CommandLine.arguments.dropFirst(2).first)
                    try MultiCaretCheck.runComposition(in: sample.editor)
                    try await EditorCheck.checkViewportResize(in: makeDocument())
                    try await EditorCheck.checkScrolledZoom(in: makeDocument())
                    receivedInitialSession = true
                    let folderWindow = try await FolderCheck.run(in: self)
                    try checkWindow(folderWindow, screenshot: nil)
                    try await HeaderCheck.run(in: self)
                    try await WorktreeCheck.run(in: self)
                    try await FilesCheck.checkFilePreview(in: self)
                    try await ScratchCheck.run(in: self)
                    try await ScratchTreeCheck.run(in: self)
                    try MultiCaretCheck.checkBlink()
                    print("Edit passed its native editing and file-session checks without activation.")
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("Edit check: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

        initial.present()
        app.activate()

        let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--" && !$0.hasPrefix("-psn_") }
        if !arguments.isEmpty {
            let urls = arguments.map { URL(fileURLWithPath: $0).standardizedFileURL }
            pendingFiles.append((urls, true, nil))
        }

        startup = Task { @MainActor in
            await recentFiles.load()
            Task { await recentFiles.prune() }
            let store = sessionStore
            do {
                if let previous = try await Task.detached(operation: { try store.read() }).value {
                    await restore(previous, reusing: initial)
                }
            } catch {
                sessionReadFailed = true
                if !isQuitting {
                    Task { await activeDocument?.showError("Could Not Restore Session", detail: error.localizedDescription) }
                }
            }
            startup = nil
            receivedInitialSession = true
            let requests = pendingFiles
            pendingFiles.removeAll()
            for request in requests where !isQuitting {
                await openFiles(request.urls, allowMissing: request.allowMissing, in: request.document)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        requestOpen(urls.filter(\.isFileURL))
        requestOpen(urls.compactMap(Self.launcherFileURL), allowMissing: true)
    }

    nonisolated static func launcherFileURL(_ url: URL) -> URL? {
        guard url.scheme == "dev-edit-swift", url.host == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let titleClickMonitor { NSEvent.removeMonitor(titleClickMonitor) }
    }

    private func routeTitleClick(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard !isQuitting, let window = event.window,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && modifiers == .control) else { return event }

        // AppKit can host the fullscreen toolbar in a different window from the document.
        for document in documents {
            if document.titleBar.handleSecondaryClick(at: event.locationInWindow, in: window) { return nil }
        }
        return event
    }

    func dismissControlForTitleClick() {
        controlPanel?.dismiss(restoreFocus: false)
    }

    func applicationWillResignActive(_ notification: Notification) {
        activeDocument?.requestAutosave()
    }

    func menuWillOpen(_ menu: NSMenu) {
        activeDocument?.requestAutosave()
        guard let recentMenu, menu === recentMenu || menu === recentMenu.supermenu else { return }
        populateRecentMenu(recentMenu)
        if menu === recentMenu { Task { await recentFiles.prune() } }
    }

    private func populateRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if !recentFiles.folders.isEmpty {
            menu.addItem(.sectionHeader(title: "Folders"))
            for recent in recentFiles.folders.prefix(10) {
                let item = menu.addItem(withTitle: recent.displayPath, action: #selector(openRecentDocument(_:)),
                                        keyEquivalent: "")
                item.target = self
                item.representedObject = recent.url
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            }
            if !recentFiles.entries.isEmpty { menu.addItem(.separator()) }
        }
        if !recentFiles.entries.isEmpty {
            menu.addItem(.sectionHeader(title: "Files"))
        }
        for recent in recentFiles.entries.prefix(10) {
            let item = menu.addItem(withTitle: recent.displayPath, action: #selector(openRecentDocument(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = recent.url
            item.image = FileIcons.image(for: recent.url, appearance: NSApplication.shared.effectiveAppearance,
                                        language: manualIconLanguage(for: recent))
        }
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        requestOpen([url], in: activeDocument)
    }

    @objc func showGoToFile(_ sender: Any?) { showControl(.files) }
    @objc func showCommandMode(_ sender: Any?) { showControl(.commands) }
    @objc func showLanguageModes(_ sender: Any?) { showControl(.languages) }

    func checkHeaderLanguagePicker(in document: DocumentWindow) throws {
        guard let controlPanel else { throw CocoaError(.featureUnsupported) }
        try controlPanel.checkHeaderLanguagePicker(in: document)
    }

    func showLanguageModes(in document: DocumentWindow) {
        showControl(.languages, in: document)
    }

    private func showControl(_ mode: ControlPanel.Mode, in source: DocumentWindow? = nil) {
        guard let document = source ?? activeDocument, !isQuitting,
              mode != .languages || !document.isShowingFilePreview else { return }
        let panel = controlPanel ?? ControlPanel(app: self)
        controlPanel = panel
        panel.toggle(in: document, mode: mode)
    }

    func scratchesDidChange(updated: [ScratchFile] = []) {
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        for document in documents {
            if let id = document.scratchFile?.id, let file = byID[id] { document.updateScratch(file) }
            document.reloadScratches()
        }
        controlPanel?.scratchesDidChange()
    }

    @discardableResult
    private func recordScratchOpen(_ file: ScratchFile) async -> ScratchFile? {
        do {
            let current = try await scratchStore.recordOpen(file.id, at: Date())
            controlPanel?.scratchesDidChange(recencyOnly: true)
            return current
        } catch {
            NSLog("Could not save scratch recency: %@", error.localizedDescription)
            return nil
        }
    }

    func beginScratchOperation() -> Bool {
        guard !isQuitting, !isPerformingScratchOperation else { return false }
        isPerformingScratchOperation = true
        return true
    }

    func endScratchOperation() { isPerformingScratchOperation = false }

    @objc func newDocument(_ sender: Any?) {
        guard let document = activeDocument, !isQuitting else { return }
        Task { await document.newBuffer() }
    }

    @objc func newWindow(_ sender: Any?) {
        guard !isQuitting else { return }
        let placement = documents.isEmpty ? lastPlacement : nil
        let document = makeDocument(placement: placement)
        if !isAgentCheck { document.present() }
    }

    @objc func openDocument(_ sender: Any?) {
        guard !isQuitting else { return }
        if let openFilePanel, openFilePanel.isOpening {
            openFilePanel.bringForward()
            return
        }
        guard let document = activeDocument, document.canReplaceBuffer else { return }
        document.requestAutosave()
        let panel = openFilePanel ?? OpenFilePanel()
        openFilePanel = panel
        openPanelDocument = document
        let directory = document.folderURL ?? document.displayedFileURL?.deletingLastPathComponent()
        panel.open(in: directory) { [weak self, weak document] result in
            guard let self else { return }
            openPanelDocument = nil
            guard !isQuitting, let document, documents.contains(where: { $0 === document }) else { return }
            switch result {
            case .success(let url):
                if let url { requestOpen([url], in: document) }
            case .failure(let error):
                Task { await document.showError("Could Not Open", detail: error.localizedDescription) }
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let document = activeDocument, !document.isBusy, !isQuitting else { return }
        Task { await document.save() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let document = activeDocument, !document.isBusy, !isQuitting else { return }
        Task { await document.save(asNew: true) }
    }

    @objc func saveDocumentAsScratch(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Task { await document.saveAsScratch() }
    }

    @objc func openFind(_ sender: Any?) {
        focusSidebar(.search)
    }

    @objc func openReplace(_ sender: Any?) {
        controlPanel?.dismiss(restoreFocus: true)
        activeDocument?.performFind(.replace)
    }

    @objc func findNext(_ sender: Any?) { activeDocument?.performFind(.next) }
    @objc func findPrevious(_ sender: Any?) { activeDocument?.performFind(.previous) }
    // Keep the selector used by existing Control pins and command history.
    @objc(toggleFindSidebar:) func toggleSidebar(_ sender: Any?) { activeDocument?.performFind(.toggleSidebar) }

    // Keep the selector used by existing Control pins and command history.
    @objc func toggleWorktreeSidebar(_ sender: Any?) {
        focusSidebar(.worktree)
    }

    @objc func focusScratches(_ sender: Any?) {
        focusSidebar(.scratches)
    }

    private func focusSidebar(_ mode: SidebarMode) {
        guard let document = activeDocument, document.window.attachedSheet == nil,
              mode != .worktree || document.folderURL != nil else { return }
        controlPanel?.dismiss(restoreFocus: true)
        document.toggleSidebarFocus(mode)
    }

    @objc func performFindControlAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? FindCommand { activeDocument?.performFind(command) }
    }

    @objc func focusSelection(_ sender: Any?) { activeDocument?.focusSelection() }
    @objc func exitFocus(_ sender: Any?) { activeDocument?.exitFocus() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !isQuitting else { return false }
        switch item.action {
        case #selector(focusSelection(_:)): return activeDocument?.canFocusSelection ?? false
        case #selector(exitFocus(_:)): return activeDocument?.canExitFocus ?? false
        case #selector(newDocument(_:)): return activeDocument?.canReplaceBuffer ?? false
        case #selector(showGoToFile(_:)), #selector(showCommandMode(_:)):
            return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(showLanguageModes(_:)):
            return activeDocument.map { !$0.isShowingFilePreview && $0.window.attachedSheet == nil } ?? false
        case #selector(newWindow(_:)): return true
        case #selector(openDocument(_:)):
            return openFilePanel?.isOpening == true || activeDocument?.canReplaceBuffer == true
        case #selector(openRecentDocument(_:)):
            return activeDocument?.canReplaceBuffer ?? false
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(saveDocumentAsScratch(_:)):
            return activeDocument.map { !$0.isShowingFilePreview && !$0.isBusy && $0.window.attachedSheet == nil } ?? false
        case #selector(openFind(_:)): return activeDocument?.canPerformFind(.find) ?? false
        case #selector(openReplace(_:)): return activeDocument?.canPerformFind(.replace) ?? false
        case #selector(toggleSidebar(_:)), #selector(focusScratches(_:)):
            return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(toggleWorktreeSidebar(_:)):
            return activeDocument.map { $0.folderURL != nil && $0.window.attachedSheet == nil } ?? false
        case #selector(findNext(_:)): return activeDocument?.canPerformFind(.next) ?? false
        case #selector(findPrevious(_:)): return activeDocument?.canPerformFind(.previous) ?? false
        case #selector(performFindControlAction(_:)):
            guard let command = (item as? NSMenuItem)?.representedObject as? FindCommand else { return false }
            return activeDocument?.canPerformFind(command) ?? false
        default: return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isAgentCheck
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isAgentCheck { return .terminateNow }
        if isQuitting { return .terminateLater }
        guard worktreeMutationPaths.isEmpty, !isPerformingScratchOperation,
              !documents.contains(where: { $0.isBusy || $0.window.attachedSheet != nil }) else {
            return .terminateCancel
        }
        // The temporary startup window can be closed before restoration reads the saved session.
        if startup != nil && documents.isEmpty { return .terminateNow }
        isQuitting = true
        openFilePanel?.cancel()
        controlPanel?.dismiss(restoreFocus: true)
        for document in documents {
            if document.editor.hasMarkedText() { document.editor.unmarkText() }
            document.editor.isEditable = false
        }
        Task { @MainActor in
            await startup?.value
            for document in documents { await document.flushAutosave() }
            let session = sessionSnapshot()
            for index in documents.indices where index != session.activeIndex {
                documents[index].rememberFilePosition(session.documents[index].editorPosition)
            }
            if let index = session.activeIndex {
                // The active view is the most recent when several windows have the same file open.
                documents[index].rememberFilePosition(session.documents[index].editorPosition)
            }
            await recentFiles.finishWrites()
            let store = sessionStore
            let copyUnrestoredSession = sessionReadFailed
            do {
                try await Task.detached {
                    if copyUnrestoredSession {
                        let backup = store.url.deletingLastPathComponent()
                            .appendingPathComponent("unrestored-session-\(UUID().uuidString).json")
                        do {
                            try FileManager.default.copyItem(at: store.url, to: backup)
                        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                            // The file may have been removed after the error was shown.
                        }
                    }
                    try store.write(session)
                }.value
                if sender.isActive, let document = activeDocument {
                    let failures = documents.compactMap { $0.takeAutosaveFailure() }
                    if !failures.isEmpty {
                        await document.showError("Could Not Autosave Some Files",
                                                 detail: failures.joined(separator: "\n") +
                                                    "\n\nYour edits are available as drafts the next time you open Edit.")
                    }
                }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isQuitting = false
                for document in documents {
                    document.editor.isEditable = !document.isShowingFilePreview
                    if !document.window.isVisible { document.window.orderFront(nil) }
                }
                let document = activeDocument ?? makeDocument(placement: lastPlacement)
                document.present()
                sender.reply(toApplicationShouldTerminate: false)
                await document.showError("Could Not Save Session", detail: error.localizedDescription)
            }
        }
        return .terminateLater
    }

    func scheduleFullScreenRestore(for document: DocumentWindow) {
        guard !isQuitting, enteringFullScreen !== document,
              !pendingFullScreen.contains(where: { $0 === document }) else { return }
        pendingFullScreen.append(document)
        Task { @MainActor in restoreNextFullScreenWindow() }
    }

    func didFinishFullScreenRestore(for document: DocumentWindow) {
        guard enteringFullScreen === document else { return }
        enteringFullScreen = nil
        Task { @MainActor in restoreNextFullScreenWindow() }
    }

    private func restoreNextFullScreenWindow() {
        guard enteringFullScreen == nil && !isQuitting else { return }
        while !pendingFullScreen.isEmpty {
            let document = pendingFullScreen.removeFirst()
            // AppKit switches Spaces asynchronously. Start one transition at a time.
            enteringFullScreen = document
            if document.restoreFullScreen() { return }
            enteringFullScreen = nil
        }
    }

    func didClose(_ document: DocumentWindow) {
        if openPanelDocument === document { openFilePanel?.cancel() }
        lastPlacement = document.placement
        pendingFullScreen.removeAll { $0 === document }
        didFinishFullScreenRestore(for: document)
        documents.removeAll { $0 === document }
    }

    func reserveSave(to url: URL, identity: FileIdentity?, for document: DocumentWindow) -> Bool {
        // Buffers already associated with a path compare their revisions before writing.
        // Save As must not claim a path owned by another window.
        guard !isWorktreeMutationPath(url) else { return false }
        guard url == document.fileURL || !documents.contains(where: {
            $0 !== document && ($0.fileURL == url || (identity != nil && $0.fileURL != nil && $0.fileIdentity == identity))
        }) else { return false }
        guard !saveTargets.keys.contains(url),
              identity == nil || !saveTargets.values.contains(identity)
        else { return false }
        saveTargets.updateValue(identity, forKey: url)
        return true
    }

    func finishSave(to url: URL) {
        saveTargets.removeValue(forKey: url)
    }

    func performWorktreeMutation<T: Sendable>(
        affecting sources: [URL], operation: @MainActor () async throws -> T
    ) async throws -> T {
        let affected = documents.filter { $0.worktreeMutationAffects(sources) }
        guard !isQuitting, worktreeMutationPaths.isEmpty, affected.allSatisfy(\.canReplaceBuffer) else {
            throw worktreeBusyError()
        }
        worktreeMutationPaths = sources
        worktreeMutationGeneration &+= 1
        for document in affected { document.beginWorktreeMutation() }
        defer {
            worktreeMutationPaths = []
            for document in affected { document.finishWorktreeMutation() }
        }
        for document in affected { await document.waitForWorktreeWrites() }
        guard !isQuitting, !saveTargets.keys.contains(where: isWorktreeMutationPath) else {
            throw worktreeBusyError()
        }
        return try await operation()
    }

    private func isWorktreeMutationPath(_ url: URL) -> Bool {
        worktreeMutationPaths.contains { DocumentWindow.worktreePathSuffix(from: $0, to: url) != nil }
    }

    private func worktreeBusyError() -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Edit is busy with another file operation."])
    }

    func sessionSnapshot() -> EditorSession {
        let active = activeDocument
        return EditorSession(
            documents: documents.map { $0.sessionDocument() },
            activeIndex: documents.firstIndex { $0 === active },
            lastWindow: active?.placement ?? lastPlacement
        )
    }

    func restore(_ previous: EditorSession, reusing placeholder: DocumentWindow) async {
        lastPlacement = previous.lastWindow
        var restored: [(index: Int, document: DocumentWindow)] = []
        var warnings: [String] = []
        for (index, record) in previous.documents.enumerated() {
            let url = record.path.map { URL(fileURLWithPath: $0) }
            let isScratch = url.map(scratchStore.identifiesScratch(at:)) ?? false
            let scratch: ScratchFile?
            if isScratch, let url {
                scratch = try? await scratchStore.file(at: url)
            } else {
                scratch = nil
            }
            let opened: OpenedFile?
            if record.draft == nil, let url {
                do {
                    opened = try await Self.readForOpening(
                        url,
                        allowsPreview: !isScratch && record.isFilePreview == true
                    )
                } catch {
                    warnings.append("“\(scratch?.name ?? url.lastPathComponent)” — \(error.localizedDescription)")
                    guard record.folderPath != nil else { continue }
                    opened = nil
                }
            } else {
                opened = nil
            }
            let document = restored.isEmpty && documents.contains(where: { $0 === placeholder }) && placeholder.isReusable
                ? placeholder : makeDocument()
            document.restorePlacement(record.placement)
            if let path = record.folderPath { document.setFolder(URL(filePath: path, directoryHint: .isDirectory)) }
            if let draft = record.draft {
                let identity = await Task.detached {
                    record.path.flatMap { FileIdentity.at(URL(fileURLWithPath: $0)) }
                }.value
                document.restoreDraft(record, text: draft, identity: identity, scratch: scratch)
            } else if let opened {
                switch opened {
                case .text(let file):
                    let syntax = await document.prepareOpeningSyntax(file, position: record.editorPosition,
                                                                     storedSyntaxLanguage: record.syntaxLanguage, scratch: scratch)
                    document.load(file, storedSyntaxLanguage: record.syntaxLanguage, preparedSyntax: syntax, scratch: scratch)
                case .preview(let preview):
                    document.loadPreview(preview)
                    document.focusContent()
                }
            }
            document.restoreSidebar(record)
            document.restoreEditorPosition(record.editorPosition)
            if let scratch = document.scratchFile { await recordScratchOpen(scratch) }
            else if !isScratch, let url { await recentFiles.record(url) }
            if isQuitting { document.editor.isEditable = false }
            restored.append((index, document))
        }

        if restored.isEmpty && placeholder.isReusable, let placement = previous.lastWindow {
            placeholder.restorePlacement(placement)
        }
        if !isAgentCheck && !isQuitting {
            let preferred = restored.first { $0.index == previous.activeIndex }?.document ?? restored.last?.document
            for entry in restored where entry.document !== preferred { entry.document.present() }
            (preferred ?? placeholder).present()
            if !warnings.isEmpty {
                let detail = warnings.joined(separator: "\n")
                Task { await activeDocument?.showError("Could Not Reopen Some Files", detail: detail) }
            }
        }
    }

    func openFiles(
        _ urls: [URL], allowMissing: Bool = false, in sourceDocument: DocumentWindow? = nil,
        focusEditor: Bool = true, shouldOpen: () -> Bool = { true }
    ) async {
        guard let document = sourceDocument ?? activeDocument else { return }
        for url in urls where !isQuitting {
            do {
                guard try await openFile(url, allowMissing: allowMissing, in: document, focusEditor: focusEditor,
                                         shouldOpen: shouldOpen) != nil else { break }
            } catch is CancellationError {
                break
            } catch {
                await recentFiles.removeIfMissing(url)
                if !isAgentCheck && !isQuitting && document.canReplaceBuffer && documents.contains(where: { $0 === document }) {
                    await document.showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func openFile(
        _ url: URL, allowMissing: Bool = false, in sourceDocument: DocumentWindow? = nil,
        focusEditor: Bool = true, shouldOpen: () -> Bool = { true }
    ) async throws -> DocumentWindow? {
        guard !isQuitting, !Task.isCancelled, let document = sourceDocument ?? activeDocument, document.canReplaceBuffer,
              documents.contains(where: { $0 === document }), !isWorktreeMutationPath(url), shouldOpen() else { return nil }
        document.openRequestGeneration &+= 1
        let openGeneration = document.openRequestGeneration
        let mutationGeneration = worktreeMutationGeneration
        func isCurrentRequest(at target: URL) -> Bool {
            !isQuitting && !Task.isCancelled && document.canReplaceBuffer &&
            document.openRequestGeneration == openGeneration && mutationGeneration == worktreeMutationGeneration &&
            documents.contains(where: { $0 === document }) && !isWorktreeMutationPath(target) && shouldOpen()
        }

        let (canonical, identity, isFolder) = await Task.detached {
            let path = FileBuffer.canonicalURL(url)
            let identity = FileIdentity.at(path)
            var isDirectory: ObjCBool = false
            if identity == nil { _ = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) }
            return (path, identity, isDirectory.boolValue)
        }.value
        guard isCurrentRequest(at: canonical) else { return nil }
        if isFolder {
            let folder = URL(filePath: canonical.path, directoryHint: .isDirectory)
            return try await openFolder(url, canonical: folder, in: document,
                                        focusEditor: focusEditor, isCurrentRequest: isCurrentRequest)
        }
        let isScratch = scratchStore.identifiesScratch(at: canonical)
        if !document.isShowingFilePreview &&
            (document.fileURL == canonical || (identity != nil && identity == document.fileIdentity)) {
            if let scratch = document.scratchFile { await recordScratchOpen(scratch) }
            else if !isScratch { await recentFiles.record(url, in: document.folderURL) }
            return document
        }

        let scratch = isScratch ? try await scratchStore.file(at: canonical) : nil
        let opened = try await Self.readForOpening(canonical, allowMissing: allowMissing && !isScratch, allowsPreview: !isScratch)
        guard isCurrentRequest(at: canonical),
              await opened.replaceBuffer(in: document, focusEditor: focusEditor, scratch: scratch) else { return nil }
        if let scratch {
            if let current = await recordScratchOpen(scratch) { document.updateScratch(current) }
        } else if !isScratch, opened.identity != nil {
            await recentFiles.record(url, in: document.folderURL)
        } else if case .preview = opened {
            await recentFiles.removeIfMissing(url)
        }
        return document
    }

    private func openFolder(
        _ url: URL, canonical folder: URL, in document: DocumentWindow,
        focusEditor: Bool, isCurrentRequest: (URL) -> Bool
    ) async throws -> DocumentWindow? {
        var opened: OpenedFile?
        if let last = await recentFiles.lastFile(in: folder),
           let candidate = try? await Self.readForOpening(last, within: folder), candidate.identity != nil {
            opened = candidate
        }
        if opened == nil {
            let readmes = try await Task.detached { try Self.folderReadmes(folder) }.value
            for readme in readmes {
                if let candidate = try? await Self.readForOpening(readme, within: folder, allowsPreview: false) {
                    opened = candidate
                    break
                }
            }
        }
        guard isCurrentRequest(opened?.url ?? folder) else { return nil }
        if let opened {
            if opened.url != document.displayedFileURL {
                guard await opened.replaceBuffer(in: document, focusEditor: focusEditor) else { return nil }
            }
        } else {
            guard await document.replaceBuffer(with: nil, focusEditor: focusEditor) else { return nil }
        }
        if document.folderURL != folder {
            document.setFolder(folder)
            controlPanel?.folderDidChange(in: document)
        }
        await recentFiles.recordFolder(url, opening: opened?.url)
        return document
    }

    private nonisolated static func folderReadmes(_ folder: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        let preferredNames = ["readme.md", "readme", "readme.txt"]
        let readmes = children.compactMap { url -> (priority: Int, url: URL)? in
            let name = url.lastPathComponent.lowercased()
            guard name == "readme" || name.hasPrefix("readme."),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return (preferredNames.firstIndex(of: name) ?? preferredNames.count, url)
        }
        return readmes.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }.map(\.url)
    }

    @concurrent
    private nonisolated static func readForOpening(
        _ url: URL, allowMissing: Bool = false, within folder: URL? = nil, allowsPreview: Bool = true
    ) async throws -> OpenedFile {
        try Task.checkCancellation()
        let target: URL
        if let folder {
            target = FileBuffer.canonicalURL(url)
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard target.path.hasPrefix(prefix) else { throw FileBufferError.invalidPath(url) }
        } else {
            target = url
        }

        let identity: FileIdentity?
        let reason: String
        // Media can be much larger than text. Let the system decoders read it on demand.
        if allowsPreview, !target.pathExtension.isEmpty,
           let type = UTType(filenameExtension: target.pathExtension),
           type != .svg, !type.conforms(to: .text),
           type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video),
           let mediaIdentity = FileIdentity.at(target) {
            identity = mediaIdentity
            reason = ""
        } else {
            do {
                return try .text(FileBuffer.read(target, allowMissing: allowMissing))
            } catch {
                guard allowsPreview else { throw error }
                identity = FileIdentity.at(target)
                reason = error.localizedDescription
            }
        }
        let details = await FilePreviewDetails.load(target)
        try Task.checkCancellation()
        return .preview(OpenFilePreview(url: target, identity: identity, reason: reason, details: details))
    }

    func manualIconLanguage(for recent: RecentFile) -> String? {
        if let document = activeDocument,
           document.displayedFileURL == recent.canonicalURL || document.fileIdentity == recent.identity {
            return document.manualSyntaxLanguage?.iconIdentifier
        }
        return syntaxOverrides.language(for: recent.canonicalURL)?.iconIdentifier
    }

    private func requestOpen(_ urls: [URL], allowMissing: Bool = false, in document: DocumentWindow? = nil) {
        guard !urls.isEmpty, !isQuitting else { return }
        if !receivedInitialSession {
            pendingFiles.append((urls, allowMissing, document))
        } else {
            let document = document ?? activeDocument
            Task { await openFiles(urls, allowMissing: allowMissing, in: document) }
        }
    }

    @discardableResult
    func makeDocument(placement: WindowPlacement? = nil) -> DocumentWindow {
        let document = DocumentWindow(app: self, placement: placement)
        documents.append(document)
        return document
    }

    private func installMenus(in app: NSApplication) {
        let menuBar = NSMenu()
        func addMenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            menu.delegate = self
            menuBar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }

        let appMenu = addMenu("Edit")
        appMenu.addItem(withTitle: "Quit Edit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = addMenu("File")
        file.addCommand("New", #selector(newDocument(_:)), "n").target = self
        file.addCommand("New Window", #selector(newWindow(_:)), "n", [.command, .shift]).target = self
        file.addCommand("Open…", #selector(openDocument(_:)), "o").target = self
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        recentMenu = recent
        file.addCommand("Go to File…", #selector(showGoToFile(_:)), "p").target = self
        file.addItem(.separator())
        file.addCommand("Save", #selector(saveDocument(_:)), "s").target = self
        file.addCommand("Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift]).target = self
        file.addCommand("Save as Scratch…", #selector(saveDocumentAsScratch(_:))).target = self
        file.addCommand("Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = addMenu("Edit")
        edit.addCommand("Undo", Selector(("undo:")), "z")
        edit.addCommand("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.addCommand("Cut", #selector(NSText.cut(_:)), "x")
        edit.addCommand("Copy", #selector(NSText.copy(_:)), "c")
        edit.addCommand("Paste", #selector(NSText.paste(_:)), "v")
        edit.addCommand("Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        edit.addCommand("Focus Selection", #selector(focusSelection(_:))).target = self
        edit.addCommand("Exit Focus", #selector(exitFocus(_:))).target = self
        edit.addItem(.separator())

        edit.addCommand("Find…", #selector(openFind(_:)), "f").target = self
        edit.addCommand("Replace…", #selector(openReplace(_:)), "f", [.command, .option]).target = self
        edit.addCommand("Find Next", #selector(findNext(_:)), "g").target = self
        edit.addCommand("Find Previous", #selector(findPrevious(_:)), "g", [.command, .shift]).target = self
        edit.addItem(.separator())

        let lines = NSMenu(title: "Lines")
        lines.addCommand("Move Line Up", #selector(EditorTextView.moveLinesUp(_:)), "\u{F700}", [.option])
        lines.addCommand("Move Line Down", #selector(EditorTextView.moveLinesDown(_:)), "\u{F701}", [.option])
        lines.addCommand("Insert Line Above", #selector(EditorTextView.insertLineAbove(_:)), "\r", [.command, .shift])
        lines.addCommand("Insert Line Below", #selector(EditorTextView.insertLineBelow(_:)), "\r")
        lines.addCommand("Indent Lines", #selector(EditorTextView.indentLines(_:)), "]")
        lines.addCommand("Outdent Lines", #selector(EditorTextView.outdentLines(_:)), "[")
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines

        let selection = NSMenu(title: "Selection")
        selection.addCommand("Add Caret Above", #selector(EditorTextView.addCaretAbove(_:)), "\u{F700}", [.command, .option])
        selection.addCommand("Add Caret Below", #selector(EditorTextView.addCaretBelow(_:)), "\u{F701}", [.command, .option])
        selection.addCommand("Add Carets at Ends of Lines", #selector(EditorTextView.addCaretsAtLineEnds(_:)), "i", [.option, .shift])
        selection.addItem(.separator())
        selection.addCommand("Select Next Occurrence", #selector(EditorTextView.selectNextOccurrence(_:)), "d")
        selection.addCommand("Skip to Next Occurrence", #selector(EditorTextView.skipNextOccurrence(_:)))
        selection.addCommand("Select All Occurrences", #selector(EditorTextView.selectAllOccurrences(_:)), "l", [.command, .shift])
        selection.addItem(.separator())
        selection.addCommand("Undo Selection", #selector(EditorTextView.undoSelection(_:)), "u")
        selection.addCommand("Redo Selection", #selector(EditorTextView.redoSelection(_:)), "u", [.command, .shift])
        selection.addCommand("Keep Only Primary Selection", #selector(EditorTextView.keepPrimarySelection(_:)))
        edit.addItem(withTitle: "Selection", action: nil, keyEquivalent: "").submenu = selection

        let view = addMenu("View")
        view.addCommand("Toggle Sidebar", #selector(toggleSidebar(_:)), "b").target = self
        view.addCommand("Focus Worktree", #selector(toggleWorktreeSidebar(_:)), "e", [.command, .shift]).target = self
        view.addCommand("Focus Scratches", #selector(focusScratches(_:)), "w", [.command, .shift]).target = self
        view.addCommand("Command Mode…", #selector(showCommandMode(_:)), "p", [.command, .shift]).target = self
        view.addCommand("Change Language Mode…", #selector(showLanguageModes(_:))).target = self
        view.addItem(.separator())
        view.addCommand("Increase Text Size", #selector(EditorTextView.increaseTextSize(_:)), "=")
        view.addCommand("Decrease Text Size", #selector(EditorTextView.decreaseTextSize(_:)), "-")
        view.addCommand("Reset Text Size", #selector(EditorTextView.resetTextSize(_:)), "0")
        view.addItem(.separator())
        view.addCommand("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])

        let window = addMenu("Window")
        window.addCommand("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addCommand("Zoom", #selector(NSWindow.performZoom(_:)))
        let help = addMenu("Help")
        app.mainMenu = menuBar
        app.windowsMenu = window
        app.helpMenu = help
    }

    private func checkWindow(_ window: NSWindow, screenshot: String?) throws {
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited, !app.isActive, !window.isVisible,
              let frameView = window.contentView?.superview else {
            throw CheckError.unexpectedWindow
        }

        window.layoutIfNeeded()
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CheckError.unrenderableWindow
        }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        if let screenshot {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CheckError.unrenderableWindow
            }
            try png.write(to: URL(fileURLWithPath: screenshot), options: .atomic)
        }
    }

    private enum CheckError: LocalizedError {
        case unexpectedWindow
        case unrenderableWindow

        var errorDescription: String? {
            switch self {
            case .unexpectedWindow:
                "Expected a hidden, non-activating window."
            case .unrenderableWindow:
                "AppKit could not render the window."
            }
        }
    }
}

private extension NSMenu {
    @discardableResult
    func addCommand(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
