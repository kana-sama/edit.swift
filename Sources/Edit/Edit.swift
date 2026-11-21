import AppKit

@main
@MainActor
final class Edit: NSObject, NSApplicationDelegate, NSUserInterfaceValidations, NSMenuDelegate {
    let isAgentCheck = CommandLine.arguments.dropFirst().first == "--agent-check"
    private lazy var sessionStore = SessionStore.application()
    private var startup: Task<Void, Never>?
    private var receivedInitialSession = false
    private var pendingFiles: [(urls: [URL], allowMissing: Bool)] = []
    private var saveTargets: [URL: DocumentWindow] = [:]
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
    }

    func applicationWillResignActive(_ notification: Notification) {
        activeDocument?.requestAutosave()
    }

    func menuWillOpen(_ menu: NSMenu) {
        activeDocument?.requestAutosave()
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

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !isQuitting else { return false }
        switch item.action {
        case #selector(newDocument(_:)): return activeDocument?.canReplaceBuffer ?? false
        case #selector(newWindow(_:)): return true
        case #selector(openDocument(_:)): return activeDocument.map { $0.window.attachedSheet == nil } ?? false
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return activeDocument.map { !$0.isBusy && $0.window.attachedSheet == nil } ?? false
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
        for document in documents {
            if document.editor.hasMarkedText() { document.editor.unmarkText() }
            document.editor.isEditable = false
        }
        Task { @MainActor in
            await startup?.value
            for document in documents { await document.flushAutosave() }
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

    func reserveSave(to url: URL, for document: DocumentWindow) -> Bool {
        guard !documents.contains(where: { $0 !== document && $0.fileURL == url }),
              saveTargets[url] == nil else { return false }
        saveTargets[url] = document
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
                document.restoreDraft(record, text: draft)
            } else if let file {
                document.load(file)
            }
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
            if let existing = documents.first(where: { $0.fileURL == url.standardizedFileURL }) {
                if !isAgentCheck { existing.present() }
                continue
            }

            do {
                let file = try await Task.detached { try FileBuffer.read(url, allowMissing: allowMissing) }.value
                guard !isQuitting else { return }
                if let existing = documents.first(where: { $0.fileURL == file.url }) ?? saveTargets[file.url] {
                    if !isAgentCheck { existing.present() }
                    continue
                }
                let document = activeDocument.flatMap { $0.isReusable ? $0 : nil } ?? makeDocument()
                document.load(file)
                if !isAgentCheck { document.present() }
            } catch {
                if !isAgentCheck && !isQuitting {
                    await activeDocument?.showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
                }
            }
        }
    }

    private func requestOpen(_ urls: [URL]) {
        guard !isQuitting else { return }
        if !receivedInitialSession {
            pendingFiles.append((urls, false))
        } else {
            Task { await openFiles(urls) }
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

        let lines = NSMenu(title: "Lines")
        lines.addCommand("Move Line Up", #selector(EditorTextView.moveLinesUp(_:)), "\u{F700}", [.option])
        lines.addCommand("Move Line Down", #selector(EditorTextView.moveLinesDown(_:)), "\u{F701}", [.option])
        lines.addCommand("Insert Line Above", #selector(EditorTextView.insertLineAbove(_:)), "\r", [.command, .shift])
        lines.addCommand("Insert Line Below", #selector(EditorTextView.insertLineBelow(_:)), "\r")
        lines.addCommand("Indent Lines", #selector(EditorTextView.indentLines(_:)), "]")
        lines.addCommand("Outdent Lines", #selector(EditorTextView.outdentLines(_:)), "[")
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines

        let view = addMenu("View")
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
