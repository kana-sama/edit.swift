import AppKit

@MainActor
enum MultiCaretCheck {
    static func run(in window: NSWindow, editor: EditorTextView, undo: UndoManager) throws {
        func range(_ location: Int, _ length: Int = 0) -> NSRange {
            NSRange(location: location, length: length)
        }
        func set(_ text: String, _ ranges: [NSRange]) {
            editor.resetMultiCarets()
            editor.string = text
            editor.setCaretSelections(ranges, record: false)
            undo.removeAllActions()
        }
        func edit(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
        }

        set("apple pear", [range(2)])
        editor.selectNextOccurrence(nil)
        try expect(editor.caretSelections == [range(0, 5)], "Command-D first selects the current word")

        set("a b a b a b", [range(0, 1)])
        editor.selectNextOccurrence(nil)
        try expect(editor.caretSelections == [range(0, 1), range(4, 1)], "select next literal match")
        let prefix = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)
        guard let prefix else { throw Failure("create isolated shortcut event") }
        editor.keyDown(with: prefix)
        editor.selectNextOccurrence(nil)
        try expect(editor.caretSelections == [range(0, 1), range(8, 1)], "skip occurrence with Command-K Command-D")
        editor.undoSelection(nil)
        try expect(editor.caretSelections == [range(0, 1), range(4, 1)], "selection-only Undo")
        editor.redoSelection(nil)
        try expect(editor.caretSelections == [range(0, 1), range(8, 1)] && editor.string == "a b a b a b",
                   "selection-only Redo preserves text")
        edit { editor.insertText("🙂", replacementRange: range(NSNotFound)) }
        try expect(editor.string == "🙂 b a b 🙂 b", "typing replaces every selected range")
        undo.undo()
        try expect(editor.string == "a b a b a b" && editor.caretSelections == [range(0, 1), range(8, 1)],
                   "one Undo restores all edited regions and selections")
        undo.redo()
        try expect(editor.string == "🙂 b a b 🙂 b", "batch Redo")
        editor.keepPrimarySelection(nil)
        try expect(editor.caretSelections == [range(11)], "Escape keeps the primary selection")

        set("a a A a", [range(2, 1)])
        editor.selectAllOccurrences(nil)
        try expect(editor.caretSelections == [range(0, 1), range(6, 1), range(2, 1)],
                   "select all case-sensitive matches on either side")
        set("ab\ncd\nef", [range(0, 4)])
        editor.addCaretsAtLineEnds(nil)
        try expect(editor.caretSelections == [range(2), range(4)], "carets at selected line ends")
        edit { editor.insertTab(nil) }
        try expect(editor.string == "ab    \nc    d\nef", "Tab inserts spaces at empty carets")
        undo.undo()
        try expect(editor.string == "ab\ncd\nef", "one Undo reverses all caret indent insertions")

        set("a\nb\n", [range(1), range(3)])
        edit { editor.insertText("🙂", replacementRange: range(NSNotFound)) }
        try expect(editor.string == "a🙂\nb🙂\n", "typing at distinct empty carets")
        edit { editor.deleteBackward(nil) }
        try expect(editor.string == "a\nb\n", "delete a composed character at every caret")
        undo.undo()
        try expect(editor.string == "a🙂\nb🙂\n", "one Undo reverses all deletions")

        set("one\ntwo\nthree\nfour\nfive", [range(5), range(15)])
        edit { editor.moveLinesUp(nil) }
        try expect(editor.string == "two\none\nfour\nthree\nfive"
                   && editor.caretSelections == [range(1), range(9)], "move disjoint lines and remap their carets")
        undo.undo()
        try expect(editor.string == "one\ntwo\nthree\nfour\nfive", "one Undo reverses both line moves")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        set("red\ngreen\nblue", [range(0), range(2), range(11)])
        edit { _ = editor.copySelections(to: pasteboard, cutting: true) }
        try expect(editor.string == "green" && pasteboard.string(forType: .string) == "red\nblue\n",
                   "cut distinct lines once with several empty carets")
        undo.undo()
        try expect(editor.string == "red\ngreen\nblue", "one Undo restores all cut lines")
        set("A\nB", [range(1), range(3)])
        edit { _ = editor.pasteAtCarets(from: pasteboard) }
        try expect(editor.string == "red\nA\nblue\nB", "whole-line paste pairs items with distinct target lines")

        set("apple pea", [range(0, 5), range(6, 3)])
        edit { _ = editor.copySelections(to: pasteboard, cutting: true) }
        try expect(editor.string == " " && pasteboard.string(forType: .string) == "apple\npea",
                   "cut several selected spans")
        undo.undo()
        try expect(editor.string == "apple pea", "one Undo restores several cut spans")
        set("A B", [range(0, 1), range(2, 1)])
        edit { _ = editor.pasteAtCarets(from: pasteboard) }
        try expect(editor.string == "apple pea", "paste matching copied parts into selected spans")

        set("abc\nabc", [range(2), range(6)])
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.doCommand(by: #selector(EditorTextView.moveLeftAndModifySelection(_:)))
        editor.doCommand(by: #selector(EditorTextView.moveLeftAndModifySelection(_:)))
        try expect(editor.caretSelections == [range(0, 2), range(4, 2)], "extend both selections toward the left")
        editor.doCommand(by: #selector(EditorTextView.moveRightAndModifySelection(_:)))
        try expect(editor.caretSelections == [range(1, 1), range(5, 1)], "reverse direction without losing the anchors")

        set("abc\ndef\nghi", [range(0, 2), range(5), range(8, 2)])
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
        try expect(editor.multiCaret.highlights.count == 1 && editor.multiCaret.indicators.count == 1,
                   "layout renders a secondary highlight and places a native insertion indicator")
        try expect(editor.multiCaret.highlights.allSatisfy { $0.width > 0 && $0.height > 0 }
                   && editor.multiCaret.indicators.allSatisfy { $0.frame.height > 0 },
                   "decoration rectangles are measurable in the hidden window")

        set("one\ntwo\nthree", [range(5)])
        editor.scrollRangeToVisible(range(5))
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.addCaretAbove(nil)
        try expect(editor.hasSecondarySelections && editor.caretSelections.last?.location == 1,
                   "add a caret above at the matching column")
        editor.addCaretBelow(nil)
        try expect(editor.caretSelections.last?.location == 9, "add a caret below the last selected line")
        editor.resetMultiCarets()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw Failure(description) }
    }

    private struct Failure: LocalizedError {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { "Failed multiple carets check for \(description)." }
    }
}
