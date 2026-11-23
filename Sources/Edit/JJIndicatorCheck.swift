import AppKit

@MainActor
enum JJIndicatorCheck {
    static func run(in app: Edit, render: (NSWindow) throws -> Void) async throws {
        guard let executable = JJRepository.executable else {
            print("Edit skipped native jj checks because jj is unavailable.")
            return
        }
        let fixture = FileManager.default.temporaryDirectory.appending(path: "Edit jj \(UUID())")
        let folder = fixture.appending(path: "Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await command(executable, in: folder, ["git", "init", "--colocate"])

        let added = folder.appending(path: "Added")
        let tracked = folder.appending(path: "Tracked.txt")
        let base = (0..<150).map { "Line \($0)\n" }.joined()
        try Data(base.utf8).write(to: tracked)
        try await command(executable, in: folder, ["new", "-m", "Indicator check"])
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data("New file\n".utf8).write(to: added.appending(path: "New.txt"))
        let changed = base.replacingOccurrences(of: "Line 70\n", with: "Line 70 changed\n")
        try Data(changed.utf8).write(to: tracked)
        try await command(executable, in: folder, ["util", "snapshot"])

        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(folder, in: document)
        _ = try await app.openFile(tracked, in: document)
        document.toggleSidebarFocus(.worktree)
        guard let tree = document.worktreeSidebar?.outline else { throw Failure("open a jj worktree") }
        let operations = try operationObjects(in: folder)
        let recordedMark = JJLineMark(kind: .replacement, lines: 70..<71)
        try await waitFor("show the recorded editor and collapsed folder status") {
            document.editor.jjLineMarks.contains(recordedMark) &&
                document.editor.jjInlineDiff?.canToggle(recordedMark) == true &&
                hasStatus("Added, Added", in: tree) && hasStatus("Tracked.txt, Changed", in: tree)
        }
        try render(document.window)

        let previousMarks = document.editor.jjLineMarks
        document.editor.insertText("First line\n", replacementRange: NSRange(location: 0, length: 0))
        try expect(document.editor.jjLineMarks == previousMarks, "typing keeps the last rendered marks while refreshing")
        for _ in 0..<7 {
            try await Task.sleep(for: .milliseconds(45))
            document.editor.insertText(">", replacementRange: NSRange(location: 0, length: 0))
            try expect(!document.editor.jjLineMarks.isEmpty, "consecutive edits do not flash an empty gutter")
        }
        try await waitFor("show a second mark from unsaved text") {
            document.editor.jjLineMarks.contains(JJLineMark(kind: .insertion, lines: 0..<1)) &&
                document.editor.jjLineMarks.contains(JJLineMark(kind: .replacement, lines: 71..<72))
        }
        await document.flushAutosave()
        try expect(try operationObjects(in: folder) == operations, "reading and autosave create no jj operations")
        try expect(document.editor.jjLineMarks.count == 2, "autosave preserves equivalent marks")

        try await command(executable, in: folder, ["new", "-m", "Clean working copy"])
        try await waitFor("follow an external jj new") {
            document.editor.jjLineMarks.isEmpty && hasStatus("Tracked.txt", in: tree) && hasStatus("Added", in: tree)
        }
        try await command(executable, in: folder, ["edit", "@-"])
        try await waitFor("show a newly edited change with existing modifications") {
            document.editor.jjLineMarks.count == 2 && hasStatus("Tracked.txt, Changed", in: tree)
        }
        try await checkPresentationDeadline(in: app, tracked: tracked)
        try await checkSnapshotCadence(executable, in: folder, tracked: tracked)
        try await checkRefreshDuringSnapshot(executable, in: folder)
    }

    private static func checkRefreshDuringSnapshot(_ executable: URL, in folder: URL) async throws {
        guard let workspace = await JJRepository.discover(at: folder) else { throw Failure("resolve workspace for slow snapshot") }
        var writing: CheckedContinuation<Void, Never>?
        var displayedOperation: String?
        let monitor = JJChangeMonitor(checkInterval: .milliseconds(40), snapshotInterval: .milliseconds(150)) { _ in
            await withCheckedContinuation { writing = $0 }
        }
        let subscription = monitor.subscribe(to: workspace, updated: { displayedOperation = $0?.repository.operationID })
        defer {
            monitor.unsubscribe(subscription)
            writing?.resume()
        }
        try await waitFor("begin a scheduled snapshot") { writing != nil }
        let before = try await JJRepository.operation(in: workspace)
        try await command(executable, in: folder, ["describe", "-m", "Read during snapshot"])
        let after = try await JJRepository.operation(in: workspace)
        try expect(before != after, "the external command publishes a new operation")
        try await waitFor("refresh status while the scheduled snapshot is still waiting") { displayedOperation == after }
    }

    private static func checkPresentationDeadline(in app: Edit, tracked: URL) async throws {
        @MainActor
        final class Presentation {
            var text: String?
            var marks: [JJLineMark] = []
            var localStatus: JJWorktreeDecorations.Override?
        }

        let file = try FileBuffer.read(tracked)
        let presentation = Presentation()
        presentation.text = file.text
        let changes = JJDocumentChanges(monitor: app.jjChanges, text: { presentation.text }, showMarks: { result, _ in
            presentation.marks = result?.marks ?? []
        }, suspendMarkerNavigation: {}, showWorktree: { decorations in
            presentation.localStatus = decorations?.override
        })
        defer { changes.stop() }
        changes.update(file: file.url, revision: file.revision, folder: tracked.deletingLastPathComponent())
        try await waitFor("install marks and local status before delaying the next diff") {
            !presentation.marks.isEmpty && presentation.localStatus != nil
        }

        presentation.text = nil
        changes.bufferChanged()
        try expect(!presentation.marks.isEmpty && presentation.localStatus != nil,
                   "keep the old result during the short transition")
        let deadline = ContinuousClock.now + .seconds(2)
        while !presentation.marks.isEmpty && ContinuousClock.now < deadline {
            changes.bufferChanged()
            try await Task.sleep(for: .milliseconds(80))
        }
        try expect(presentation.marks.isEmpty && presentation.localStatus == nil,
                   "continued changes cannot extend the old result's deadline")

        presentation.text = file.text
        changes.bufferChanged()
        try await waitFor("show the current result when it becomes available") {
            !presentation.marks.isEmpty && presentation.localStatus != nil
        }
    }

    private static func checkSnapshotCadence(_ executable: URL, in folder: URL, tracked: URL) async throws {
        guard let workspace = await JJRepository.discover(at: folder) else { throw Failure("resolve snapshot workspace") }
        let before = try operationObjects(in: folder)
        let monitor = JJChangeMonitor(checkInterval: .milliseconds(40), snapshotInterval: .milliseconds(600))
        let first = monitor.subscribe(to: workspace, updated: { _ in })
        let second = monitor.subscribe(to: workspace, updated: { _ in })
        defer {
            monitor.unsubscribe(first)
            monitor.unsubscribe(second)
        }
        try Data("First saved version\n".utf8).write(to: tracked)
        try Data("Second saved version\n".utf8).write(to: tracked)
        try await Task.sleep(for: .milliseconds(200))
        try expect(try operationObjects(in: folder) == before, "reads do not create even unpublished operations")
        try await waitFor("one scheduled operation shared by two observers") {
            try operationObjects(in: folder).subtracting(before).count == 1
        }
        let operation = try await JJRepository.operation(in: workspace)
        let recorded = try await command(executable, in: folder, [
            "--at-op=\(operation)", "--ignore-working-copy", "file", "show", "Tracked.txt",
        ])
        try expect(recorded == "Second saved version\n", "published snapshot contains the latest saved text")
        try await Task.sleep(for: .milliseconds(750))
        try expect(try operationObjects(in: folder).subtracting(before).count == 1, "clean interval adds no operation")
    }

    private static func hasStatus(_ label: String, in tree: NSOutlineView) -> Bool {
        for row in 0..<tree.numberOfRows {
            let cell = tree.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
            if let field = cell?.textField, (field.accessibilityLabel() ?? field.stringValue) == label { return true }
        }
        return false
    }

    private static func operationObjects(in folder: URL) throws -> Set<String> {
        let directory = folder.appending(path: ".jj/repo/op_store/operations")
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    @concurrent @discardableResult
    private static func command(_ executable: URL, in folder: URL, _ arguments: [String]) async throws -> String {
        let command = Process()
        command.executableURL = executable
        command.currentDirectoryURL = folder
        command.arguments = ["--no-pager", "--color=never"] + arguments
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = pipe
        command.standardInput = FileHandle.nullDevice
        try command.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw Failure("jj \(arguments.joined(separator: " ")): \(output)") }
        return output
    }

    private static func waitFor(_ message: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<160 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(message)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "Jujutsu indicators: \(message)" }
    }
}
