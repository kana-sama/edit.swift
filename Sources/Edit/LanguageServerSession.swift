import Darwin
import Foundation

@MainActor
final class LanguageServerSession {
    enum State: Equatable {
        case starting, ready, stopping, stopped, notOnPATH, failed(String)

        var title: String {
            switch self {
            case .starting: "Starting"
            case .ready: "Ready"
            case .stopping: "Stopping"
            case .stopped: "Stopped"
            case .notOnPATH: "Not on PATH"
            case .failed: "Failed"
            }
        }

        var failureReason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    var onStateChange: (() -> Void)?
    private(set) var generation = 0
    var revision: Int { document.revision }
    var state: State { root == nil && rootLookup != nil ? .starting : phase }
    var failureReason: String? { state.failureReason }
    var isEligible: Bool { root != nil && recognizedScope == scope }
    var canStart: Bool {
        guard canControl else { return false }
        switch phase {
        case .stopped, .notOnPATH, .failed: return true
        default: return false
        }
    }
    var canStop: Bool { canControl && (phase == .starting || phase == .ready) }
    var canRestart: Bool { canControl && phase != .stopping }
    var supportsDefinition: Bool { isReady && capabilities?.definition == true }
    var supportsReferences: Bool { isReady && capabilities?.references == true }
    var supportsHover: Bool { isReady && capabilities?.hover == true }
    var supportsDocumentHighlight: Bool { isReady && capabilities?.documentHighlight == true }

    private var canControl: Bool { isEligible && rootLookup == nil }
    private var isReady: Bool { canControl && phase == .ready && document.url != nil }
    private var phase = State.stopped
    private var document = LSPDocument(url: nil, text: "", revision: 0)
    private struct Scope: Equatable, Sendable {
        let directory: URL
        let searchesParentProjects: Bool
    }
    private var scope: Scope?
    private var recognizedScope: Scope?
    private var monitor: FileSystemEvents?
    private var root: URL?
    private var manuallyStopped: Set<URL> = []
    private var rootLookup: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var sync: Task<Void, Never>?
    private var connection: LanguageServerConnection?
    private var capabilities: LSPCapabilities?

    /// A non-nil URL denotes an eligible named Zig buffer. The caller owns language mode and editability.
    func setDocument(url: URL?, folder: URL?, searchesParentProjects: Bool, text: String) {
        let url = url?.standardizedFileURL
        let scope = folder.map { Scope(directory: $0.standardizedFileURL, searchesParentProjects: searchesParentProjects) }
        let scopeChanged = scope != self.scope
        guard url != document.url || scopeChanged else {
            updateText(text)
            return
        }
        self.scope = scope
        document = LSPDocument(url: url, text: url == nil ? "" : text, revision: revision + 1)
        sync?.cancel()
        sync = nil
        if scopeChanged {
            monitor = scope.map { scope in
                FileSystemEvents(directory: scope.directory) { [weak self] events in
                    guard let self, self.scope == scope,
                          events.contains(where: { ZigProjects.affectsDiscovery($0, in: scope.directory) }) else { return }
                    discoverProject()
                }
            }
        }
        if !scopeChanged, url == nil, recognizedScope == scope, rootLookup == nil {
            connection?.updateDocument(document)
            onStateChange?()
            return
        }
        discoverProject()
    }

    private func discoverProject() {
        rootLookup?.cancel()
        rootLookup = nil
        guard let scope else {
            recognizedScope = nil
            activate(root: nil)
            return
        }
        let file = document.url
        let previousRoot = recognizedScope == scope ? root : nil
        let search = Task.detached(priority: .utility) {
            ZigProjects.root(in: scope.directory, activeFile: file, previousRoot: previousRoot,
                             searchesParents: scope.searchesParentProjects)
        }
        rootLookup = Task { [weak self] in
            let root = await withTaskCancellationHandler {
                await search.value
            } onCancel: {
                search.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.rootLookup = nil
            self.recognizedScope = scope
            self.activate(root: root)
        }
        onStateChange?()
    }

    func updateText(_ text: String) {
        guard let url = document.url, !text.utf8.elementsEqual(document.text.utf8) else { return }
        document = LSPDocument(url: url, text: text, revision: revision + 1)
        guard isReady, sync == nil else { return }
        sync = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard let self else { return }
            self.sync = nil
            guard self.isReady else { return }
            self.connection?.updateDocument(self.document)
        }
    }

    func start() {
        guard canStart, let root else { return }
        manuallyStopped.remove(root)
        replaceConnection(startingAt: root)
    }

    func stop() {
        guard canStop, let root else { return }
        manuallyStopped.insert(root)
        replaceConnection(startingAt: nil)
    }

    func restart() {
        guard canRestart, let root else { return }
        manuallyStopped.remove(root)
        replaceConnection(startingAt: root)
    }

    func close() {
        rootLookup?.cancel()
        rootLookup = nil
        monitor = nil
        sync?.cancel()
        sync = nil
        document = LSPDocument(url: nil, text: "", revision: revision + 1)
        root = nil
        replaceConnection(startingAt: nil)
    }

    func definition(at offset: Int) async throws -> [LSPLocation] {
        guard supportsDefinition, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.definition(at: offset, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func references(at offset: Int, includeDeclaration: Bool) async throws -> [LSPLocation] {
        guard supportsReferences, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.references(at: offset, includeDeclaration: includeDeclaration, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func hover(at offset: Int) async throws -> LSPHover? {
        guard supportsHover, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.hover(at: offset, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func documentHighlights(at offset: Int) async throws -> [NSRange] {
        guard supportsDocumentHighlight, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.documentHighlights(at: offset, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    private func validate(revision: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard self.revision == revision, self.generation == generation else { throw CancellationError() }
    }

    private func activate(root: URL?) {
        if self.root == root {
            if phase == .ready { connection?.updateDocument(document) }
            onStateChange?()
            return
        }
        self.root = root
        replaceConnection(startingAt: root.flatMap { manuallyStopped.contains($0) ? nil : $0 })
    }

    private func replaceConnection(startingAt root: URL?) {
        generation += 1
        let generation = generation
        let previous = connection
        let previousTransition = transition
        previousTransition?.cancel()
        sync?.cancel()
        sync = nil
        connection = nil
        capabilities = nil
        phase = previous != nil || previousTransition != nil ? .stopping : root == nil ? .stopped : .starting
        onStateChange?()
        transition = Task { [weak self] in
            await previous?.stop()
            await previousTransition?.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            if let root {
                self.setPhase(.starting)
                await self.launch(in: root, generation: generation)
            } else {
                self.setPhase(.stopped)
            }
            if self.generation == generation { self.transition = nil }
        }
    }

    private func launch(in root: URL, generation: Int) async {
        let launch = await Self.resolveExecutable()
        guard !Task.isCancelled, self.generation == generation else { return }
        guard let launch else {
            setPhase(.notOnPATH)
            return
        }
        let connection = LanguageServerConnection(executable: launch.executable, root: root,
                                                  environment: launch.environment) { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.connection = nil
                self.capabilities = nil
                self.setPhase(.failed(reason))
            }
        }
        self.connection = connection
        do {
            let capabilities = try await connection.start()
            guard !Task.isCancelled, self.generation == generation else { return }
            self.capabilities = capabilities
            if rootLookup == nil { connection.updateDocument(document) }
            setPhase(.ready)
        } catch {
            await connection.stop()
            guard !Task.isCancelled, self.generation == generation else { return }
            self.connection = nil
            capabilities = nil
            if case .failed = phase { return }
            setPhase(.failed(error.localizedDescription))
        }
    }

    private func setPhase(_ phase: State) {
        guard phase != self.phase else { return }
        self.phase = phase
        onStateChange?()
    }

    private struct Launch: Sendable {
        let executable: URL
        let environment: [String: String]
    }

    @concurrent private nonisolated static func resolveExecutable() async -> Launch? {
        var environment = ProcessInfo.processInfo.environment
        // Launch Services starts the app through launchd. Direct executable launches retain their caller's PATH.
        if getppid() == 1, let loginPath = await loginShellPATH() { environment["PATH"] = loginPath }
        guard !Task.isCancelled, let path = environment["PATH"], let executable = executable(in: path) else { return nil }
        return Launch(executable: executable, environment: environment)
    }

    nonisolated static func executable(in path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let files = FileManager.default
        let current = URL(filePath: files.currentDirectoryPath, directoryHint: .isDirectory)
        for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = entry.isEmpty ? current : URL(filePath: String(entry), directoryHint: .isDirectory, relativeTo: current)
            let candidate = directory.appending(path: "zls").standardizedFileURL
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private nonisolated static func loginShellPATH() async -> String? {
        guard let path = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let command = """
        /usr/bin/printf '\\000'
        /usr/bin/printenv PATH
        /usr/bin/printf '\\000'
        """
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let result = try? await JJCommand.run(URL(filePath: path), arguments: ["-l", "-c", command],
                                                    in: home, limit: 64 * 1_024, timeout: 2), result.status == 0 else { return nil }
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 3, let value = String(data: Data(fields[1]), encoding: .utf8), value.last == "\n" else { return nil }
        return String(value.dropLast())
    }
}
