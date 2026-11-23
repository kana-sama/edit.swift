import AppKit
import Darwin

enum OpenPanelMessage: Codable {
    case initialized
    case visible
    case selected(URL, bookmark: Data? = nil, inAnotherWindow: Bool = false)
    case cancelled
}

@MainActor
final class OpenFilePanel {
    struct Selection {
        let url: URL
        let inAnotherWindow: Bool
    }

    enum Failure: LocalizedError {
        case unavailable
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: "The macOS Open dialog closed unexpectedly. Try Open again."
            case .startupTimedOut: "The macOS Open dialog did not appear. Try Open again."
            }
        }
    }

    private final class Request {
        let process: Process
        let keepAlive: FileHandle
        let completion: (Result<Selection?, Error>) -> Void
        var reader: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var initialized = false
        var visible = false

        init(process: Process, keepAlive: FileHandle, completion: @escaping (Result<Selection?, Error>) -> Void) {
            self.process = process
            self.keepAlive = keepAlive
            self.completion = completion
        }
    }

    private var request: Request?
    // Keep the panel's file grants available for subsequent reads and saves in this app session.
    private var panelAccess: [URL: URL] = [:]
    var isOpening: Bool { request != nil }

    deinit {
        for url in panelAccess.values { url.stopAccessingSecurityScopedResource() }
    }

    func open(in directory: URL?, completion: @escaping (Result<Selection?, Error>) -> Void) {
        guard !isOpening else {
            bringForward()
            return
        }
        guard let process = OpenFilePanelHelper.process(directory: directory) else {
            completion(.failure(Failure.unavailable))
            return
        }
        start(process, completion: completion)
    }

    @discardableResult
    func start(_ process: Process, startupTimeout: Duration = .seconds(6),
               completion: @escaping (Result<Selection?, Error>) -> Void) -> Bool {
        guard !isOpening else { return false }

        let output = Pipe()
        let lifetime = Pipe()
        process.standardOutput = output
        process.standardInput = lifetime
        let request = Request(process: process, keepAlive: lifetime.fileHandleForWriting, completion: completion)
        self.request = request
        do {
            try process.run()
        } catch {
            finish(request, with: .failure(error))
            return true
        }

        let reader = output.fileHandleForReading
        // EOF closes the request if the helper exits before it sends a result.
        try? output.fileHandleForWriting.close()
        request.reader = Task { [weak self, weak request] in
            do {
                for try await line in reader.bytes.lines {
                    guard !Task.isCancelled, let self, let request, self.request === request else { return }
                    let message = try JSONDecoder().decode(OpenPanelMessage.self, from: Data(line.utf8))
                    await receive(message, from: request)
                }
            } catch {
                // A truncated or invalid reply is handled in the same way as an unexpected exit.
            }
            guard !Task.isCancelled, let self, let request else { return }
            finish(request, with: .failure(Failure.unavailable))
        }
        request.deadline = Task { [weak self, weak request] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, let request, !request.visible else { return }
            finish(request, with: .failure(Failure.startupTimedOut))
        }
        return true
    }

    func bringForward() {
        guard let request, request.initialized, request.process.isRunning, NSApp.isActive,
              let helper = NSRunningApplication(processIdentifier: request.process.processIdentifier) else { return }
        NSApp.yieldActivation(to: helper)
        _ = helper.activate(from: .current, options: [])
    }

    func cancel() {
        if let request { finish(request, with: .success(nil)) }
    }

    private func receive(_ message: OpenPanelMessage, from request: Request) async {
        switch message {
        case .initialized:
            request.initialized = true
            bringForward()
        case .visible:
            request.visible = true
            request.deadline?.cancel()
        case .selected(let url, let bookmark, let inAnotherWindow):
            guard url.isFileURL, url.path.hasPrefix("/") else {
                finish(request, with: .failure(Failure.unavailable))
                return
            }
            request.deadline?.cancel()
            let scoped = await Task.detached {
                guard let bookmark else { return nil as URL? }
                var stale = false
                return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
            }.value
            guard self.request === request else {
                scoped?.stopAccessingSecurityScopedResource()
                return
            }
            if let scoped {
                let previous = panelAccess.updateValue(scoped, forKey: scoped.standardizedFileURL)
                previous?.stopAccessingSecurityScopedResource()
            }
            finish(request, with: .success(Selection(url: scoped ?? url, inAnotherWindow: inAnotherWindow)))
        case .cancelled:
            finish(request, with: request.visible ? .success(nil) : .failure(Failure.unavailable))
        }
    }

    private func finish(_ request: Request, with result: Result<Selection?, Error>) {
        guard self.request === request else { return }
        self.request = nil
        request.reader?.cancel()
        request.deadline?.cancel()
        // Closing this pipe also stops a helper whose main thread is stuck in AppKit.
        try? request.keepAlive.close()
        if request.process.isRunning { request.process.terminate() }
        request.completion(result)
    }
}

@MainActor
final class OpenFilePanelHelper: NSObject, NSApplicationDelegate, NSOpenSavePanelDelegate {
    private static let flag = "--edit-open-panel-helper"
    private static let parentKey = "EDIT_OPEN_PANEL_PARENT"
    private let parent: pid_t
    private let directory: URL?
    private let probe: Bool
    private var panel: NSOpenPanel?
    private var announcedVisibility = false
    private var promptShowsNewWindow: Bool?
    private var acceptedInAnotherWindow: Bool?

    static func process(directory: URL?, probe: Bool = false) -> Process? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, probe ? "probe" : "open", directory?.path ?? ""]
        var environment = ProcessInfo.processInfo.environment
        environment[parentKey] = String(getpid())
        process.environment = environment
        return process
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        let parent = getppid()
        guard args.count == 3, args.first == flag,
              ProcessInfo.processInfo.environment[parentKey] == String(parent) else { return false }
        let probe = args[args.startIndex + 1] == "probe"
        if probe && Bundle.main.bundleIdentifier?.hasSuffix(".agent") != true { return false }

        // The parent owns the only writer. This callback can exit even if panel creation blocks the main thread.
        FileHandle.standardInput.readabilityHandler = { input in
            if input.availableData.isEmpty { _exit(EXIT_SUCCESS) }
        }
        let path = args[args.startIndex + 2]
        let helper = OpenFilePanelHelper(parent: parent,
                                       directory: path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory),
                                       probe: probe)
        let app = NSApplication.shared
        app.setActivationPolicy(probe ? .prohibited : .accessory)
        app.delegate = helper
        withExtendedLifetime(helper) { app.run() }
        return true
    }

    private init(parent: pid_t, directory: URL?, probe: Bool) {
        self.parent = parent
        self.directory = directory
        self.probe = probe
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.delegate = self
        updatePrompt(in: panel)
        self.panel = panel
        if probe {
            send(.visible)
            send(.cancelled)
            exit(EXIT_SUCCESS)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(panelBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: panel)
        send(.initialized)
        panel.begin { [self] response in
            let inAnotherWindow = acceptedInAnotherWindow ?? NSEvent.modifierFlags.contains(.option)
            if NSApp.isActive, let editor = NSRunningApplication(processIdentifier: parent) {
                NSApp.yieldActivation(to: editor)
                _ = editor.activate(from: .current, options: [])
            }
            if response == .OK, let url = panel.url {
                // An implicit bookmark carries the user-selected file grant to the editor process.
                let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                send(.selected(url, bookmark: bookmark, inAnotherWindow: inAnotherWindow))
            } else {
                send(.cancelled)
            }
            exit(EXIT_SUCCESS)
        }

        // The system panel can be visible without becoming key and may receive Option events in its own process.
        Task { [weak self] in
            while let self {
                if !announcedVisibility, panel.isVisible { reportVisibility() }
                updatePrompt(in: panel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        // Remember Option before the system returns the selection and hands focus back to Edit.
        acceptedInAnotherWindow = NSEvent.modifierFlags.contains(.option)
    }

    private func updatePrompt(in panel: NSOpenPanel) {
        let inAnotherWindow = NSEvent.modifierFlags.contains(.option)
        guard inAnotherWindow != promptShowsNewWindow else { return }
        promptShowsNewWindow = inAnotherWindow
        panel.prompt = inAnotherWindow ? "Open in New Window" : "Open in This Window"
    }

    @objc private func panelBecameKey(_ notification: Notification) { reportVisibility() }

    private func reportVisibility() {
        guard !announcedVisibility else { return }
        announcedVisibility = true
        send(.visible)
    }

    private func send(_ message: OpenPanelMessage) {
        do {
            var line = try JSONEncoder().encode(message)
            line.append(10)
            try FileHandle.standardOutput.write(contentsOf: line)
        } catch {
            exit(EXIT_FAILURE)
        }
    }
}
