import AppKit

struct SourceControlFileRestore: Sendable {
    let file: JJSourceControlFile
    let workspace: JJWorkspace
    private let revision: JJSourceControlRevision
    private let paths: [String]

    init?(file: JJSourceControlFile, in revision: JJSourceControlRevision, workspace: JJWorkspace) {
        guard revision.isWorkingCopy, !revision.isImmutable, Self.canRestore(file),
              JJRepository.isRelativePath(file.path) else { return nil }
        if file.kind == .renamed {
            guard let source = file.sourcePath, source != file.path, JJRepository.isRelativePath(source) else { return nil }
            paths = [source, file.path]
        } else {
            paths = [file.path]
        }
        self.file = file
        self.workspace = workspace
        self.revision = revision
    }

    func matchesSelection(_ revision: JJSourceControlRevision, in workspace: JJWorkspace) -> Bool {
        workspace == self.workspace && revision.isWorkingCopy && !revision.isImmutable &&
            revision.changeID == self.revision.changeID && revision.parents == self.revision.parents
    }

    @MainActor
    func confirmAndDiscard(in document: DocumentWindow) async throws -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to “\(file.name)”?"
        alert.informativeText = explanation + "\n\nUnsaved edits to the affected file will also be discarded."
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard await alert.beginSheetModal(for: document.window) == .alertFirstButtonReturn else { return false }
        return try await document.performSourceControlMutation(in: workspace, discardingChangesTo: urls) {
            try await discardChanges()
        }
    }

    func discardChanges() async throws {
        // A path may now pass through a nested workspace or a symlinked directory.
        for url in urls {
            guard await JJRepository.discover(at: url.deletingLastPathComponent()) == workspace else {
                throw JJSourceControlRepository.Failure.changedOperation
            }
        }
        try await JJRepository.withWriteAccess(in: workspace) {
            let before = try await JJRepository.operation(in: workspace)
            _ = try await workingCommit(at: before)

            // Record pending disk changes before checking the paths. In particular, the
            // source of a rename may have been restored by an editor or another process.
            try await JJRepository.snapshotWithWriteAccess(workspace)
            let operation = try await JJRepository.operation(in: workspace)
            let commit = try await workingCommit(at: operation)
            let changes = try await JJSourceControlRepository.changedFiles(commit, in: workspace, at: operation)
            guard matches(changes), try await JJRepository.operation(in: workspace) == operation else {
                throw JJSourceControlRepository.Failure.changedOperation
            }
            try validateWorkingCopyPaths()

            let filesets = paths.map(JJRepository.literalFileset)
            // Restrict the command to the checked-out commit we just checked after the snapshot.
            let arguments = ["--at-op=@", "--config", "edit.source-control=true", "restore",
                             "--changes-in=@ & \(commit) & mutable()", "--"] + filesets
            _ = try await JJRepository.command(arguments, in: workspace, timeout: nil)
        }
    }

    private var urls: [URL] {
        paths.map { workspace.root.appending(path: $0, directoryHint: .notDirectory) }
    }

    private func validateWorkingCopyPaths() throws {
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                throw blockedPath(url)
            }
            // Restoring a deleted child below a file can turn that unrelated file into a conflict.
            var parent = url.deletingLastPathComponent()
            while parent.path != workspace.root.path {
                let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == false || values?.isSymbolicLink == true { throw blockedPath(parent) }
                parent.deleteLastPathComponent()
            }
        }
    }

    private func blockedPath(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "The working-copy path “\(url.path)” prevents restoring only this file."
        ])
    }

    private var explanation: String {
        let baseline = revision.parents.count == 1 ? "the parent change" : "the merged parents"
        if file.kind == .renamed, let source = file.sourcePath {
            return "Jujutsu will restore “\(source)” from \(baseline) and discard “\(file.path)”."
        }
        if Self.removesPath(file) {
            return "Jujutsu will remove “\(file.path)” from the working copy."
        }
        return "Jujutsu will restore “\(file.path)” from \(baseline)."
    }

    private func workingCommit(at operation: String) async throws -> String {
        let template = JJRepository.template([
            "commit_id", "change_id", "immutable", #"parents.map(|parent| parent.commit_id()).join(",")"#,
        ])
        let result = try await JJRepository.readCommand(
            ["log", "--no-graph", "-r", "@", "-T", template], in: workspace, at: operation
        )
        let records = try JJRepository.records(in: result, width: 4)
        guard records.count == 1, let row = records.first, JJRepository.isHexID(row[0]),
              row[1] == revision.changeID, row[2] == "false",
              row[3].split(separator: ",").map(String.init) == revision.parents else {
            throw JJSourceControlRepository.Failure.changedOperation
        }
        return row[0]
    }

    private func matches(_ changes: [JJSourceControlFile]) -> Bool {
        let current = changes.first { $0.path == file.path }
        if file.kind == .renamed {
            return current?.kind == .renamed && current?.sourcePath == file.sourcePath && current.map(Self.canRestore) == true
        }
        if changes.contains(where: { $0.kind == .renamed && $0.sourcePath == file.path }) { return false }
        // A live buffer may be the only change. The restore still discards that buffer.
        guard let current else { return true }
        return current.kind != .renamed && Self.canRestore(current) && Self.removesPath(file) == Self.removesPath(current)
    }

    private static func removesPath(_ file: JJSourceControlFile) -> Bool {
        file.kind == .added || file.kind == .copied || file.kind == .conflict && file.source == .absent
    }

    private static func canRestore(_ file: JJSourceControlFile) -> Bool {
        ![file.source, file.target].contains { $0 == .tree || $0 == .submodule }
    }
}
