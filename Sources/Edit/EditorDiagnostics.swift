import AppKit
import CoreText

struct EditorDiagnosticHover: Equatable {
    let anchor: NSRect
    let text: String
}

extension EditorTextView {
    private static let diagnosticGap: CGFloat = 10
    private static let diagnosticInset: CGFloat = 7
    private static let diagnosticIconGap: CGFloat = 5
    private static let diagnosticTrailingSpace: CGFloat = 8

    func rebuildDiagnosticMessages() {
        let font = font ?? Self.defaultFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        func textLine(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        diagnosticMessagesByLineEnd = Dictionary(grouping: diagnostics, by: \.lineEnd).compactMapValues { errors in
            let messages = diagnosticMessages(errors)
            guard let first = messages.first else { return nil }
            let summary = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return DiagnosticMessage(text: messages.joined(separator: "\n\n"),
                                     line: textLine(summary),
                                     countLine: messages.count > 1 ? textLine(String(messages.count)) : nil)
        }
        updateDiagnosticWidth()
    }

    func updateDiagnosticWidth() {
        var width: CGFloat = 0
        if !wrapsWords, !diagnosticMessagesByLineEnd.isEmpty, let source = textStorage?.mutableString {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? Self.defaultFont, .paragraphStyle: defaultParagraphStyle ?? .default
            ]
            for (end, message) in diagnosticMessagesByLineEnd where end <= source.length {
                let start = LineEditing.line(at: end, in: source).start
                let code = source.substring(with: NSRange(location: start, length: end - start)) as NSString
                let textEnd = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
                    + code.size(withAttributes: attributes).width
                width = max(width, textEnd + Self.diagnosticGap + messageWidth(message) + Self.diagnosticTrailingSpace)
            }
        }
        let minimum = ceil(width)
        let previous = diagnosticMinimumWidth
        guard previous != minimum else { return }
        diagnosticMinimumWidth = minimum
        if frame.width < minimum {
            setFrameSize(NSSize(width: minimum, height: frame.height))
        } else if !wrapsWords, minimum < previous, frame.width <= previous,
                  let scroll = enclosingScrollView, let layout = textLayoutManager {
            let textWidth = ceil(layout.usageBoundsForTextContainer.maxX + 2 * textContainerOrigin.x)
            let width = max(scroll.contentSize.width, textWidth, minimum)
            if width < frame.width { setFrameSize(NSSize(width: width, height: frame.height)) }
        }
        needsDisplay = true
    }

    struct DiagnosticMessage {
        let text: String
        let line: CTLine
        let countLine: CTLine?
    }

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
        let message: DiagnosticMessage
    }

    private func diagnosticRows(in visible: NSRange) -> [DiagnosticRow] {
        diagnosticMessagesByLineEnd.compactMap { end, message in
            guard end >= visible.location, end <= visible.upperBound,
                  let row = laidOutLineBounds(at: end) else { return nil }
            return DiagnosticRow(bounds: row, message: message)
        }
    }

    private var diagnosticIconSize: CGFloat { max(6, ((font ?? Self.defaultFont).pointSize * 0.9).rounded()) }

    private func diagnosticIconOffset(for message: DiagnosticMessage) -> CGFloat {
        guard let count = message.countLine else { return Self.diagnosticInset }
        return Self.diagnosticInset + ceil(CTLineGetTypographicBounds(count, nil, nil, nil)) + Self.diagnosticIconGap
    }

    private func diagnosticTextOffset(for message: DiagnosticMessage) -> CGFloat {
        diagnosticIconOffset(for: message) + diagnosticIconSize + Self.diagnosticIconGap
    }

    private func messageWidth(_ message: DiagnosticMessage) -> CGFloat {
        ceil(CTLineGetTypographicBounds(message.line, nil, nil, nil)) + diagnosticTextOffset(for: message) + Self.diagnosticInset
    }

    private func messageFrame(for row: DiagnosticRow) -> NSRect {
        let x = row.bounds.maxX + Self.diagnosticGap
        let naturalWidth = messageWidth(row.message)
        // In wrap mode the text view already tracks the unobscured editor width.
        let width = wrapsWords ? min(naturalWidth, bounds.maxX - Self.diagnosticTrailingSpace - x) : naturalWidth
        guard width >= diagnosticTextOffset(for: row.message) + 2 * Self.diagnosticInset else { return .zero }
        return NSRect(x: x, y: row.bounds.minY, width: width, height: row.bounds.height)
    }

    private func diagnosticMessages(_ errors: [LSPError]) -> [String] {
        errors.map(\.message).filter { $0.contains { !$0.isWhitespace } }
    }

    func diagnosticHover(at point: NSPoint) -> EditorDiagnosticHover? {
        guard let visible = diagnosticViewport else { return nil }
        if let row = diagnosticRows(in: visible).first(where: { $0.bounds.minY <= point.y && point.y < $0.bounds.maxY }) {
            let message = messageFrame(for: row).intersection(visibleRect)
            let anchor = !message.isEmpty
                ? NSRect(x: message.minX + min(7, message.width / 2), y: message.minY, width: 1, height: message.height)
                : row.bounds
            let clipped = anchor.intersection(visibleRect)
            if !clipped.isEmpty { return EditorDiagnosticHover(anchor: clipped, text: row.message.text) }
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
        let color = NSColor.systemRed
        let iconSize = diagnosticIconSize
        let icon = NSImage(systemSymbolName: "exclamationmark.octagon", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)
                .applying(.init(paletteColors: [.labelColor])))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for row in diagnosticRows(in: visible) where row.bounds.minY < clip.maxY && row.bounds.maxY > clip.minY {
            let band = NSRect(x: clip.minX, y: row.bounds.minY, width: clip.width, height: row.bounds.height)
            color.withAlphaComponent(0.10).setFill()
            band.intersection(clip).fill()

            let area = messageFrame(for: row)
            guard area.intersects(clip) else { continue }
            let background = area.insetBy(dx: 0, dy: 1)
            color.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
            let iconRect = NSRect(x: area.minX + diagnosticIconOffset(for: row.message), y: area.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

            let textOffset = diagnosticTextOffset(for: row.message)
            let available = area.width - textOffset - Self.diagnosticInset
            let line = row.message.line
            let displayed: CTLine
            if wrapsWords, messageWidth(row.message) > area.width {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                    .font: font ?? Self.defaultFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
                ]))
                displayed = CTLineCreateTruncatedLine(line, available, .end, token) ?? token
            } else {
                displayed = line
            }
            let textClip = clip.intersection(background)
            if let count = row.message.countLine {
                drawDiagnosticLine(count, x: area.minX + Self.diagnosticInset, midY: area.midY, clip: textClip, in: context)
            }
            drawDiagnosticLine(displayed, x: area.minX + textOffset, midY: area.midY, clip: textClip, in: context)
        }
    }

    private func drawDiagnosticLine(_ line: CTLine, x: CGFloat, midY: CGFloat, clip: NSRect, in context: CGContext) {
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.clip(to: clip)
        context.translateBy(x: x, y: midY + (ink.midY.isFinite ? ink.midY : 0))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setFillColor(NSColor.labelColor.cgColor)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    func drawDiagnostics(in dirtyRect: NSRect) {
        guard let visible = diagnosticViewport else { return }
        let clip = dirtyRect.intersection(bounds)
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
