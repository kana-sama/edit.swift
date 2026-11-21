import AppKit

@MainActor
enum EditorCheck {
    static func run(in window: NSWindow, editor: EditorTextView, scrollView: NSScrollView) throws {
        // Check focus and editing without activating the sample window or using the owner's clipboard.
        try expect(!window.isVisible && !NSApplication.shared.isActive, "quiet test window")
        try expect(window.firstResponder === editor && editor.string.isEmpty, "focused, empty editor")
        try expect(editor.textLayoutManager != nil, "TextKit 2 editor")

        guard let undo = editor.undoManager else { throw Failure("window undo manager") }
        undo.groupsByEvent = false
        func edit(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
        }
        func setBuffer(_ string: String, at location: Int = 0, length: Int = 0) {
            editor.string = string
            editor.setSelectedRange(NSRange(location: location, length: length))
            undo.removeAllActions()
        }

        edit { editor.insertText("Café 👋", replacementRange: editor.selectedRange()) }
        try expect(editor.string == "Café 👋", "Unicode input")
        try expect(editor.tryToPerform(Selector(("undo:")), with: nil), "Undo menu action on responder chain")
        try expect(editor.string.isEmpty, "undo native text input")
        try expect(editor.tryToPerform(Selector(("redo:")), with: nil), "Redo menu action on responder chain")
        try expect(editor.string == "Café 👋", "redo native text input")

        setBuffer("  first\nsecond", at: 7)
        edit { editor.insertNewline(nil) }
        try expect(editor.string == "  first\n  \nsecond", "Return copies indentation")
        undo.undo()
        try expect(editor.string == "  first\nsecond", "undo Return")
        edit { editor.insertLineAbove(nil) }
        try expect(editor.string == "  \n  first\nsecond", "insert indented line above")
        undo.undo()
        edit { editor.insertLineBelow(nil) }
        try expect(editor.string == "  first\n  \nsecond", "insert indented line below")

        setBuffer("a\nb\nc", length: 3)
        edit { editor.insertTab(nil) }
        try expect(editor.string == "    a\n    b\nc", "Tab indents selected lines")
        edit { editor.insertBacktab(nil) }
        try expect(editor.string == "a\nb\nc", "Shift-Tab restores selected lines")
        edit { editor.moveLinesDown(nil) }
        try expect(editor.string == "c\na\nb", "move block below final line without newline")
        try expect(editor.selectedRange() == NSRange(location: 2, length: 3), "move retains selection")
        undo.undo()
        try expect(editor.string == "a\nb\nc", "undo restores moved block")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        setBuffer("first\nlast", at: 8)
        edit { editor.copyLine(to: pasteboard, cutting: true) }
        try expect(editor.string == "first", "cut the unterminated final line")
        try expect(pasteboard.string(forType: .string) == "last\n", "whole-line plain text")
        undo.undo()
        try expect(editor.string == "first\nlast", "undo whole-line cut")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        edit { _ = editor.pasteLine(from: pasteboard) }
        try expect(editor.string == "last\nfirst\nlast", "paste a whole line above the caret")

        setBuffer("first\nsecond", at: 6)
        edit { editor.deleteToBeginningOfLine(nil) }
        try expect(editor.string == "firstsecond", "delete at line start joins the previous line")
        setBuffer("first\nsecond", at: 5)
        edit { editor.deleteToEndOfLine(nil) }
        try expect(editor.string == "firstsecond", "delete at line end joins the next line")

        let wideLine = String(repeating: "0123456789", count: 20)
        setBuffer(wideLine + String(repeating: "\nA second line", count: 60))
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.scrollRangeToVisible(NSRange(location: wideLine.utf16.count, length: 0))
        try expect(scrollView.hasHorizontalScroller && scrollView.contentView.bounds.minX > 0, "horizontal overflow")
        editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
        try expect(scrollView.hasVerticalScroller && scrollView.contentView.bounds.minY > 0, "vertical overflow")
        try expect(editor.textLayoutManager != nil, "editing stays on TextKit 2")

        try MultiCaretCheck.run(in: window, editor: editor, undo: undo)

        let sample = "let greeting = \"Hello, Edit!\"\n\nprint(greeting)"
        let selection = (sample as NSString).range(of: "Hello, Edit!")
        setBuffer(sample, at: selection.location, length: selection.length)
        let size = editor.font?.pointSize
        editor.increaseTextSize(nil)
        try expect(size.map { $0 + 1 } == editor.font?.pointSize, "increase text size")
        try expect(editor.selectedRange() == selection, "text size preserves selection")
        editor.resetTextSize(nil)
        try expect(editor.font?.pointSize == size, "restore default text size")
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw Failure(description) }
    }

    private struct Failure: LocalizedError {
        let description: String

        init(_ description: String) { self.description = description }

        var errorDescription: String? { "Failed editor check for \(description)." }
    }
}
