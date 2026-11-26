import AppKit
import CoreText

struct EditorDiagnosticHover: Equatable {
    let anchor: NSRect
    let messages: [String]
}

extension EditorTextView {
    private static let diagnosticTrailingSpace: CGFloat = 8

    private var diagnosticGap: CGFloat {
        ("0000" as NSString).size(withAttributes: [.font: font ?? Self.defaultFont]).width
    }

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
            let suffix = messages.count > 1 ? "  +\(messages.count - 1)" : ""
            return DiagnosticMessage(messages: messages, line: textLine(summary + suffix), truncation: textLine("…" + suffix))
        }
        updateDiagnosticWidth()
    }

    func updateDiagnosticWidth() {
        var width: CGFloat = 0
        if !wrapsWords, !diagnosticMessagesByLineEnd.isEmpty, let source = textStorage?.mutableString {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? Self.defaultFont, .paragraphStyle: defaultParagraphStyle ?? .default
            ]
            let gap = diagnosticGap
            for (end, message) in diagnosticMessagesByLineEnd where end <= source.length {
                let start = LineEditing.line(at: end, in: source).start
                let code = source.substring(with: NSRange(location: start, length: end - start)) as NSString
                let textEnd = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
                    + code.size(withAttributes: attributes).width
                width = max(width, textEnd + gap + messageWidth(message) + Self.diagnosticTrailingSpace)
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
        let messages: [String]
        let line: CTLine
        let truncation: CTLine
    }

    private var diagnosticViewport: NSRange? {
        guard !diagnostics.isEmpty, renameRange == nil, !hasMarkedText(), conflictEdits.isEmpty,
              let manager = textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        return charRange(viewport, in: manager)
    }

    var diagnosticRanges: [NSRange] { diagnostics.map(\.displayRange) }

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

    private func messageWidth(_ message: DiagnosticMessage) -> CGFloat {
        ceil(CTLineGetTypographicBounds(message.line, nil, nil, nil))
    }

    private func messageFrame(for row: DiagnosticRow) -> NSRect {
        let gap = diagnosticGap
        let x = row.bounds.maxX + gap
        let naturalWidth = messageWidth(row.message)
        // In wrap mode the text view already tracks the unobscured editor width.
        let width = wrapsWords ? min(naturalWidth, bounds.maxX - Self.diagnosticTrailingSpace - x) : naturalWidth
        let tokenWidth = ceil(CTLineGetTypographicBounds(row.message.truncation, nil, nil, nil))
        guard width > 0, width == naturalWidth || width >= max(gap, tokenWidth) else { return .zero }
        return NSRect(x: x, y: row.bounds.minY, width: width, height: row.bounds.height)
    }

    private func diagnosticMessages(_ errors: [LSPError]) -> [String] {
        errors.map(\.message).filter { $0.contains { !$0.isWhitespace } }
    }

    func diagnosticHover(at point: NSPoint) -> EditorDiagnosticHover? {
        guard visibleRect.contains(point), let visible = diagnosticViewport else { return nil }
        for row in diagnosticRows(in: visible) where row.bounds.minY <= point.y && point.y < row.bounds.maxY {
            let lens = messageFrame(for: row).intersection(visibleRect)
            if lens.contains(point) {
                let anchor = NSRect(x: lens.minX + min(7, lens.width / 2), y: lens.minY, width: 1, height: lens.height)
                return EditorDiagnosticHover(anchor: anchor, messages: row.message.messages)
            }
        }

        // A narrower underline identifies the more specific error when ranges overlap.
        var match: (error: LSPError, anchor: NSRect)?
        for error in diagnostics {
            let range = error.displayRange
            guard range.location <= visible.upperBound, range.upperBound >= visible.location,
                  range.length < (match?.error.displayRange.length ?? Int.max),
                  error.message.contains(where: { !$0.isWhitespace }),
                  let rect = diagnosticRects(for: [range], in: visible).first(where: { $0.contains(point) }) else { continue }
            match = (error, rect)
        }
        guard let match else { return nil }
        return EditorDiagnosticHover(anchor: match.anchor.intersection(visibleRect), messages: [match.error.message])
    }

    private var usesDarkDiagnosticColors: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func drawDiagnosticBackground(in clip: NSRect) {
        guard let visible = diagnosticViewport, !clip.isEmpty else { return }
        let lineTint = NSColor(srgbRed: 228 / 255, green: 84 / 255, blue: 84 / 255,
                               alpha: (usesDarkDiagnosticColors ? 27 : 32) / 255)
        lineTint.setFill()
        for row in diagnosticRows(in: visible) where row.bounds.minY < clip.maxY && row.bounds.maxY > clip.minY {
            let band = NSRect(x: clip.minX, y: row.bounds.minY, width: clip.width, height: row.bounds.height)
            band.intersection(clip).fill()
        }
    }

    private func drawDiagnosticMessages(in clip: NSRect, visible: NSRange) {
        // Dark uses Error Lens's foreground. Use a deeper red against the tinted light background.
        let foreground = usesDarkDiagnosticColors
            ? NSColor(srgbRed: 1, green: 100 / 255, blue: 100 / 255, alpha: 1)
            : NSColor(srgbRed: 174 / 255, green: 49 / 255, blue: 49 / 255, alpha: 1)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for row in diagnosticRows(in: visible) where row.bounds.minY < clip.maxY && row.bounds.maxY > clip.minY {
            let area = messageFrame(for: row)
            guard area.intersects(clip) else { continue }
            let line = row.message.line
            let displayed: CTLine
            if wrapsWords, messageWidth(row.message) > area.width {
                let token = row.message.truncation
                displayed = CTLineCreateTruncatedLine(line, area.width, .end, token) ?? token
            } else {
                displayed = line
            }
            let ink = CTLineGetBoundsWithOptions(displayed, .useGlyphPathBounds)
            context.saveGState()
            context.clip(to: clip.intersection(area))
            context.translateBy(x: area.minX, y: area.midY + (ink.midY.isFinite ? ink.midY : 0))
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            context.setFillColor(foreground.cgColor)
            CTLineDraw(displayed, context)
            context.restoreGState()
        }
    }

    func drawDiagnosticForeground(in dirtyRect: NSRect) {
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
