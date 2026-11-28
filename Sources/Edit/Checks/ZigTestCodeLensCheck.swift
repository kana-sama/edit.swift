import AppKit
import SwiftTerm

@MainActor
enum ZigTestCodeLensCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Zig test CodeLens check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSWindow) throws -> Void) async throws {
        let files = FileManager.default
        let root = FileBuffer.canonicalURL(files.temporaryDirectory.appending(path: "Zig tests \(UUID())"))
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? files.removeItem(at: root)
        }
        try checkCachePruning(under: root)
        let zig = root.appending(path: "Selected tests.zig")
        let plain = root.appending(path: "Plain.txt")
        try "Plain text\n".write(to: plain, atomically: true, encoding: .utf8)
        let fixture = #"""
        const std = @import("std");
        // test "comment" {}
        const text = "test \"literal\" {}";
        test
            "exact"
        {
            try std.testing.expect(false);
        }
        test "exactExtra" { return error.NeighborRan; }
        test { return error.UnnamedRan; }
        """# + "\n"
        try fixture.write(to: zig, atomically: true, encoding: .utf8)
        document.setFolder(root)
        try expect(try await app.openFile(zig, in: document) === document, "open the Zig buffer")
        document.languageFeatures.perform(.stop)
        if document.isHighlightingEnabled(.treeSitter) { document.toggleHighlighting(.treeSitter) }
        document.window.layoutIfNeeded()
        let editor = document.editor
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try await wait("discover three actual tests with syntax highlighting out of use") { buttons(in: editor).count == 3 }
        try expect(isPositioned("exact", keyword: "\ntest\n", in: editor), "anchor to the keyword above the name and brace")
        try expect(isPositioned("exactExtra", keyword: "\ntest \"exactExtra\"", in: editor), "place the button after the code")
        try capture(document.window)

        let incomplete = "test \"partial\" {\n"
        let end = (editor.string as NSString).length
        editor.insertText(incomplete, replacementRange: NSRange(location: end, length: 0))
        try await wait("keep discovery while the final test body is still open") { button("partial", in: editor) != nil }
        editor.insertText("", replacementRange: NSRange(location: end, length: incomplete.utf16.count))
        try await wait("clear the removed test action") { buttons(in: editor).count == 3 }

        editor.insertText("// 🧪 a new first line\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait("move the button after the UTF-16 edit above it") {
            isPositioned("exact", keyword: "\ntest\n", in: editor)
        }
        let failing = (editor.string as NSString).range(of: "false")
        editor.insertText("true", replacementRange: failing)
        try expect(isPositioned("exact", keyword: "\ntest\n", in: editor), "retain the button while the body changes")
        try expect(try String(contentsOf: zig, encoding: .utf8).contains("false"), "keep the edit pending before Run test")
        editor.setWordWrap(true)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try await wait("keep the button on the first row with word wrap enabled") {
            isPositioned("exact", keyword: "\ntest\n", in: editor)
        }
        let run = try require(button("exact", in: editor), "find the Run test button")
        let point = NSPoint(x: run.frame.midX, y: run.frame.midY)
        try expect(editor.hitTest(editor.convert(point, to: editor.superview)) === run, "hit the same-row button")
        document.focusContent()
        run.performClick(nil)
        try await waitForOutput("save the file and run only the selected declaration", in: document.window) { text in
            text.contains("Selected tests.test.exact") && text.contains("Passed") && text.contains("status 0") &&
                text.contains("$ cd ") && text.contains("zig test ")
        }
        try expect(try String(contentsOf: zig, encoding: .utf8) == editor.string, "write the live buffer before testing")
        try expect(!output(in: document.window).contains("NeighborRan") && !output(in: document.window).contains("UnnamedRan"),
                   "leave similarly named and unnamed siblings unexecuted")
        try expect(document.window.firstResponder === editor, "keep keyboard focus in the editor")

        try require(button("exactExtra", in: editor), "find the neighboring test").performClick(nil)
        try await waitForOutput("run again in the same terminal and retain the failure", in: document.window) { text in
            return text.contains("NeighborRan") && text.contains("status 1") && text.contains("Passed")
        }
        try require(button("Unnamed test", in: editor), "find the unnamed block").performClick(nil)
        try await waitForOutput("select the unnamed block by its compiler identity", in: document.window) { text in
            text.contains("Selected tests.test_0") && text.contains("UnnamedRan") &&
                text.components(separatedBy: "Zig exited with status 1.").count == 3
        }

        let renamed = root.appending(path: "Renamed tests.zig")
        try expect(await document.save(asNew: true, to: renamed), "save under a new Zig filename")
        try await wait("discover actions for the new filename") { button("exact", in: editor) != nil }
        try require(button("exact", in: editor), "find the test after Save As").performClick(nil)
        try await waitForOutput("use the new file and its compiler name", in: document.window) { text in
            text.contains("Renamed tests.test.exact") &&
                text.components(separatedBy: "Zig exited with status 0.").count == 3
        }

        let title = document.window.title
        let (heldOpen, finishOpen) = AsyncStream<Void>.makeStream()
        var pending = false
        document.beforeInstallFileForCheck = { incoming in
            guard incoming.url == plain else { return }
            pending = true
            for await _ in heldOpen { break }
        }
        let opening = Task { try await app.openFile(plain, in: document) }
        defer {
            document.beforeInstallFileForCheck = nil
            finishOpen.finish()
            opening.cancel()
        }
        try await wait("hold the incoming plain-text file") { pending }
        try expect(document.window.title == title && button("exact", in: editor) != nil,
                   "keep the test action with the outgoing text and title while opening")
        finishOpen.finish()
        try expect(try await opening.value === document, "open the plain-text file")
        try expect(document.window.title.hasSuffix("Plain.txt") && buttons(in: editor).isEmpty,
                   "clear the action on the first presentation of the new file")

        try await checkProject(in: app, document: document, under: root)
    }

    private static func checkProject(in app: Edit, document: DocumentWindow, under root: URL) async throws {
        let project = root.appending(path: "Project with modules", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectCache = project.appending(path: ".zig-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectCache, withIntermediateDirectories: false)
        try Data().write(to: projectCache.appending(path: "existing"))
        try """
        const std = @import("std");
        pub fn build(b: *std.Build) void {
            const library = b.createModule(.{ .root_source_file = b.path("value.zig"), .target = b.graph.host });
            const tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("project.t.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "value", .module = library }},
            }) });
            b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
        }
        """.write(to: project.appending(path: "build.zig"), atomically: true, encoding: .utf8)
        try "pub const answer = 42;\n".write(to: project.appending(path: "value.zig"), atomically: true, encoding: .utf8)
        let file = project.appending(path: "project.t.zig")
        try """
        const std = @import("std");
        const value = @import("value");
        test "project import" {
            try std.testing.expectEqual(42, value.answer);
        }
        test "project import neighbor" { return error.WholeSuiteRan; }
        """.write(to: file, atomically: true, encoding: .utf8)
        try await runProjectCase(project: project, file: file, name: "project import", in: app, document: document)
        try expect(!output(in: document.window).contains("WholeSuiteRan"), "leave the project test's neighbor unexecuted")
        try "pub const answer = 43;\n".write(to: project.appending(path: "value.zig"), atomically: true, encoding: .utf8)
        let rebuilt = try await runProjectTest(named: "project import", in: document)
        try expect(rebuilt.contains("expected 42, found 43") && rebuilt.contains("Zig exited with status 1.") &&
                   compileLine(in: rebuilt)?.contains("cached") == false,
                   "rebuild after an imported module changes\nTerminal output:\n\(rebuilt)")
        try expect(try FileManager.default.contentsOfDirectory(atPath: projectCache.path) == ["existing"],
                   "store the CodeLens build artifacts in Edit's cache")

        let environment = ProcessInfo.processInfo.environment
        if let fixture = environment["EDIT_ZIG_TEST_PROJECT_FILE"], let name = environment["EDIT_ZIG_TEST_PROJECT_CASE"] {
            let file = FileBuffer.canonicalURL(URL(filePath: fixture))
            let parent = file.deletingLastPathComponent()
            let root = LanguageServer.zig.projectRoot(in: parent, activeFile: file, previousRoot: nil, searchesParents: true) ?? parent
            try await runProjectCase(project: root, file: file, name: name, in: app, document: document)
        }
    }

    private static func runProjectCase(project: URL, file: URL, name: String, in app: Edit, document: DocumentWindow) async throws {
        document.setFolder(project)
        try expect(try await app.openFile(file, in: document) === document, "open the module-dependent test file")
        document.languageFeatures.perform(.stop)
        let first = try await runProjectTest(named: name, in: document)
        let second = try await runProjectTest(named: name, in: document)
        for text in [first, second] {
            try expect(text.contains("zig build ") && text.contains(".test.\(name)") && text.contains("Passed") &&
                       text.contains("Zig exited with status 0."),
                       "run the selected test with the Zig build configuration\nTerminal output:\n\(text)")
        }
        let commands = { (text: String) in text.split(separator: "\n").filter { $0.hasPrefix("$ ") } }
        try expect(commands(first) == commands(second), "keep the terminal command and generated paths stable")
        let initialCompile = try require(compileLine(in: first), "observe the initial compilation in Zig's summary")
        let cachedCompile = try require(compileLine(in: second), "observe the cached compilation in Zig's summary")
        try expect(!initialCompile.contains("cached") && cachedCompile.contains("cached"),
                   "execute the test again using a cached binary\nFirst: \(initialCompile)\nSecond: \(cachedCompile)")
        print("Zig CodeLens \(file.lastPathComponent), \(name): \(initialCompile.trimmingCharacters(in: .whitespaces)) → \(cachedCompile.trimmingCharacters(in: .whitespaces))")
    }

    private static func compileLine(in output: String) -> Substring? {
        output.split(separator: "\n").first { $0.contains("compile test ") }
    }

    private static func runProjectTest(named name: String, in document: DocumentWindow) async throws -> String {
        let completion = "Zig exited with status "
        let previous = output(in: document.window).components(separatedBy: completion).count
        try await wait("discover the project test") { button(name, in: document.editor) != nil }
        try require(button(name, in: document.editor), "find the project test button").performClick(nil)
        try await waitForOutput("finish the project test", in: document.window, seconds: 120) { text in
            let parts = text.components(separatedBy: completion)
            return parts.count == previous + 1 && parts.last?.contains(".") == true
        }
        let text = output(in: document.window)
        let parts = text.components(separatedBy: completion)
        return parts[parts.count - 2] + completion + parts[parts.count - 1]
    }

    private static func checkCachePruning(under root: URL) throws {
        let files = FileManager.default
        let cacheRoot = root.appending(path: "Cache cleanup", directoryHint: .isDirectory)
        let (active, _) = try ZigTestCache.prepare(in: cacheRoot, project: root, executable: URL(filePath: "/usr/bin/true"),
                                                   inputs: ["test"]) { _, _ in [] }
        func mark(_ directory: URL, age: TimeInterval) throws {
            let marker = directory.appending(path: "last-use")
            if !files.fileExists(atPath: marker.path) { try Data().write(to: marker) }
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: marker.path)
        }
        func group(named digit: Character, age: TimeInterval) throws -> URL {
            let group = cacheRoot.appending(path: String(repeating: digit, count: 64))
            try files.createDirectory(at: group, withIntermediateDirectories: false)
            try mark(group, age: age)
            try Data(repeating: 1, count: 4_096).write(to: group.appending(path: "artifact"))
            return group
        }
        let expired = try group(named: "a", age: 30 * 24 * 60 * 60)
        let older = try group(named: "b", age: 240)
        let recent = try group(named: "c", age: 60)
        try mark(active.directory, age: 30 * 24 * 60 * 60)
        try ZigTestCache.prune(in: cacheRoot, maximumGroups: 2)
        try expect(!files.fileExists(atPath: expired.path) && !files.fileExists(atPath: older.path),
                   "expire old groups and remove the least recently used group at the count limit")
        try expect(files.fileExists(atPath: recent.path), "retain a recently used cache group")
        try ZigTestCache.prune(in: cacheRoot, maximumBytes: 0)
        try expect(!files.fileExists(atPath: recent.path), "remove an inactive cache group at the disk budget")
        try expect(files.fileExists(atPath: active.directory.path), "keep an active cache group through both sweeps")
        withExtendedLifetime(active) {}
    }

    private static func buttons(in editor: EditorTextView) -> [NSButton] {
        editor.subviews.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "Edit.TestCodeLens.Run" }
    }

    private static func button(_ name: String, in editor: EditorTextView) -> NSButton? {
        buttons(in: editor).first { $0.toolTip == "Run test “\(name)”" }
    }

    private static func isPositioned(_ name: String, keyword: String, in editor: EditorTextView) -> Bool {
        let start = (editor.string as NSString).range(of: keyword).location
        guard start != NSNotFound, let row = editor.laidOutLineBounds(at: start + 1), let button = button(name, in: editor) else {
            return false
        }
        return abs(button.frame.minY - row.minY) < 0.5 && button.frame.minX > row.maxX
    }

    private static func output(in window: NSWindow) -> String {
        func terminal(in view: NSView) -> LocalProcessTerminalView? {
            (view as? LocalProcessTerminalView) ?? view.subviews.lazy.compactMap(terminal).first
        }
        guard let view = window.contentView, let terminal = terminal(in: view) else { return "" }
        return terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?.rows.reduce(into: "") { text, row in
            if !row.isWrapped { text += "\n" }
            text += row.text
        } ?? ""
    }

    private static func wait(_ detail: String, seconds: Int = 5, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func waitForOutput(_ detail: String, in window: NSWindow, seconds: Int = 35,
                                      until ready: (String) -> Bool) async throws {
        do { try await wait(detail, seconds: seconds) { ready(output(in: window)) } }
        catch { throw Failure(detail: "\(detail)\nTerminal output:\n\(output(in: window))") }
    }

    private static func require<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw Failure(detail: detail) }
        return value
    }

    private static func expect(_ value: Bool, _ detail: String) throws {
        guard value else { throw Failure(detail: detail) }
    }
}
