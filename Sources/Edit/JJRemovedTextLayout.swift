import AppKit

/// Lays out removed text without creating a separate view. All drawing and hit testing
/// use local coordinates that the editor translates to the removed block's document origin.
@MainActor
final class JJRemovedTextLayout {
    private struct Row {
        let range: NSRange
        let fragment: NSTextLayoutFragment
        let line: NSTextLineFragment
        let top: CGFloat

        var nativeTop: CGFloat { fragment.layoutFragmentFrame.minY + line.typographicBounds.minY }
        var verticalOffset: CGFloat { top - nativeTop }
    }

    private let content = NSTextContentStorage()
    private let manager = NSTextLayoutManager()
    private let text: NSString
    private let highlights: [NSRange]
    private let lineHeight: CGFloat
    // The final end offset is a sentinel, never an extra visible row.
    private let rowStarts: [Int]

    init(hunk: JJDiffHunk, font: NSFont, paragraph: NSParagraphStyle, padding: CGFloat) {
        text = hunk.removedText as NSString
        highlights = hunk.removedHighlights
        lineHeight = max(1, paragraph.minimumLineHeight)
        var starts = [0]
        while let start = starts.last, start < text.length {
            starts.append(NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))))
        }
        rowStarts = starts

        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: unbounded, height: unbounded))
        container.lineFragmentPadding = padding
        manager.textContainer = container
        content.addTextLayoutManager(manager)
        content.performEditingTransaction {
            content.textStorage?.setAttributedString(NSAttributedString(string: hunk.removedText, attributes: [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor,
            ]))
        }
    }

    func draw(at origin: NSPoint, dirtyRect: NSRect, in context: CGContext,
              selection: NSRange?, selectionIsActive: Bool) {
        guard rowStarts.count > 1,
              dirtyRect.maxY > origin.y, dirtyRect.minY < origin.y + CGFloat(rowStarts.count - 1) * lineHeight else { return }
        let first = rowIndex(at: dirtyRect.minY - origin.y)
        let last = rowIndex(at: dirtyRect.maxY - origin.y)
        let visible = NSRange(location: rowStarts[first], length: rowStarts[last + 1] - rowStarts[first])
        let visibleHighlights = highlights.filter { NSIntersectionRange($0, visible).length > 0 }
        let selectionColor = selectionIsActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)

        for index in first...last {
            guard let row = row(at: index) else { continue }
            context.setFillColor(NSColor.systemRed.withAlphaComponent(0.36).cgColor)
            for highlight in visibleHighlights {
                fill(highlight, in: row, at: origin, type: .standard, context: context)
            }
            if let selection {
                context.setFillColor(selectionColor.cgColor)
                fill(selection, in: row, at: origin, type: .selection, context: context)
            }
            row.line.draw(at: NSPoint(x: origin.x + row.fragment.layoutFragmentFrame.minX + row.line.typographicBounds.minX,
                                      y: origin.y + row.top), in: context)
        }
    }

    func insertionOffset(at point: NSPoint) -> Int {
        guard rowStarts.count > 1, let row = row(at: rowIndex(at: point.y)) else { return 0 }
        let top = row.nativeTop
        let localY = max(0, min(lineHeight - 0.5, point.y - row.top))
        let location = NSPoint(x: point.x, y: top + localY)
        let left = min(0, point.x)
        let right = max(row.fragment.layoutFragmentFrame.maxX, point.x, 0)
        let bounds = NSRect(x: left, y: top, width: right - left + 1, height: lineHeight)
        let documentStart = manager.documentRange.location
        let selections = manager.textSelectionNavigation.textSelections(
            interactingAt: location, inContainerAt: documentStart, anchors: [], modifiers: [], selecting: false, bounds: bounds
        )
        guard let insertion = selections.first?.textRanges.first?.location else { return row.range.location }
        let offset = manager.offset(from: documentStart, to: insertion)
        let end = LineEditing.line(at: row.range.location, in: text).contentEnd
        return min(max(row.range.location, offset), end)
    }

    func caretRect(at offset: Int) -> NSRect? {
        guard rowStarts.count > 1 else { return nil }
        let offset = max(0, min(offset, text.length))
        // A final separator produces an extra native insertion line. The removed block ends
        // with the caret on its last visible row instead.
        let location = offset == text.length ? LineEditing.line(at: offset - 1, in: text).contentEnd : offset
        guard let row = row(at: rowIndex(containing: location)),
              let range = textRange(NSRange(location: location, length: 0)) else { return nil }
        var caret: NSRect?
        manager.enumerateTextSegments(in: range, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
            caret = rect.offsetBy(dx: 0, dy: row.verticalOffset)
            return false
        }
        return caret
    }

    private func fill(_ range: NSRange, in row: Row, at origin: NSPoint,
                      type: NSTextLayoutManager.SegmentType, context: CGContext) {
        let intersection = NSIntersectionRange(range, row.range)
        guard intersection.length > 0, let selected = textRange(intersection) else { return }
        manager.enumerateTextSegments(in: selected, type: type, options: .rangeNotRequired) { _, rect, _, _ in
            let visible = rect.offsetBy(dx: origin.x, dy: origin.y + row.verticalOffset)
                .intersection(context.boundingBoxOfClipPath)
            if !visible.isEmpty { context.fill(visible) }
            return true
        }
    }

    private func rowIndex(at y: CGFloat) -> Int {
        guard y.isFinite else { return 0 }
        return Int(max(0, min(CGFloat(rowStarts.count - 2), floor(y / lineHeight))))
    }

    private func rowIndex(containing offset: Int) -> Int {
        var lower = 0
        var upper = rowStarts.count - 1
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if rowStarts[middle] <= offset { lower = middle }
            else { upper = middle }
        }
        return lower
    }

    private func row(at index: Int) -> Row? {
        let start = rowStarts[index]
        let range = NSRange(location: start, length: rowStarts[index + 1] - start)
        guard let nativeRange = textRange(range) else { return nil }
        manager.ensureLayout(for: nativeRange)
        guard let fragment = manager.textLayoutFragment(for: nativeRange.location),
              let line = fragment.textLineFragment(for: nativeRange.location, isUpstreamAffinity: false) else { return nil }
        return Row(range: range, fragment: fragment, line: line, top: CGFloat(index) * lineHeight)
    }

    private func textRange(_ range: NSRange) -> NSTextRange? {
        let start = manager.documentRange.location
        guard let lower = manager.location(start, offsetBy: range.location),
              let upper = manager.location(lower, offsetBy: range.length) else { return nil }
        return NSTextRange(location: lower, end: upper)
    }
}
