import Darwin
import Foundation
import Synchronization

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

private enum JJEntryKind: String {
    case absent, file, symlink, tree, conflict
    case submodule = "git-submodule"
}

private struct JJChangedEntry: Equatable, Sendable {
    let source: JJEntryKind
    let target: JJEntryKind
}

enum JJRepository {
    private enum Failure: Error {
        case unavailable, invalidResponse, staleWorkspace, timedOut, outputTooLarge
        case command(String)
    }

    private final class CommandCancellation: Sendable {
        let cancelled = Mutex(false)
    }

    private static let processQueue = DispatchQueue(label: "Edit.Jujutsu", qos: .utility, attributes: .concurrent)
    private static let readLimit = 32 * 1024 * 1024
    private static let fileLimit = 4 * 1024 * 1024
    static var executable: URL? { executable(in: ProcessInfo.processInfo.environment) }

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
        try await requireCurrentWorkingCopy(workspace, operationID: operationID, commitID: commitID)

        let output = try await readCommand(
            ["diff", "-r", "@", "-T", template([
                "status", "path", "source.path()", kind("source"), kind("target"),
                #"if(source.file_type() == "file" && target.file_type() == "file", source.executable() != target.executable(), false)"#,
            ])], in: workspace, at: operationID
        )
        var changes: [String: JJChange] = [:]
        var entries: [String: JJChangedEntry] = [:]
        for row in try records(in: output, width: 6) {
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

        guard try await operation(in: workspace) == operationID else { throw Failure.staleWorkspace }
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
        let recorded: Data?
        if target == .file || target == .conflict {
            recorded = try await readCommand(
                ["file", "show", "-r", "@", fileset], in: workspace, at: pin, limit: fileLimit
            )
        } else {
            recorded = nil
        }
        let base: Data?
        if changed == nil {
            base = source == .file ? recorded : nil
        } else if source == .file {
            // A one-file native diff materializes the merged parent on the left.
            // Passing a fixed program and arguments avoids user diff tools and shell interpolation.
            base = try await readCommand([
                "--config", #"merge-tools.edit-jj-source.program="/bin/cat""#,
                "--config", #"merge-tools.edit-jj-source.diff-args=["$left"]"#,
                "--config", #"merge-tools.edit-jj-source.diff-invocation-mode="file-by-file""#,
                "diff", "-r", "@", "--tool", "edit-jj-source", fileset,
            ], in: workspace, at: pin, limit: fileLimit)
        } else {
            base = nil
        }
        // jj skips EOL conversion for blobs containing NUL, including encoded text such as UTF-16.
        let normalizeCRLF = state.normalizesCRLF && base?.contains(0) != true && recorded?.contains(0) != true
        return JJFileComparison(base: base.flatMap(fileText), recorded: recorded.flatMap(fileText),
                                isConflicted: target == .conflict, existsInBase: source != .absent,
                                normalizeCRLF: normalizeCRLF)
    }

    static func snapshot(_ workspace: JJWorkspace) async throws {
        let head = try await operation(in: workspace)
        let commit = try await workspaceCommit(in: workspace, at: head)
        try await requireCurrentWorkingCopy(workspace, operationID: head, commitID: commit)
        // Resolve the current head again inside jj. "@" rejects divergent heads before it can
        // reconcile them. With 0.46, this pin alone still permits the intended snapshot.
        // Finishing the write belongs to jj even if the last Edit window closes during it.
        _ = try await command(["--at-op=@", "util", "snapshot"], in: workspace, timeout: nil)
    }

    private static func requireCurrentWorkingCopy(
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

    private static func readCommand(
        _ arguments: [String], in workspace: JJWorkspace, at operationID: String = "@", limit: Int = readLimit
    ) async throws -> Data {
        guard operationID == "@" || isOperationID(operationID) else { throw Failure.invalidResponse }
        return try await command(["--at-op=\(operationID)", "--ignore-working-copy"] + arguments, in: workspace, limit: limit)
    }

    private static func command(
        _ arguments: [String], in workspace: JJWorkspace, limit: Int = readLimit, timeout: TimeInterval? = 12
    ) async throws -> Data {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                processQueue.async {
                    continuation.resume(with: Result {
                        try run(arguments, in: workspace, limit: limit, timeout: timeout, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancelled.withLock { $0 = true }
        }
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

    private static func run(
        _ arguments: [String], in workspace: JJWorkspace, limit: Int, timeout: TimeInterval?,
        cancellation: CommandCancellation
    ) throws -> Data {
        guard !cancellation.cancelled.withLock({ $0 }) else { throw CancellationError() }
        let environment = ProcessInfo.processInfo.environment
        guard let executable = executable(in: environment) else { throw Failure.unavailable }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workspace.root
        process.arguments = ["--no-pager", "--color=never", "--config", "snapshot.auto-update-stale=false"] + arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        // Read both pipes as they become ready, including diagnostics emitted before stdout ends.
        var descriptors = [stdout, stderr].map {
            pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        var output = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let start = ProcessInfo.processInfo.systemUptime
        while descriptors.contains(where: { $0.fd >= 0 }) || process.isRunning {
            if let timeout {
                if cancellation.cancelled.withLock({ $0 }) { throw CancellationError() }
                if ProcessInfo.processInfo.systemUptime - start > timeout { throw Failure.timedOut }
            }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready == -1 && errno == EINTR { continue }
            guard ready >= 0 else { throw Failure.invalidResponse }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count == 0 {
                    descriptors[index].fd = -1
                } else if count > 0 {
                    let space = (index == 0 ? limit : 2 * 1024 * 1024) - output[index].count
                    if count > space && timeout != nil {
                        throw Failure.outputTooLarge
                    }
                    output[index].append(contentsOf: buffer.prefix(min(count, space)))
                } else if errno != EINTR {
                    throw Failure.invalidResponse
                }
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.command(String(decoding: output[1], as: UTF8.self))
        }
        return output[0]
    }

    private static func fileText(_ data: Data) -> String? {
        if let encoding = FileTextEncoding.fromBOM(in: data) {
            return String(data: data.dropFirst(encoding.bom.count), encoding: encoding.foundation)
        }
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func template(_ fields: [String]) -> String {
        fields.map { $0 + #" ++ "\0""# }.joined(separator: " ++ ")
    }

    private static func kind(_ name: String) -> String {
        #"if(\#(name).conflict(), "conflict", if(\#(name).normal_value(), \#(name).file_type(), "absent"))"#
    }

    private static func records(in data: Data, width: Int) throws -> [[String]] {
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

    private static func literalFileset(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\r"#)
            .replacingOccurrences(of: "\t", with: #"\t"#)
        return #"root-file:"\#(escaped)""#
    }

    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isOperationID(_ value: String) -> Bool {
        value.utf8.count == 128 && isHexID(value)
    }

    private static func isHexID(_ value: String) -> Bool {
        value.utf8.count >= 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
