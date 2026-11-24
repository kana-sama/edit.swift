import AppKit

@MainActor
enum NavigationHistoryCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "Navigation history: \(message)" }
    }

    static func run(in app: Edit) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Navigation \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileBuffer.canonicalURL(folder)
        let first = root.appending(path: "First.txt")
        let second = root.appending(path: "Second.txt")
        let text = (0..<32).map { "line \($0) abcdef\n" }.joined()
        for file in [first, second] { try text.write(to: file, atomically: true, encoding: .utf8) }
        let document = app.makeDocument()
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }

        func position(_ line: Int) -> Int { (text as NSString).range(of: "line \(line) abcdef").location + 2 }
        func caret(_ line: Int) -> NSRange { NSRange(location: position(line), length: 0) }
        try expect(try await app.openFile(first, in: document) === document, "open the first fixture")
        let backward = NSRange(location: position(4), length: 3)
        document.editor.setCaretSelections([backward], primaryAffinity: .upstream)
        document.editor.setCaretSelections([caret(14)])
        try sendShortcut(forward: false, to: document.window, in: app)
        try await wait("Control-Minus restores the selection ten lines back") {
            document.editor.selectedRange() == backward && document.editor.selectionAffinity == .upstream
        }
        try sendShortcut(forward: true, to: document.window, in: app)
        try await wait("Control-Shift-Minus restores the forward stop") { document.editor.selectedRange() == caret(14) }
        await app.navigate(.back)
        document.editor.setCaretSelections([caret(5)])
        try expect(app.canNavigate(.forward), "a nearby caret move keeps the forward branch")
        try expect(try await app.openFile(second, in: document) === document, "open a new history branch")
        try expect(!app.canNavigate(.forward), "a new file open removes the forward branch")
        await app.navigate(.back)
        try expect(document.fileURL == first && document.editor.selectedRange() == caret(5), "Back opens the previous file at its updated location")
        await app.navigate(.forward)
        try expect(document.fileURL == second, "Forward reopens the next file")
    }

    private static func sendShortcut(forward: Bool, to window: NSWindow, in app: Edit) throws {
        let flags: NSEvent.ModifierFlags = forward ? [.control, .shift] : .control
        let character = forward ? "_" : "-"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: character,
                                          charactersIgnoringModifiers: character, isARepeat: false, keyCode: 27)
        else { throw Failure("create the macOS navigation shortcut") }
        try expect(app.routeWindowEvent(event) == nil, "the editor handles the navigation shortcut")
    }

    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(4)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(condition(), message)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
}
