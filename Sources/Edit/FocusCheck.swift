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
        let firstWord = source.range(of: "LOCAL")
        let lastWord = source.range(of: "LOCAL", options: .backwards)
        let first = source.range(of: "!prefix LOCAL suffix")
        let last = source.range(of: "end LOCAL tail")
        editor.setCaretSelections([firstWord, lastWord])
        let menu = try require(NSApp.mainMenu)
        let commands = ControlCommand.fromMenu(menu)
        let enter = try require(commands.first { $0.item.action == #selector(Edit.focusSelection(_:)) })
        let leave = try require(commands.first { $0.item.action == #selector(Edit.exitFocus(_:)) })
        try expect(enter.isAvailable(in: document, focus: nil), "Control offers Focus Selection")
        let activeColumns = editor.caretSelections.map { NSRange(location: editor.activeEnd(of: $0), length: 0) }
        enter.run(in: document)
        try expect(editor.focusRanges == [first, last] && editor.caretSelections == activeColumns,
                   "focus the complete lines from two partial words and keep both active columns")
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
        try expect(clipboard.string(forType: .string) == "!prefix LOCAL suffix\nend LOCAL tail",
                   "clipboard includes complete focused lines and skips the protected gap")

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
        try expect(editor.string == "new\nmiddle LOCAL gap\n\n" &&
                   editor.focusRanges?.last?.length == 0, "replacing a logical selection inserts once and preserves the gap")
        history.undo()

        editor.setCaretSelections([
            NSRange(location: firstWord.location, length: 0), NSRange(location: lastWord.location, length: 0),
        ])
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
        let bands = try require(editor.focusDecoration?.activeBands)
        try expect(bands.count == 2 && bands.allSatisfy { $0.width >= editor.visibleRect.width - 2 },
                   "each focused row fills the editor width in native rendering")

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
        let suffix = current.range(of: "suffix").location
        try clickCharacter(at: suffix, editor: editor, window: window)
        try expect(editor.focusRanges != nil && editor.selectedRange() == NSRange(location: suffix, length: 0),
                   "a click in the focused line beyond the original selected word stays in Focus")
        let changed = current.replacingCharacters(in: NSRange(location: suffix, length: 0), with: "X")
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.string == changed,
                   "typing anywhere on the focused line edits that line")
        editor.deleteBackward(nil)
        try expect(editor.string == original && editor.focusRanges != nil,
                   "backspace inside the focused line removes the inserted character")
        let outside = current.range(of: "gap").location
        try clickCharacter(at: outside, editor: editor, window: window)
        try expect(editor.focusRanges == nil && editor.selectedRange() == NSRange(location: outside, length: 0),
                   "an outside click exits and places the native caret at the click")

        try verifyLineScope(in: app)
        try verifyOccurrencesAcrossFocusBlocks(in: app)
        try await verifyFileLifecycle(in: app)
        try await verifyRememberedFocus(in: app)
    }

    private static func clickCharacter(at offset: Int, editor: EditorTextView, window: NSWindow) throws {
        let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
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
    }

    private static func verifyLineScope(in app: Edit) throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        let editor = document.editor
        let original = "before\r\n  alpha suffix\r\n  bravo end\r\n  charlie tail\r\n  delta last\r\nprotected\r\nend of file"
        editor.string = original
        editor.preferredLineEnding = "\r\n"
        let text = original as NSString
        let alpha = text.range(of: "  alpha suffix")
        let adjacent = text.range(of: "  alpha suffix\r\n  bravo end\r\n  charlie tail\r\n  delta last")
        let bravo = text.range(of: "  bravo end")
        let last = text.range(of: "end of file")
        let words = ["bravo end", "alpha suffix", "delta last", "charlie tail"].map { text.range(of: $0) }
        editor.setCaretSelections(words)
        document.focusSelection()
        try expect(editor.focusRanges == [adjacent], "partial selections on four adjacent rows focus one block")
        editor.exitFocus()

        let carets = words.map { NSRange(location: $0.location + 2, length: 0) } +
            [NSRange(location: last.location + 2, length: 0)]
        editor.setCaretSelections(carets)
        document.focusSelection()
        try expect(editor.focusRanges == [adjacent, last] && editor.caretSelections == carets,
                   "carets focus complete lines, coalesce adjacent rows and retain their original columns")

        editor.setCaretSelections([NSRange(location: adjacent.location, length: 0)])
        editor.deleteBackward(nil)
        editor.setCaretSelections([NSRange(location: NSMaxRange(adjacent), length: 0)])
        editor.deleteForward(nil)
        try expect(editor.string == original, "deletion at either edge preserves the outside CRLF")

        editor.insertNewline(nil)
        let inserted = text.replacingCharacters(in: NSRange(location: NSMaxRange(adjacent), length: 0), with: "\r\n  ")
        let expanded = NSRange(location: adjacent.location, length: adjacent.length + 4)
        try expect(editor.string == inserted && editor.focusRanges?.first == expanded &&
                   editor.selectedRange() == NSRange(location: NSMaxRange(expanded), length: 0),
                   "Return on the final focused line adds an indented CRLF line within Focus")
        editor.deleteForward(nil)
        try expect(editor.string == inserted, "the external CRLF after the new focused line remains protected")
        editor.editorUndoManager.undo()
        try expect(editor.string == original && editor.focusRanges == [adjacent, last],
                   "Undo restores the original focused line boundary")

        editor.setCaretSelections([NSRange(location: NSMaxRange(last), length: 0)])
        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
        let lastBand = try require(editor.focusDecoration?.activeBands.last)
        editor.insertNewline(nil)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
        let expandedBand = try require(editor.focusDecoration?.activeBands.last)
        try expect(expandedBand.minY == lastBand.minY && expandedBand.height > lastBand.height,
                   "the bottom boundary moves below the new blank line at EOF")
        editor.insertText("new", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.string == original + "\r\nnew" &&
                   editor.focusRanges?.last == NSRange(location: last.location, length: last.length + 5),
                   "Return at EOF adds another focused line that accepts text")

        editor.exitFocus()
        editor.setSelectedRange(NSRange(location: alpha.location + 3, length: bravo.location - alpha.location - 3),
                                affinity: .downstream, stillSelecting: false)
        document.focusSelection()
        try expect(editor.focusRanges == [alpha] &&
                   editor.selectedRange() == NSRange(location: NSMaxRange(alpha), length: 0),
                   "a selection ending at the next line start excludes that row and keeps its caret in Focus")
    }

    private static func verifyOccurrencesAcrossFocusBlocks(in app: Edit) throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        let editor = document.editor
        let left = "AB\nAB\n\nAB"
        let gap = "\nAB\n\nAB\n"
        let right = "AB\n\nAB\nAB"
        let original = left + gap + right
        editor.string = original
        let leftBlock = NSRange(location: 0, length: left.utf16.count)
        let rightBlock = NSRange(location: leftBlock.upperBound + gap.utf16.count, length: right.utf16.count)
        editor.setCaretSelections([leftBlock, rightBlock])
        document.focusSelection()
        try expect(editor.focusRanges == [leftBlock, rightBlock], "focus the occurrence fixture's whole-line blocks")
        let needle = "B\nA"
        let leftMatch = (left as NSString).range(of: needle)
        let rightMatch = (original as NSString).range(of: needle, options: .literal, range: rightBlock)
        let splitMatch = [NSRange(location: leftBlock.upperBound - 1, length: 1),
                          NSRange(location: rightBlock.location, length: 1)]
        let matches = Set([[leftMatch], splitMatch, [rightMatch]])

        editor.setCaretSelections([leftMatch])
        editor.doCommand(by: #selector(EditorTextView.selectAllOccurrences(_:)))
        try expect(Set(editor.focusedSelectionGroups ?? []) == matches && editor.caretSelections.count == 4,
                   "Select All Occurrences finds three logical matches, with two highlights for the virtual newline match")
        try expect(editor.selectedRange() == leftMatch, "Select All Occurrences keeps the original primary selection")

        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCaretDecorations()
        let seamLine = try require(editor.lineBounds(at: leftBlock.upperBound))
        let gapLine = try require(editor.lineBounds(at: leftBlock.upperBound + 1))
        let x = editor.visibleRect.midX
        let seamHighlight = NSPoint(x: x, y: seamLine.midY)
        let gapHighlight = NSPoint(x: x, y: gapLine.midY)
        try expect(editor.multiCaret.highlights.contains(where: { $0.contains(seamHighlight) }) &&
                   !editor.multiCaret.highlights.contains(where: { $0.contains(gapHighlight) }),
                   "the selected virtual newline fills its row without painting the protected line")
        editor.setCaretSelections([splitMatch[0], leftMatch])
        editor.refreshCaretDecorations()
        try expect(!editor.multiCaret.highlights.contains(where: { $0.contains(seamHighlight) }),
                   "selecting only the final character leaves the virtual newline unhighlighted")

        editor.setCaretSelections([leftMatch])
        editor.doCommand(by: #selector(EditorTextView.selectNextOccurrence(_:)))
        try expect(editor.focusedSelectionGroups == [[leftMatch], splitMatch] &&
                   editor.selectedRange() == splitMatch.last,
                   "Select Next Occurrence selects the virtual newline match as one selection")
        editor.doCommand(by: #selector(EditorTextView.selectNextOccurrence(_:)))
        try expect(editor.focusedSelectionGroups == [[leftMatch], splitMatch, [rightMatch]] &&
                   editor.selectedRange() == rightMatch,
                   "Select Next Occurrence uses the entire split match as its needle")

        editor.setCaretSelections([leftMatch])
        editor.doCommand(by: #selector(EditorTextView.selectNextOccurrence(_:)))
        editor.doCommand(by: #selector(EditorTextView.skipNextOccurrence(_:)))
        try expect(editor.focusedSelectionGroups == [[leftMatch], [rightMatch]],
                   "Skip to Next Occurrence drops both pieces of the split match")

        editor.setCaretSelections([leftMatch])
        editor.doCommand(by: #selector(EditorTextView.selectNextOccurrence(_:)))
        editor.doCommand(by: #selector(EditorTextView.selectAllOccurrences(_:)))
        try expect(Set(editor.focusedSelectionGroups ?? []) == matches && editor.selectedRange() == splitMatch.last,
                   "Select All Occurrences uses the split needle and keeps its active piece in place")

        let history = editor.editorUndoManager
        history.groupsByEvent = false
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.string == "AXB\n\nAX" + gap + "B\n\nAXB",
                   "typing replaces each logical match once and leaves the original gap intact")
        history.undo()
        try expect(editor.string == original && editor.focusRanges == [leftBlock, rightBlock] &&
                   Set(editor.focusedSelectionGroups ?? []) == matches && editor.selectedRange() == splitMatch.last,
                   "one Undo restores text, scope, and the grouped occurrence selections")

        editor.setCaretSelections([NSRange(location: leftBlock.upperBound - 1, length: 0)])
        editor.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        editor.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        let selectAll = #selector(EditorTextView.selectAllOccurrences(_:))
        try expect(editor.selectedRange().length == 0 && editor.validateSelectionCommand(selectAll) == true,
                   "the shortcut remains available when the logical selection ends at the start of the next block")
        editor.doCommand(by: selectAll)
        try expect(editor.focusedSelectionGroups?.count == 5,
                   "a selected letter and virtual newline match real and virtual line endings")
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
        try expect(editor.focusRanges == [NSRange(location: 0, length: 11)] && editor.string == "plain draft",
                   "cancelling replacement of a dirty draft preserves Focus")
    }

    private static func verifyRememberedFocus(in app: Edit) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "focus-position-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = app.documents.count
        defer { app.documents.dropFirst(existing).forEach { $0.window.close() } }
        let source = directory.appending(path: "Focused source.txt")
        let other = directory.appending(path: "Unrelated source.txt")
        let filler = (0..<110).map { "position_\($0) " + String(repeating: "wide text ", count: 22) + "\n" }.joined()
        let contents = "first block\nprotected middle\n" + filler + "last block\n"
        try Data(contents.utf8).write(to: source)
        try Data("other file\n".utf8).write(to: other)
        let text = contents as NSString
        let firstBlock = text.range(of: "first block")
        let middleBlock = text.range(of: "protected middle")
        let lastBlock = text.range(of: "last block")
        let selectedPrefix = NSRange(location: lastBlock.location, length: 4)
        let anchor = NSRange(location: selectedPrefix.upperBound, length: 0)

        func expectBackwardSelection(in document: DocumentWindow, _ message: String) throws {
            let editor = document.editor
            try expect(editor.focusRanges == [firstBlock, lastBlock] &&
                       editor.focusedSelectionGroups == [[firstBlock, selectedPrefix]] &&
                       editor.selectedRange() == firstBlock && editor.activeEnd(of: firstBlock) == firstBlock.location,
                       message)
        }

        func expectViewport(in document: DocumentWindow, at expected: EditorPosition) throws {
            let actual = document.editor.capturePosition()
            let expectedLine = try require(expected.topLine)
            let actualLine = try require(actual.topLine)
            try expect(actualLine.textOffset == expectedLine.textOffset &&
                       abs(actualLine.offsetIntoLine - expectedLine.offsetIntoLine) <= 1 &&
                       abs(actual.horizontalOffset - expected.horizontalOffset) <= 1,
                       "restoring Focus keeps the saved viewport with the primary selection offscreen")
        }

        let first = app.makeDocument()
        _ = try await app.openFile(source, in: first)
        first.editor.setCaretSelections([firstBlock, lastBlock])
        first.focusSelection()
        first.editor.setCaretSelections([anchor])
        first.editor.doCommand(by: #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)))
        try expectBackwardSelection(in: first, "create a backward logical selection across two focused blocks")

        let scrollAnchor = text.range(of: "position_42 ")
        first.editor.scrollRangeToVisible(scrollAnchor)
        first.window.layoutIfNeeded()
        first.editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let line = try require(first.editor.lineBounds(at: scrollAnchor.location))
        first.scrollView.scrollToVisibleContentOrigin(NSPoint(x: 170, y: line.minY + 4))
        first.editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let viewport = first.editor.capturePosition()
        try expect(viewport.horizontalOffset > 100 && viewport.verticalOffset > 500,
                   "the Focus restoration scenario starts scrolled in both directions")

        _ = try await app.openFile(other, in: first)
        try expect(first.editor.focusRanges == nil && first.editor.string == "other file\n",
                   "switching to an unrelated file leaves Focus behind")
        _ = try await app.openFile(source, in: first)
        try expectBackwardSelection(in: first, "reopening a file restores its saved Focus and direction")
        try expectViewport(in: first, at: viewport)

        let second = app.makeDocument()
        _ = try await app.openFile(source, in: second)
        second.editor.exitFocus()
        second.editor.setCaretSelections([middleBlock])
        let middleCaret = NSRange(location: second.editor.activeEnd(of: middleBlock), length: 0)
        second.focusSelection()
        try expect(second.editor.focusRanges == [middleBlock] && second.editor.selectedRange() == middleCaret,
                   "another window can focus a different line in the same file")

        let draft = app.makeDocument()
        let draftText = "outside draft\ninside draft"
        draft.editor.insertText(draftText, replacementRange: NSRange(location: NSNotFound, length: 0))
        let draftBlock = (draftText as NSString).range(of: "inside draft")
        draft.editor.setCaretSelections([draftBlock])
        draft.focusSelection()

        let store = SessionStore(url: directory.appending(path: "focus-session.json"))
        try store.write(EditorSession(documents: [first, second, draft].map { $0.sessionDocument() },
                                      activeIndex: 0, lastWindow: nil))
        let session = try require(store.read())
        [first, second, draft].forEach { $0.window.close() }
        let placeholder = app.makeDocument()
        await app.restore(session, reusing: placeholder)
        let restored = Array(app.documents.dropFirst(existing))
        try expect(restored.count == 3 && restored.first === placeholder,
                   "restore the saved Focus windows, including the untitled draft")
        try expectBackwardSelection(in: restored[0], "session restores the first window's own Focus and active end")
        try expectViewport(in: restored[0], at: viewport)
        try expect(restored[1].editor.focusRanges == [middleBlock] &&
                   restored[1].editor.selectedRange() == middleCaret,
                   "session restores the second window's own Focus even for the same file")
        try expect(restored[2].fileURL == nil && restored[2].window.isDocumentEdited &&
                   restored[2].editor.string == draftText && restored[2].editor.focusRanges == [draftBlock],
                   "session restores a focused untitled draft with its text and dirty state")

        let editor = restored[0].editor
        editor.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        let shortened = NSRange(location: firstBlock.location + 1, length: firstBlock.length - 1)
        try expect(editor.focusedSelectionGroups == [[shortened, selectedPrefix]] &&
                   editor.activeEnd(of: shortened) == shortened.location,
                   "Shift-Right shrinks the restored logical selection from its original active end")

        _ = try await app.openFile(other, in: restored[0])
        let changed = "other block\nprotected middle\n" + filler + "last block\n"
        try Data(changed.utf8).write(to: source)
        _ = try await app.openFile(source, in: restored[0])
        try expect(editor.string == changed && editor.focusRanges == nil &&
                   editor.caretSelections == [selectedPrefix, shortened],
                   "an external same-length edit discards stale Focus boundaries and keeps the ordinary selections")
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
