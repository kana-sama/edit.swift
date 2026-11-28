import AppKit

@MainActor
enum EditorCheck {
    static func run(in document: DocumentWindow) throws {
        let (window, editor, scrollView) = (document.window, document.editor, document.scrollView)
        // Check focus and editing without activating the sample window or using the owner's clipboard.
        try expect(!window.isVisible && !NSApplication.shared.isActive, "quiet test window")
        try expect(window.firstResponder === editor && editor.string.isEmpty, "focused, empty editor")
        try expect(editor.textLayoutManager != nil, "TextKit 2 editor")
        try checkDoubleClick(in: window, editor: editor)

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

        guard let menu = NSApp.mainMenu else { throw Failure("find the editor menus") }
        let caseCommands = ControlCommand.fromMenu(menu)
        guard let uppercase = caseCommands.first(where: { $0.title == "Edit: Uppercase" }),
              let lowercase = caseCommands.first(where: { $0.title == "Edit: Lowercase" }),
              let uppercaseAction = uppercase.item.action, let lowercaseAction = lowercase.item.action else {
            throw Failure("expose the case transformations in Edit and Command Mode")
        }
        setBuffer("straße · café · Keep")
        editor.setCaretSelections([NSRange(location: 0, length: 6), NSRange(location: 9, length: 4)])
        edit { _ = editor.tryToPerform(uppercaseAction, with: uppercase.item) }
        try expect(editor.string == "STRASSE · CAFÉ · Keep" && editor.caretSelections.count == 2,
                   "uppercase both selections including a Unicode length change")
        undo.undo()
        try expect(editor.string == "straße · café · Keep" && editor.caretSelections.count == 2,
                   "undo all uppercase replacements together")
        setBuffer("ÉDIT · Keep", length: 4)
        edit { _ = editor.tryToPerform(lowercaseAction, with: lowercase.item) }
        try expect(editor.string == "édit · Keep", "lowercase the selected text")
        editor.isEditable = false
        let disablesCaseWhenReadOnly = !editor.validateUserInterfaceItem(uppercase.item) &&
            !editor.validateUserInterfaceItem(lowercase.item)
        editor.isEditable = true
        try expect(disablesCaseWhenReadOnly, "disable case transformations in a read-only editor")

        guard let lines = menu.items.compactMap(\.submenu).lazy.compactMap({ $0.item(withTitle: "Lines")?.submenu }).first,
              let comment = lines.item(withTitle: "Toggle Line Comments"),
              let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "/", charactersIgnoringModifiers: "/", isARepeat: false,
                                             keyCode: 44) else {
            throw Failure("find the line comment menu and shortcut")
        }
        try expect(!editor.validateUserInterfaceItem(comment), "disable line comments in plain text")
        document.setSyntaxLanguage(.swift)
        // Keep the fixture unordered while AppKit dispatches the menu key equivalent.
        comment.target = window.firstResponder
        defer { comment.target = nil }
        setBuffer("  café", at: 4)
        try expect(lines.performKeyEquivalent(with: shortcut) && editor.string == "  // café" &&
                   editor.selectedRange() == NSRange(location: 7, length: 0),
                   "Command-/ comments an indented Swift line and moves the caret with the text")
        undo.undo()
        try expect(editor.string == "  café" && editor.selectedRange() == NSRange(location: 4, length: 0),
                   "undo line comment and restore the caret")
        undo.redo()
        try expect(lines.performKeyEquivalent(with: shortcut) && editor.string == "  café",
                   "redo and toggle the Swift comment off")
        document.setSyntaxLanguage(.python)
        setBuffer("  one\r\n\t#two\r\nthree", length: 14)
        try expect(lines.performKeyEquivalent(with: shortcut) && editor.string == "  # one\r\n\t# #two\r\nthree",
                   "toggle a mixed Python selection ending at the next line boundary")
        try expect(lines.performKeyEquivalent(with: shortcut) && editor.string == "  one\r\n\t#two\r\nthree",
                   "round-trip mixed lines with CRLF separators")
        undo.undo()
        try expect(editor.string == "  # one\r\n\t# #two\r\nthree", "undo a multiline toggle in one step")
        setBuffer("one\ntwo")
        editor.setCaretSelections([0, 2, 6].map { NSRange(location: $0, length: 0) })
        try expect(lines.performKeyEquivalent(with: shortcut) && editor.string == "# one\n# two" &&
                   editor.caretSelections.map(\.location) == [2, 4, 10],
                   "comment each line once and preserve all carets")
        editor.isEditable = false
        try expect(!editor.validateUserInterfaceItem(comment), "disable line comments in a read-only editor")
        editor.isEditable = true
        document.setSyntaxLanguage(nil)

        guard let moveUp = lines.item(withTitle: "Move Line Up"),
              let moveDown = lines.item(withTitle: "Move Line Down"),
              let editMenu = lines.supermenu,
              let undoAction = editMenu.item(withTitle: "Undo")?.action,
              let redoAction = editMenu.item(withTitle: "Redo")?.action else {
            throw Failure("find the Move Line, Undo, and Redo menu items")
        }
        moveUp.target = editor
        moveDown.target = editor
        defer {
            moveUp.target = nil
            moveDown.target = nil
        }
        let lineMoves: [(arrow: String, code: UInt16, before: Int, after: Int)] = [("\u{F700}", 126, 7, 1), ("\u{F701}", 125, 2, 7)]
        for (arrow, code, before, after) in lineMoves {
            guard let moveKey = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                 modifierFlags: [.option, .numericPad, .function],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: arrow, charactersIgnoringModifiers: arrow,
                                                 isARepeat: false, keyCode: code) else {
                throw Failure("create the Move Line shortcut")
            }
            setBuffer("  red\nblue", at: before)
            var moved = false
            edit { moved = lines.performKeyEquivalent(with: moveKey) }
            try expect(moved && editor.string == "blue\n  red" &&
                       editor.selectedRange() == NSRange(location: after, length: 0), "move the caret with its line")
            try expect(editor.tryToPerform(undoAction, with: nil) && editor.string == "  red\nblue", "Undo restores the line order")
            try expect(editor.selectedRange() == NSRange(location: before, length: 0),
                       "Undo returns the original caret after moving a line (got \(editor.selectedRange()))")
            try expect(editor.tryToPerform(redoAction, with: nil) && editor.string == "blue\n  red" &&
                       editor.selectedRange() == NSRange(location: after, length: 0),
                       "Redo returns the caret to the moved line")
        }

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

        try checkTyping(in: document, undo: undo)

        setBuffer("a\nb\nc", length: 3)
        edit { editor.insertTab(nil) }
        try expect(editor.string == "    a\n    b\nc", "Tab indents selected lines")
        edit { editor.insertBacktab(nil) }
        try expect(editor.string == "a\nb\nc", "Shift-Tab restores selected lines")
        edit { editor.moveLinesDown(nil) }
        try expect(editor.string == "c\na\nb", "move block below final line without newline")
        try expect(editor.selectedRange() == NSRange(location: 2, length: 3), "move retains selection")
        undo.undo()
        try expect(editor.string == "a\nb\nc" && editor.selectedRange() == NSRange(location: 0, length: 3),
                   "Undo restores the moved block and the original selection")
        undo.redo()
        try expect(editor.string == "c\na\nb" && editor.selectedRange() == NSRange(location: 2, length: 3),
                   "Redo restores the block and its moved selection")

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
        let secondLine = (sample as NSString).range(of: "\n").location + 1
        func checkTypography(size: CGFloat, lineHeight: CGFloat) throws {
            try expect(editor.font?.fontName == "Menlo-Regular" && editor.font?.pointSize == size,
                       "use Menlo Regular at \(size) points")
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let lineOrigins = [0, secondLine, secondLine + 1].map { location in
                editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil).minY
            }
            for index in 1..<lineOrigins.count {
                let step = abs(lineOrigins[index] - lineOrigins[index - 1])
                try expect(abs(step - lineHeight) < 0.5, "line step \(step) should be \(lineHeight) points")
            }
        }
        try checkTypography(size: 12, lineHeight: 18)
        editor.increaseTextSize(nil)
        try checkTypography(size: 13, lineHeight: 20)
        try expect(editor.selectedRange() == selection, "text size preserves selection")
        editor.resetTextSize(nil)
        try checkTypography(size: 12, lineHeight: 18)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshCurrentLine()
    }

    static func checkViewportResize(in document: DocumentWindow) async throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        defer { window.close() }

        let line = "Prefix " + String(repeating: "0123456789 ", count: 45)
        editor.string = Array(repeating: line, count: 70).joined(separator: "\n")
        window.makeFirstResponder(editor)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        for sidebar in [false, true] {
            if sidebar {
                document.performFind(.find)
                window.layoutIfNeeded()
                await Task.yield()
                try expect(scroll.contentInsets.left > 0, "resize check includes a visible sidebar")
            }
            let cases: [(NSRange, NSPoint, CGFloat)] = [
                (NSRange(location: 280, length: 0), .zero, 540),
                (NSRange(location: 0, length: 5), NSPoint(x: 145, y: 72), 900),
                (NSRange(location: 280, length: 0), NSPoint(x: 145, y: 72), 640),
            ]
            for (selection, origin, width) in cases {
                editor.setSelectedRange(selection)
                editor.scrollRangeToVisible(selection)
                scroll.scrollToVisibleContentOrigin(origin)
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                func checkPosition(_ stage: String) throws {
                    let actual = scroll.visibleContentOrigin
                    try expect(abs(actual.x - origin.x) < 1 && abs(actual.y - origin.y) < 1
                               && editor.selectedRange() == selection,
                               "resize preserves the viewport and selection \(stage), sidebar \(sidebar), \(origin) → \(actual)")
                }

                try checkPosition("before resizing")
                var frame = window.frame
                frame.size.width = width
                editor.viewWillStartLiveResize()
                window.setFrame(frame, display: false)
                window.layoutIfNeeded()
                try checkPosition("during resizing")
                editor.viewDidEndLiveResize()
                try checkPosition("at the end of resizing")
                try await Task.sleep(for: .milliseconds(20))
                try checkPosition("after layout settles")
            }
        }
    }

    static func checkScrollReversal(in app: Edit) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Scroll Reversal \(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let document = app.makeDocument()
        let window = document.window
        defer {
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1470, height: 923), display: false)
        window.orderBack(nil)
        try expect(window.alphaValue == 0 && window.ignoresMouseEvents && !NSApp.isActive, "quiet live scrolling check")

        // Alternate between sections with short declarations and sections with long signatures.
        let rows = (0..<10_258).map { row in
            let width = switch row {
            case 0..<720: 24 + row * 17 % 34
            case 720..<795: 24 + row * 43 % 97
            case 795..<905: 24 + row * 19 % 24
            case 905..<1050: 32 + row * 31 % 98
            default: 24 + row * 47 % 93
            }
            return "\(row) " + String(repeating: "x", count: width)
        }
        let source = rows.joined(separator: "\n") + "\n"
        let url = root.appending(path: "Declarations.txt")
        try Data(source.utf8).write(to: url)
        _ = try await app.openFile(root, in: document)
        _ = try await app.openFile(url, in: document, focusEditor: false)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let editor = document.editor
        let scroll = document.scrollView
        guard let manager = editor.textLayoutManager else { throw Failure("TextKit 2 scroll layout") }
        let viewport = manager.textViewportLayoutController
        let starts = [0] + source.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
        let destination = NSRange(location: starts[949] + 12, length: 0)
        document.navigate(to: destination, from: nil)
        window.displayIfNeeded()

        func firstViewportRow() throws -> Int {
            guard let range = viewport.viewportRange,
                  let row = starts.firstIndex(of: manager.offset(from: manager.documentRange.location, to: range.location)) else {
                throw Failure("TextKit provides a laid-out first row")
            }
            return row
        }

        let down: [Int32] = [5, 28, 58, 35, 63, 104, 17, 52, 21, 8, 8, 15, 16, 44, 40, 67, 98, 32, 15, 25, 21, 10,
                             8, 3, 29, 77, 80, 80, 19, 6, 43, 12, 11, 9, 9, 16, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2, 1, 1, 1]
        func scrollBy(_ points: Int32) throws {
            guard let input = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: -points, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: input) else { throw Failure("create pixel scroll event") }
            scroll.scrollWheel(with: event)
            window.displayIfNeeded()
        }

        for delta in down {
            try scrollBy(delta)
            await Task.yield()
        }
        guard let lineHeight = editor.defaultParagraphStyle?.minimumLineHeight, lineHeight > 0 else {
            throw Failure("fixed line height for unwrapped scrolling")
        }
        let initialHeight = editor.frame.height
        let up: [Int32] = [-24, -49, -65, -76]
        for delta in up {
            let previousRow = try firstViewportRow()
            let previousOrigin = scroll.contentView.bounds.minY
            try scrollBy(delta)
            let nextRow = try firstViewportRow()
            let movement = scroll.contentView.bounds.minY - previousOrigin
            try expect(abs(movement - CGFloat(delta)) < 1
                       && abs(movement - CGFloat(nextRow - previousRow) * lineHeight) < 2 * lineHeight,
                       "first frame of upward scroll follows the clip movement (\(previousRow + 1) → \(nextRow + 1), \(movement) pt)")
            try expect(abs(editor.frame.height - initialHeight) < lineHeight,
                       "scrollbar extent stays stable during upward scrolling")
            await Task.yield()
        }
        try expect(editor.selectedRange() == destination && editor.string == source, "scrolling preserves selection and text")
    }

    static func checkScrolledZoom(in document: DocumentWindow) async throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        let clip = scroll.contentView
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        // Keep AppKit's backing layers live without displaying or activating the test window.
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try expect(window.isVisible && !NSApp.isActive && window.alphaValue == 0, "quiet live zoom check")

        let text = (0..<1_200).map { row in
            "\tlet row_\(row) = \"This line should always stay visible when resizing the editor font.\";"
        }.joined(separator: "\n")
        let caret = NSRange(location: 0, length: 0)
        editor.string = text
        editor.setSelectedRange(caret)
        document.setSyntaxLanguage(.rust)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        func rowBounds(at offset: Int) -> NSRect {
            let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
            return editor.convert(window.convertFromScreen(rect), from: nil)
        }

        func textTop() -> CGFloat { scroll.documentVisibleRect.minY + scroll.contentInsets.top }
        func textBottom() -> CGFloat { scroll.documentVisibleRect.maxY - scroll.contentInsets.bottom }

        func checkTopRow(_ offset: Int) throws {
            let row = rowBounds(at: offset)
            let top = textTop()
            try expect(row.minY <= top && top < row.maxY, "zoom preserves the top visible row")
        }

        let source = text as NSString
        let topRow = source.range(of: "row_920 =")
        func scrollToTopRow() {
            editor.scrollRangeToVisible(topRow)
            let row = rowBounds(at: topRow.location)
            var origin = clip.bounds.origin
            origin.y += row.minY + row.height / 2 - textTop()
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        scrollToTopRow()
        try await checkTextPaint(in: clip, after: "scrolling deep into the buffer")
        try expect(clip.bounds.minY > 10_000, "the zoom test starts deep in the buffer")
        try checkTopRow(topRow.location)
        editor.decreaseTextSize(nil)
        try await checkTextPaint(in: clip, after: "decreasing text size without scrolling")
        try checkTopRow(topRow.location)
        editor.increaseTextSize(nil)
        try await checkTextPaint(in: clip, after: "increasing text size without scrolling")
        try checkTopRow(topRow.location)
        editor.increaseTextSize(nil)
        editor.resetTextSize(nil)
        try await checkTextPaint(in: clip, after: "resetting text size without scrolling")
        try checkTopRow(topRow.location)
        try expect(editor.string == text && editor.selectedRange() == caret, "zoom preserves text and the offscreen caret")

        let middleRow = source.range(of: "row_930 =")
        editor.setSelectedRange(middleRow)
        editor.increaseTextSize(nil)
        try await checkTextPaint(in: clip, after: "zooming with the active row still visible")
        try checkTopRow(topRow.location)

        for length in [0, 4] {
            editor.resetTextSize(nil)
            if length == 0 {
                for _ in 0..<5 { editor.decreaseTextSize(nil) }
            }
            scrollToTopRow()
            let rowHeight = rowBounds(at: topRow.location).height
            let offsetNearBottom = editor.characterIndexForInsertion(
                at: NSPoint(x: editor.textContainerOrigin.x, y: textBottom() - rowHeight)
            )
            let selection = NSRange(location: offsetNearBottom, length: length)
            editor.setSelectedRange(selection)
            scrollToTopRow()
            let before = rowBounds(at: selection.location)
            try expect(before.minY > textTop() && before.maxY <= textBottom(), "active row starts near the bottom")

            if length == 0 {
                editor.resetTextSize(nil)
            } else {
                editor.increaseTextSize(nil)
            }
            try await checkTextPaint(in: clip, after: "revealing the active row")
            let after = rowBounds(at: selection.location)
            try expect(after.minY >= textTop() && abs(after.maxY - textBottom()) <= 1,
                       "zoom scrolls just enough to reveal the previously visible active row")
            try expect(editor.selectedRange() == selection, "revealing the active row preserves the selection")
        }
    }

    static func checkCurrentLinePaint() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = EditorFocusCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (scroll, editor) = EditorTextView.scrollingEditor(in: bounds)
        editor.isEditable = false
        window.contentView = scroll
        window.makeFirstResponder(editor)
        let clip = scroll.contentView
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        try expect(window.isVisible && !NSApp.isActive, "quiet live active-line check")

        let wideLine = String(repeating: " ", count: 240) + "x\n"
        editor.string = String(repeating: wideLine, count: 25)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        let activeRows = [1, 3, 5]
        let referenceRow = 8
        let rowBounds = try Dictionary(uniqueKeysWithValues: (activeRows + [referenceRow]).map { row in
            guard let line = editor.lineBounds(at: wideLine.utf16.count * row) else {
                throw Failure("lay out row \(row) for the active-line check")
            }
            return (row, line)
        })

        func paint(_ row: Int, in frame: NSBitmapImageRep) throws -> [NSColor] {
            guard let line = rowBounds[row] else { throw Failure("find the row to sample") }
            let y = Int(clip.convert(line, from: editor).midY - clip.bounds.minY)
            return try stride(from: 2, to: frame.pixelsWide - 18, by: 4).map { x in
                guard let sample = frame.colorAt(x: x, y: y) else { throw Failure("sample active-line paint") }
                return sample
            }
        }

        func checkFrame(active row: Int?, at x: CGFloat) async throws {
            try await Task.sleep(for: .milliseconds(65))
            try expect(abs(scroll.visibleContentOrigin.x - x) < 1, "active-line check keeps horizontal position \(x)")
            let frame = try liveViewportBitmap(in: clip)
            let plain = try paint(referenceRow, in: frame)
            if let row {
                let active = try paint(row, in: frame)
                try expect(Set(active).count == 1 && zip(active, plain).allSatisfy { $0.0 != $0.1 },
                           "paint active row \(row) across the viewport at horizontal offset \(x)")
            }
            for other in activeRows where other != row {
                let old = try paint(other, in: frame)
                try expect(old == plain, "clear old active row \(other) at horizontal offset \(x)")
            }
        }

        func selectRow(_ row: Int) {
            editor.setSelectedRange(NSRange(location: wideLine.utf16.count * row + 76, length: 0))
        }
        selectRow(1)
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 460, y: 0))
        try await checkFrame(active: 1, at: 460)
        scroll.scrollToVisibleContentOrigin(.zero)
        try await checkFrame(active: 1, at: 0)
        selectRow(3)
        try await checkFrame(active: 3, at: 0)
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 460, y: 0))
        try await checkFrame(active: 3, at: 460)
        selectRow(5)
        try await checkFrame(active: 5, at: 460)
        scroll.scrollToVisibleContentOrigin(.zero)
        try await checkFrame(active: 5, at: 0)
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 900, y: 0))
        try await checkFrame(active: 5, at: 900)
        selectRow(1)
        try await checkFrame(active: 1, at: 900)
        scroll.scrollToVisibleContentOrigin(.zero)
        try await checkFrame(active: 1, at: 0)
        window.makeFirstResponder(nil)
        try await checkFrame(active: nil, at: 0)
        window.makeFirstResponder(editor)
        try await checkFrame(active: 1, at: 0)
        window.simulatedKeyStatus = false
        try await checkFrame(active: nil, at: 0)
    }

    private static func liveViewportBitmap(in clip: NSClipView) throws -> NSBitmapImageRep {
        let bounds = clip.bounds
        guard let layer = clip.layer,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { throw Failure("capturing the live viewport") }
        bitmap.size = bounds.size
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure("viewport graphics context") }
        let rendered = layer.presentation() ?? layer
        let context = graphics.cgContext
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rendered.bounds.minX, y: -rendered.bounds.minY)
        rendered.render(in: context)
        return bitmap
    }

    private static func checkTextPaint(in clip: NSClipView, after action: String) async throws {
        // Let Core Animation commit the frame. Do not force layout or display while inspecting it.
        try await Task.sleep(for: .milliseconds(80))
        let bitmap = try liveViewportBitmap(in: clip)
        guard let bytes = bitmap.bitmapData else { throw Failure("read live viewport pixels") }
        var blankHeight = 0
        for y in stride(from: 52, to: bitmap.pixelsHigh - 12, by: 2) {
            let hasText = stride(from: 8, to: min(bitmap.pixelsWide - 18, 385), by: 2).contains { x in
                let offset = y * bitmap.bytesPerRow + 4 * x
                return max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 135
            }
            blankHeight = hasText ? 0 : blankHeight + 2
            try expect(blankHeight < 50, "zoom keeps the viewport painted after \(action)")
        }
    }

    private static func checkTyping(in document: DocumentWindow, undo: UndoManager) throws {
        let (window, editor) = (document.window, document.editor)
        func range(_ offset: Int, _ length: Int = 0) -> NSRange { NSRange(location: offset, length: length) }
        func set(_ source: String, _ ranges: NSRange...) {
            editor.string = source
            editor.setCaretSelections(ranges, record: false)
            undo.removeAllActions()
        }
        func key(_ characters: String, code: UInt16, shifted: Bool = false) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shifted ? .shift : [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { throw Failure("create a typing event") }
            undo.beginUndoGrouping()
            editor.keyDown(with: event)
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
        }

        set("fn () ", range(6))
        try key("{", code: 33, shifted: true)
        try expect(editor.string == "fn () {}" && editor.selectedRange() == range(7), "type both braces around the caret")
        try key("\r", code: 36)
        try expect(editor.string == "fn () {\n    \n}" && editor.selectedRange() == range(12), "Return splits the brace pair and indents its interior")
        undo.undo()
        try expect(editor.string == "fn () {}" && editor.selectedRange() == range(7), "Undo restores the one-line pair and caret")
        undo.undo()
        try expect(editor.string == "fn () " && editor.selectedRange() == range(6), "Undo removes both inserted braces")
        undo.redo()
        undo.redo()
        try expect(editor.string == "fn () {\n    \n}" && editor.selectedRange() == range(12), "Redo restores the split pair and caret")
        editor.setSelectedRange(range(13))
        try key("}", code: 30, shifted: true)
        try expect(editor.string == "fn () {\n    \n}" && editor.selectedRange() == range(14), "type over the auto-inserted closing brace after Redo")

        set("  call(  ", range(9))
        try key("\r", code: 36)
        try expect(editor.string == "  call(  \n    " && editor.selectedRange() == range(14), "Return indents to the next stop after an opener")
        set("fn () {  }", range(7))
        try key("\r", code: 36)
        try expect(editor.string == "fn () {\n    \n  }" && editor.selectedRange() == range(12),
                   "Return splits a pair across whitespace before the closer")
        let previousLanguage = document.manualSyntaxLanguage
        document.setSyntaxLanguage(.python)
        set("if ready:", range(9))
        editor.setIndentation(Indentation(style: .spaces, width: 2))
        try key("\r", code: 36)
        try expect(editor.string == "if ready:\n  " && editor.selectedRange() == range(12), "Python Return uses the configured width after a colon")
        editor.setIndentation(.standard)
        document.setSyntaxLanguage(previousLanguage)

        set("🙂 café\nnext", range(3, 9))
        try key("'", code: 39)
        try expect(editor.string == "🙂 'café\nnext'" && editor.selectedRange() == range(4, 9), "wrap a multiline Unicode selection in quotes")
        undo.undo()
        try expect(editor.string == "🙂 café\nnext" && editor.selectedRange() == range(3, 9), "Undo restores the original selected text")
        try key("]", code: 30)
        try expect(editor.string == "🙂 ]" && editor.selectedRange() == range(4), "a closing bracket replaces selected text")
        set("x  y", range(1, 2))
        try key("[", code: 33)
        try expect(editor.string == "x[y" && editor.selectedRange() == range(2), "an opener replaces whitespace-only selections")

        set("can", range(3))
        try key("'", code: 39)
        try expect(editor.string == "can'", "type an apostrophe after a word")
        set("", range(0))
        try key("\"", code: 39, shifted: true)
        try expect(editor.string == "\"\"" && editor.selectedRange() == range(1), "type a pair of double quotes")
        try key("x", code: 7)
        try key("y", code: 16)
        try key("\u{7f}", code: 51)
        try key("\"", code: 39, shifted: true)
        try expect(editor.string == "\"x\"" && editor.selectedRange() == range(3),
                   "type through an auto-inserted quote after typing and Backspace (\(editor.string), \(editor.selectedRange()))")
        set("\\", range(1))
        try key("\"", code: 39, shifted: true)
        try expect(editor.string == "\\\"", "type an escaped quote")
        set("hello", range(2))
        try key("[", code: 33)
        try expect(editor.string == "he[llo", "type a single opener in the middle of a word")
        set(")", range(0))
        try key(")", code: 29, shifted: true)
        try expect(editor.string == "))", "insert a closer before a manually entered closer")
        set(")", range(0))
        try key("(", code: 25, shifted: true)
        try expect(editor.string == "()" && editor.selectedRange() == range(1), "reuse an existing unmatched closer")
        set("()", range(1))
        try key("(", code: 25, shifted: true)
        try expect(editor.string == "(())" && editor.selectedRange() == range(2), "insert a nested pair before a matched closer")
        set(".value", range(0))
        try key("(", code: 25, shifted: true)
        try expect(editor.string == "().value" && editor.selectedRange() == range(1), "autoclose a bracket before a period")
        set("", range(0))
        try key("[", code: 33)
        try key("\u{7f}", code: 51)
        try expect(editor.string.isEmpty && editor.selectedRange() == range(0), "Backspace removes both sides of a fresh pair")
        undo.undo()
        try expect(editor.string == "[]" && editor.selectedRange() == range(1), "Undo restores the empty pair and caret")
        try key("\u{7f}", code: 51)
        try expect(editor.string.isEmpty, "Undo restores the auto-pair tracking")

        set("    a\n  b", range(4), range(8))
        try key("\u{7f}", code: 51)
        try expect(editor.string == "a\nb" && editor.caretSelections == [range(0), range(2)],
                   "Backspace deletes leading spaces to each preceding tab stop")
        set("    if (ok) {\n  ", range(16))
        try key("\t", code: 48)
        try expect(editor.string == "    if (ok) {\n        " && editor.selectedRange() == range(22),
                   "Tab uses the enclosing indentation on a whitespace-only line")
        document.setSyntaxLanguage(.javascript)
        set("abc", range(0, 3))
        try key("`", code: 50)
        try expect(editor.string == "`abc`" && editor.selectedRange() == range(1, 3), "wrap a JavaScript selection in backticks")
        set("html", range(4))
        try key("`", code: 50)
        try expect(editor.string == "html``" && editor.selectedRange() == range(5), "pair a JavaScript tagged template delimiter")
        document.setSyntaxLanguage(previousLanguage)
        set("", range(0))
        undo.beginUndoGrouping()
        editor.insertText("[", replacementRange: range(NSNotFound))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        try expect(editor.string == "[", "explicit text input inserts its literal text")

        set("  abc\n\t x\né", range(2), range(8), range(11))
        try key("\t", code: 48)
        try expect(editor.string == "    abc\n\t    x\né   " && editor.caretSelections == [range(4), range(13), range(19)],
                   "Tab aligns several carets using logical columns and existing tabs")

        set("left\n  ", range(0, 4), range(7))
        try key("[", code: 33)
        try expect(editor.string == "[\n  [" && editor.caretSelections == [range(1), range(5)],
                   "mixed selections and empty carets insert literal brackets together")
        undo.undo()
        try expect(editor.string == "left\n  " && editor.caretSelections == [range(0, 4), range(7)], "Undo restores both caret ranges")

        set("keep\r\n\t[]\r\nprotected\r\n()", range(8), range(23))
        let previousSeparator = editor.preferredLineEnding
        editor.preferredLineEnding = "\r\n"
        defer {
            editor.exitFocus()
            editor.preferredLineEnding = previousSeparator
        }
        editor.beginFocus()
        try key("\r", code: 36)
        try expect(editor.string == "keep\r\n\t[\r\n        \r\n\t]\r\nprotected\r\n(\r\n    \r\n)" &&
                   editor.caretSelections == [range(18), range(42)], "Return splits CRLF pairs in multiple Focus blocks")
        undo.undo()
        try expect(editor.string == "keep\r\n\t[]\r\nprotected\r\n()" && editor.caretSelections == [range(8), range(23)],
                   "Undo restores both focused pairs and their carets")
    }

    private static func checkDoubleClick(in window: NSWindow, editor: EditorTextView) throws {
        let sample = "  playdate_mod.getEmittedDocs(),  \nnext"
        editor.string = sample
        defer {
            editor.string = ""
            editor.undoManager?.removeAllActions()
        }
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        func event(_ type: NSEvent.EventType, at offset: Int, count: Int) throws -> NSEvent {
            let hit = NSRange(location: offset, length: 0)
            let rect = editor.firstRect(forCharacterRange: hit, actualRange: nil)
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.midY))
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: count,
                                                 clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw Failure("create a text selection mouse event")
            }
            return event
        }
        func doubleClick(at offset: Int, draggingTo target: Int? = nil) throws {
            NSApp.postEvent(try event(.leftMouseUp, at: offset, count: 1), atStart: true)
            editor.mouseDown(with: try event(.leftMouseDown, at: offset, count: 1))
            NSApp.postEvent(try event(.leftMouseUp, at: target ?? offset, count: 2), atStart: true)
            if let target { NSApp.postEvent(try event(.leftMouseDragged, at: target, count: 2), atStart: true) }
            editor.mouseDown(with: try event(.leftMouseDown, at: offset, count: 2))
        }

        let text = sample as NSString
        for (offset, expected) in [(10, text.range(of: "playdate_mod")), (14, text.range(of: "playdate_mod")),
                                   (15, text.range(of: "getEmittedDocs")), (31, text.range(of: "(),")),
                                   (1, NSRange(location: 0, length: 2)), (33, NSRange(location: 32, length: 2))] {
            try doubleClick(at: offset)
            let selected = editor.selectedRange()
            try expect(selected == expected, "double-click selection at \(offset), got \(selected), expected \(expected)")
        }
        for (target, start, end, affinity) in [(1, 1, 14, NSSelectionAffinity.upstream),
                                               (15, 2, 15, .downstream), (22, 2, 29, .downstream)] {
            try doubleClick(at: 10, draggingTo: target)
            try expect(editor.selectedRange() == NSRange(start..<end) && editor.selectionAffinity == affinity,
                       "extend a double-click selection to \(target), got \(editor.selectedRange())")
        }
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

// Exercise key-window drawing without making a test window key on the desktop.
final class EditorFocusCheckWindow: NSWindow {
    var simulatedKeyStatus = true {
        didSet {
            guard oldValue != simulatedKeyStatus else { return }
            let event = simulatedKeyStatus ? Self.didBecomeKeyNotification : Self.didResignKeyNotification
            NotificationCenter.default.post(name: event, object: self)
        }
    }

    override var isKeyWindow: Bool { simulatedKeyStatus }
}
