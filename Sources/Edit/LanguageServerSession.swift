import Darwin
import Foundation

@MainActor
final class LanguageServerSession {
    enum State: Equatable {
        case starting, ready, stopping, stopped, notOnPATH, toolchainUnavailable, failed(String)

        var title: String {
            switch self {
            case .starting: "Initializing"
            case .ready: "Ready"
            case .stopping: "Stopping"
            case .stopped: "Stopped"
            case .notOnPATH: "Not on PATH"
            case .toolchainUnavailable: "Toolchain unavailable"
            case .failed: "Failed"
            }
        }

        var failureReason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    let server: LanguageServer
    var onStateChange: (() -> Void)?
    var onProgressChange: (() -> Void)?
    var onSemanticTokensRefresh: (() -> Void)?
    var onDiagnosticsChange: (() -> Void)?
    private(set) var pathsWithErrors: Set<String> = []
    /// A ready session returns nil until it receives a report for this revision.
    var diagnostics: [LSPError]? {
        guard isReady else { return [] }
        guard let documentErrors, documentErrors.revision == revision else { return nil }
        return documentErrors.errors
    }
    private(set) var semanticTokensRefresh = 0
    private(set) var progress: [LSPWorkDoneActivity] = []
    private(set) var generation = 0
    var revision: Int { document.revision }
    var state: State { root == nil && rootLookup != nil ? .starting : phase }
    var failureReason: String? { state.failureReason }
    var isEligible: Bool { root != nil && recognizedScope == scope }
    var canStart: Bool {
        guard canControl else { return false }
        switch phase {
        case .stopped, .notOnPATH, .toolchainUnavailable, .failed: return true
        default: return false
        }
    }
    var canStop: Bool { canControl && (phase == .starting || phase == .ready) }
    var canRestart: Bool { canControl && phase != .stopping }
    var supportsDefinition: Bool { isReady && capabilities?.definition == true }
    var supportsReferences: Bool { isReady && capabilities?.references == true }
    var supportsHover: Bool { isReady && capabilities?.hover == true }
    var supportsDocumentHighlight: Bool { isReady && capabilities?.documentHighlight == true }
    var supportsSemanticTokens: Bool {
        guard isReady, let options = capabilities?.semanticTokens else { return false }
        return options.full || options.range
    }
    var canPreviewSemanticTokens: Bool {
        // SourceKit computes file-wide semantic tokens even for a range request.
        isReady && server == .zig && capabilities?.semanticTokens?.full == true
            && capabilities?.semanticTokens?.range == true && document.text.utf8.count >= 64 * 1_024
    }
    var supportsDocumentSymbols: Bool { isReady && capabilities?.documentSymbols == true }
    var supportsWorkspaceSymbols: Bool { isServerReady && capabilities?.workspaceSymbols == true }
    var supportsRename: Bool { isReady && capabilities?.rename == true }
    var supportsCompletion: Bool { isReady && capabilities?.completion != nil }
    var supportsCompletionResolve: Bool { supportsCompletion && capabilities?.completion?.resolveProvider == true }
    var completionTriggers: Set<String> { Set(capabilities?.completion?.triggerCharacters ?? []) }
    var supportsSignatureHelp: Bool { isReady && capabilities?.signature != nil }
    var signatureTriggers: Set<String> { Set(capabilities?.signature?.triggerCharacters ?? []) }
    var signatureRetriggers: Set<String> { Set(capabilities?.signature?.retriggerCharacters ?? []) }
    var supportsFormatting: Bool { isReady && capabilities?.formatting == true }
    var workspaceRoot: URL? { root }

    private var canControl: Bool { isEligible && rootLookup?.blocksServer != true }
    private var isServerReady: Bool { canControl && phase == .ready }
    private var isReady: Bool { isServerReady && document.url != nil }
    private var phase = State.stopped
    private var document = LSPDocument(url: nil, language: nil, text: "", revision: 0)
    private struct Scope: Equatable, Sendable {
        let directory: URL
        let searchesParentProjects: Bool
    }
    private var scope: Scope?
    private var recognizedScope: Scope?
    private var monitor: FileSystemEvents?
    private var indexMonitor: FileSystemEvents?
    private var root: URL?
    private let workspacePreferences: WorkspaceLanguageServers
    private var isManuallyStopped = false
    private var preferenceWorkspace: URL? {
        guard let root, let recognizedScope else { return nil }
        return recognizedScope.searchesParentProjects ? root : recognizedScope.directory
    }
    private struct ProjectLookup {
        let task: Task<Void, Never>
        let blocksServer: Bool
    }
    private var rootLookup: ProjectLookup?
    private var transition: Task<Void, Never>?
    private var sync: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var documentErrors: LSPDocumentErrors?
    private var connection: LanguageServerConnection?
    private var capabilities: LSPCapabilities?
    private var semanticTokenResult: LSPSemanticTokens?
#if EDIT_AGENT_CHECKS
    var beforeApplyProjectRootForCheck: (() async -> Void)?
    var beforeApplyDiagnosticsForCheck: (() async -> Void)?
#endif

    init(server: LanguageServer, workspacePreferences: WorkspaceLanguageServers) {
        self.server = server
        self.workspacePreferences = workspacePreferences
    }

    /// A non-nil URL denotes an eligible named buffer for this server.
    func setDocument(url: URL?, language: SyntaxLanguage?, folder: URL?, searchesParentProjects: Bool, text: String) {
        // OLS and Solar use the canonical path when scanning the workspace for references.
        let url = server == .odin || server == .solidity ? url : url?.standardizedFileURL
        let scope = folder.map { Scope(directory: $0.standardizedFileURL, searchesParentProjects: searchesParentProjects) }
        let scopeChanged = scope != self.scope
        let urlChanged = url != document.url
        guard urlChanged || language != document.language || scopeChanged else {
            updateText(text)
            return
        }
        self.scope = scope
        semanticTokenResult = nil
        document = LSPDocument(url: url, language: language, text: url == nil ? "" : text, revision: revision + 1)
        sync?.cancel()
        sync = nil
        if scopeChanged {
            monitor = scope.map { scope in
                FileSystemEvents(directory: scope.directory) { [weak self] events in
                    guard let self, self.scope == scope,
                          events.contains(where: { server.affectsProjectDiscovery($0, in: scope.directory) }) else { return }
                    discoverProject(recheckingCurrentContext: true)
                }
            }
        }
        if !scopeChanged, (!urlChanged || url == nil), recognizedScope == scope, rootLookup == nil {
            connection?.updateDocument(document)
            onStateChange?()
            return
        }
        discoverProject()
    }

    private func discoverProject(recheckingCurrentContext: Bool = false) {
        let blocksServer = !recheckingCurrentContext || !canControl
        rootLookup?.task.cancel()
        rootLookup = nil
        guard let scope else {
            recognizedScope = nil
            activate(root: nil)
            return
        }
        let file = document.url
        let previousRoot = recognizedScope == scope ? root : nil
        let server = server
        let search = Task.detached(priority: .utility) {
            server.projectRoot(in: scope.directory, activeFile: file, previousRoot: previousRoot,
                               searchesParents: scope.searchesParentProjects)
        }
        let task = Task { [weak self] in
            let root = await withTaskCancellationHandler {
                await search.value
            } onCancel: {
                search.cancel()
            }
            guard !Task.isCancelled, let self else { return }
#if EDIT_AGENT_CHECKS
            if let beforeApply = self.beforeApplyProjectRootForCheck {
                await beforeApply()
                guard !Task.isCancelled else { return }
            }
#endif
            self.rootLookup = nil
            self.recognizedScope = scope
            self.activate(root: root)
        }
        // A filesystem recheck can confirm the current root. Keep serving it until there is a change.
        rootLookup = ProjectLookup(task: task, blocksServer: blocksServer)
        if blocksServer { onStateChange?() }
    }

    func updateText(_ text: String) {
        guard let url = document.url, !text.utf8.elementsEqual(document.text.utf8) else { return }
        document = LSPDocument(url: url, language: document.language, text: text, revision: revision + 1)
        guard isReady, sync == nil else { return }
        sync = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard let self else { return }
            self.sync = nil
            guard self.isReady else { return }
            self.connection?.updateDocument(self.document)
        }
    }

    func didSave(_ url: URL, text: String) {
        guard server == .solidity, isReady, document.url?.path == url.path,
              document.text.utf8.elementsEqual(text.utf8) else { return }
        connection?.didSave(document)
    }

    func start() {
        guard canStart else { return }
        setManuallyStopped(false)
    }

    func stop() {
        guard canStop else { return }
        setManuallyStopped(true)
    }

    func restart() {
        guard canRestart else { return }
        setManuallyStopped(false)
    }

    private func setManuallyStopped(_ stopped: Bool) {
        guard let root, let workspace = preferenceWorkspace else { return }
        workspacePreferences.setStopped(stopped, for: server, in: workspace)
        isManuallyStopped = stopped
        replaceConnection(startingAt: stopped ? nil : root)
    }

    func workspacePreferenceDidChange() {
        guard isEligible, let workspace = preferenceWorkspace,
              isManuallyStopped != workspacePreferences.isStopped(server, in: workspace) else { return }
        activate(root: root)
    }

    func close() {
        rootLookup?.task.cancel()
        rootLookup = nil
        monitor = nil
        sync?.cancel()
        sync = nil
        document = LSPDocument(url: nil, language: nil, text: "", revision: revision + 1)
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

    func semanticTokens(visibleRange: NSRange? = nil) async throws -> [SyntaxSpan]? {
        guard supportsSemanticTokens, let connection, let options = capabilities?.semanticTokens else {
            throw LSPFailure.unavailable
        }
        let snapshot = document
        let generation = generation
        let result = try await connection.semanticTokens(in: snapshot, options: options,
                                                         previous: semanticTokenResult, visibleRange: visibleRange)
        try validate(revision: snapshot.revision, generation: generation)
        if visibleRange == nil {
            semanticTokenResult = options.delta && result?.0.resultID != nil ? result?.0 : nil
        }
        return result?.1
    }

    func documentSymbols() async throws -> [LSPSymbol] {
        guard supportsDocumentSymbols, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.documentSymbols(in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func workspaceSymbols(query: String) async throws -> [LSPSymbol] {
        guard supportsWorkspaceSymbols, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.workspaceSymbols(query: query, synchronizing: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func prepareRename(at offset: Int) async throws -> LSPPreparedRename? {
        guard supportsRename, let connection else { throw LSPFailure.unavailable }
        guard capabilities?.prepareRename == true else { return nil }
        let snapshot = document
        let generation = generation
        let result = try await connection.prepareRename(at: offset, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func rename(at offset: Int, to name: String) async throws -> LSPWorkspaceEdit? {
        guard supportsRename, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.rename(at: offset, to: name, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func completion(at offset: Int, trigger: String? = nil, retriggering: Bool = false) async throws -> LSPCompletionList {
        guard supportsCompletion, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.completion(at: offset, trigger: trigger, retriggering: retriggering,
                                                     canResolve: supportsCompletionResolve, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func resolveCompletion(_ item: LSPCompletionItem) async throws -> LSPCompletionItem {
        guard supportsCompletion, let connection else { throw LSPFailure.unavailable }
        guard supportsCompletionResolve else { return item }
        let snapshot = document
        let generation = generation
        let result = try await connection.resolveCompletion(item, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func signatureHelp(at offset: Int, trigger: String? = nil, retriggering: Bool = false) async throws -> LSPSignatureHelp? {
        guard supportsSignatureHelp, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.signatureHelp(at: offset, trigger: trigger, retriggering: retriggering, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    func formatting(tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        guard supportsFormatting, let connection else { throw LSPFailure.unavailable }
        let snapshot = document
        let generation = generation
        let result = try await connection.formatting(tabSize: tabSize, insertSpaces: insertSpaces, in: snapshot)
        try validate(revision: snapshot.revision, generation: generation)
        return result
    }

    private func validate(revision: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard self.revision == revision, self.generation == generation else { throw CancellationError() }
    }

    private func activate(root: URL?) {
        let previousRoot = self.root
        self.root = root
        let stopped = preferenceWorkspace.map { workspacePreferences.isStopped(server, in: $0) } ?? false
        if previousRoot == root && stopped == isManuallyStopped {
            if phase == .ready { connection?.updateDocument(document) }
            onStateChange?()
            return
        }
        isManuallyStopped = stopped
        replaceConnection(startingAt: stopped ? nil : root)
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
        indexMonitor = nil
        capabilities = nil
        semanticTokenResult = nil
        clearProgress()
        clearDiagnostics()
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
        let launch = await Self.resolveExecutable(for: server, in: root)
        guard !Task.isCancelled, self.generation == generation else { return }
        guard let launch else {
            setPhase(server == .sourceKit ? .toolchainUnavailable : .notOnPATH)
            return
        }
        let connection = LanguageServerConnection(server: server, executable: launch.executable, root: root,
                                                  environment: launch.environment, onSemanticTokensRefresh: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.semanticTokensRefresh &+= 1
                self.onSemanticTokensRefresh?()
            }
        }) { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.connection = nil
                self.indexMonitor = nil
                self.capabilities = nil
                self.semanticTokenResult = nil
                self.clearProgress()
                self.clearDiagnostics()
                self.setPhase(.failed(reason))
            }
        }
        self.connection = connection
        progressTask = Task { [weak self, updates = connection.progress] in
            for await progress in updates {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.progress = progress
                self.onProgressChange?()
            }
        }
        diagnosticsTask = Task { [weak self, updates = connection.diagnostics] in
            for await update in updates {
#if EDIT_AGENT_CHECKS
                await self?.beforeApplyDiagnosticsForCheck?()
#endif
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                let isActive = self.document.url.map(WorktreeFileOperations.path) == update.path
                var changed = false
                if isActive, let errors = update.documentErrors {
                    guard self.isReady, self.revision == errors.revision else { continue }
                    self.documentErrors = errors
                    changed = true
                }
                let badgeChanged = update.hasErrors
                    ? self.pathsWithErrors.insert(update.path).inserted
                    : self.pathsWithErrors.remove(update.path) != nil
                if changed || badgeChanged { self.onDiagnosticsChange?() }
            }
        }
        do {
            let capabilities = try await connection.start()
            guard !Task.isCancelled, self.generation == generation, self.connection === connection else { return }
            self.capabilities = capabilities
            if server.usesCanonicalFileURLs {
                indexMonitor = FileSystemEvents(directory: root) { [weak connection, server] events in
                    connection?.updateWatchedFiles(server.indexChanges(events, in: root))
                }
            }
            if canControl { connection.updateDocument(document) }
            setPhase(.ready)
        } catch {
            await connection.stop()
            guard !Task.isCancelled, self.generation == generation else { return }
            self.connection = nil
            capabilities = nil
            clearProgress()
            clearDiagnostics()
            if case .failed = phase { return }
            setPhase(.failed(error.localizedDescription))
        }
    }

    private func clearProgress() {
        progressTask?.cancel()
        progressTask = nil
        progress = []
    }

    private func clearDiagnostics() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        documentErrors = nil
        pathsWithErrors.removeAll()
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

    @concurrent private nonisolated static func resolveExecutable(for server: LanguageServer, in root: URL) async -> Launch? {
        let environment = await launchEnvironment()
        guard !Task.isCancelled else { return nil }
        if let path = environment["PATH"], let executable = executable(in: path, named: server.executable),
           server != .sourceKit || executable.path != "/usr/bin/sourcekit-lsp" {
            return Launch(executable: executable, environment: environment)
        }
        if server == .sourceKit,
           let result = try? await JJCommand.run(URL(fileURLWithPath: "/usr/bin/xcrun"),
                                                arguments: ["--find", server.executable], in: root,
                                                limit: 8_192, timeout: 3),
           result.status == 0, let output = String(data: result.stdout, encoding: .utf8) {
            let path = output.trimmingCharacters(in: .newlines)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
                return Launch(executable: URL(filePath: path), environment: environment)
            }
        }
        return nil
    }

    @concurrent nonisolated static func launchEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Launch Services starts the app through launchd. Direct executable launches retain their caller's PATH.
        if getppid() == 1, let loginPath = await loginShellPATH() { environment["PATH"] = loginPath }
        return environment
    }

    nonisolated static func executable(in path: String, named name: String = "zls") -> URL? {
        guard !path.isEmpty else { return nil }
        let files = FileManager.default
        let current = URL(filePath: files.currentDirectoryPath, directoryHint: .isDirectory)
        for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = entry.isEmpty ? current : URL(filePath: String(entry), directoryHint: .isDirectory, relativeTo: current)
            let candidate = directory.appending(path: name).standardizedFileURL
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
