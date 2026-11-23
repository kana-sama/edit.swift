import AppKit

@MainActor
enum JJEditorCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "JJ editor: " + message }
    }

    static func run(in document: DocumentWindow) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        defer { window.close() }

        let row = String(repeating: "long text ", count: 18) + "\n"
        let starts = (0..<240).map { $0 * row.utf16.count }
        let marks: [JJLineMark] = [
            JJLineMark(kind: .insertion, lines: 2..<5),
            JJLineMark(kind: .deletion, lines: 70..<70),
            JJLineMark(kind: .conflict, lines: 150..<155),
        ]
        let sampleBackground = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        scroll.backgroundColor = sampleBackground
        editor.backgroundColor = sampleBackground
        editor.string = String(repeating: row, count: starts.count)
        let selection = NSRange(location: 2, length: 3)
        editor.setSelectedRange(selection)
        window.makeFirstResponder(editor)

        for style: NSScroller.Style in [.legacy, .overlay] {
            editor.setJJLineMarks([])
            scroll.scrollerStyle = style
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            scroll.scrollToVisibleContentOrigin(NSPoint(x: 34, y: 0))
            let before = scroll.visibleContentOrigin
            guard scroll.scrollerStyle == style, let scroller = scroll.verticalScroller, let parent = scroll.superview else {
                throw Failure("missing native \(style) scrollbar")
            }
            let slot = scroller.rect(for: .knobSlot)
            guard !slot.isEmpty, before.x > 0 else { throw Failure("sample has no scroll range") }
            func point(at fraction: CGFloat) -> NSPoint {
                let y = scroller.isFlipped ? slot.minY + slot.height * fraction : slot.maxY - slot.height * fraction
                return scroller.convert(NSPoint(x: slot.midX, y: y), to: nil)
            }
            let destination = point(at: 152.5 / CGFloat(starts.count))
            let unmarked = point(at: 0.43)
            let unmarkedHit = scroll.hitTest(parent.convert(unmarked, from: nil))
            let nativeHit = scroll.hitTest(parent.convert(destination, from: nil))
            let editorPaint = try editorBodyPaint(in: scroll)
            editor.setJJLineMarks(marks, lineStarts: starts)
            guard try editorBodyPaint(in: scroll) == editorPaint else {
                throw Failure("markers cover the editor body in \(style)")
            }
            guard editor.jjLineMarks == marks,
                  scroll.hitTest(parent.convert(unmarked, from: nil)) === unmarkedHit,
                  let marker = scroll.hitTest(parent.convert(destination, from: nil)), marker !== nativeHit,
                  let click = NSEvent.mouseEvent(with: .leftMouseDown, location: destination, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure("exposed marker and unmarked track route clicks in \(style)")
            }
            editor.suspendJJMarkerNavigation()
            guard editor.jjLineMarks == marks, scroll.hitTest(parent.convert(destination, from: nil)) === nativeHit else {
                throw Failure("pending markers stay visible and yield clicks to the native scroll view in \(style)")
            }
            editor.setJJLineMarks(marks, lineStarts: starts)
            guard scroll.hitTest(parent.convert(destination, from: nil)) === marker else {
                throw Failure("a matching refresh restores marker clicks in \(style)")
            }

            marker.mouseDown(with: click)
            guard let layout = editor.textLayoutManager,
                  let location = layout.location(layout.documentRange.location, offsetBy: starts[150]),
                  let target = layout.textLayoutFragment(for: location), target.state == .layoutAvailable else {
                throw Failure("marker destination is laid out")
            }
            let targetCenter = target.layoutFragmentFrame.midY + editor.textContainerOrigin.y
            let visible = scroll.documentVisibleRect
            guard targetCenter > visible.minY, targetCenter < visible.maxY,
                  abs(scroll.visibleContentOrigin.x - before.x) < 1,
                  editor.selectedRange() == selection, window.firstResponder === editor else {
                throw Failure("marker scroll preserves horizontal viewport, selection, and focus in \(style)")
            }
            if style == .legacy {
                let thumb = scroller.convert(NSPoint(x: scroller.rect(for: .knob).midX,
                                                    y: scroller.rect(for: .knob).midY), to: nil)
                guard scroll.hitTest(parent.convert(thumb, from: nil)) === scroller else {
                    throw Failure("native scrollbar thumb retains its hit target")
                }
            }
        }

        scroll.scrollToVisibleContentOrigin(.zero)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard let line = editor.lineBounds(at: starts[3]) else { throw Failure("lay out a visible gutter mark") }
        let gutterX = editor.convert(scroll.visibleContentOrigin, to: scroll).x
        let sample = NSRect(x: max(gutterX, scroll.contentView.frame.minX) + 3,
                            y: scroll.convert(line, from: editor).midY, width: 1, height: 1)
        func gutterPixel() throws -> NSColor {
            let bitmap = try capture(scroll, in: sample)
            guard let color = bitmap.colorAt(x: 0, y: 0) else { throw Failure("sample the gutter") }
            return color
        }
        let painted = try gutterPixel()
        editor.setJJLineMarks([])
        guard try gutterPixel() != painted else { throw Failure("draw the gutter mark on the running editor") }
        editor.setJJLineMarks(marks, lineStarts: starts)
        editor.suspendJJMarkerNavigation()
        editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        guard try gutterPixel() == painted else { throw Failure("keep the gutter painted before a new diff arrives") }

        try checkTrackAfterResize(in: document)
        try checkGutterUnderTitlebar(in: document)
        try checkCurrentLineThroughGutter(in: document)
    }

    private static func checkCurrentLineThroughGutter(in document: DocumentWindow) throws {
        let editor = document.editor
        let scroll = document.scrollView
        let row = String(repeating: "long test line ", count: 24) + "\n"
        let starts = [0, 1] + (0..<80).map { 2 + $0 * row.utf16.count }
        editor.string = "\n\n" + String(repeating: row, count: 80)
        document.window.layoutIfNeeded()
        editor.setJJLineMarks([JJLineMark(kind: .insertion, lines: 0..<1)], lineStarts: starts)

        func pixel(x: CGFloat, at offset: Int) throws -> NSColor {
            guard let line = editor.lineBounds(at: offset) else { throw Failure("lay out the current line") }
            let sample = NSRect(x: scroll.safeAreaRect.minX + x, y: scroll.convert(line, from: editor).midY,
                                width: 1, height: 1)
            guard let color = try capture(scroll, in: sample).colorAt(x: 0, y: 0) else {
                throw Failure("sample the current-line background")
            }
            return color
        }

        for horizontalOffset: CGFloat in [0, 55] {
            for activeLine in [0, 1] {
                editor.setSelectedRange(NSRange(location: activeLine, length: 0))
                scroll.scrollToVisibleContentOrigin(NSPoint(x: horizontalOffset, y: 0))
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                editor.refreshCurrentLine()
                let active = try pixel(x: 25, at: activeLine)
                let inactive = try pixel(x: 25, at: 1 - activeLine)
                guard active != inactive, try pixel(x: 1, at: activeLine) == active,
                      try pixel(x: 1, at: 1 - activeLine) == inactive,
                      try pixel(x: 3, at: 0) != (activeLine == 0 ? active : inactive) else {
                    throw Failure("extend the current-line background through the gutter while keeping the marker visible")
                }
            }
        }
    }

    private static func checkGutterUnderTitlebar(in document: DocumentWindow) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        let row = String(repeating: "long test line ", count: 24) + "\n"
        let starts = (0..<80).map { $0 * row.utf16.count }
        let marker = JJLineMark(kind: .replacement, lines: 0..<6)
        editor.string = String(repeating: row, count: starts.count)
        window.layoutIfNeeded()
        scroll.scrollToVisibleContentOrigin(.zero)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard let splitLine = editor.lineBounds(at: starts[3]) else {
            throw Failure("lay out a changed range that can scroll under the titlebar")
        }

        let gutterX = scroll.safeAreaRect.minX + 3
        for horizontalOffset: CGFloat in [0, 55] {
            editor.setJJLineMarks([])
            scroll.scrollToVisibleContentOrigin(NSPoint(x: horizontalOffset, y: splitLine.minY))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            guard let covered = editor.lineBounds(at: starts[2]), let exposed = editor.lineBounds(at: starts[4]),
                  abs(scroll.visibleContentOrigin.x - horizontalOffset) < 1 else {
                throw Failure("scroll a changed range with the sidebars open")
            }
            let titlebarBottom = window.contentLayoutRect.maxY
            guard editor.convert(covered, to: nil).midY > titlebarBottom,
                  editor.convert(exposed, to: nil).midY < titlebarBottom else {
                throw Failure("straddle the titlebar edge with the marked text")
            }
            let documentX = editor.convert(NSPoint(x: gutterX, y: 0), from: scroll).x
            let samples = [covered, exposed].map { NSRect(x: documentX, y: $0.midY, width: 1, height: 1) }
            let barePixels = try samples.map { try capture(editor, in: $0).colorAt(x: 0, y: 0) }
            editor.setJJLineMarks([marker], lineStarts: starts)
            for (sample, barePixel) in zip(samples, barePixels) {
                guard let barePixel, let painted = try capture(editor, in: sample).colorAt(x: 0, y: 0),
                      painted != barePixel else {
                    throw Failure("paint the same document gutter above and below the titlebar edge")
                }
            }
        }
    }

    private static func checkTrackAfterResize(in document: DocumentWindow) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        editor.setJJLineMarks([])
        editor.string = "one\ntwo\nthree\nfour\n"
        var frame = window.frame
        frame.size.width = 1120
        window.setFrame(frame, display: false)
        document.setFolder(FileManager.default.temporaryDirectory)
        document.toggleSidebarFocus(.worktree)
        scroll.scrollerStyle = .overlay
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let undockedEdge = scroll.safeAreaRect.maxX
        let mark = JJLineMark(kind: .insertion, lines: 1..<2)
        let starts = [0, 4, 8, 14]
        editor.setJJLineMarks([mark], lineStarts: starts)

        document.restoreTerminal(DocumentTerminalState(
            panel: TerminalPanelState(dock: .right, spaces: [], selectedSpace: nil, nextSpaceNumber: 1),
            sizes: TerminalDockSizes(), isVisible: true, wasFocused: false
        ))
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        func checkShortTrack(previousEdge: CGFloat) throws {
            let clip = scroll.contentView
            let rightEdge = scroll.safeAreaRect.maxX
            guard document.isTerminalDockedRight, let sidebar = document.documentSplitView.arrangedSubviews.last,
                  abs(scroll.convert(sidebar.bounds, from: sidebar).minX - rightEdge) < 2,
                  rightEdge + 100 < scroll.bounds.maxX, editor.frame.height <= clip.bounds.height else {
                throw Failure("put the scrollbar at the exposed edge of a split editor with a short document")
            }
            let width = NSScroller.scrollerWidth(for: scroll.verticalScroller?.controlSize ?? .regular, scrollerStyle: .overlay)
            let y = scroll.isFlipped ? clip.frame.minY + clip.frame.height * 0.375 : clip.frame.maxY - clip.frame.height * 0.375
            let edge = NSRect(x: rightEdge - width / 2, y: y, width: 1, height: 1)
            let oldEdge = edge.offsetBy(dx: previousEdge - rightEdge, dy: 0)
            let paintedEdge = try capture(scroll, in: edge).colorAt(x: 0, y: 0)
            let paintedBody = try capture(scroll, in: oldEdge).colorAt(x: 0, y: 0)
            editor.setJJLineMarks([])
            guard let paintedEdge, let paintedBody,
                  try capture(scroll, in: edge).colorAt(x: 0, y: 0) != paintedEdge,
                  try capture(scroll, in: oldEdge).colorAt(x: 0, y: 0) == paintedBody else {
                throw Failure("paint a short document's marks at the exposed edge after the split changes")
            }
        }
        try checkShortTrack(previousEdge: undockedEdge)
        let dockedEdge = scroll.safeAreaRect.maxX
        editor.setJJLineMarks([mark], lineStarts: starts)
        frame.size.width += 250
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard scroll.safeAreaRect.maxX > dockedEdge + 100 else {
            throw Failure("resize the exposed editor pane beside Terminal")
        }
        try checkShortTrack(previousEdge: dockedEdge)

        let row = "A long line for the scrollbar check.\n"
        editor.string = String(repeating: row, count: 240)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        scroll.scrollToVisibleContentOrigin(.zero)
        scroll.flashScrollers()
        guard let scroller = scroll.verticalScroller else { throw Failure("show the overlay scrollbar beside Terminal") }
        let slot = scroller.rect(for: .knobSlot)
        let knob = scroller.rect(for: .knob)
        let fraction = 0.75
        let markY = scroller.isFlipped ? slot.minY + slot.height * fraction : slot.maxY - slot.height * fraction
        let point = NSPoint(x: slot.midX, y: markY)
        guard slot.contains(point), !knob.contains(point) else {
            throw Failure("sample the overlay track outside its thumb")
        }
        let origin = scroll.convert(point, from: scroller)
        let probe = NSRect(x: origin.x, y: origin.y, width: 1, height: 1)
        let bareTrack = try capture(scroll, in: probe).colorAt(x: 0, y: 0)
        editor.setJJLineMarks([JJLineMark(kind: .insertion, lines: 174..<186)],
                             lineStarts: (0..<240).map { $0 * row.utf16.count })
        guard let bareTrack, let paintedTrack = try capture(scroll, in: probe).colorAt(x: 0, y: 0),
              paintedTrack != bareTrack else {
            throw Failure("paint an offscreen change through the visible overlay scroller beside Terminal")
        }
    }

    private static func editorBodyPaint(in scroll: NSScrollView) throws -> [NSColor] {
        let bitmap = try capture(scroll, in: scroll.bounds)
        return try [2, 3, 4].map { row in
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * row / 6) else {
                throw Failure("sample the rendered editor body")
            }
            return color
        }
    }

    private static func capture(_ view: NSView, in rect: NSRect) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw Failure("capture the editor")
        }
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }
}
