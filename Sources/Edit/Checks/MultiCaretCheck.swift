import Accessibility
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
        try expect(editor.string == "ab  \nc   d\nef", "Tab reaches the next stop at each empty caret")
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

        func arrow(_ keyCode: UInt16, _ arrow: String, _ modifiers: NSEvent.ModifierFlags) throws {
            let flags = modifiers.union([.numericPad, .function])
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: arrow, charactersIgnoringModifiers: arrow,
                                                isARepeat: false, keyCode: keyCode) else {
                throw Failure("create isolated movement key event")
            }
            if !editor.performKeyEquivalent(with: event) { editor.keyDown(with: event) }
        }

        let procedure = "main :: proc() {\n    \n}"
        let leftArrow = "\u{F702}"
        let rightArrow = "\u{F703}"
        set(procedure, [range(0)])
        for stop in [4, 7, 12, 14, 16, 21, 23, 23] {
            try arrow(124, rightArrow, .option)
            try expect(editor.caretSelections == [range(stop)], "Option-Right in the procedure stops at \(stop)")
        }
        for stop in [22, 17, 15, 12, 8, 5, 0, 0] {
            try arrow(123, leftArrow, .option)
            try expect(editor.caretSelections == [range(stop)], "Option-Left in the procedure stops at \(stop)")
        }

        set(procedure, [range(21)])
        for stop in [17, 15, 12, 8, 5, 0] {
            try arrow(123, leftArrow, [.option, .shift])
            try expect(editor.caretSelections == [range(stop, 21 - stop)],
                       "Shift-Option-Left extends from the indented line to \(stop)")
        }

        set(procedure, [range(12)])
        for (key, glyph, result) in [
            (124 as UInt16, rightArrow, range(12, 2)),
            (123, leftArrow, range(12)),
            (123, leftArrow, range(8, 4)),
            (123, leftArrow, range(5, 7)),
            (124, rightArrow, range(7, 5)),
            (124, rightArrow, range(12)),
            (124, rightArrow, range(12, 2)),
        ] {
            try arrow(key, glyph, [.option, .shift])
            try expect(editor.caretSelections == [result], "Shift-Option moves the active end across the anchor")
        }
        try arrow(123, leftArrow, .option)
        try expect(editor.caretSelections == [range(12)], "Option movement starts at the active end, not the near edge")
        try arrow(123, leftArrow, [.option, .shift])
        try arrow(124, rightArrow, .option)
        try expect(editor.caretSelections == [range(12)], "Option-Right starts at the active end of a backward selection")

        set("main :: proc() {\r\n\r\n\t}", [range(16)])
        for stop in [18, 22] {
            try arrow(124, rightArrow, .option)
            try expect(editor.caretSelections == [range(stop)], "Option-Right crosses one logical line at a time over CRLF")
        }

        set("if item.action", [range(3)])
        try arrow(124, "\u{F703}", .option)
        try expect(editor.caretSelections == [range(7)], "Option-Right stops before the dot")
        try arrow(124, "\u{F703}", .option)
        try expect(editor.caretSelections == [range(14)], "Option-Right then reaches the end of action")
        try arrow(123, "\u{F702}", .option)
        try expect(editor.caretSelections == [range(8)], "Option-Left stops at the start of action")
        try arrow(123, "\u{F702}", .option)
        try expect(editor.caretSelections == [range(3)], "Option-Left then reaches the start of item")

        set("item.action\nitem.action", [range(0), range(12)])
        try arrow(124, "\u{F703}", [.option, .shift])
        try expect(editor.caretSelections == [range(0, 4), range(12, 4)], "Shift-Option-Right stops both selections before their dots")
        try arrow(124, "\u{F703}", [.option, .shift])
        try expect(editor.caretSelections == [range(0, 11), range(12, 11)], "Shift-Option-Right extends to the end of action")
        try arrow(123, "\u{F702}", [.option, .shift])
        try expect(editor.caretSelections == [range(0, 5), range(12, 5)], "Shift-Option-Left reaches the start of action")
        try arrow(123, leftArrow, [.option, .shift])
        try expect(editor.caretSelections == [range(0, 4), range(12, 4)], "Option-Left does not skip a lone separator with multiple carets")
        try arrow(123, leftArrow, [.option, .shift])
        try expect(editor.caretSelections == [range(0), range(12)], "reversed word movement returns to both anchors")

        set("item.action", [range(11)])
        edit { editor.deleteWordBackward(nil) }
        try expect(editor.string == "item.", "Option-Delete stops after the dot")
        undo.undo()
        try expect(editor.string == "item.action", "undo restores the deleted word")
        editor.setCaretSelections([range(0)])
        edit { editor.deleteWordForward(nil) }
        try expect(editor.string == ".action", "Option-Forward Delete stops before the dot")

        set("item.action\nitem.action", [range(4), range(16)])
        edit { editor.deleteWordForward(nil) }
        try expect(editor.string == "itemaction\nitemaction", "word deletion keeps the separator stop that movement skips")
        undo.undo()
        try expect(editor.string == "item.action\nitem.action", "one Undo restores both separators")

        set("main :: proc() {\n    \n}", [range(7), range(20)])
        edit { editor.deleteWordBackward(nil) }
        try expect(editor.string == "main  proc() {\n \n}", "word deletion removes a punctuation run and an indentation run separately")
        set("a\r\n  b", [range(1)])
        edit { editor.deleteWordForward(nil) }
        try expect(editor.string == "ab", "forward word deletion at end of line removes the newline and following indentation")
        set("a\r\n  b", [range(3)])
        edit { editor.deleteWordBackward(nil) }
        try expect(editor.string == "a  b", "backward word deletion at start of line removes just CRLF")

        let movementText = "zero one\ntwo three\nfour five\nsix seven\n"
        let originalCarets = [range(2), range(12)]
        set(movementText, originalCarets)
        try arrow(123, "\u{F702}", .command)
        try expect(editor.caretSelections == [range(0), range(9)], "Command-Left moves each caret to its own line start")
        try arrow(124, "\u{F703}", .command)
        try expect(editor.caretSelections == [range(8), range(18)], "Command-Right moves each caret to its own line end")
        try arrow(123, "\u{F702}", [.command, .shift])
        try expect(editor.caretSelections == [range(0, 8), range(9, 9)], "Shift-Command-Left extends both selections")
        try arrow(124, "\u{F703}", [.command, .shift])
        try expect(editor.caretSelections == [range(8), range(18)], "Shift-Command-Right returns to the original anchors")

        set(movementText, originalCarets)
        try arrow(124, "\u{F703}", .option)
        try expect(editor.caretSelections == [range(4), range(18)], "Option-Right advances each caret to a word end")
        try arrow(125, "\u{F701}", [])
        try expect(editor.caretSelections == [range(13), range(28)], "Down moves both carets to the next visual line")
        editor.doCommand(by: #selector(EditorTextView.moveToBeginningOfParagraph(_:)))
        try expect(editor.caretSelections == [range(9), range(19)], "move to each paragraph start")
        try arrow(126, "\u{F700}", .command)
        try expect(editor.caretSelections == [range(0)], "coincident document-start carets merge")

        set(String(repeating: "abcdefghij\n", count: 250), [range(4), range(554)])
        let beforePage = editor.caretSelections
        editor.doCommand(by: #selector(EditorTextView.pageDownAndModifySelection(_:)))
        let afterPage = editor.caretSelections
        try expect(afterPage.count == beforePage.count
                   && zip(afterPage, beforePage).allSatisfy { $0.location == $1.location && $0.length > 11 }
                   && afterPage[0].length == afterPage[1].length,
                   "extending a page keeps independent selections and column positions")

        set("abc\ndef\nghi", [range(0, 2), range(5), range(8, 2)])
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
        try expect(editor.multiCaret.highlights.count == 1 &&
                   editor.multiCaret.highlights.allSatisfy { $0.width > 0 && $0.height > 0 },
                   "the secondary selection renders a measurable highlight in the hidden window")

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

    static func checkBlink() throws {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 220)
        let window = EditorFocusCheckWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (scroll, editor) = EditorTextView.scrollingEditor(in: rect)
        window.contentView = scroll
        defer { window.close() }
        editor.string = String(repeating: "abcdefgh\n", count: 100)
        try expect(window.makeFirstResponder(editor) && !window.isVisible && !NSApp.isActive,
                   "the isolated caret view has focus without activating Edit")
        let near = NSRange(location: 3, length: 0)
        let far = NSRange(location: 9 * 70 + 3, length: 0)
        let separate = NSRange(location: 30, length: 0)
        let primary = NSRange(location: 12, length: 0)
        editor.setCaretSelections([near, far, separate, primary])
        func layoutCarets() {
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            editor.refreshCurrentLine()
        }
        layoutCarets()
        guard let group = editor.multiCaret.indicatorGroup, let layer = group.layer else {
            throw Failure("an active multiple selection has a shared insertion view")
        }
        let bars = group.caretRects.sorted { $0.minY < $1.minY }
        try expect(bars.count == 3 && editor.insertionPointColor.alphaComponent == 0
                   && bars.allSatisfy { $0.height > 0 && $0.width > 0 && $0.width < 2 },
                   "the editor draws all visible carets with thin bars")
        try expect(bars[0].minX == bars[1].minX && bars[0].maxY == bars[1].minY
                   && bars[1].maxY < bars[2].minY,
                   "same-column carets join only across adjacent rows")
        let phase = layer.animation(forKey: CaretIndicatorGroup.blinkKey)?.beginTime
        try expect((phase == nil) == AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator,
                   "one group animation respects the steady cursor setting")

        editor.scrollRangeToVisible(far)
        layoutCarets()
        try expect(editor.multiCaret.indicatorGroup === group && group.caretRects.count == 1
                   && layer.animation(forKey: CaretIndicatorGroup.blinkKey)?.beginTime == phase,
                   "an offscreen caret enters the same animation phase after scrolling")

        editor.keepPrimarySelection(nil)
        editor.scrollRangeToVisible(primary)
        layoutCarets()
        try expect(group.caretRects.count == 1 && group.caretRects.first == bars[1]
                   && editor.insertionPointColor.alphaComponent == 0,
                   "returning to one caret keeps exactly the same geometry")

        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(editor.selectedRange().location == primary.location + 1
                   && group.caretRects.count == 1 && group.caretRects[0].minX > bars[1].minX,
                   "the first frame with an inserted character has the new single caret")
        editor.deleteBackward(nil)
        try expect(editor.selectedRange() == primary && group.caretRects == [bars[1]],
                   "the first frame after deletion has the restored caret position")

        editor.setCaretSelections([near, primary])
        layoutCarets()
        let beforeTyping = group.caretRects
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(beforeTyping.count == 2 && group.caretRects.count == 2
                   && zip(group.caretRects, beforeTyping).allSatisfy { $0.minX > $1.minX },
                   "the first frame with simultaneous insertions has both new caret positions")

        editor.resetMultiCarets()
        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        layoutCarets()
        try expect(group.caretRects.count == 1 && group.caretRects[0].height > 0,
                   "an empty buffer shows a caret")
        try expect(window.makeFirstResponder(nil) && group.superview == nil
                   && editor.insertionPointColor.alphaComponent == 0 && !editor.shouldDrawInsertionPoint,
                   "leaving the editor removes the custom and system carets")
        let selections = [NSRange(location: 0, length: 2), NSRange(location: 9, length: 2)]
        editor.string = "abcdefgh\nabcdefgh"
        window.makeFirstResponder(editor)
        editor.setCaretSelections(selections)
        layoutCarets()
        try expect(!editor.multiCaret.highlights.isEmpty, "draw the secondary selection in the editor")
        window.simulatedKeyStatus = false
        layoutCarets()
        try expect(editor.multiCaret.indicatorGroup == nil && !editor.shouldDrawInsertionPoint &&
                   editor.caretSelections == selections && !editor.multiCaret.highlights.isEmpty,
                   "keep selections after the editor's window loses key status")
    }

    static func runComposition(in editor: EditorTextView) throws {
        guard let undo = editor.undoManager else { throw Failure("find IME Undo manager") }
        undo.groupsByEvent = false
        let original = "aa BB cc DD ee"
        let selections = [NSRange(location: 3, length: 2), NSRange(location: 9, length: 2)]
        let implicit = NSRange(location: NSNotFound, length: 0)
        let notify = editor.onTextChange
        let notifyBuffer = editor.onBufferEdit
        var changes = 0
        var bufferEdits: [[EditorTextEdit]?] = []
        editor.onTextChange = { changes += 1 }
        editor.onBufferEdit = { storage, edits in
            bufferEdits.append(edits)
            notifyBuffer?(storage, edits)
        }
        defer {
            editor.onTextChange = notify
            editor.onBufferEdit = notifyBuffer
        }

        func edit(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }

        func reset() {
            editor.resetMultiCarets()
            editor.string = original
            editor.setCaretSelections(selections, record: false)
            undo.removeAllActions()
            changes = 0
            bufferEdits.removeAll()
        }

        func mark(_ text: String) {
            editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                 replacementRange: implicit)
        }

        reset()
        mark("ka")
        mark("かな")
        try expect(editor.hasMarkedText() && editor.string == "aa BB cc かな ee" && changes == 0 &&
                   bufferEdits.isEmpty && !undo.canUndo,
                   "native primary preedit stays out of edit notifications and Undo")
        let markedRange = editor.markedRange()
        edit { editor.insertText("仮名", replacementRange: markedRange) }
        try expect(!editor.hasMarkedText() && editor.string == "aa 仮名 cc 仮名 ee" && changes == 1,
                   "commit broadcasts input with one edit notification")
        try expect(bufferEdits.count == 1 && bufferEdits[0]?.map(\.range) == selections,
                   "publish only the committed replacements in the original buffer coordinates")
        undo.undo()
        try expect(editor.string == original && editor.caretSelections == selections && !undo.canUndo,
                   "one Undo restores text and selections before the composition")
        undo.redo()
        try expect(editor.string == "aa 仮名 cc 仮名 ee", "redo repeats the complete composition")

        reset()
        mark("한")
        mark("")
        try expect(!editor.hasMarkedText() && editor.string == original
                   && editor.caretSelections == selections && changes == 0 && bufferEdits.isEmpty && !undo.canUndo,
                   "empty preedit cancels composition without history or an edit notification")

        reset()
        mark("ㅎ")
        editor.cancelOperation(nil)
        try expect(!editor.hasMarkedText() && editor.string == original
                   && editor.caretSelections == selections && !undo.canUndo,
                   "cancelling the native command restores the original selections")

        reset()
        mark("한")
        edit { editor.unmarkText() }
        try expect(!editor.hasMarkedText() && editor.string == "aa 한 cc 한 ee" && changes == 1,
                   "unmark commits through the standard AppKit input-client path")
        undo.undo()
        try expect(editor.string == original && !undo.canUndo, "unmark uses the same grouped Undo")
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
