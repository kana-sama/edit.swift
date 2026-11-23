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
        editor.insertText("edited ", replacementRange: selection)
        guard editor.jjLineMarks.isEmpty else { throw Failure("edits clear markers awaiting a new diff") }
    }

    private static func editorBodyPaint(in scroll: NSScrollView) throws -> [NSColor] {
        let bounds = scroll.bounds
        guard let bitmap = scroll.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw Failure("capture the editor with and without markers")
        }
        scroll.cacheDisplay(in: bounds, to: bitmap)
        return try [2, 3, 4].map { row in
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * row / 6) else {
                throw Failure("sample the rendered editor body")
            }
            return color
        }
    }
}
