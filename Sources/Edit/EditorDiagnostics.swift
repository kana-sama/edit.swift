import AppKit

struct EditorDiagnosticHover: Equatable {
    let anchor: NSRect
    let text: String
}

extension EditorTextView {
    private var diagnosticViewport: NSRange? {
        guard !diagnostics.isEmpty, renameRange == nil, !hasMarkedText(), conflictEdits.isEmpty,
              let manager = textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        return charRange(viewport, in: manager)
    }

    var diagnosticRanges: [NSRange] { diagnostics.map(\.range) }

    func diagnosticRects() -> [NSRect] {
        guard let visible = diagnosticViewport else { return [] }
        return diagnosticRects(for: diagnosticRanges, in: visible)
    }

    private func diagnosticRects(for ranges: [NSRange], in visible: NSRange) -> [NSRect] {
        var rects = highlightRects(for: ranges)
        if let window {
            for range in ranges where range.length == 0 && range.location >= visible.location
                && range.location <= visible.upperBound {
                let screen = firstRect(forCharacterRange: range, actualRange: nil)
                guard screen.height > 0 else { continue }
                let caret = convert(window.convertFromScreen(screen), from: nil)
                rects.append(NSRect(x: caret.minX, y: caret.minY, width: 6, height: caret.height))
            }
        }
        return rects
    }

    private struct DiagnosticRow {
        let bounds: NSRect
        let messages: [String]

        func messageFrame(in viewport: NSRect) -> NSRect {
            let x = bounds.maxX + 10
            let width = viewport.maxX - 8 - x
            guard width >= 28 else { return .zero }
            return NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    private func diagnosticRows(in visible: NSRange) -> [DiagnosticRow] {
        let rows = Dictionary(grouping: diagnostics.filter {
            $0.lineEnd >= visible.location && $0.lineEnd <= visible.upperBound
        }, by: \.lineEnd)
        return rows.compactMap { end, errors in
            guard let row = laidOutLineBounds(at: end), row.maxY > visibleRect.minY, row.minY < visibleRect.maxY else { return nil }
            let messages = diagnosticMessages(errors)
            return messages.isEmpty ? nil : DiagnosticRow(bounds: row, messages: messages)
        }
    }

    private func diagnosticMessages(_ errors: [LSPError]) -> [String] {
        var seen: Set<String> = []
        return errors.map(\.message).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func diagnosticHover(at point: NSPoint) -> EditorDiagnosticHover? {
        guard let visible = diagnosticViewport else { return nil }
        if let row = diagnosticRows(in: visible).first(where: { $0.bounds.minY <= point.y && point.y < $0.bounds.maxY }) {
            let message = row.messageFrame(in: visibleRect).intersection(visibleRect)
            let anchor = !message.isEmpty
                ? NSRect(x: message.minX + min(7, message.width / 2), y: message.minY, width: 1, height: message.height)
                : row.bounds
            let clipped = anchor.intersection(visibleRect)
            if !clipped.isEmpty { return EditorDiagnosticHover(anchor: clipped, text: row.messages.joined(separator: "\n\n")) }
        }
        // An underline can be on an earlier wrapped row or span several source lines.
        let matching = diagnostics.compactMap { error -> (LSPError, NSRect)? in
            guard let rect = diagnosticRects(for: [error.range], in: visible).first(where: {
                $0.minY <= point.y && point.y < $0.maxY && $0.intersects(visibleRect)
            }) else { return nil }
            return (error, rect)
        }
        let messages = diagnosticMessages(matching.map(\.0))
        guard let anchor = matching.first?.1, !messages.isEmpty else { return nil }
        return EditorDiagnosticHover(anchor: anchor.intersection(visibleRect), text: messages.joined(separator: "\n\n"))
    }

    private func drawDiagnosticMessages(in clip: NSRect, visible: NSRange) {
        let paragraph = defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let messageFont = font ?? Self.defaultFont
        let color = NSColor.systemRed
        let attributes: [NSAttributedString.Key: Any] = [
            .font: messageFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        for row in diagnosticRows(in: visible) {
            let band = NSRect(x: clip.minX, y: row.bounds.minY, width: clip.width, height: row.bounds.height)
            color.withAlphaComponent(0.10).setFill()
            band.intersection(clip).fill()

            let area = row.messageFrame(in: visibleRect)
            guard area.intersects(clip) else { continue }
            let message = row.messages.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .joined(separator: "  ·  ")
            let background = area.insetBy(dx: 0, dy: 1)
            color.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
            let textBounds = area.insetBy(dx: 7, dy: 0)
            (message as NSString).draw(with: textBounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes)
        }
    }

    func drawDiagnostics(in dirtyRect: NSRect) {
        guard let visible = diagnosticViewport else { return }
        let clip = dirtyRect.intersection(visibleRect)
        guard !clip.isEmpty else { return }
        drawDiagnosticMessages(in: clip, visible: visible)
        let rects = diagnosticRects(for: diagnosticRanges, in: visible)
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
