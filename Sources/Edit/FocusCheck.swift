import AppKit

@MainActor
enum FocusCheck {
    static func run(in app: Edit) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        let editor = document.editor
        let window = document.window
        let original = "prefix LOCAL suffix\nmiddle LOCAL gap\nend LOCAL tail\n"
        editor.string = original
        let history = editor.editorUndoManager
        history.groupsByEvent = false
        history.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        history.endUndoGrouping()
        let source = editor.string as NSString
        let first = source.range(of: "LOCAL")
        let last = source.range(of: "LOCAL", options: .backwards)
        editor.setCaretSelections([first, last])
        let menu = try require(NSApp.mainMenu)
        let commands = ControlCommand.fromMenu(menu)
        let enter = try require(commands.first { $0.item.action == #selector(Edit.focusSelection(_:)) })
        let leave = try require(commands.first { $0.item.action == #selector(Edit.exitFocus(_:)) })
        try expect(enter.isAvailable(in: document, focus: nil), "Control offers Focus Selection")
        enter.run(in: document)
        try expect(editor.focusRanges == [first, last] && editor.caretSelections.count == 2 &&
                   editor.caretSelections.allSatisfy { $0.length == 0 }, "enter Focus with two scope ranges and two empty carets")
        try expect(leave.isAvailable(in: document, focus: nil) && !history.canUndo && !history.canRedo,
                   "Focus presents its exit command and closes off older undo history")

        editor.setCaretSelections([NSRange(location: NSMaxRange(first), length: 0)])
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        try expect(editor.selectedRange().location == last.location, "Right skips the gap")
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        try expect(editor.selectedRange().location == NSMaxRange(first), "Left skips the gap")
        editor.deleteForward(nil)
        try expect(editor.string == source as String, "forward delete at the seam preserves protected text")
        editor.selectAll(nil)
        try expect(editor.caretSelections == [first, last], "Select All keeps only the focused ranges")
        let clipboard = NSPasteboard(name: .init("edit.focus.check.\(UUID())"))
        defer { clipboard.releaseGlobally() }
        _ = editor.copySelections(to: clipboard, cutting: false)
        try expect(clipboard.string(forType: .string) == "LOCAL\nLOCAL", "clipboard excludes protected text")

        editor.lowercaseWord(nil)
        let lowercased = "!prefix local suffix\nmiddle LOCAL gap\nend local tail\n"
        try expect(editor.string == lowercased, "case conversion transforms both pieces in place")
        history.undo()
        try expect(editor.string == source as String && editor.focusRanges == [first, last] && !history.canUndo,
                   "a compound edit restores both ranges with one Undo and stops at the Focus boundary")
        history.undo()
        try expect(editor.string == source as String, "undo while focused cannot change an older revision")
        history.redo()
        try expect(editor.string == lowercased, "redo restores the scoped edit")
        history.undo()

        editor.selectAll(nil)
        editor.insertText("new", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.string == "!prefix new suffix\nmiddle LOCAL gap\nend  tail\n" &&
                   editor.focusRanges?.last?.length == 0, "replacing a logical selection inserts once and preserves the gap")
        history.undo()

        editor.setCaretSelections([NSRange(location: first.location, length: 0), NSRange(location: last.location, length: 0)])
        editor.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.hasMarkedText(), "IME uses native marked input within Focus")
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.string == "!prefix éLOCAL suffix\nmiddle LOCAL gap\nend éLOCAL tail\n",
                   "IME commits to both carets without editing the protected gap")
        history.undo()
        try expect(editor.string == source as String && editor.focusRanges == [first, last],
                   "undo restores the pre-composition ranges and text")

        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
        try expect(editor.focusDecoration?.active.isEmpty == false, "native rendering includes the Focus outline")

        document.findSettings.query = "LOCAL"
        document.findSettings.replacement = "local"
        document.performFind(.replace)
        let results = try require(descendant(of: window.contentView, type: FindResultsTable.self))
        try await waitFor("Focus Search lists only the two in-scope matches") { results.numberOfRows == 2 }
        document.performFind(.replaceAll)
        try expect(editor.string == lowercased, "Replace All leaves the protected match intact")
        history.undo()
        try expect(editor.string == source as String && editor.focusRanges == [first, last],
                   "one undo restores Focus Replace All and its ranges")
        try await waitFor("scoped results refresh after undo") { results.numberOfRows == 2 }
        try expect(editor.focusRanges != nil, "Search activity keeps Focus active")
        window.makeFirstResponder(editor)
        editor.selectAll(nil)
        editor.cancelOperation(nil)
        try expect(editor.focusRanges != nil && editor.caretSelections.count == 1 && editor.selectedRange().length == 0,
                   "the first Escape clears the selection and extra carets")
        editor.cancelOperation(nil)
        try expect(editor.focusRanges == nil, "the second Escape exits Focus")
        try await waitFor("Search restores all results after exiting Focus") { results.numberOfRows == 3 }
        try expect(history.canUndo, "exiting restores pre-Focus history")
        history.undo()
        try expect(editor.string == original, "normal Undo reaches the earlier document edit")

        let current = editor.string as NSString
        editor.setCaretSelections([current.range(of: "LOCAL")])
        document.focusSelection()
        let outside = current.range(of: "gap").location
        let rect = editor.firstRect(forCharacterRange: NSRange(location: outside, length: 1), actualRange: nil)
        let location = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                                  timestamp: stamp, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                                timestamp: stamp + 0.01, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        editor.mouseDown(with: down)
        try expect(editor.focusRanges == nil && editor.selectedRange() == NSRange(location: outside, length: 0),
                   "an outside click exits and places the native caret at the click")

        try await verifyFileLifecycle(in: app)
    }

    private static func verifyFileLifecycle(in app: Edit) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "focus-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.txt")
        let renamed = directory.appending(path: "saved-as.txt")
        try Data("before\r\nLOCAL\r\nafter\r\n".utf8).write(to: file)
        let opened = try await app.openFile(file, in: document)
        try expect(opened === document, "open a named file for Focus")
        let editor = document.editor
        editor.setCaretSelections([(editor.string as NSString).range(of: "LOCAL")])
        document.focusSelection()
        editor.selectAll(nil)
        editor.insertText("local", replacementRange: NSRange(location: NSNotFound, length: 0))
        await document.flushAutosave()
        let expected = Data("before\r\nlocal\r\nafter\r\n".utf8)
        let bytes = try Data(contentsOf: file)
        try expect(bytes == expected && editor.focusRanges != nil, "autosave writes the whole source with its line endings")
        let saved = await document.save(asNew: true, to: renamed)
        let savedBytes = try Data(contentsOf: renamed)
        try expect(saved && savedBytes == expected && editor.focusRanges != nil, "Save As preserves scope and all source text")
        await document.newBuffer()
        try expect(editor.focusRanges == nil && editor.string.isEmpty, "replacing the buffer ends Focus")

        editor.insertText("plain draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setCaretSelections([NSRange(location: 6, length: 5)])
        document.focusSelection()
        await document.newBuffer()
        try expect(editor.focusRanges == [NSRange(location: 6, length: 5)] && editor.string == "plain draft",
                   "cancelling replacement of a dirty draft preserves Focus")
    }

    private static func descendant<T: NSView>(of view: NSView?, type: T.Type) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(of: $0, type: type) }.first
    }

    private static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
        try expect(condition(), message)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "missing native Focus test object") }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "Focus: " + message }
    }
}
