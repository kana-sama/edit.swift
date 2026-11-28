import AppKit
import UniformTypeIdentifiers

struct OpenFilePreview: Sendable {
    let url: URL
    let identity: FileIdentity?
    let reason: String
    let details: FilePreviewDetails
    var mediaBacking: FilePreviewMediaBacking? = nil
    var allowsReveal = true
}

enum OpenedFile: Sendable {
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
    func destination(focusEditor: Bool, scratch: ScratchFile? = nil, folder: URL? = nil) -> DocumentWindow.CloseDestination {
        switch self {
        case .text(let file):
            .buffer(file, focusEditor: focusEditor, scratch: scratch, folder: folder)
        case .preview(let preview):
            .preview(preview, focusEditor: focusEditor, folder: folder)
        }
    }
}

@main
@MainActor
final class Edit: NSObject, NSApplicationDelegate, NSUserInterfaceValidations, NSMenuDelegate {
    private struct OpenRequest {
        let document: DocumentWindow
        let generation: UInt64
        let mutationGeneration: UInt64
        let isWanted: () -> Bool
    }

    private struct ClosedFile {
        let url: URL
        let folder: URL?
        let markdown: EditorPosition?
        let revision: MarkdownRevisionRecord?
        let syntax: String?
        weak var document: DocumentWindow?
    }

#if EDIT_AGENT_CHECKS
    let isAgentCheck = CommandLine.arguments.dropFirst().first == "--agent-check"
    var holdSessionFileReadForCheck: ((URL) async -> Void)?
    var observeStartupPresentationForCheck: ((DocumentWindow) -> Void)?
#else
    let isAgentCheck = false
#endif
    private lazy var sessionStore = SessionStore.application()
    lazy var draftRecovery = DraftRecoveryStore(directory: storageFolder.appending(path: "DraftRecovery", directoryHint: .isDirectory))
    lazy var syntaxOverrides = SyntaxLanguageOverrides(defaults: isAgentCheck ? nil : .standard)
    lazy var fileWordWrap = FileWordWrap(defaults: isAgentCheck ? nil : .standard)
    lazy var fileIndentation = FileIndentationOverrides(defaults: isAgentCheck ? nil : .standard)
    lazy var workspaceLanguageServers = WorkspaceLanguageServers(defaults: isAgentCheck ? nil : .standard)
    lazy var workspaceHighlighting = WorkspaceHighlighting(defaults: isAgentCheck ? nil : .standard)
    lazy var workspaceFormatOnSave = WorkspaceFormatOnSave(defaults: isAgentCheck ? nil : .standard)
    lazy var workspaceFindPreferences = WorkspaceFindPreferences(defaults: isAgentCheck ? nil : .standard)
    private weak var recentMenu: NSMenu?
    private weak var focusJujutsuItem: NSMenuItem?
    private weak var findPreviousItem: NSMenuItem?
    private var controlPanel: ControlPanel?
    private var windowEventMonitor: Any?
    private var openFilePanel: OpenFilePanel?
    private weak var openPanelDocument: DocumentWindow?
    private(set) lazy var recentFiles = RecentFiles(url: recentHistoryURL)
    lazy var jjChanges = JJChangeMonitor()
    lazy var sourceControlRevsets = SourceControlRevsetStore(url: storageFolder.appending(path: "jujutsu-revsets.json"))
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
    private var closedFiles: [ClosedFile] = []
    private var reopeningClosedFile = false
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
        let app = EditApplication.shared
        let delegate = Edit()
        app.delegate = delegate
        app.setActivationPolicy(delegate.isAgentCheck ? .prohibited : .regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        // Begin reading the one atomic session file before building the launch UI.
        let saved = isAgentCheck ? nil : readStartupSession(from: sessionStore)
        installMenus(in: app)
        windowEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return routeWindowEvent(event)
        }
#if EDIT_AGENT_CHECKS
        if isAgentCheck {
            receivedInitialSession = true
            let initial = makeDocument()
            Task { @MainActor in
                do {
                    let arguments = CommandLine.arguments.dropFirst(2)
                    if arguments.first == "--only" {
                        try await checkOnly(arguments.dropFirst(), in: initial)
                        exit(EXIT_SUCCESS)
                    }
                    try EditorCheck.run(in: initial)
                    // The text editor check uses its own undo grouping and sample text.
                    initial.window.close()
                    makeDocument()
                    try await TerminalCheck.run(in: self)
                    print("Edit passed its native terminal checks without activation.")
                    let sample = try await FilesCheck.run(in: self)
                    try await ControlPanel(app: self).checkHidden(in: sample)
                    try await ControlPanel(app: self).checkPins(in: sample)
                    try await ControlSearchCheck.run(in: self)
                    try await SyntaxCheck.run(in: self)
                    try await MarkdownCheck.run(in: self)
                    try await BracketCheck.run(in: self)
                    try await OccurrenceCheck.run(in: self)
                    try await FindCheck.run(in: self)
                    try await WorkspaceFindCheck.run(in: self) { _, _ in }
                    try ReferencesCheck.run(in: makeDocument()) { _, _ in }
                    try await NavigationHistoryCheck.run(in: self)
                    try await FocusCheck.run(in: self)
                    try checkWindow(sample.window, screenshot: arguments.first)
                    try MultiCaretCheck.runComposition(in: sample.editor)
                    try await checkEditorViewport()
                    try await WordWrapCheck.run(in: self) { window, _ in
                        try checkWindow(window, screenshot: nil)
                    }
                    let folderWindow = try await FolderCheck.run(in: self)
                    try checkWindow(folderWindow, screenshot: nil)
                    try await FolderCheck.checkCloseWorkspace(in: self) { _, _ in }
                    try await HeaderCheck.run(in: self)
                    try await WorktreeCheck.run(in: self)
                    try await checkJJ()
                    try await FilesCheck.checkFilePreview(in: self)
                    try await ScratchCheck.run(in: self)
                    try await ScratchTreeCheck.run(in: self)
                    try MultiCaretCheck.checkBlink()
                    try await OpenFilePanelCheck.run(in: self)
                    try await StartupRestoreCheck.run(in: self)
                    try await TerminalCheck.checkFolderSessions(in: self)
                    print("Edit passed its native editing and file-session checks without activation.")
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("Edit check: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
            }
            return
        }

#endif
        app.activate()

        let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--" && !$0.hasPrefix("-psn_") }
        if !arguments.isEmpty {
            let urls = arguments.map { URL(fileURLWithPath: $0).standardizedFileURL }
            pendingFiles.append((urls, true, nil))
        }

        guard let saved else { return }
        startup = Task { @MainActor in
            await restoreStartupSession(from: saved)
            startup = nil
            receivedInitialSession = true
            let requests = pendingFiles
            pendingFiles.removeAll()
            for request in requests where !isQuitting {
                await openFiles(request.urls, allowMissing: request.allowMissing, in: request.document)
            }
        }
    }

    func readStartupSession(from store: SessionStore) -> Task<EditorSession?, any Error> {
        Task.detached(priority: .userInitiated) { try store.read() }
    }

    func restoreStartupSession(from sessionRead: Task<EditorSession?, any Error>) async {
        async let recovery = draftRecovery.read()
        Task { await recentFiles.prune() }

        var saved: EditorSession?
        var sessionError: String?
        do {
            saved = try await sessionRead.value
        } catch {
            sessionReadFailed = true
            sessionError = error.localizedDescription
        }
        var checkpoints: [DraftCheckpoint] = []
        var recoveryError: String?
        do {
            let result = try await recovery
            checkpoints = result.checkpoints
            if result.unreadable > 0 { recoveryError = "Some draft recovery files could not be read." }
        } catch {
            recoveryError = error.localizedDescription
        }
        let activeDraftIDs = Set(documents.compactMap(\.draftRecoveryID))
        checkpoints.removeAll { activeDraftIDs.contains($0.revision.id) }
        let previous = EditorSession.recovering(checkpoints, into: saved)
            ?? EditorSession(documents: [], activeIndex: nil, lastWindow: nil)
        await restore(previous)

        if !isQuitting, let document = activeDocument {
            if let sessionError {
                Task { await document.showError("Could Not Restore Session", detail: sessionError) }
            }
            if let recoveryError {
                Task { await document.showError("Could Not Recover Some Drafts", detail: recoveryError) }
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

    func applicationDidResignActive(_ notification: Notification) {
        for document in documents { document.checkForExternalFileChanges() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowEventMonitor { NSEvent.removeMonitor(windowEventMonitor) }
        documents.forEach { $0.closeTerminalSessions() }
    }

    func routeWindowEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
            if event.characters(byApplyingModifiers: []) == "-",
               modifiers == .control || modifiers == [.control, .shift] {
                let direction: NavigationHistory.Direction = modifiers.contains(.shift) ? .forward : .back
                if let document = navigationDocument(for: event.window ?? NSApp.keyWindow), canNavigate(direction, in: document) {
                    Task { await navigate(direction, in: document) }
                    return nil
                }
            }
            if event.charactersIgnoringModifiers?.lowercased() == "g",
               modifiers == [.command, .shift] {
                updateJujutsuShortcut()
            }
            let document = documents.first { $0.window === event.window }
            if modifiers.isEmpty, event.keyCode == 53, document?.handleMarkdownEscape() == true { return nil }
            if (modifiers == .command || modifiers == [.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "z",
               document?.handleMarkdownUndo(redo: modifiers.contains(.shift)) == true { return nil }
            return document?.handleTerminalKey(event) == true ? nil : event
        default:
            return routeTitleClick(event)
        }
    }

    private func routeTitleClick(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard !isQuitting, let window = event.window else { return event }
        let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && modifiers == .control)
        let primary = event.type == .leftMouseDown && modifiers.isEmpty && event.clickCount == 1
        guard primary || secondary else { return event }

        // AppKit can host the fullscreen toolbar in a different window from the document.
        for document in documents {
            let handled = primary
                ? document.titleBar.handlePrimaryClick(at: event.locationInWindow, in: window)
                : document.titleBar.handleSecondaryClick(at: event.locationInWindow, in: window)
            if handled { return nil }
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
        if menu === focusJujutsuItem?.menu || menu === findPreviousItem?.menu { updateJujutsuShortcut() }
        guard let recentMenu, menu === recentMenu || menu === recentMenu.supermenu else { return }
        populateRecentMenu(recentMenu)
        if menu === recentMenu { Task { await recentFiles.prune() } }
    }

    private func populateRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = recentFiles.entries(in: activeDocument?.folderURL)
        if !recentFiles.folders.isEmpty {
            menu.addItem(.sectionHeader(title: "Folders"))
            for recent in recentFiles.folders.prefix(10) {
                let item = menu.addItem(withTitle: recent.displayPath, action: #selector(openRecentDocument(_:)),
                                        keyEquivalent: "")
                item.target = self
                item.representedObject = recent.url
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            }
            if !files.isEmpty { menu.addItem(.separator()) }
        }
        if !files.isEmpty {
            menu.addItem(.sectionHeader(title: "Files"))
        }
        for recent in files.prefix(10) {
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
    @objc func showDocumentSymbols(_ sender: Any?) { showControl(.documentSymbols) }
    @objc func showWorkspaceSymbols(_ sender: Any?) { showControl(.workspaceSymbols) }

#if EDIT_AGENT_CHECKS
    func checkHeaderLanguagePicker(in document: DocumentWindow) throws {
        guard let controlPanel else { throw CocoaError(.featureUnsupported) }
        try controlPanel.checkHeaderLanguagePicker(in: document)
    }

#endif

    func showLanguageModes(in document: DocumentWindow) {
        showControl(.languages, in: document)
    }

    private func showControl(_ mode: ControlPanel.Mode, in source: DocumentWindow? = nil) {
        guard let document = source ?? activeDocument, !isQuitting,
              mode != .languages && mode != .documentSymbols || document.hasTextDocument else { return }
        let panel = controlPanel ?? ControlPanel(app: self)
        controlPanel = panel
        panel.toggle(in: document, mode: mode)
    }

    func languageServerStateDidChange(in document: DocumentWindow) {
        controlPanel?.languageServerStateDidChange(in: document)
    }

    var pathsWithLanguageErrors: Set<String> {
        documents.reduce(into: Set<String>()) { $0.formUnion($1.languageFeatures.pathsWithErrors) }
    }

    func worktreeDiagnosticsDidChange() {
        let paths = pathsWithLanguageErrors
        for document in documents { document.worktreeSidebar?.setDiagnosticPaths(paths) }
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

    @objc func closeDocument(_ sender: Any?) {
        activeDocument?.closeDocument()
    }

    @objc func closeWorkspace(_ sender: Any?) {
        activeDocument?.closeWorkspace()
    }

    func workspaceDidClose(in document: DocumentWindow) {
        controlPanel?.folderDidChange(in: document)
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
            case .success(.some(let selection)):
                if selection.inAnotherWindow {
                    Task {
                        do {
                            _ = try await openInAnotherWindow(selection.url)
                        } catch {
                            if !isQuitting && documents.contains(where: { $0 === document }) {
                                await document.showError("Could Not Open “\(selection.url.lastPathComponent)”",
                                                         detail: error.localizedDescription)
                            }
                        }
                    }
                } else {
                    requestOpen([selection.url], in: document)
                }
            case .success(nil): break
            case .failure(let error):
                Task { await document.showError("Could Not Open", detail: error.localizedDescription) }
            }
        }
    }

    func openInAnotherWindow(_ url: URL, folder: URL? = nil) async throws -> DocumentWindow? {
        guard !isQuitting, !Task.isCancelled else { return nil }
        let document = makeDocument()
        if let folder { document.setFolder(folder) }
        var opened = false
        defer {
            if !opened { document.window.close() }
        }
        guard try await openFile(url, in: document) != nil, !isQuitting, !Task.isCancelled else { return nil }
        opened = true
        if !isAgentCheck { document.present() }
        return document
    }

    private var canReopenClosedFile: Bool {
        !isQuitting && !reopeningClosedFile && !closedFiles.isEmpty && activeDocument?.window.attachedSheet == nil
    }

    @objc func reopenClosedFile(_ sender: Any?) {
        guard canReopenClosedFile, let entry = closedFiles.last else { return }
        let index = closedFiles.count - 1
        reopeningClosedFile = true
        Task {
            defer { reopeningClosedFile = false }
            do {
                if let revision = entry.revision {
                    let loaded = try await revision.load()
                    guard !isQuitting else { return }
                    let document: DocumentWindow
                    if let previous = entry.document, documents.contains(where: { $0 === previous }),
                       previous.showsEmptyFolder, previous.folderURL == entry.folder, previous.canReplaceBuffer {
                        document = previous
                    } else {
                        document = makeDocument()
                        if let folder = entry.folder { document.setFolder(folder) }
                    }
                    document.restoreMarkdownRevision(loaded, syntax: entry.syntax)
                    document.restoreEditorPosition(entry.markdown)
                    if !isAgentCheck { document.present() }
                } else if let document = entry.document, documents.contains(where: { $0 === document }),
                   document.folderURL == entry.folder, document.showsEmptyFolder, document.canReplaceBuffer {
                    guard try await openFile(entry.url, in: document, shouldOpen: {
                        document.showsEmptyFolder && document.folderURL == entry.folder
                    }) != nil else { return }
                    if entry.markdown != nil { document.restoreEditorPosition(entry.markdown) }
                    if !isAgentCheck && !isQuitting { document.present() }
                } else {
                    guard let document = try await openInAnotherWindow(entry.url, folder: entry.folder) else { return }
                    if entry.markdown != nil { document.restoreEditorPosition(entry.markdown) }
                }
                // New closes can append entries while the reopen is preparing the file.
                closedFiles.remove(at: index)
            } catch {
                if !isQuitting {
                    await activeDocument?.showError("Could Not Reopen “\(entry.url.lastPathComponent)”",
                                                    detail: error.localizedDescription)
                }
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
        guard let document = activeDocument, document.canPerformFind(.find) else { return }
        controlPanel?.dismiss(restoreFocus: true)
        document.performFind(.find)
    }

    @objc func openWorkspaceFind(_ sender: Any?) {
        guard let document = activeDocument, document.canPerformFind(.findWorkspace) else { return }
        controlPanel?.dismiss(restoreFocus: true)
        document.performFind(.findWorkspace)
    }

    @objc func openReplace(_ sender: Any?) {
        controlPanel?.dismiss(restoreFocus: true)
        activeDocument?.performFind(.replace)
    }

    @objc func findNext(_ sender: Any?) { activeDocument?.performFind(.next) }
    @objc func findPrevious(_ sender: Any?) { activeDocument?.performFind(.previous) }

    @objc func toggleTerminal(_ sender: Any?) {
        controlPanel?.dismiss(restoreFocus: true)
        activeDocument?.toggleTerminal()
    }
    // Keep the selector used by existing Control pins and command history.
    @objc(toggleFindSidebar:) func toggleSidebar(_ sender: Any?) { activeDocument?.performFind(.toggleSidebar) }

    // Keep the selector used by existing Control pins and command history.
    @objc func toggleWorktreeSidebar(_ sender: Any?) {
        focusSidebar(.worktree)
    }

    @objc func focusScratches(_ sender: Any?) {
        focusSidebar(.scratches)
    }

    @objc func focusJujutsu(_ sender: Any?) {
        focusSidebar(.sourceControl)
    }

    func updateJujutsuShortcut() {
        let document = activeDocument
        let inWorkspace = document?.hasJujutsuWorkspace == true
        document?.recheckJujutsuSidebar(available: inWorkspace)
        // Keep Find Previous on the same shortcut in windows where Jujutsu is unavailable.
        focusJujutsuItem?.keyEquivalent = inWorkspace ? "g" : ""
        focusJujutsuItem?.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem?.keyEquivalent = inWorkspace ? "" : "g"
        findPreviousItem?.keyEquivalentModifierMask = [.command, .shift]
    }

    private func focusSidebar(_ mode: SidebarMode) {
        guard let document = activeDocument, document.canFocusSidebar(mode) else { return }
        controlPanel?.dismiss(restoreFocus: true)
        document.toggleSidebarFocus(mode)
    }

    @objc func performFindControlAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? FindCommand { activeDocument?.performFind(command) }
    }

    @objc func focusSelection(_ sender: Any?) { activeDocument?.focusSelection() }
    @objc func exitFocus(_ sender: Any?) { activeDocument?.exitFocus() }
    @objc func toggleMarkdownPreview(_ sender: Any?) { activeDocument?.toggleMarkdownPreview() }
    @objc func toggleWordWrap(_ sender: Any?) { activeDocument?.toggleWordWrap() }
    @objc func toggleFormatOnSave(_ sender: Any?) { activeDocument?.toggleFormatOnSave() }
    @objc func toggleLSPHighlight(_ sender: Any?) { activeDocument?.toggleHighlighting(.lsp) }
    @objc func toggleTreeSitterHighlight(_ sender: Any?) { activeDocument?.toggleHighlighting(.treeSitter) }

    @objc func goBack(_ sender: Any?) { navigateInCurrentWindow(.back) }
    @objc func goForward(_ sender: Any?) { navigateInCurrentWindow(.forward) }

    private var currentNavigationDocument: DocumentWindow? {
        navigationDocument(for: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private func navigationDocument(for window: NSWindow?) -> DocumentWindow? {
        guard let window else { return nil }
        // Control is a child window of the document it serves.
        return documents.first { $0.window === window || $0.window === window.parent }
    }

    private func navigateInCurrentWindow(_ direction: NavigationHistory.Direction) {
        guard let document = currentNavigationDocument else { return }
        Task { await navigate(direction, in: document) }
    }

    func recordNavigation(in document: DocumentWindow, reason: NavigationHistory.Reason = .selection) {
        guard let location = document.navigationLocation else { return }
        recordNavigation(location, in: document, reason: reason)
    }

    func recordNavigation(_ location: NavigationHistory.Location, in document: DocumentWindow, reason: NavigationHistory.Reason) {
        guard !isQuitting, !document.isReplayingNavigation, documents.contains(where: { $0 === document }) else { return }
        document.navigationHistory.record(location, reason: reason)
    }

    func retargetNavigation(from source: URL, to destination: URL) {
        for document in documents {
            document.navigationHistory.moveFiles { url in
                guard let suffix = DocumentWindow.worktreePathSuffix(from: source, to: url) else { return nil }
                return (suffix.isEmpty ? destination : destination.appending(path: suffix, directoryHint: .notDirectory))
                    .standardizedFileURL
            }
        }
    }

    func removeNavigationFiles(under urls: [URL]) {
        for document in documents {
            document.navigationHistory.removeFiles { file in
                urls.contains { DocumentWindow.worktreePathSuffix(from: $0, to: file) != nil }
            }
        }
    }

    func canNavigate(_ direction: NavigationHistory.Direction, in document: DocumentWindow) -> Bool {
        !isQuitting && document.window.attachedSheet == nil && documents.contains { $0 === document } &&
            document.navigationHistory.canGo(direction)
    }

    func navigate(_ direction: NavigationHistory.Direction, in document: DocumentWindow) async {
        let history = document.navigationHistory
        while !Task.isCancelled, canNavigate(direction, in: document), let move = history.begin(direction) {
            guard await skipOrNavigate(to: move, in: document) else { return }
        }
    }

    /// A location discarded while looking it up should not block the remaining stack.
    private func skipOrNavigate(to move: NavigationHistory.Move, in document: DocumentWindow) async -> Bool {
        let history = document.navigationHistory
        let location = move.location
        let isCurrent = {
            !self.isQuitting && !Task.isCancelled && history.isPending(move) && self.documents.contains { $0 === document }
        }
        var opened = false
        defer { history.finish(move, opened: opened) }

        if document.navigationLocation?.resource != location.resource {
            if case .revision(let key) = location.resource {
                let reopened = await document.reopenMarkdownRevision(key, while: isCurrent)
                guard isCurrent() else { return false }
                if !reopened {
                    history.remove(resource: location.resource)
                    return true
                }
            } else if case .file(let url) = location.resource {
                let missing = await Self.navigationFileIsMissing(url)
                guard isCurrent() else { return false }
                if missing {
                    history.remove(resource: location.resource)
                    return true
                }
                do {
                    guard try await openFile(url, in: document, focusEditor: false, shouldOpen: isCurrent) === document else { return false }
                } catch {
                    guard isCurrent() else { return false }
                    await document.showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
                    return false
                }
            } else {
                history.remove(resource: location.resource)
                return true
            }
        }
        guard isCurrent() else { return false }
        document.isReplayingNavigation = true
        defer { document.isReplayingNavigation = false }
        controlPanel?.dismiss(in: document, restoreFocus: false)
        if let markdown = location.markdown { document.restoreMarkdownState(markdown) }
        if let selection = location.selection, document.hasTextDocument, location.markdown?.showsPreview != true {
            document.restoreNavigationSelection(selection)
        } else {
            document.focusContent()
        }
        opened = true
        return false
    }

    @concurrent private nonisolated static func navigationFileIsMissing(_ url: URL) async -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch let error as CocoaError {
            return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        } catch {
            return false
        }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !isQuitting else { return false }
        switch item.action {
        case #selector(focusSelection(_:)): return activeDocument?.canFocusSelection ?? false
        case #selector(exitFocus(_:)): return activeDocument?.canExitFocus ?? false
        case #selector(toggleMarkdownPreview(_:)): return activeDocument?.canToggleMarkdownPreview ?? false
        case #selector(toggleWordWrap(_:)):
            (item as? NSMenuItem)?.state = activeDocument?.editor.wrapsWords == true ? .on : .off
            return activeDocument?.canToggleWordWrap ?? false
        case #selector(toggleFormatOnSave(_:)):
            (item as? NSMenuItem)?.state = activeDocument?.isFormatOnSaveEnabled == true ? .on : .off
            return activeDocument?.canChangeWorkspaceSettings ?? false
        case #selector(toggleLSPHighlight(_:)), #selector(toggleTreeSitterHighlight(_:)):
            let layer: HighlightingLayer = item.action == #selector(toggleLSPHighlight(_:)) ? .lsp : .treeSitter
            (item as? NSMenuItem)?.state = activeDocument?.isHighlightingEnabled(layer) == true ? .on : .off
            return activeDocument?.canChangeWorkspaceSettings ?? false
        case #selector(goBack(_:)), #selector(goForward(_:)):
            guard let document = currentNavigationDocument else { return false }
            return canNavigate(item.action == #selector(goBack(_:)) ? .back : .forward, in: document)
        case #selector(newDocument(_:)): return activeDocument?.canReplaceBuffer ?? false
        case #selector(closeDocument(_:)): return activeDocument?.canCloseDocument ?? false
        case #selector(closeWorkspace(_:)): return activeDocument?.canCloseWorkspace ?? false
        case #selector(showGoToFile(_:)), #selector(showCommandMode(_:)), #selector(showWorkspaceSymbols(_:)):
            return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(showLanguageModes(_:)), #selector(showDocumentSymbols(_:)):
            return activeDocument.map { $0.hasTextDocument && $0.window.attachedSheet == nil } ?? false
        case #selector(newWindow(_:)): return true
        case #selector(openDocument(_:)):
            return openFilePanel?.isOpening == true || activeDocument?.canReplaceBuffer == true
        case #selector(openRecentDocument(_:)):
            return activeDocument?.canReplaceBuffer ?? false
        case #selector(reopenClosedFile(_:)): return canReopenClosedFile
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(saveDocumentAsScratch(_:)):
            return activeDocument.map { $0.hasEditableTextDocument && !$0.isBusy && $0.window.attachedSheet == nil } ?? false
        case #selector(openFind(_:)): return activeDocument?.canPerformFind(.find) ?? false
        case #selector(openWorkspaceFind(_:)): return activeDocument?.canPerformFind(.findWorkspace) ?? false
        case #selector(openReplace(_:)): return activeDocument?.canPerformFind(.replace) ?? false
        case #selector(toggleSidebar(_:)), #selector(focusScratches(_:)), #selector(toggleTerminal(_:)):
            return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(toggleWorktreeSidebar(_:)):
            return activeDocument.map { $0.folderURL != nil && $0.window.attachedSheet == nil } ?? false
        case #selector(focusJujutsu(_:)):
            return activeDocument?.canFocusSidebar(.sourceControl) ?? false
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
        // Quitting before any window has opened must not overwrite the saved session.
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
                await draftRecovery.removeSaved(in: session)
                if sender.isActive, let document = activeDocument {
                    let failures = documents.compactMap { $0.takeAutosaveFailure() }
                    if !failures.isEmpty {
                        await document.showError("Could Not Autosave Some Files",
                                                 detail: failures.joined(separator: "\n") +
                                                    "\n\nYour edits are available as drafts the next time you open Edit.")
                    }
                }
                for document in documents { document.languageFeatures.close() }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isQuitting = false
                for document in documents {
                    document.editor.isEditable = document.hasEditableTextDocument
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

    func recordClosedFile(in document: DocumentWindow) {
        let revision = document.markdownRevisionRecord
        guard !isQuitting, let url = document.displayedFileURL ?? (revision == nil ? nil : document.fileIconURL) else { return }
        closedFiles.append(ClosedFile(url: url, folder: document.folderURL, markdown: document.markdownPositionForClose,
                                      revision: revision, syntax: document.manualSyntaxLanguage?.rawValue, document: document))
    }

    func didClose(_ document: DocumentWindow) {
        if openPanelDocument === document { openFilePanel?.cancel() }
        lastPlacement = document.placement
        pendingFullScreen.removeAll { $0 === document }
        didFinishFullScreenRestore(for: document)
        documents.removeAll { $0 === document }
        updateJujutsuShortcut()
    }

    func reserveSave(
        to url: URL, identity: FileIdentity?, for document: DocumentWindow, duringWorkspaceMutation: Bool = false
    ) -> Bool {
        // Buffers already associated with a path compare their revisions before writing.
        // Save As must not claim a path owned by another window.
        guard !isWorktreeMutationPath(url) || (duringWorkspaceMutation && url == document.fileURL) else { return false }
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

    func performWorktreeMutation<T>(
        affecting sources: [URL], preservingRenameIn renameOrigin: DocumentWindow? = nil,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        let affected = documents.filter { $0.worktreeMutationAffects(sources) }
        guard !isQuitting, worktreeMutationPaths.isEmpty, affected.allSatisfy(\.canReplaceBuffer) else {
            throw worktreeBusyError()
        }
        worktreeMutationPaths = sources
        worktreeMutationGeneration &+= 1
        for document in affected { document.beginWorktreeMutation(preservingRename: document === renameOrigin) }
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

    // Preparing a window does not touch its live AppKit presentation.
    private struct SessionOpening: Sendable {
        let record: SessionDocument
        let url: URL?
        let folder: URL?
        let isScratch: Bool
        let scratch: ScratchFile?
        let historical: MarkdownRevisionRecord.Loaded?
        let opened: OpenedFile?
        let identity: FileIdentity?
        let syntax: SyntaxSnapshot?
        let openingConflicts: JJOpeningConflicts?
        let restoredConflicts: (text: String, edits: [JJConflictEdit])?
    }

    private func prepareSessionOpening(_ savedRecord: SessionDocument) async -> (SessionOpening?, [String]) {
        var warnings: [String] = []
        var record = savedRecord
        let historical: MarkdownRevisionRecord.Loaded?
        if let revision = record.markdownRevision {
            do { historical = try await revision.load() }
            catch {
                historical = nil
                warnings.append("“\(revision.path)” — \(error.localizedDescription)")
            }
        } else {
            historical = nil
        }
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
#if EDIT_AGENT_CHECKS
            await holdSessionFileReadForCheck?(url)
#endif
            do {
                opened = try await Self.readForOpening(
                    url,
                    allowsPreview: !isScratch && record.isFilePreview == true
                )
            } catch {
                warnings.append("“\(scratch?.name ?? url.lastPathComponent)” — \(error.localizedDescription)")
                guard record.folderPath != nil || record.terminal != nil || record.inactiveTerminals?.isEmpty == false
                else { return (nil, warnings) }
                opened = nil
            }
        } else {
            opened = nil
        }
        let folder = record.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let identity: FileIdentity?
        let syntax: SyntaxSnapshot?
        let openingConflicts: JJOpeningConflicts?
        let restoredConflicts: (text: String, edits: [JJConflictEdit])?
        if let draft = record.draft {
            if let drafts = record.conflictDrafts, !drafts.isEmpty {
                restoredConflicts = await JJConflictEdit.restore(drafts, in: draft)
                if restoredConflicts == nil {
                    let name = url?.lastPathComponent ?? "Untitled"
                    warnings.append("“\(name)” opened as untitled because its conflict draft could not be restored.")
                    record.path = nil
                    record.revision = nil
                }
            } else {
                restoredConflicts = nil
            }
            let draftURL = record.path == nil ? nil : url
            let conflictURL = isScratch || restoredConflicts != nil ? nil : draftURL
            async let conflicts = JJOpeningConflicts.prepare(draft, at: conflictURL)
            identity = await Task.detached { draftURL.flatMap { FileIdentity.at($0) } }.value
            syntax = nil
            openingConflicts = await conflicts
        } else {
            identity = nil
            restoredConflicts = nil
            if case .text(let file) = opened, folder == nil || file.identity != nil {
                async let conflicts = JJOpeningConflicts.prepare(file.text, at: isScratch ? nil : file.url)
                syntax = await DocumentWindow.prepareOpeningSyntax(
                    file, position: record.editorPosition, folder: folder,
                    storedSyntaxLanguage: record.syntaxLanguage, scratch: scratch, app: self,
                    visibleLines: Int(ceil(record.placement.openingHeight / 18)) + 2
                )
                openingConflicts = await conflicts
            } else {
                syntax = nil
                openingConflicts = nil
            }
        }

        return (SessionOpening(record: record, url: url, folder: folder, isScratch: isScratch, scratch: scratch,
                               historical: historical, opened: opened, identity: identity, syntax: syntax,
                               openingConflicts: openingConflicts, restoredConflicts: restoredConflicts), warnings)
    }

    private func installSessionOpening(_ opening: SessionOpening, in document: DocumentWindow) {
        let record = opening.record
        let folder = opening.folder
        let scratch = opening.scratch
        if let folder { document.setFolder(folder) }
        if let historical = opening.historical {
            document.restoreMarkdownRevision(historical, syntax: record.syntaxLanguage)
        } else if let draft = record.draft {
            document.restoreDraft(record, text: opening.restoredConflicts?.text ?? draft, identity: opening.identity, scratch: scratch,
                                  openingConflicts: opening.openingConflicts, restoredConflicts: opening.restoredConflicts?.edits ?? [])
        } else if let opened = opening.opened, document.folderURL == nil || opened.identity != nil {
            switch opened {
            case .text(let file):
                document.load(file, storedSyntaxLanguage: record.syntaxLanguage, preparedSyntax: opening.syntax,
                              openingConflicts: opening.openingConflicts, scratch: scratch)
            case .preview(let preview):
                document.loadPreview(preview)
                document.focusContent()
            }
        } else if document.folderURL != nil && (record.path != nil || record.showsEmptyFolder != false) {
            document.loadEmptyFolder()
            document.focusContent()
        } else if record.path == nil, record.syntaxLanguage != nil {
            document.restoreDraft(record, text: "")
        }
        document.restoreSidebar(record)
        document.restoreTerminals(from: record)
        document.restoreEditorPosition(record.editorPosition)
    }

    func restore(_ previous: EditorSession, reusing placeholder: DocumentWindow? = nil) async {
        lastPlacement = previous.lastWindow
        var restored: [(index: Int, document: DocumentWindow)] = []
        var warnings: [String] = []
        var recent: [(index: Int, url: URL?, folder: URL?, scratch: ScratchFile?)] = []

        func install(_ opening: SessionOpening?, at index: Int) {
            guard let opening else { return }
            let document: DocumentWindow
            if let placeholder, restored.isEmpty, documents.contains(where: { $0 === placeholder }),
               placeholder.canRestoreSession {
                document = placeholder
                document.restorePlacement(opening.record.placement)
            } else {
                document = DocumentWindow(app: self, placement: opening.record.placement)
                let successor = restored.first { $0.index > index }?.document
                let insertion = successor.flatMap { successor in documents.firstIndex { $0 === successor } }
                documents.insert(document, at: insertion ?? documents.endIndex)
            }
            installSessionOpening(opening, in: document)
            if isQuitting { document.editor.isEditable = false }
            let insertion = restored.firstIndex { $0.index > index } ?? restored.endIndex
            restored.insert((index, document), at: insertion)
            if let scratch = opening.scratch {
                recent.append((index, nil, opening.folder, scratch))
            } else if !opening.isScratch, let url = opening.url, opening.record.path != nil {
                recent.append((index, url, opening.folder, nil))
            }
            let key = NSApp.keyWindow
            let isRestoredKey = restored.contains { $0.document.window === key }
            let preferred = index == previous.activeIndex && isRestoredKey
            presentRestoredWindow(document, behind: preferred ? nil : key)
        }

        await withTaskGroup(of: (Int, SessionOpening?, [String]).self) { group in
            for (index, record) in previous.documents.enumerated() {
                group.addTask {
                    let (opening, warnings) = await self.prepareSessionOpening(record)
                    return (index, opening, warnings)
                }
            }
            var waiting: [Int: (SessionOpening?, [String])] = [:]
            var next = 0
            for await (index, opening, issues) in group {
                if placeholder == nil {
                    warnings += issues
                    install(opening, at: index)
                } else {
                    // A caller supplying a reusable window expects it to receive the first surviving record.
                    waiting[index] = (opening, issues)
                    while let (opening, issues) = waiting.removeValue(forKey: next) {
                        warnings += issues
                        install(opening, at: next)
                        next += 1
                    }
                }
            }
        }

        if restored.isEmpty {
            if let placeholder, documents.contains(where: { $0 === placeholder }), placeholder.canRestoreSession {
                if let placement = previous.lastWindow { placeholder.restorePlacement(placement) }
            } else if documents.isEmpty && !isQuitting {
                let document = makeDocument(placement: previous.lastWindow)
                presentRestoredWindow(document)
            }
        }
        if !isAgentCheck && !isQuitting && !warnings.isEmpty {
            let detail = warnings.joined(separator: "\n")
            Task { await activeDocument?.showError("Could Not Reopen Some Files", detail: detail) }
        }
        // Persist recency after ordering the windows, never on the path to their first frame.
        for entry in recent.sorted(by: { $0.index < $1.index }) {
            if let scratch = entry.scratch {
                await recordScratchOpen(scratch)
            } else if let url = entry.url {
                await recentFiles.record(url, in: entry.folder, rememberInFolder: false)
            }
        }
    }

    private func presentRestoredWindow(_ document: DocumentWindow, behind frontWindow: NSWindow? = nil) {
        guard !isQuitting else { return }
#if EDIT_AGENT_CHECKS
        if isAgentCheck {
            guard let observeStartupPresentationForCheck else { return }
            document.present(behind: frontWindow)
            observeStartupPresentationForCheck(document)
            return
        }
#endif
        document.present(behind: frontWindow)
    }

    @discardableResult
    func openFiles(
        _ urls: [URL], allowMissing: Bool = false, in sourceDocument: DocumentWindow? = nil,
        focusEditor: Bool = true, shouldOpen: @escaping () -> Bool = { true }
    ) async -> Bool {
        guard !urls.isEmpty, let request = beginOpening(in: sourceDocument, while: shouldOpen) else { return false }
        let document = request.document
        var allOpened = true
        for url in urls {
            do {
                guard try await openFile(url, allowMissing: allowMissing, request: request, focusEditor: focusEditor) != nil
                else { return false }
            } catch is CancellationError {
                return false
            } catch {
                allOpened = false
                await recentFiles.removeIfMissing(url)
                if !isAgentCheck && isCurrent(request, at: url) && document.canReplaceBuffer {
                    await document.showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
                }
            }
        }
        return allOpened
    }

    @discardableResult
    func openFile(
        _ url: URL, allowMissing: Bool = false, in sourceDocument: DocumentWindow? = nil,
        focusEditor: Bool = true, markdownLink: MarkdownLinkOpening? = nil, matchingText: String? = nil,
        shouldOpen: @escaping () -> Bool = { true }
    ) async throws -> DocumentWindow? {
        guard let request = beginOpening(in: sourceDocument, while: shouldOpen) else { return nil }
        return try await openFile(url, allowMissing: allowMissing, request: request, focusEditor: focusEditor,
                                  markdownLink: markdownLink, matchingText: matchingText)
    }

    private func beginOpening(in source: DocumentWindow?, while isWanted: @escaping () -> Bool) -> OpenRequest? {
        guard !isQuitting, !Task.isCancelled, let document = source ?? activeDocument, document.canRequestOpen,
              documents.contains(where: { $0 === document }), isWanted() else { return nil }
        return OpenRequest(document: document, generation: document.beginOpenRequest(),
                           mutationGeneration: worktreeMutationGeneration, isWanted: isWanted)
    }

    private func isCurrent(_ request: OpenRequest, at target: URL) -> Bool {
        !isQuitting && !Task.isCancelled && request.generation == request.document.openRequestGeneration &&
            request.mutationGeneration == worktreeMutationGeneration && documents.contains { $0 === request.document } &&
            !isWorktreeMutationPath(target) && request.isWanted()
    }

    private func openFile(
        _ url: URL, allowMissing: Bool, request: OpenRequest, focusEditor: Bool,
        markdownLink: MarkdownLinkOpening? = nil, matchingText: String? = nil
    ) async throws -> DocumentWindow? {
        guard isCurrent(request, at: url) else { return nil }
        let document = request.document

        let (canonical, identity, isFolder) = await Task.detached {
            let path = FileBuffer.canonicalURL(url)
            let identity = FileIdentity.at(path)
            var isDirectory: ObjCBool = false
            if identity == nil { _ = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) }
            return (path, identity, isDirectory.boolValue)
        }.value
        guard isCurrent(request, at: canonical) else { return nil }
        guard matchingText == nil || canonical.path == url.path else { return nil }
        if isFolder {
            guard matchingText == nil else { return nil }
            let folder = URL(filePath: canonical.path, directoryHint: .isDirectory)
            return await openFolder(url, canonical: folder, request: request, focusEditor: focusEditor)
        }
        let isScratch = scratchStore.identifiesScratch(at: canonical)
        if document.hasTextDocument &&
            (document.fileURL == canonical || (identity != nil && identity == document.fileIdentity)) {
            if let matchingText, !document.editor.string.utf8.elementsEqual(matchingText.utf8) { return nil }
            if let scratch = document.scratchFile { await recordScratchOpen(scratch) }
            else if !isScratch { await recentFiles.record(url, in: document.folderURL) }
            return document
        }

        let scratch: ScratchFile?
        let opened: OpenedFile
        do {
            scratch = isScratch ? try await scratchStore.file(at: canonical) : nil
            opened = try await Self.readForOpening(canonical, allowMissing: allowMissing && !isScratch, allowsPreview: !isScratch)
        } catch {
            guard isCurrent(request, at: canonical) else { return nil }
            throw error
        }
        if let matchingText {
            guard case .text(let file) = opened, file.text.utf8.elementsEqual(matchingText.utf8) else { return nil }
        }
        guard await document.open(opened.destination(focusEditor: focusEditor, scratch: scratch), markdownLink: markdownLink, while: {
            self.isCurrent(request, at: canonical)
        }) else { return nil }
        let folder = document.folderURL
        if let scratch {
            if let current = await recordScratchOpen(scratch) { document.updateScratch(current) }
        } else if !isScratch, opened.identity != nil {
            await recentFiles.record(url, in: folder)
        } else if case .preview = opened {
            await recentFiles.removeIfMissing(url)
        }
        return document
    }

    private func openFolder(
        _ url: URL, canonical folder: URL, request: OpenRequest, focusEditor: Bool
    ) async -> DocumentWindow? {
        var opened: OpenedFile?
        if let last = await recentFiles.lastFile(in: folder),
           let candidate = try? await Self.readForOpening(last, within: folder), candidate.identity != nil {
            opened = candidate
        }
        let document = request.document
        let previousFolder = document.folderURL
        let destination = opened?.destination(focusEditor: focusEditor, folder: folder)
            ?? .emptyFolder(focusContent: focusEditor, folder: folder)
        let file = opened?.url ?? folder
        guard await document.open(destination, while: {
            self.isCurrent(request, at: folder) && !self.isWorktreeMutationPath(file)
        }) else { return nil }
        if previousFolder != folder {
            controlPanel?.folderDidChange(in: document)
        }
        let recent = previousFolder == folder || controlPanel == nil ? [] : recentFiles.entries(in: folder)
        await recentFiles.recordFolder(url, opening: opened?.url)
        if previousFolder != folder, document.folderURL == folder, recentFiles.entries(in: folder) != recent {
            controlPanel?.recentFilesDidChange(in: document)
        }
        return document
    }

    @concurrent
    nonisolated static func readForOpening(
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
        file.addCommand("Close", #selector(closeDocument(_:)), "w").target = self
        file.addCommand("Close Workspace", #selector(closeWorkspace(_:))).target = self
        file.addCommand("Reopen Closed File", #selector(reopenClosedFile(_:)), "t", [.command, .shift]).target = self

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
        edit.addCommand("Complete", #selector(EditorTextView.complete(_:)), " ", [.control])
        edit.addCommand("Show Signature Help", #selector(EditorTextView.showSignatureHelp(_:)), " ", [.control, .shift])
        edit.addCommand("Format Document", #selector(EditorTextView.formatDocument(_:)), "f", [.option, .shift])
        edit.addCommand("Format on Save", #selector(toggleFormatOnSave(_:))).target = self
        edit.addItem(.separator())

        edit.addCommand("Find…", #selector(openFind(_:)), "f").target = self
        edit.addCommand("Find in Workspace", #selector(openWorkspaceFind(_:)), "f", [.command, .shift]).target = self
        edit.addCommand("Replace…", #selector(openReplace(_:)), "f", [.command, .option]).target = self
        edit.addCommand("Find Next", #selector(findNext(_:)), "g").target = self
        let previousItem = edit.addCommand("Find Previous", #selector(findPrevious(_:)), "g", [.command, .shift])
        previousItem.target = self
        findPreviousItem = previousItem
        edit.addItem(.separator())

        let lines = NSMenu(title: "Lines")
        lines.addCommand("Move Line Up", #selector(EditorTextView.moveLinesUp(_:)), "\u{F700}", [.option])
        lines.addCommand("Move Line Down", #selector(EditorTextView.moveLinesDown(_:)), "\u{F701}", [.option])
        lines.addCommand("Insert Line Above", #selector(EditorTextView.insertLineAbove(_:)), "\r", [.command, .shift])
        lines.addCommand("Insert Line Below", #selector(EditorTextView.insertLineBelow(_:)), "\r")
        lines.addCommand("Indent Lines", #selector(EditorTextView.indentLines(_:)), "]")
        lines.addCommand("Outdent Lines", #selector(EditorTextView.outdentLines(_:)), "[")
        lines.addCommand("Toggle Line Comments", #selector(EditorTextView.toggleLineComments(_:)), "/")
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines

        let transformations = NSMenu(title: "Transformations")
        transformations.addCommand("Uppercase", #selector(EditorTextView.uppercaseWord(_:)))
        transformations.addCommand("Lowercase", #selector(EditorTextView.lowercaseWord(_:)))
        edit.addItem(withTitle: "Transformations", action: nil, keyEquivalent: "").submenu = transformations

        let selection = NSMenu(title: "Selection")
        selection.addCommand("Add Caret Above", #selector(EditorTextView.addCaretAbove(_:)), "\u{F700}", [.command, .option])
        selection.addCommand("Add Caret Below", #selector(EditorTextView.addCaretBelow(_:)), "\u{F701}", [.command, .option])
        selection.addCommand("Add Carets at Ends of Lines", #selector(EditorTextView.addCaretsAtLineEnds(_:)), "i", [.option, .shift])
        selection.addItem(.separator())
        selection.addCommand("Select Next Occurrence", #selector(EditorTextView.selectNextOccurrence(_:)), "d")
        selection.addCommand("Skip to Next Occurrence", #selector(EditorTextView.skipNextOccurrence(_:)))
        selection.addCommand("Select All Occurrences", #selector(EditorTextView.selectAllOccurrences(_:)), "l", [.command, .shift])
        selection.addItem(.separator())
        selection.addCommand("Go to Bracket", #selector(EditorTextView.goToBracket(_:)))
        selection.addCommand("Select to Bracket", #selector(EditorTextView.selectToBracket(_:)))
        selection.addItem(.separator())
        selection.addCommand("Undo Selection", #selector(EditorTextView.undoSelection(_:)), "u")
        selection.addCommand("Redo Selection", #selector(EditorTextView.redoSelection(_:)), "u", [.command, .shift])
        selection.addCommand("Keep Only Primary Selection", #selector(EditorTextView.keepPrimarySelection(_:)))
        edit.addItem(withTitle: "Selection", action: nil, keyEquivalent: "").submenu = selection

        let view = addMenu("View")
        view.addCommand("Markdown: preview", #selector(toggleMarkdownPreview(_:))).target = self
        view.addCommand("Toggle Sidebar", #selector(toggleSidebar(_:)), "b").target = self
        view.addCommand("Focus Worktree", #selector(toggleWorktreeSidebar(_:)), "e", [.command, .shift]).target = self
        view.addCommand("Focus Scratches", #selector(focusScratches(_:)), "w", [.command, .shift]).target = self
        let jujutsuItem = view.addCommand("Focus Jujutsu", #selector(focusJujutsu(_:)), "", [.command, .shift])
        jujutsuItem.target = self
        focusJujutsuItem = jujutsuItem
        view.addCommand("Toggle Terminal", #selector(toggleTerminal(_:))).target = self
        view.addCommand("Command Mode…", #selector(showCommandMode(_:)), "p", [.command, .shift]).target = self
        view.addCommand("Change Language Mode…", #selector(showLanguageModes(_:))).target = self
        view.addItem(.separator())
        view.addCommand("Toggle Word Wrap", #selector(toggleWordWrap(_:))).target = self
        view.addCommand("Toggle LSP Highlight", #selector(toggleLSPHighlight(_:))).target = self
        view.addCommand("Toggle Tree-sitter Highlight", #selector(toggleTreeSitterHighlight(_:))).target = self
        view.addCommand("Increase Text Size", #selector(EditorTextView.increaseTextSize(_:)), "=")
        view.addCommand("Decrease Text Size", #selector(EditorTextView.decreaseTextSize(_:)), "-")
        view.addCommand("Reset Text Size", #selector(EditorTextView.resetTextSize(_:)), "0")
        view.addItem(.separator())
        view.addCommand("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])

        let go = addMenu("Go")
        go.addCommand("Go Back", #selector(goBack(_:)), "-", [.control]).target = self
        go.addCommand("Go Forward", #selector(goForward(_:)), "-", [.control, .shift]).target = self
        go.addItem(.separator())
        go.addCommand("Go to Line or Symbol…", #selector(showDocumentSymbols(_:))).target = self
        go.addCommand("Go to Workspace Symbol…", #selector(showWorkspaceSymbols(_:))).target = self

        let window = addMenu("Window")
        window.addCommand("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addCommand("Zoom", #selector(NSWindow.performZoom(_:)))
        let help = addMenu("Help")
        app.mainMenu = menuBar
        app.windowsMenu = window
        app.helpMenu = help
        updateJujutsuShortcut()
    }

#if EDIT_AGENT_CHECKS
    private func checkOnly(_ arguments: ArraySlice<String>, in document: DocumentWindow) async throws {
        guard let scope = arguments.first, arguments.count <= 2 else { throw CheckError.unknownScope }
        let screenshot = arguments.dropFirst().first
        switch scope {
        case "editor":
            try EditorCheck.run(in: document)
            try checkWindow(document.window, screenshot: screenshot)
            try MultiCaretCheck.runComposition(in: document.editor)
            try MultiCaretCheck.checkBlink()
            document.window.close()
            try await BracketCheck.run(in: self)
            try await checkEditorViewport()
            try await WordWrapCheck.run(in: self) { window, suffix in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-\(suffix).png" }
                try checkWindow(window, screenshot: target)
            }
            try await NavigationHistoryCheck.run(in: self)
        case "syntax":
            document.window.close()
            try await SyntaxCheck.run(in: self)
        case "inline-diff":
            if let screenshot {
                try JJInlineDiffCheck.run(in: document) { view in
                    try self.captureCheckView(view, screenshot: screenshot)
                }
            } else {
                try JJInlineDiffCheck.run(in: document)
            }
            try await JJEditorCheck.run(in: makeDocument()) { window in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-wrapped-track.png" }
                try self.checkWindow(window, screenshot: target)
            }
        case "files":
            _ = try await FilesCheck.run(in: self)
            try await FilesCheck.checkFilePreview(in: self)
            try await HeaderCheck.run(in: self) { window in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-header.png" }
                try checkWindow(window, screenshot: target)
            }
            try await FolderCheck.checkCloseWorkspace(in: self) { window, suffix in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-\(suffix).png" }
                try checkWindow(window, screenshot: target)
            }
            try await StartupRestoreCheck.run(in: self)
        case "terminal":
            try await TerminalCheck.checkFolderSessions(in: self)
            try await TerminalCheck.run(in: self)
        case "zig-test":
            try await ZigTestCodeLensCheck.run(in: self, document: document) { window in
                try checkWindow(window, screenshot: screenshot)
            }
        case "markdown":
            try await MarkdownCheck.run(in: self, screenshot: screenshot)
        case "results":
            try ReferencesCheck.run(in: document) { window, suffix in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-\(suffix).png" }
                try checkWindow(window, screenshot: target)
            }
            try await FindCheck.run(in: self)
        case "workspace-search":
            try await WorkspaceFindCheck.run(in: self) { window, suffix in
                let target = screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-\(suffix).png" }
                try checkWindow(window, screenshot: target)
            }
        case "control":
            try await ControlSearchCheck.run(in: self) { view in
                try self.captureCheckView(view, screenshot: screenshot)
            }
        case "jj":
            try await checkJJ(screenshot: screenshot)
        case "source-control":
            try await checkSourceControl(screenshot: screenshot)
        case "lsp":
            try await LanguageServerCheck.run(in: self, document: document, capture: { window in
                try self.checkWindow(window, screenshot: screenshot)
            }, captureHover: { view, suffix in
                guard let screenshot else { return }
                let file = URL(fileURLWithPath: screenshot).deletingPathExtension().path + "-" + suffix + ".png"
                try self.captureCheckView(view, screenshot: file)
            }, captureServers: { view, toggle in
                guard let screenshot else { return }
                let suffix = toggle == .start ? "-servers-stopped.png" : "-servers.png"
                let file = URL(fileURLWithPath: screenshot).deletingPathExtension().path + suffix
                try self.captureCheckView(view, screenshot: file)
            })
        case "lsp-progress":
            try await LanguageServerProgressCheck.run(in: self, document: document) { view, suffix in
                guard let screenshot else { return }
                let file = URL(fileURLWithPath: screenshot).deletingPathExtension().path + "-" + suffix + ".png"
                try self.captureCheckView(view, screenshot: file)
            }
        case "lsp-state":
            try await LanguageServerStateCheck.run(in: self, replacing: document) { window in
                try checkWindow(window, screenshot: screenshot)
            }
        case "lsp-highlight":
            func target(_ suffix: String) -> String? {
                screenshot.map { URL(fileURLWithPath: $0).deletingPathExtension().path + "-\(suffix).png" }
            }
            try await LSPSemanticHighlightCheck.run(in: self, document: document) { window, suffix in
                try self.checkWindow(window, screenshot: target(suffix))
            } captureControl: { view, suffix in
                try self.captureCheckView(view, screenshot: target(suffix))
            }
        case "lsp-swift":
            try await SourceKitLSPCheck.run(in: self, document: document) { view, suffix in
                guard let screenshot else { return }
                let file = URL(fileURLWithPath: screenshot).deletingPathExtension().path + "-" + suffix + ".png"
                try self.captureCheckView(view, screenshot: file)
            }
        case "lsp-diagnostics":
            try await LSPDiagnosticsCheck.run(in: self, document: document) { window, suffix in
                let target = screenshot.map { file in
                    suffix.map { URL(filePath: file).deletingPathExtension().path + "-\($0).png" } ?? file
                }
                try self.checkWindow(window, screenshot: target)
            }
        case "lsp-odin":
            try await OdinLSPCheck.run(in: self, document: document) { view, suffix in
                let target = screenshot.map {
                    suffix.isEmpty ? $0 : URL(filePath: $0).deletingPathExtension().path + "-\(suffix).png"
                }
                try self.captureCheckView(view, screenshot: target)
            }
        case "lsp-editing":
            try await LanguageServerEditingCheck.run(in: self, document: document)
        case "lsp-solidity":
            try await SolidityLSPCheck.run(in: self, document: document) { view in
                guard let screenshot else { return }
                try self.captureCheckView(view, screenshot: screenshot)
            }
        case "lsp-c-family":
            try await SourceKitLSPCheck.checkCFamily(in: self, document: document) { window, suffix in
                let target = screenshot.flatMap { path in
                    suffix.map { URL(fileURLWithPath: path).deletingPathExtension().path + "-\($0).png" } ?? path
                }
                try checkWindow(window, screenshot: target)
            }
        case "worktree" where screenshot == nil:
            try await WorktreeCheck.run(in: self)
        default:
            throw CheckError.unknownScope
        }
        print("Edit passed its native \(scope) checks without activation.")
    }

    private func checkEditorViewport() async throws {
        try await EditorCheck.checkViewportResize(in: makeDocument())
        try await EditorCheck.checkCurrentLinePaint()
        try await EditorCheck.checkScrolledZoom(in: makeDocument())
        try await EditorCheck.checkScrollReversal(in: self)
    }

    private func checkJJ(screenshot: String? = nil) async throws {
        try await JJEditorCheck.run(in: makeDocument())
        try JJInlineDiffCheck.run(in: makeDocument())
        try await JJIndicatorCheck.run(in: self) { window in
            for name: NSAppearance.Name in [.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                try checkWindow(window, screenshot: name == .darkAqua ? screenshot : nil)
            }
        }
        try await checkSourceControl()
        print("Edit passed its native Jujutsu indicator checks without activation.")
    }

    private func checkSourceControl(screenshot: String? = nil) async throws {
        try await SourceControlCheck.run(in: self) { window in
            for name: NSAppearance.Name in [.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: name)
                try checkWindow(window, screenshot: name == .aqua ? screenshot : nil)
            }
        }
    }

    private func checkWindow(_ window: NSWindow, screenshot: String?) throws {
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited, !app.isActive, !window.isVisible,
              let frameView = window.contentView?.superview else {
            throw CheckError.unexpectedWindow
        }

        window.layoutIfNeeded()
        try captureCheckView(frameView, screenshot: screenshot)
    }

    private func captureCheckView(_ view: NSView, screenshot: String?) throws {
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CheckError.unrenderableWindow
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        if let screenshot {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CheckError.unrenderableWindow
            }
            try png.write(to: URL(fileURLWithPath: screenshot), options: .atomic)
        }
    }

    private enum CheckError: LocalizedError {
        case unknownScope
        case unexpectedWindow
        case unrenderableWindow

        var errorDescription: String? {
            switch self {
            case .unknownScope:
                "Expected an editor or inline-diff check scope."
            case .unexpectedWindow:
                "Expected a hidden, non-activating window."
            case .unrenderableWindow:
                "AppKit could not render the window."
            }
        }
    }
#endif
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
