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
            return text.contains("Selected tests.test.exact") && text.contains("Passed") && text.contains("status 0")
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
        return terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?.rows.map(\.text)
            .joined(separator: "\n") ?? ""
    }

    private static func wait(_ detail: String, seconds: Int = 5, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func waitForOutput(_ detail: String, in window: NSWindow, until ready: (String) -> Bool) async throws {
        do { try await wait(detail, seconds: 35) { ready(output(in: window)) } }
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
