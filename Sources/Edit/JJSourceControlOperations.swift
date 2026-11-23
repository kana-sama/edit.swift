import Foundation

enum JJSourceControlOperations {
    enum Direction: String, CaseIterable, Sendable {
        case undo, redo

        var title: String { rawValue.capitalized }
        fileprivate var restorePrefix: String { "\(rawValue): restore to operation " }
    }

    struct FileEffect: Equatable, Sendable {
        let path: String
        let label: String
    }

    struct Preview: Sendable {
        let direction: Direction
        let head: String
        let target: String
        let operationID: String
        let description: String
        let time: String
        let origin: String?
        let workingCopyBefore: String
        let workingCopyAfter: String
        let workingCopyChangeIDBefore: String
        let workingCopyChangeIDAfter: String
        let revisionEffects: [String]
        let bookmarkEffects: [String]
        let fileEffects: [FileEffect]
        fileprivate let workspace: JJWorkspace
        fileprivate let sparsePaths: String
    }

    private enum Failure: LocalizedError {
        case unavailable(String)
        case invalidResponse
        case changed
        case resultChanged

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .invalidResponse: "Jujutsu did not return a complete operation preview."
            case .changed: "The repository changed. Review the updated preview before continuing."
            case .resultChanged: "Jujutsu recorded a different result. Review the current repository state."
            }
        }
    }

    private struct Operation: Decodable, Sendable {
        struct Time: Decodable, Sendable { let end: String }
        let id: String
        let description: String
        let parents: [String]
        let time: Time
        let workspaceName: String?
        let attributes: [String: String]

        enum CodingKeys: String, CodingKey {
            case id, description, parents, time, attributes
            case workspaceName = "workspace_name"
        }

        var timeLabel: String {
            let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time.end)
            return date?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? time.end
        }

        var origin: String? {
            if attributes["args"]?.contains("edit.source-control=true") == true { return "Edit" }
            return workspaceName
        }

        var summary: String {
            if description.hasPrefix("squash commits") { return "Squash changes" }
            if description.hasPrefix("describe commit") { return "Describe change" }
            if description.hasPrefix("edit commit") || description.hasPrefix("check out commit") { return "Edit change" }
            if description.hasPrefix("new empty commit") { return "New change" }
            if description.hasPrefix("abandon commit") { return "Abandon change" }
            if description.hasPrefix(Direction.undo.restorePrefix) { return "Undo repository operation" }
            if description.hasPrefix(Direction.redo.restorePrefix) { return "Redo repository operation" }
            return description.isEmpty ? "Repository operation" : description.prefix(250).description
        }

        func restoredOperation(_ direction: Direction) -> String? {
            let prefix = direction.restorePrefix
            guard description.hasPrefix(prefix) else { return nil }
            return String(description.dropFirst(prefix.count))
        }
    }

    private struct Revision: Decodable, Sendable {
        let commitID: String
        let changeID: String
        let subject: String
        let conflicted: Bool
        let parentIDs: [String]

        var label: String {
            let title = subject.isEmpty ? "(no description)" : String(subject.prefix(140))
            let state = conflicted ? " · Conflict" : ""
            return "\(changeID.prefix(8))  \(title)\(state)"
        }
    }

    private struct Checkout: Decodable, Sendable {
        let name: String
        let root: String?
        let current: Bool
        let revision: Revision
    }

    private struct Reference: Decodable, Equatable, Sendable {
        let name: String
        let remote: String?
        let present: Bool
        let tracked: Bool
        let conflict: Bool
        let added: [String]
        let removed: [String]

        var qualifiedName: String { remote.map { "\(name)@\($0)" } ?? name }
        var location: String {
            guard present else { return "absent" }
            let targets = added.map { String($0.prefix(8)) }.joined(separator: ", ")
            if conflict && targets.isEmpty { return "conflict" }
            return conflict ? "conflict (\(targets))" : targets
        }
    }

    private struct PathChange: Decodable, Sendable {
        let path: String
        let sourcePath: String
        let status: String
        let sourceConflict: Bool
        let targetConflict: Bool
    }

    private struct Snapshot: Sendable {
        let checkouts: [Checkout]
        let heads: Set<String>
        let bookmarks: [Reference]
        let tags: [Reference]
    }

    private static let revisionTemplate = #"json({"commitID" => commit_id, "changeID" => change_id, "subject" => description.first_line(), "conflicted" => conflict, "parentIDs" => parents.map(|p| p.commit_id())}) ++ "\n""#
    private static let checkoutTemplate = #"json({"name" => name, "root" => root, "current" => target.current_working_copy(), "revision" => {"commitID" => target.commit_id(), "changeID" => target.change_id(), "subject" => target.description().first_line(), "conflicted" => target.conflict(), "parentIDs" => target.parents().map(|p| p.commit_id())}}) ++ "\n""#
    private static let referenceTemplate = #"json({"name" => name, "remote" => remote, "present" => present, "tracked" => tracked, "conflict" => conflict, "added" => added_targets.map(|ref| ref.commit_id()), "removed" => removed_targets.map(|ref| ref.commit_id())}) ++ "\n""#
    private static let pathTemplate = #"json({"path" => path, "sourcePath" => source.path(), "status" => status, "sourceConflict" => source.conflict(), "targetConflict" => target.conflict()}) ++ "\n""#

    static func preview(_ direction: Direction, in workspace: JJWorkspace) async throws -> Preview {
        let head = try await operation(nil, in: workspace)
        let target = try await target(for: direction, from: head, in: workspace)
        async let previous = snapshot(head.id, in: workspace)
        async let next = snapshot(target.state.id, in: workspace)
        async let sparse = read(["sparse", "list"], in: workspace, at: head.id)
        let (before, after, sparsePaths) = try await (previous, next, sparse)
        let current = try currentCheckout(before.checkouts, in: workspace)
        if let name = target.operation.workspaceName, name != current.name {
            throw Failure.unavailable("This operation belongs to workspace \(name).")
        }
        guard let destination = after.checkouts.first(where: { $0.name == current.name }) else {
            throw Failure.unavailable("This operation would remove the current workspace’s working copy.")
        }
        try await JJRepository.requireCurrentWorkingCopy(workspace, operationID: head.id, commitID: current.revision.commitID)
        async let graph = revisionEffects(from: before.heads, to: after.heads, direction: direction, at: head.id, in: workspace)
        async let files = fileEffects(from: current.revision, to: destination.revision, sparsePaths: sparsePaths,
                                      at: head.id, in: workspace)
        let bookmarkEffects = referenceEffects(from: before.bookmarks, to: after.bookmarks, kind: "bookmark")
            + referenceEffects(from: before.tags, to: after.tags, kind: "tag")
        let workspaceChanges = workspaceEffects(from: before.checkouts, to: after.checkouts, excluding: current.name)
        let (changedRevisions, changedFiles) = try await (graph, files)
        guard try await JJRepository.operation(in: workspace) == head.id else { throw Failure.changed }
        return Preview(direction: direction, head: head.id, target: target.state.id,
                       operationID: target.display.id, description: target.display.summary,
                       time: target.display.timeLabel, origin: target.display.origin,
                       workingCopyBefore: current.revision.label, workingCopyAfter: destination.revision.label,
                       workingCopyChangeIDBefore: current.revision.changeID, workingCopyChangeIDAfter: destination.revision.changeID,
                       revisionEffects: changedRevisions + workspaceChanges, bookmarkEffects: bookmarkEffects,
                       fileEffects: changedFiles, workspace: workspace, sparsePaths: sparsePaths)
    }

    static func apply(_ preview: Preview, in workspace: JJWorkspace) async throws {
        guard preview.workspace == workspace else { throw Failure.changed }
        // After the user confirms, record pending writes first. An Undo selected before a
        // snapshot must not silently apply to that new snapshot instead.
        try await Task.detached(priority: .userInitiated) {
            try await JJRepository.withWriteAccess(in: workspace) {
                guard try await JJRepository.operation(in: workspace) == preview.head else { throw Failure.changed }
                try await JJRepository.snapshotWithWriteAccess(workspace)
                guard try await read(["sparse", "list"], in: workspace, at: preview.head) == preview.sparsePaths,
                      try await JJRepository.operation(in: workspace) == preview.head else { throw Failure.changed }
                _ = try await JJRepository.command(
                    ["--at-op=@", "--config", "edit.source-control=true", preview.direction.rawValue],
                    in: workspace, timeout: nil
                )
                let result = try await operation(nil, in: workspace)
                guard result.parents == [preview.head],
                      result.restoredOperation(preview.direction) == preview.target else { throw Failure.resultChanged }
            }
        }.value
    }

    private static func target(for direction: Direction, from head: Operation, in workspace: JJWorkspace) async throws
        -> (operation: Operation, state: Operation, display: Operation) {
        // jj 0.46 maintains its two stacks using restore IDs stored in operation descriptions.
        let subject: Operation
        if let pointer = head.restoredOperation(direction) {
            subject = try await operation(pointer, in: workspace)
        } else {
            subject = head
        }
        if direction == .redo && subject.restoredOperation(.undo) == nil {
            throw Failure.unavailable("There is no operation to redo.")
        }
        guard subject.parents.count == 1, let parentID = subject.parents.first else {
            let reason = subject.parents.isEmpty ? "There is no operation to undo." : "Jujutsu cannot undo a merged operation."
            throw Failure.unavailable(reason)
        }
        let parent = try await operation(parentID, in: workspace)
        let state: Operation
        if let earlier = parent.restoredOperation(direction) {
            state = try await operation(earlier, in: workspace)
        } else {
            state = parent
        }
        let display = direction == .redo ? state : subject
        return (subject, state, display)
    }

    private static func currentCheckout(_ checkouts: [Checkout], in workspace: JJWorkspace) throws -> Checkout {
        let root = FileBuffer.canonicalURL(workspace.root)
        if let matching = checkouts.first(where: { checkout in
            checkout.current && checkout.root.map { FileBuffer.canonicalURL(URL(filePath: $0)) == root } == true
        }) { return matching }
        let candidates = checkouts.filter(\.current)
        guard candidates.count == 1, let checkout = candidates.first else { throw Failure.invalidResponse }
        return checkout
    }

    private static func snapshot(_ operation: String, in workspace: JJWorkspace) async throws -> Snapshot {
        async let checkouts: [Checkout] = records(["workspace", "list", "-T", checkoutTemplate], in: workspace, at: operation)
        async let heads: [String] = records(["log", "-G", "-r", "heads(all())", "-T", #"json(commit_id) ++ "\n""#],
                                            in: workspace, at: operation)
        async let bookmarks: [Reference] = records(["bookmark", "list", "-a", "-T", referenceTemplate], in: workspace, at: operation)
        async let tags: [Reference] = records(["tag", "list", "-a", "-T", referenceTemplate], in: workspace, at: operation)
        return try await Snapshot(checkouts: checkouts, heads: Set(heads), bookmarks: bookmarks, tags: tags)
    }

    private static func revisionEffects(from before: Set<String>, to after: Set<String>, direction: Direction,
                                        at operation: String, in workspace: JJWorkspace) async throws -> [String] {
        guard before != after else { return [] }
        guard !before.isEmpty, !after.isEmpty, before.union(after).allSatisfy({ isHex($0, length: 40) }) else {
            throw Failure.invalidResponse
        }
        // The two visible head sets define which ancestors each operation shows. Compare
        // their ancestry in jj instead of loading all of either history into the editor.
        let old = "::(\(before.sorted().joined(separator: " | ")))"
        let new = "::(\(after.sorted().joined(separator: " | ")))"
        let limit = 500
        guard old.utf8.count + new.utf8.count < 100_000 else {
            throw Failure.unavailable("This operation has too many revision heads to preview.")
        }
        let log = ["log", "-G", "-n", "\(limit + 1)", "-T", revisionTemplate, "-r"]
        async let removed: [Revision] = records(log + ["\(old) ~ \(new)"], in: workspace, at: operation)
        async let added: [Revision] = records(log + ["\(new) ~ \(old)"], in: workspace, at: operation)
        let (oldRevisions, newRevisions) = try await (removed, added)
        guard oldRevisions.count + newRevisions.count <= limit else {
            throw Failure.unavailable("This operation affects too many revisions to preview.")
        }
        let oldByChange = Dictionary(grouping: oldRevisions, by: \.changeID)
        let newByChange = Dictionary(grouping: newRevisions, by: \.changeID)
        let changes = Array(Set((oldRevisions + newRevisions).map(\.changeID))).sorted()
        return changes.flatMap { change -> [String] in
            let old = oldByChange[change] ?? []
            let new = newByChange[change] ?? []
            if old.count == 1, new.count == 1, let a = old.first, let b = new.first {
                if a.subject != b.subject { return ["Rename \(a.label) → \(b.label)"] }
                if a.parentIDs != b.parentIDs {
                    let parents = b.parentIDs.map { $0.prefix(8) }.joined(separator: ", ")
                    return ["Update \(b.label) on \(parents)"]
                }
                return ["Update \(b.label) (\(a.commitID.prefix(8)) → \(b.commitID.prefix(8)))"]
            }
            let verb = direction == .undo ? "Restore" : "Add"
            return old.map { "Remove \($0.label)" } + new.map { "\(verb) \($0.label)" }
        }
    }

    private static func workspaceEffects(from before: [Checkout], to after: [Checkout], excluding current: String) -> [String] {
        let old = Dictionary(before.map { ($0.name, $0.revision) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.name, $0.revision) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).sorted().compactMap { name in
            guard name != current, old[name]?.commitID != new[name]?.commitID else { return nil }
            if let revision = new[name] { return "Set working copy in \(name) to \(revision.label)" }
            return "Remove working copy in workspace \(name)"
        }
    }

    private static func referenceEffects(from before: [Reference], to after: [Reference], kind: String) -> [String] {
        let old = Dictionary(before.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).sorted().compactMap { name in
            let source = old[name]
            let target = new[name]
            guard source != target else { return nil }
            if source?.present != true, let target, target.present { return "Add \(kind) \(name) at \(target.location)" }
            if target?.present != true, source?.present == true { return "Remove \(kind) \(name)" }
            if let source, let target, source.location != target.location {
                return "Move \(kind) \(name) from \(source.location) to \(target.location)"
            }
            return "Update \(kind) \(name)"
        }
    }

    private static func fileEffects(from before: Revision, to after: Revision, sparsePaths: String,
                                    at operation: String, in workspace: JJWorkspace) async throws -> [FileEffect] {
        guard before.commitID != after.commitID else { return [] }
        let paths = sparsePaths.split(separator: "\n").map(String.init)
        func included(_ path: String) -> Bool {
            paths.contains { $0 == "." || path == $0 || path.hasPrefix($0 + "/") }
        }
        let changes: [PathChange] = try await records(
            ["diff", "--from", before.commitID, "--to", after.commitID, "-T", pathTemplate], in: workspace, at: operation
        )
        return try changes.compactMap { change in
            if !included(change.path) {
                return change.status == "renamed" && included(change.sourcePath)
                    ? FileEffect(path: change.sourcePath, label: "Removed") : nil
            }
            let label: String
            switch change.status {
            case "added": label = "Added"
            case "removed": label = "Removed"
            case "modified": label = "Modified"
            case "copied", "renamed":
                label = included(change.sourcePath) ? "\(change.status.capitalized) from \(change.sourcePath)" : "Added"
            default: throw Failure.invalidResponse
            }
            let conflict = change.targetConflict ? " · Conflict" : change.sourceConflict ? " · Conflict resolved" : ""
            return FileEffect(path: change.path, label: label + conflict)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func operation(_ id: String?, in workspace: JJWorkspace) async throws -> Operation {
        if let id, !isHex(id, length: 128) { throw Failure.invalidResponse }
        let output = try await read(["op", "log", "-G", "-n", "1", "-T", "json(self)"], in: workspace, at: id)
        let value = try JSONDecoder().decode(Operation.self, from: Data(output.utf8))
        guard isHex(value.id, length: 128), id == nil || value.id == id else { throw Failure.invalidResponse }
        return value
    }

    private static func records<T: Decodable>(_ arguments: [String], in workspace: JJWorkspace,
                                               at operation: String) async throws -> [T] {
        let output = try await read(arguments, in: workspace, at: operation)
        let decoder = JSONDecoder()
        return try output.split(separator: "\n").map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private static func read(_ arguments: [String], in workspace: JJWorkspace, at operation: String?) async throws -> String {
        try await JJSourceControlRepository.read(workspace, operation: operation, arguments: arguments)
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
