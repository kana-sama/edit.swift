import Foundation

enum JJPathStatus: Equatable, Sendable {
    case added, modified, removed, conflict
}

struct JJWorkspace: Hashable, Sendable {
    let root: URL
    let repository: URL
}

struct JJChange: Equatable, Sendable {
    let status: JJPathStatus
    let sourcePath: String?
    var isRename = false
    var keepsModificationWhenTextMatchesBase = false
}

struct JJRepositoryState: Equatable, Sendable {
    let workspace: JJWorkspace
    let operationID: String
    let commitID: String
    let changes: [String: JJChange]
    let conflicts: Set<String>

    fileprivate var entries: [String: JJChangedEntry] = [:]
    fileprivate var normalizesCRLF = false
}

struct JJFileComparison: Sendable {
    let base: String?
    let recorded: String?
    let isConflicted: Bool
    let existsInBase: Bool
    var normalizeCRLF = false
}

enum JJEntryKind: String, Sendable {
    case absent, file, symlink, tree, conflict
    case submodule = "git-submodule"
}

private struct JJChangedEntry: Equatable, Sendable {
    let source: JJEntryKind
    let target: JJEntryKind
}

enum JJRepository {
    private enum Failure: LocalizedError {
        case unavailable, invalidResponse, staleWorkspace, busy
        case command(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "Jujutsu is unavailable."
            case .invalidResponse: "Jujutsu returned an unexpected response."
            case .staleWorkspace: "The Jujutsu working copy is stale. Run jj workspace update-stale and try again."
            case .busy: "Another Jujutsu operation is running. Try again when it finishes."
            case .command(let message): message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private actor Writes {
        var active: Set<URL> = []

        func run<T: Sendable>(in repository: URL, _ operation: @Sendable () async throws -> T) async throws -> T {
            guard active.insert(repository).inserted else { throw Failure.busy }
            defer { active.remove(repository) }
            return try await operation()
        }
    }

    private static let writes = Writes()
    private static let processQueue = DispatchQueue(label: "Edit.Jujutsu", qos: .utility, attributes: .concurrent)
    private static let readLimit = 32 * 1024 * 1024
    static let fileLimit = 4 * 1024 * 1024
    static var executable: URL? { executable(in: ProcessInfo.processInfo.environment) }

    static func hasWorkspace(at directory: URL) -> Bool {
        guard let location = enclosingWorkspace(of: directory) else { return false }
        let operationStore = location.repository.appending(path: "op_store", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: operationStore.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func discover(at directory: URL) async -> JJWorkspace? {
        guard let candidate = await onProcessQueue(body: { enclosingWorkspace(of: directory) }),
              let response = try? await readCommand(["root"], in: candidate),
              let root = String(data: response, encoding: .utf8),
              root == candidate.root.path + "\n" else { return nil }
        return candidate
    }

    static func operation(in workspace: JJWorkspace) async throws -> String {
        let output = try await readCommand(["op", "log", "--no-graph", "-n", "1", "-T", "id"], in: workspace)
        guard let id = String(data: output, encoding: .utf8), isOperationID(id) else {
            throw Failure.invalidResponse
        }
        return id
    }

    static func read(_ workspace: JJWorkspace, at operationID: String) async throws -> JJRepositoryState {
        // conflicted_files() includes inherited conflicts without scanning or emitting the whole tree.
        let context = try await readCommand(
            ["log", "--no-graph", "-r", "@", "-T",
             #"commit_id ++ "\0" ++ config("working-copy.eol-conversion").as_string() ++ "\0" ++ conflicted_files.map(|entry| entry.path() ++ "\0").join("")"#],
            in: workspace, at: operationID
        )
        let fields = try records(in: context, width: 1).map { $0[0] }
        guard fields.count >= 2, isHexID(fields[0]),
              fields.dropFirst(2).allSatisfy(isRelativePath) else { throw Failure.invalidResponse }
        let commitID = fields[0]
        let normalizesCRLF = fields[1] == "input" || fields[1] == "input-output"
        async let diff = readCommand(
            ["diff", "-r", "@", "-T", template([
                "status", "path", "source.path()", kind("source"), kind("target"),
                #"if(source.file_type() == "file" && target.file_type() == "file", source.executable() != target.executable(), false)"#,
            ])], in: workspace, at: operationID
        )
        try await requireCurrentWorkingCopy(workspace, operationID: operationID, commitID: commitID)
        var changes: [String: JJChange] = [:]
        var entries: [String: JJChangedEntry] = [:]
        for row in try await records(in: diff, width: 6) {
            let path = row[1]
            guard isRelativePath(path), isRelativePath(row[2]),
                  let source = JJEntryKind(rawValue: row[3]), let target = JJEntryKind(rawValue: row[4]) else {
                throw Failure.invalidResponse
            }
            let status: JJPathStatus
            switch row[0] {
            case "added": status = .added
            case "removed": status = .removed
            case "modified", "copied", "renamed": status = .modified
            default: throw Failure.invalidResponse
            }
            let isRename = row[0] == "renamed"
            let isCopy = row[0] == "copied"
            changes[path] = JJChange(
                status: status, sourcePath: isRename || isCopy ? row[2] : nil, isRename: isRename,
                keepsModificationWhenTextMatchesBase: isRename || isCopy || source != target || row[5] == "true"
            )
            entries[path] = JJChangedEntry(source: source, target: target)
        }

        return JJRepositoryState(workspace: workspace, operationID: operationID, commitID: commitID,
                                 changes: changes, conflicts: Set(fields.dropFirst(2)), entries: entries,
                                 normalizesCRLF: normalizesCRLF)
    }

    static func compare(_ path: String, in state: JJRepositoryState) async throws -> JJFileComparison? {
        guard isRelativePath(path) else { return nil }
        let fileset = literalFileset(path)
        let workspace = state.workspace
        let pin = state.operationID
        let source: JJEntryKind
        let target: JJEntryKind
        let changed = state.entries[path]
        if let changed {
            source = changed.source
            target = changed.target
        } else if state.conflicts.contains(path) {
            source = .conflict
            target = .conflict
        } else {
            let output = try await readCommand(
                ["file", "list", "-r", "@", "-T", "file_type", fileset], in: workspace, at: pin
            )
            guard let type = String(data: output, encoding: .utf8),
                  let kind = JJEntryKind(rawValue: type) else { return nil }
            source = kind
            target = kind
        }
        // A tracked modification can compare its parent directly with the editor buffer.
        // Keep the recorded text for conflicts, unchanged paths, and EOL detection.
        let needsRecorded = target == .conflict || (target == .file && (changed == nil || state.normalizesCRLF))
        async let recorded: Data? = needsRecorded ? readCommand(
            ["file", "show", "-r", "@", fileset], in: workspace, at: pin, limit: fileLimit
        ) : nil
        let base: Data?
        if changed == nil {
            base = source == .file ? try await recorded : nil
        } else if source == .file {
            // A one-file native diff materializes the merged parent on the left.
            // Passing a fixed program and arguments avoids user diff tools and shell interpolation.
            base = try await readMergedParent(fileset, revision: "@", in: workspace, at: pin)
        } else {
            base = nil
        }
        // jj skips EOL conversion for blobs containing NUL, including encoded text such as UTF-16.
        let recordedText = try await recorded
        let normalizeCRLF = state.normalizesCRLF && base?.contains(0) != true && recordedText?.contains(0) != true
        return JJFileComparison(base: base.flatMap(fileText), recorded: recordedText.flatMap(fileText),
                                isConflicted: target == .conflict, existsInBase: source != .absent,
                                normalizeCRLF: normalizeCRLF)
    }

    static func readMergedParent(
        _ fileset: String, revision: String, in workspace: JJWorkspace, at operationID: String,
        limit: Int = fileLimit
    ) async throws -> Data {
        try await readCommand([
            "--config", #"merge-tools.edit-jj-source.program="/bin/cat""#,
            "--config", #"merge-tools.edit-jj-source.diff-args=["$left"]"#,
            "--config", #"merge-tools.edit-jj-source.diff-invocation-mode="file-by-file""#,
            "diff", "-r", revision, "--tool", "edit-jj-source", fileset,
        ], in: workspace, at: operationID, limit: limit)
    }

    static func snapshot(_ workspace: JJWorkspace) async throws {
        try await withWriteAccess(in: workspace) { try await snapshotWithWriteAccess(workspace) }
    }

    static func withWriteAccess<T: Sendable>(
        in workspace: JJWorkspace, _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await writes.run(in: workspace.repository, operation)
    }

    static func snapshotWithWriteAccess(_ workspace: JJWorkspace) async throws {
        let head = try await operation(in: workspace)
        let commit = try await workspaceCommit(in: workspace, at: head)
        try await requireCurrentWorkingCopy(workspace, operationID: head, commitID: commit)
        // Resolve the current head again inside jj. "@" rejects divergent heads before it can
        // reconcile them. With 0.46, this pin alone still permits the intended snapshot.
        // Finishing the write belongs to jj even if the last Edit window closes during it.
        _ = try await command(["--at-op=@", "util", "snapshot"], in: workspace, timeout: nil)
    }

    static func requireCurrentWorkingCopy(
        _ workspace: JJWorkspace, operationID: String, commitID: String
    ) async throws {
        // jj has no working-copy operation template. This command reports the actual local
        // checkout, which can predate the repository's head when another workspace advances.
        let output = try await readCommand(["debug", "working-copy"], in: workspace, at: operationID)
        let localID = try workingCopyOperation(in: output)
        if localID != operationID {
            guard try await workspaceCommit(in: workspace, at: localID) == commitID else {
                throw Failure.staleWorkspace
            }
        }
    }

    private static func workingCopyOperation(in output: Data) throws -> String {
        let prefix = #"Current operation: OperationId(""#
        let suffix = #"")"#
        guard let lines = String(data: output, encoding: .utf8)?.split(whereSeparator: \.isNewline),
              let line = lines.first(where: { $0.hasPrefix(prefix) }), line.hasSuffix(suffix) else {
            throw Failure.invalidResponse
        }
        let id = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        guard isOperationID(id) else { throw Failure.invalidResponse }
        return id
    }

    private static func workspaceCommit(in workspace: JJWorkspace, at operationID: String) async throws -> String {
        let data = try await readCommand(["log", "--no-graph", "-r", "@", "-T", "commit_id"], in: workspace, at: operationID)
        guard let id = String(data: data, encoding: .utf8), isHexID(id) else { throw Failure.invalidResponse }
        return id
    }

    private static func enclosingWorkspace(of directory: URL) -> JJWorkspace? {
        let files = FileManager.default
        var root = FileBuffer.canonicalURL(directory)
        while root.isFileURL {
            let metadata = root.appending(path: ".jj", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: metadata.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let repo = metadata.appending(path: "repo")
                guard files.fileExists(atPath: repo.path, isDirectory: &isDirectory) else { return nil }
                if isDirectory.boolValue {
                    return JJWorkspace(root: root, repository: FileBuffer.canonicalURL(repo))
                }
                guard let pointer = try? String(contentsOf: repo, encoding: .utf8), !pointer.isEmpty else { return nil }
                let target = URL(filePath: pointer, directoryHint: .isDirectory, relativeTo: metadata)
                return JJWorkspace(root: root, repository: FileBuffer.canonicalURL(target))
            }
            let parent = FileBuffer.canonicalURL(root.deletingLastPathComponent())
            guard root.path != parent.path else { return nil }
            root = parent
        }
        return nil
    }

    static func readCommand(
        _ arguments: [String], in workspace: JJWorkspace, at operationID: String = "@", limit: Int = readLimit
    ) async throws -> Data {
        guard operationID == "@" || isOperationID(operationID) else { throw Failure.invalidResponse }
        return try await command(["--at-op=\(operationID)", "--ignore-working-copy"] + arguments, in: workspace, limit: limit)
    }

    static func command(
        _ arguments: [String], in workspace: JJWorkspace, limit: Int = readLimit, timeout: TimeInterval? = 12
    ) async throws -> Data {
        guard let executable = await onProcessQueue(body: { Self.executable }) else { throw Failure.unavailable }
        let output = try await JJCommand.run(
            executable, arguments: ["--no-pager", "--color=never", "--config", "snapshot.auto-update-stale=false"] + arguments,
            in: workspace.root, limit: limit, timeout: timeout
        )
        guard output.status == 0 else {
            throw Failure.command(String(decoding: output.stderr, as: UTF8.self))
        }
        return output.stdout
    }

    private static func onProcessQueue<T: Sendable>(body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            processQueue.async { continuation.resume(returning: body()) }
        }
    }

    private static func executable(in environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let loginPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Launch Services typically supplies only system paths, even when jj comes from Homebrew or Cargo.
        for directory in loginPath + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin"] {
            guard directory.hasPrefix("/") else { continue }
            let candidate = URL(filePath: directory, directoryHint: .isDirectory).appending(path: "jj")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func fileText(_ data: Data) -> String? {
        if let encoding = FileTextEncoding.fromBOM(in: data) {
            return String(data: data.dropFirst(encoding.bom.count), encoding: encoding.foundation)
        }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func template(_ fields: [String]) -> String {
        fields.map { $0 + #" ++ "\0""# }.joined(separator: " ++ ")
    }

    static func kind(_ name: String) -> String {
        #"if(\#(name).conflict(), "conflict", if(\#(name).normal_value(), \#(name).file_type(), "absent"))"#
    }

    static func records(in data: Data, width: Int) throws -> [[String]] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0 else { throw Failure.invalidResponse }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard fields.count.isMultiple(of: width) else { throw Failure.invalidResponse }
        return try stride(from: 0, to: fields.count, by: width).map { start in
            try fields[start..<(start + width)].map { field in
                guard let text = String(data: field, encoding: .utf8) else { throw Failure.invalidResponse }
                return text
            }
        }
    }

    static func literalFileset(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\r"#)
            .replacingOccurrences(of: "\t", with: #"\t"#)
        return #"root-file:"\#(escaped)""#
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isOperationID(_ value: String) -> Bool {
        value.utf8.count == 128 && isHexID(value)
    }

    static func isHexID(_ value: String) -> Bool {
        value.utf8.count >= 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
