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
        await app.navigate(.back, in: document)
        document.editor.setCaretSelections([caret(5)])
        try expect(app.canNavigate(.forward, in: document), "a nearby caret move keeps the forward branch")
        try expect(try await app.openFile(second, in: document) === document, "open a new history branch")
        try expect(!app.canNavigate(.forward, in: document), "a new file open removes the forward branch")
        await app.navigate(.back, in: document)
        try expect(document.fileURL == first && document.editor.selectedRange() == caret(5), "Back opens the previous file at its updated location")
        await app.navigate(.forward, in: document)
        try expect(document.fileURL == second, "Forward reopens the next file")

        try await checkWindowIsolation(in: app, other: document, first: first,
                                       second: root.appending(path: "Other.txt"), text: text)
    }

    private static func checkWindowIsolation(in app: Edit, other: DocumentWindow, first: URL, second: URL,
                                             text: String) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }

        try expect(!app.canNavigate(.back, in: document), "a new window starts with an empty history")
        try sendShortcut(forward: false, to: document.window, in: app, handled: false)

        let newText = "Second window destination\n"
        try newText.write(to: second, atomically: true, encoding: .utf8)
        try expect(try await app.openFile(first, in: document) === document, "open the first file in the new window")
        let firstCaret = NSRange(location: 2, length: 0)
        document.editor.setCaretSelections([firstCaret])
        try expect(try await app.openFile(second, in: document) === document, "open the second file in the new window")
        let secondCaret = NSRange(location: 4, length: 0)
        document.editor.setCaretSelections([secondCaret])

        let (gate, release) = AsyncStream<Void>.makeStream()
        var waitingToInstall = false
        document.beforeInstallFileForCheck = { file in
            guard file.url == first else { return }
            waitingToInstall = true
            for await _ in gate { break }
        }
        defer { release.finish() }

        try sendShortcut(forward: false, to: document.window, in: app)
        try await wait("hold Back before installing the first file") { waitingToInstall }
        try expect(document.window.title == second.lastPathComponent && document.editor.string == newText,
                   "keep the second file and title visible while Back is pending")

        try sendShortcut(forward: false, to: other.window, in: app)
        let otherCaret = NSRange(location: (text as NSString).range(of: "line 5 abcdef").location + 2, length: 0)
        try await wait("navigate in the other window while the first transition is pending") {
            other.fileURL == first && other.editor.selectedRange() == otherCaret
        }
        try expect(document.fileURL == second && document.editor.selectedRange() == secondCaret,
                   "Back in the other window leaves the pending window alone")
        release.finish()
        try await wait("restore the first file and caret in the requesting window") {
            document.fileURL == first && document.editor.selectedRange() == firstCaret
        }
        try expect(document.window.title == first.lastPathComponent && document.editor.string == text,
                   "show the restored first file with its title")
        try sendShortcut(forward: false, to: document.window, in: app, handled: false)
        try sendShortcut(forward: true, to: document.window, in: app)
        try await wait("restore the second file and caret in the requesting window") {
            document.fileURL == second && document.editor.selectedRange() == secondCaret
        }
        try expect(other.fileURL == first && other.editor.selectedRange() == otherCaret && app.canNavigate(.forward, in: other),
                   "Forward leaves the other window's file, caret, and forward history intact")
        try sendShortcut(forward: true, to: document.window, in: app, handled: false)
    }

    private static func sendShortcut(forward: Bool, to window: NSWindow, in app: Edit, handled: Bool = true) throws {
        let flags: NSEvent.ModifierFlags = forward ? [.control, .shift] : .control
        let character = forward ? "_" : "-"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: character,
                                          charactersIgnoringModifiers: character, isARepeat: false, keyCode: 27)
        else { throw Failure("create the macOS navigation shortcut") }
        try expect((app.routeWindowEvent(event) == nil) == handled, "the shortcut reflects its window's history")
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
