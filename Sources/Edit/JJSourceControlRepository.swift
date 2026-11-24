import Foundation

struct JJSourceControlEdge: Hashable, Sendable {
    /// A nil target represents ancestry outside of the displayed graph.
    let target: String?
    let indirect: Bool
}

struct JJSourceControlRevision: Identifiable, Equatable, Sendable {
    let id: String
    let changeID: String
    let shortID: String
    let description: String
    let author: String
    let parents: [String]
    var edges: [JJSourceControlEdge] = []
    let bookmarks: [String]
    let localBookmarks: [String]
    let isImmutable: Bool
    let isConflicted: Bool
    let isWorkingCopy: Bool
    let isDivergent: Bool

    var subject: String {
        description.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first
            .map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "(No description)"
    }
}

struct JJSourceControlGraph: Sendable {
    let operationID: String
    let workingCopy: JJSourceControlRevision
    let revisions: [JJSourceControlRevision]
    let isTruncated: Bool
}

struct JJSourceControlDetail: Sendable {
    let files: [JJSourceControlFile]
    let mutableParent: JJSourceControlRevision?
    let descendantCount: Int
    let descendantSubjects: [String]
}

struct JJSourceControlFile: Hashable, Sendable {
    enum Kind: String, Sendable {
        case added, modified, deleted = "removed", renamed, copied, conflict
    }

    let path: String
    let sourcePath: String?
    let kind: Kind
    let source: JJEntryKind
    let target: JJEntryKind

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var isDeleted: Bool { kind == .deleted }

    var status: JJPathStatus {
        switch kind {
        case .added: .added
        case .modified, .renamed, .copied: .modified
        case .deleted: .removed
        case .conflict: .conflict
        }
    }

    var statusName: String {
        switch kind {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .conflict: "Unresolved conflict"
        }
    }
}

struct JJSourceControlFileContents: Sendable {
    let base: Data?
    let recorded: Data?
    let isConflict: Bool
}

enum JJSourceControlMutation: Sendable {
    case edit(String, ignoreImmutable: Bool = false)
    case new(String)
    case describe(String, String)
    case abandon(String)
    case squash(String, description: String?)

    fileprivate var target: String {
        switch self {
        case .edit(let id, _), .new(let id), .describe(let id, _), .abandon(let id), .squash(let id, _): id
        }
    }

    fileprivate func arguments(revision: String) -> [String] {
        switch self {
        case .edit(_, let ignoreImmutable):
            (ignoreImmutable ? ["--ignore-immutable"] : []) + ["edit", "--", revision]
        case .new: ["new", "--", revision]
        case .describe(_, let description): ["describe", "--message=\(description)", "--", revision]
        case .abandon: ["abandon", "--", revision]
        case .squash(_, let description):
            ["--config", #"ui.editor=["/usr/bin/false"]"#, "squash", "--revision=\(revision)"]
                + (description.map { ["--message=\($0)"] } ?? [])
        }
    }
}

enum JJSourceControlRepository {
    enum Failure: LocalizedError {
        case invalidResponse, changedOperation, fileTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Jujutsu returned an unexpected response."
            case .changedOperation: "The repository changed. Review the updated change before trying again."
            case .fileTooLarge: "This revision file exceeds the 32 MB preview limit."
            }
        }
    }

    private static let revisionFields = JJRepository.template([
        "commit_id", "change_id", "change_id.short(8)", "json(description)",
        #"parents.map(|parent| parent.commit_id()).join(",")"#,
        #""[" ++ bookmarks.map(|b| json(stringify(b.name() ++ if(b.remote(), "@" ++ b.remote())))).join(",") ++ "]""#,
        #""[" ++ local_bookmarks.map(|b| json(stringify(b.name()))).join(",") ++ "]""#,
        "immutable", "conflict", "current_working_copy", "divergent",
        "json(if(author.name(), author.name(), author.email()))",
    ])
    private static let parentFields = JJRepository.template(["commit_id", #"parents.map(|c| c.commit_id()).join(",")"#])
    private static let previewLimit = 32 * 1024 * 1024

    static func read(
        _ workspace: JJWorkspace, operation: String? = nil, arguments: [String]
    ) async throws -> String {
        let data = try await JJRepository.readCommand(arguments, in: workspace, at: operation ?? "@")
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidResponse }
        return text
    }

    static func graph(
        in workspace: JJWorkspace, revset: String?, includeWorkingCopy: Bool = false,
        limit: Int = 600
    ) async throws -> JJSourceControlGraph {
        let operation = try await JJRepository.operation(in: workspace)
        let limit = min(max(1, limit), 1_800)
        let arguments = revset.map { ["--revision=\($0)"] } ?? []
        async let graph = revisions(arguments, limit: limit + 1, in: workspace, at: operation)
        async let workingCopy = singleRevision("@", in: workspace, at: operation)
        let (result, working) = try await (graph, workingCopy)
        let isTruncated = result.count > limit
        var visible = Array(result.prefix(limit))
        if includeWorkingCopy && !visible.contains(where: { $0.id == working.id }) {
            let ids = ([working] + visible).map(\.id).joined(separator: " | ")
            visible = try await revisions(["-r", ids], limit: limit + 1, in: workspace, at: operation)
        }
        let edges = try await edges(for: visible, in: workspace, at: operation)
        for index in visible.indices {
            visible[index].edges = edges[visible[index].id] ?? []
        }
        guard try await JJRepository.operation(in: workspace) == operation else { throw Failure.changedOperation }
        try await JJRepository.requireCurrentWorkingCopy(workspace, operationID: operation, commitID: working.id)
        guard try await JJRepository.operation(in: workspace) == operation else { throw Failure.changedOperation }
        return JJSourceControlGraph(operationID: operation, workingCopy: working, revisions: visible,
                                    isTruncated: isTruncated)
    }

    static func validateRevset(_ expression: String, in workspace: JJWorkspace) async throws {
        let operation = try await JJRepository.operation(in: workspace)
        _ = try await revisions(["--revision=\(expression)"], limit: 1, in: workspace, at: operation)
    }

    static func detail(
        for revision: JJSourceControlRevision, in workspace: JJWorkspace, at operationID: String
    ) async throws -> JJSourceControlDetail {
        guard JJRepository.isHexID(revision.id), revision.parents.allSatisfy(JJRepository.isHexID) else {
            throw Failure.invalidResponse
        }
        let descendants = "\(revision.id):: ~ \(revision.id)"
        async let files = changedFiles(revision.id, in: workspace, at: operationID)
        async let parents = revision.parents.count == 1
            ? revisions(["-r", "\(revision.parents[0]) & mutable()"], limit: 1, in: workspace, at: operationID)
            : []
        async let count = read(workspace, operation: operationID,
                               arguments: ["log", "--count", "-r", descendants])
        async let subjects = read(workspace, operation: operationID, arguments: [
            "log", "--no-graph", "-n", "4", "-r", descendants,
            "-T", #"if(description.first_line(), description.first_line(), "(No description)") ++ "\0""#,
        ])
        let (paths, parent, countText, subjectText) = try await (files, parents, count, subjects)
        guard let descendantCount = Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.invalidResponse
        }
        let descendantSubjects = subjectText.split(separator: "\0").map(String.init)
        return JJSourceControlDetail(files: paths, mutableParent: parent.first, descendantCount: descendantCount,
                                     descendantSubjects: descendantSubjects)
    }

    static func file(
        _ file: JJSourceControlFile, in revision: JJSourceControlRevision,
        workspace: JJWorkspace, at operationID: String
    ) async throws -> JJSourceControlFileContents {
        guard JJRepository.isHexID(revision.id), JJRepository.isRelativePath(file.path) else {
            throw Failure.invalidResponse
        }
        let path = JJRepository.literalFileset(file.path)
        let canReadRecorded = file.target == .file || file.target == .conflict
        let canReadBase = file.source == .file || file.source == .conflict && file.target != .conflict
        // The diff tool receives the merged parent and uses the source path for a rename or copy.
        async let base: Data? = canReadBase
            ? JJRepository.readMergedParent(path, revision: revision.id, in: workspace, at: operationID, limit: previewLimit)
            : nil
        async let recorded: Data? = canReadRecorded
            ? JJRepository.readCommand(["file", "show", "-r", revision.id, path], in: workspace, at: operationID,
                                       limit: previewLimit) : nil
        do {
            return try await JJSourceControlFileContents(base: base, recorded: recorded, isConflict: file.kind == .conflict)
        } catch JJCommand.Failure.outputTooLarge {
            throw Failure.fileTooLarge
        }
    }

    static func departedFile(
        _ file: JJSourceControlFile, from revision: JJSourceControlRevision, lastCommitID: String,
        lastOperationID: String, in workspace: JJWorkspace, at operationID: String
    ) async throws -> (JJSourceControlFile, JJSourceControlRevision, JJSourceControlFileContents) {
        guard isChangeID(revision.changeID), JJRepository.isHexID(lastCommitID) else { throw Failure.invalidResponse }
        let exact = "present(\(lastCommitID)) & visible()"
        let expression = revision.isDivergent ? exact : "coalesce(\(exact), present(\(revision.changeID)) & visible())"
        let visible = try await revisions(["-r", expression], limit: 2, in: workspace, at: operationID)
        let snapshot = visible.count == 1 ? operationID : lastOperationID
        let target: JJSourceControlRevision
        if visible.count == 1, let current = visible.first {
            target = current
        } else {
            target = try await singleRevision(lastCommitID, in: workspace, at: snapshot)
        }
        let files = try await changedFiles(target.id, in: workspace, at: snapshot)
        if let changed = files.first(where: { $0.path == file.path }) {
            return (changed, target, try await self.file(changed, in: target, workspace: workspace, at: snapshot))
        }
        // The path can become clean before leaving the change. Its recorded contents still belong to that change.
        let path = JJRepository.literalFileset(file.path)
        let kindText = try await read(workspace, operation: snapshot,
                                      arguments: ["file", "list", "-r", target.id, "-T", "file_type", path])
        let kind = JJEntryKind(rawValue: kindText) ?? .absent
        let data = kind == .file
            ? try await JJRepository.readCommand(["file", "show", "-r", target.id, path], in: workspace, at: snapshot,
                                                 limit: previewLimit) : nil
        let unchanged = JJSourceControlFile(path: file.path, sourcePath: nil, kind: .modified, source: kind, target: kind)
        return (unchanged, target, .init(base: data, recorded: data, isConflict: false))
    }

    static func mutate(
        _ mutation: JJSourceControlMutation, in workspace: JJWorkspace, expectedOperation: String
    ) async throws {
        guard JJRepository.isHexID(mutation.target) else { throw Failure.invalidResponse }
        try await JJRepository.withWriteAccess(in: workspace) {
            guard try await JJRepository.operation(in: workspace) == expectedOperation else {
                throw Failure.changedOperation
            }
            async let selected = singleRevision("\(mutation.target) & visible()", in: workspace, at: expectedOperation)
            async let working = singleRevision("@", in: workspace, at: expectedOperation)
            let (target, workingCopy) = try await (selected, working)
            try await JJRepository.requireCurrentWorkingCopy(
                workspace, operationID: expectedOperation, commitID: workingCopy.id
            )
            let overrideSnapshot = await JJRepository.maySnapshotImmutable(workingCopy.changeID, in: workspace)
            guard try await JJRepository.operation(in: workspace) == expectedOperation else {
                throw Failure.changedOperation
            }
            let revision: String
            let operation: String
            if target.isWorkingCopy {
                revision = "@ & present(\(target.changeID))"
                operation = if overrideSnapshot {
                    try await snapshotForSelectedRevision(in: workspace, at: expectedOperation, ignoreImmutable: true)
                } else {
                    expectedOperation
                }
            } else {
                // Snapshot first so a rebased descendant still resolves to a single exact commit.
                // Describe, abandon and new accept multiple revisions on the command line.
                operation = try await snapshotForSelectedRevision(in: workspace, at: expectedOperation, ignoreImmutable: overrideSnapshot)
                var id = target.id
                if operation != expectedOperation && !target.isDivergent {
                    let expression = "coalesce(present(\(target.id)) & visible(), present(\(target.changeID)) & visible())"
                    id = try await singleRevision(expression, in: workspace, at: operation).id
                }
                revision = "present(\(id)) & visible()"
            }
            guard try await JJRepository.operation(in: workspace) == operation else {
                throw Failure.changedOperation
            }
            _ = try await JJRepository.command(
                ["--at-op=@", "--config", "edit.source-control=true"] + mutation.arguments(revision: revision),
                in: workspace, timeout: nil
            )
            switch mutation {
            case .edit(_, let ignoreImmutable):
                await JJRepository.authorizeImmutableSnapshots(of: ignoreImmutable ? target.changeID : nil, in: workspace)
            case .new:
                await JJRepository.authorizeImmutableSnapshots(of: nil, in: workspace)
            default:
                break
            }
        }
    }

    private static func snapshotForSelectedRevision(in workspace: JJWorkspace, at operation: String, ignoreImmutable: Bool) async throws -> String {
        let token = UUID().uuidString
        let flags = ignoreImmutable ? ["--ignore-immutable"] : []
        _ = try await JJRepository.command(
            ["--at-op=@", "--config", "edit.source-control-snapshot=\(token)"] + flags + ["util", "snapshot"],
            in: workspace, timeout: nil
        )
        let head = try await JJRepository.operation(in: workspace)
        if head == operation { return head }
        let fields = JJRepository.template(["snapshot", #"parents.map(|p| p.id()).join(",")"#, "attributes"])
        let data = try await JJRepository.readCommand(
            ["op", "log", "--no-graph", "-n", "1", "-T", fields], in: workspace, at: head
        )
        let records = try JJRepository.records(in: data, width: 3)
        guard let row = records.first, records.count == 1, row[0] == "true",
              row[1] == operation, row[2].contains(token) else {
            throw Failure.changedOperation
        }
        return head
    }

    private static func singleRevision(
        _ expression: String, in workspace: JJWorkspace, at operationID: String
    ) async throws -> JJSourceControlRevision {
        let result = try await revisions(["--revision=\(expression)"], limit: 2, in: workspace, at: operationID)
        guard result.count == 1, let revision = result.first else { throw Failure.invalidResponse }
        return revision
    }

    private static func revisions(
        _ arguments: [String], limit: Int, in workspace: JJWorkspace, at operationID: String
    ) async throws -> [JJSourceControlRevision] {
        let bytes = try await JJRepository.readCommand(
            ["log", "--no-graph", "--limit=\(limit)", "-T", revisionFields] + arguments, in: workspace, at: operationID
        )
        return try JJRepository.records(in: bytes, width: 12).map { row in
            let parents = row[4].split(separator: ",").map(String.init)
            guard JJRepository.isHexID(row[0]), isChangeID(row[1]), !row[2].isEmpty,
                  parents.allSatisfy(JJRepository.isHexID),
                  !row[7...10].contains(where: { $0 != "true" && $0 != "false" }) else {
                throw Failure.invalidResponse
            }
            let decoder = JSONDecoder()
            return try JJSourceControlRevision(
                id: row[0], changeID: row[1], shortID: row[2],
                description: decoder.decode(String.self, from: Data(row[3].utf8)),
                author: decoder.decode(String.self, from: Data(row[11].utf8)), parents: parents,
                bookmarks: decoder.decode([String].self, from: Data(row[5].utf8)),
                localBookmarks: decoder.decode([String].self, from: Data(row[6].utf8)),
                isImmutable: row[7] == "true", isConflicted: row[8] == "true",
                isWorkingCopy: row[9] == "true", isDivergent: row[10] == "true"
            )
        }
    }

    private static func isChangeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (107...122).contains($0) }
    }

    private static func edges(
        for revisions: [JJSourceControlRevision], in workspace: JJWorkspace, at operationID: String
    ) async throws -> [String: [JJSourceControlEdge]] {
        let visible = Set(revisions.map(\.id))
        var nearestVisible: [String: [String?]] = [:]
        if revisions.count > 1, revisions.contains(where: { !$0.parents.allSatisfy(visible.contains) }) {
            // Only ask for commits on paths between visible revisions. An ancestor outside that
            // set only contributes a trailing edge, regardless of how large the repository is.
            let ids = revisions.map(\.id).joined(separator: "|")
            let range = "connected(\(ids))"
            let data = try await JJRepository.readCommand(
                ["log", "--no-graph", "--limit=6000", "-r", range, "-T", parentFields], in: workspace, at: operationID
            )
            for row in try JJRepository.records(in: data, width: 2).reversed() where !visible.contains(row[0]) {
                let parents = row[1].split(separator: ",").map(String.init)
                guard JJRepository.isHexID(row[0]), parents.allSatisfy(JJRepository.isHexID) else {
                    throw Failure.invalidResponse
                }
                var seen = Set<String?>()
                let targets = parents.isEmpty ? [nil] : parents.flatMap { parent -> [String?] in
                    visible.contains(parent) ? [parent] : nearestVisible[parent] ?? [nil]
                }
                nearestVisible[row[0]] = targets.filter { seen.insert($0).inserted }
            }
        }
        return Dictionary(uniqueKeysWithValues: revisions.map { revision in
            let direct = Set(revision.parents.filter(visible.contains))
            var seen = Set<JJSourceControlEdge>()
            let outgoing = revision.parents.flatMap { parent -> [JJSourceControlEdge] in
                if visible.contains(parent) {
                    return [JJSourceControlEdge(target: parent, indirect: false)]
                }
                return (nearestVisible[parent] ?? [nil]).compactMap { target in
                    if let target, direct.contains(target) { return nil }
                    return JJSourceControlEdge(target: target, indirect: true)
                }
            }
            return (revision.id, outgoing.filter { seen.insert($0).inserted })
        })
    }

    static func changedFiles(
        _ revision: String, in workspace: JJWorkspace, at operationID: String
    ) async throws -> [JJSourceControlFile] {
        async let diff = JJRepository.readCommand([
            "diff", "-r", revision, "-T", JJRepository.template([
                "status", "path", "source.path()", JJRepository.kind("source"), JJRepository.kind("target"),
            ]),
        ], in: workspace, at: operationID)
        async let conflicts = JJRepository.readCommand(
            ["log", "--no-graph", "-r", revision, "-T", #"conflicted_files.map(|entry| entry.path() ++ "\0").join("")"#],
            in: workspace, at: operationID
        )
        var files: [String: JJSourceControlFile] = [:]
        for row in try await JJRepository.records(in: diff, width: 5) {
            guard let kind = JJSourceControlFile.Kind(rawValue: row[0]),
                  JJRepository.isRelativePath(row[1]), JJRepository.isRelativePath(row[2]),
                  let source = JJEntryKind(rawValue: row[3]), let target = JJEntryKind(rawValue: row[4]) else {
                throw Failure.invalidResponse
            }
            files[row[1]] = JJSourceControlFile(
                path: row[1], sourcePath: kind == .copied || kind == .renamed ? row[2] : nil,
                kind: target == .conflict ? .conflict : kind, source: source, target: target
            )
        }
        for row in try await JJRepository.records(in: conflicts, width: 1) {
            let path = row[0]
            guard JJRepository.isRelativePath(path) else { throw Failure.invalidResponse }
            if files[path] == nil {
                files[path] = JJSourceControlFile(path: path, sourcePath: nil, kind: .conflict,
                                                  source: .conflict, target: .conflict)
            }
        }
        return files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
