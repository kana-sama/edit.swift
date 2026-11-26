import AppKit

extension EditorTextView {
    func diagnosticRects() -> [NSRect] {
        guard !diagnosticRanges.isEmpty, renameRange == nil, !hasMarkedText(), conflictEdits.isEmpty,
              let manager = textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        let visible = charRange(viewport, in: manager)
        var rects = highlightRects(for: diagnosticRanges)
        if let window {
            for range in diagnosticRanges where range.length == 0 && range.location >= visible.location
                && range.location <= visible.upperBound {
                let screen = firstRect(forCharacterRange: range, actualRange: nil)
                guard screen.height > 0 else { continue }
                let caret = convert(window.convertFromScreen(screen), from: nil)
                rects.append(NSRect(x: caret.minX, y: caret.minY, width: 6, height: caret.height))
            }
        }
        return rects
    }

    func drawDiagnostics(in dirtyRect: NSRect) {
        let clip = dirtyRect.intersection(visibleRect)
        guard !clip.isEmpty else { return }
        let rects = diagnosticRects()
        guard !rects.isEmpty else { return }
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineJoinStyle = .round
        let step: CGFloat = 2
        for rect in rects where rect.intersects(clip) {
            let firstStep = max(0, floor((clip.minX - rect.minX) / step))
            var x = rect.minX + firstStep * step
            let end = min(rect.maxX, clip.maxX + step)
            let baseline = rect.maxY - 2
            var rising = firstStep.truncatingRemainder(dividingBy: 2) == 0
            var y = baseline + (rising ? 1 : -1)
            path.move(to: NSPoint(x: x, y: y))
            while x < end {
                let width = min(step, end - x)
                x += width
                y += rising ? -width : width
                path.line(to: NSPoint(x: x, y: y))
                rising.toggle()
            }
        }
        path.stroke()
    }
}
