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
