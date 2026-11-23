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
