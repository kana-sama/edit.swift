import AppKit

struct EditorTextRows {
    let range: NSRange
    let starts: [Int]

    init(in text: NSString, range: NSRange, includingTrailingLine: Bool = false) {
        self.range = range
        var starts: [Int] = []
        var offset = range.location
        while offset < NSMaxRange(range) {
            starts.append(offset)
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
        }
        if includingTrailingLine && (range.length == 0 ||
            text.substring(with: range).last?.isNewline == true) {
            starts.append(NSMaxRange(range))
        }
        self.starts = starts
    }

    private init(range: NSRange, starts: [Int]) {
        self.range = range
        self.starts = starts
    }

    func shifted(by offset: Int) -> Self {
        Self(range: NSRange(location: range.location + offset, length: range.length), starts: starts.map { $0 + offset })
    }

    var count: Int { starts.count }

    func range(at row: Int) -> NSRange {
        let start = starts[row]
        let end = row + 1 < starts.count ? starts[row + 1] : NSMaxRange(range)
        return NSRange(location: start, length: end - start)
    }

    func index(containing offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset { lower = middle }
            else { upper = middle }
        }
        return lower
    }
}

/// TextKit geometry for read-only rows drawn inside the editor.
@MainActor
final class EditorProjectedTextLayout {
    struct Style: Equatable {
        let font: NSFont
        let paragraph: NSParagraphStyle
        let padding: CGFloat

        @MainActor init(editor: EditorTextView) {
            font = editor.font ?? EditorTextView.defaultFont
            paragraph = editor.defaultParagraphStyle ?? .default
            padding = editor.textContainer?.lineFragmentPadding ?? 0
        }

        var lineHeight: CGFloat { max(1, paragraph.minimumLineHeight) }
    }

    private struct Row {
        let range: NSRange
        let fragment: NSTextLayoutFragment
        let line: NSTextLineFragment
        let top: CGFloat

        var nativeTop: CGFloat { fragment.layoutFragmentFrame.minY + line.typographicBounds.minY }
        var verticalOffset: CGFloat { top - nativeTop }
    }

    private let content = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    let style: Style
    private let text: NSString
    private var lineHeight: CGFloat { style.lineHeight }

    init(text: String, style: Style) {
        self.text = text as NSString
        self.style = style
        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: unbounded, height: unbounded))
        container.lineFragmentPadding = style.padding
        manager.textContainer = container
        content.addTextLayoutManager(manager)
        manager.textSelectionNavigation = EditorWordNavigation(dataSource: manager)
        content.performEditingTransaction {
            content.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: style.font, .paragraphStyle: style.paragraph, .foregroundColor: NSColor.textColor,
            ]))
        }
    }

    func draw(_ rows: EditorTextRows, at origin: NSPoint, dirtyRect: NSRect, in context: CGContext,
              highlights: [NSRange], highlightColor: NSColor, selection: NSRange? = nil,
              selectionIsActive: Bool = false) {
        guard rows.count > 0, dirtyRect.maxY > origin.y,
              dirtyRect.minY < origin.y + CGFloat(rows.count) * lineHeight else { return }
        let first = rowIndex(at: dirtyRect.minY - origin.y, in: rows)
        let last = rowIndex(at: dirtyRect.maxY - origin.y, in: rows)
        let visible = NSUnionRange(rows.range(at: first), rows.range(at: last))
        let visibleHighlights = highlights.filter { NSIntersectionRange($0, visible).length > 0 }
        let selectionColor = selectionIsActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)

        for index in first...last {
            guard let row = row(at: index, in: rows) else { continue }
            context.setFillColor(highlightColor.cgColor)
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

    func insertionOffset(at point: NSPoint, in rows: EditorTextRows) -> Int {
        guard rows.count > 0, let row = row(at: rowIndex(at: point.y, in: rows), in: rows) else { return rows.range.location }
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

    func caretRect(at offset: Int, in rows: EditorTextRows) -> NSRect? {
        guard rows.count > 0 else { return nil }
        let offset = max(rows.range.location, min(offset, NSMaxRange(rows.range)))
        // A final separator produces a native insertion line after the displayed block.
        let location = offset == NSMaxRange(rows.range) && rows.range.length > 0
            ? min(offset, LineEditing.line(at: offset - 1, in: text).contentEnd) : offset
        guard let row = row(at: rows.index(containing: location), in: rows),
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

    private func rowIndex(at y: CGFloat, in rows: EditorTextRows) -> Int {
        guard y.isFinite else { return 0 }
        return Int(max(0, min(CGFloat(rows.count - 1), floor(y / lineHeight))))
    }

    private func row(at index: Int, in rows: EditorTextRows) -> Row? {
        let range = rows.range(at: index)
        guard range.length > 0 else { return nil }
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
