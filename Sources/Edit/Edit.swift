import AppKit

@main
@MainActor
final class Edit: NSObject, NSApplicationDelegate, NSUserInterfaceValidations, NSMenuDelegate {
    let isAgentCheck = CommandLine.arguments.dropFirst().first == "--agent-check"
    private lazy var sessionStore = SessionStore.application()
    lazy var syntaxOverrides = SyntaxLanguageOverrides(defaults: isAgentCheck ? nil : .standard)
    private weak var recentMenu: NSMenu?
    private var controlPanel: ControlPanel?
    private(set) lazy var recentFiles = RecentFiles(url: recentHistoryURL)

    private var recentHistoryURL: URL {
        let folder = isAgentCheck
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            : sessionStore.url.deletingLastPathComponent()
        return folder.appendingPathComponent("recent-files.json")
    }
    private var startup: Task<Void, Never>?
    private var receivedInitialSession = false
    private var pendingFiles: [(urls: [URL], allowMissing: Bool)] = []
    private var saveTargets: [URL: (document: DocumentWindow, identity: FileIdentity?)] = [:]
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
        let app = NSApplication.shared
        let delegate = Edit()
        app.delegate = delegate
        app.setActivationPolicy(delegate.isAgentCheck ? .prohibited : .regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        installMenus(in: app)
        let initial = makeDocument()
        if isAgentCheck {
            Task { @MainActor in
                do {
                    try EditorCheck.run(in: initial.window, editor: initial.editor, scrollView: initial.scrollView)
                    // The text editor check uses its own undo grouping and sample text.
                    initial.window.close()
                    makeDocument()
                    let sample = try await FilesCheck.run(in: self)
                    try ControlPanel(app: self).checkHidden(in: sample)
                    try await SyntaxCheck.run(in: self)
                    try await FindCheck.run(in: self)
                    try checkWindow(sample.window, screenshot: CommandLine.arguments.dropFirst(2).first)
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
            pendingFiles.append((urls, true))
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
                await openFiles(request.urls, allowMissing: request.allowMissing)
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
        requestOpen([url])
    }

    @objc func showGoToFile(_ sender: Any?) { showControl(.files) }
    @objc func showCommandMode(_ sender: Any?) { showControl(.commands) }
    @objc func showLanguageModes(_ sender: Any?) { showControl(.languages) }

    private func showControl(_ mode: ControlPanel.Mode) {
        guard let document = activeDocument, !isQuitting else { return }
        let panel = controlPanel ?? ControlPanel(app: self)
        controlPanel = panel
        panel.toggle(in: document, mode: mode)
    }

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
        guard let document = activeDocument, document.window.attachedSheet == nil, !isQuitting else { return }
        document.requestAutosave()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: document.window) { response in
            if response == .OK { self.requestOpen(panel.urls) }
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

    @objc func openFind(_ sender: Any?) {
        controlPanel?.dismiss(restoreFocus: true)
        activeDocument?.performFind(.find)
    }

    @objc func openReplace(_ sender: Any?) {
        controlPanel?.dismiss(restoreFocus: true)
        activeDocument?.performFind(.replace)
    }

    @objc func findNext(_ sender: Any?) { activeDocument?.performFind(.next) }
    @objc func findPrevious(_ sender: Any?) { activeDocument?.performFind(.previous) }
    @objc func toggleFindSidebar(_ sender: Any?) { activeDocument?.performFind(.toggleSidebar) }

    @objc func performFindControlAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? FindCommand { activeDocument?.performFind(command) }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !isQuitting else { return false }
        switch item.action {
        case #selector(newDocument(_:)): return activeDocument?.canReplaceBuffer ?? false
        case #selector(showGoToFile(_:)), #selector(showCommandMode(_:)), #selector(showLanguageModes(_:)): return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(newWindow(_:)), #selector(openRecentDocument(_:)): return true
        case #selector(openDocument(_:)): return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return activeDocument.map { !$0.isBusy && $0.window.attachedSheet == nil } ?? false
        case #selector(openFind(_:)), #selector(openReplace(_:)), #selector(toggleFindSidebar(_:)):
            return activeDocument.map { $0.window.attachedSheet == nil } ?? false
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
        guard !documents.contains(where: { $0.isBusy || $0.window.attachedSheet != nil }) else {
            return .terminateCancel
        }
        // The temporary startup window can be closed before restoration reads the saved session.
        if startup != nil && documents.isEmpty { return .terminateNow }
        isQuitting = true
        activeDocument?.persistFindSettings()
        for document in documents {
            if document.editor.hasMarkedText() { document.editor.unmarkText() }
            document.editor.isEditable = false
        }
        Task { @MainActor in
            await startup?.value
            for document in documents { await document.flushAutosave() }
            await recentFiles.finishWrites()
            let session = sessionSnapshot()
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
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isQuitting = false
                for document in documents {
                    document.editor.isEditable = true
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
        lastPlacement = document.placement
        pendingFullScreen.removeAll { $0 === document }
        didFinishFullScreenRestore(for: document)
        documents.removeAll { $0 === document }
    }

    func reserveSave(to url: URL, identity: FileIdentity?, for document: DocumentWindow) -> Bool {
        guard !documents.contains(where: {
            $0 !== document && ($0.fileURL == url || (identity != nil && $0.fileIdentity == identity))
        }), saveTargets[url] == nil, identity == nil || !saveTargets.values.contains(where: { $0.identity == identity })
        else { return false }
        saveTargets[url] = (document, identity)
        return true
    }

    func finishSave(to url: URL) {
        saveTargets.removeValue(forKey: url)
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
            let file: FileBuffer?
            if record.draft == nil, let path = record.path {
                do {
                    file = try await Task.detached { try FileBuffer.read(URL(fileURLWithPath: path)) }.value
                } catch {
                    warnings.append("“\(URL(fileURLWithPath: path).lastPathComponent)” — \(error.localizedDescription)")
                    continue
                }
            } else {
                file = nil
            }
            let document = restored.isEmpty && documents.contains(where: { $0 === placeholder }) && placeholder.isReusable
                ? placeholder : makeDocument()
            document.restorePlacement(record.placement)
            if let draft = record.draft {
                let identity = await Task.detached {
                    record.path.flatMap { FileIdentity.at(URL(fileURLWithPath: $0)) }
                }.value
                document.restoreDraft(record, text: draft, identity: identity)
            } else if let file {
                document.load(file, storedSyntaxLanguage: record.syntaxLanguage)
            }
            if let path = record.path { await recentFiles.record(URL(fileURLWithPath: path)) }
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

    func openFiles(_ urls: [URL], allowMissing: Bool = false) async {
        for url in urls where !isQuitting {
            do {
                _ = try await openFile(url, allowMissing: allowMissing)
            } catch {
                await recentFiles.removeIfMissing(url)
                if !isAgentCheck && !isQuitting {
                    await activeDocument?.showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func openFile(_ url: URL, allowMissing: Bool = false, promoteExisting: Bool = true) async throws -> DocumentWindow? {
        guard !isQuitting else { return nil }
        if let existing = openDocument(at: url.standardizedFileURL, identity: nil) {
            if !isAgentCheck { existing.present() }
            if promoteExisting { await recentFiles.record(url) }
            return existing
        }

        let (canonical, identity) = await Task.detached {
            let path = FileBuffer.canonicalURL(url)
            return (path, FileIdentity.at(path))
        }.value
        guard !isQuitting else { return nil }
        if let existing = openDocument(at: canonical, identity: identity) {
            if !isAgentCheck { existing.present() }
            if promoteExisting { await recentFiles.record(url) }
            return existing
        }

        let file = try await Task.detached { try FileBuffer.read(canonical, allowMissing: allowMissing) }.value
        guard !isQuitting else { return nil }
        if let existing = openDocument(at: file.url, identity: file.identity) {
            if !isAgentCheck { existing.present() }
            if promoteExisting { await recentFiles.record(url) }
            return existing
        }
        let document = activeDocument.flatMap { $0.isReusable ? $0 : nil } ?? makeDocument()
        document.load(file)
        if !isAgentCheck { document.present() }
        if file.identity != nil { await recentFiles.record(url) }
        return document
    }

    func manualIconLanguage(for recent: RecentFile) -> String? {
        let document = openDocument(at: recent.canonicalURL, identity: recent.identity)
        return document?.manualSyntaxLanguage?.iconIdentifier
            ?? syntaxOverrides.language(for: recent.canonicalURL)?.iconIdentifier
    }

    private func openDocument(at url: URL, identity: FileIdentity?) -> DocumentWindow? {
        documents.first { $0.fileURL == url || (identity != nil && $0.fileIdentity == identity) }
            ?? saveTargets[url]?.document
            ?? saveTargets.values.first { identity != nil && $0.identity == identity }?.document
    }

    private func requestOpen(_ urls: [URL], allowMissing: Bool = false) {
        guard !urls.isEmpty, !isQuitting else { return }
        if !receivedInitialSession {
            pendingFiles.append((urls, allowMissing))
        } else {
            Task { await openFiles(urls, allowMissing: allowMissing) }
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
        view.addCommand("Toggle Search Sidebar", #selector(toggleFindSidebar(_:)), "b").target = self
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
