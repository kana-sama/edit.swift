import AppKit

@MainActor
final class FindDecorations {
    private struct PreviewRows {
        let text: String
        let rows: EditorTextRows
        let layout: EditorProjectedTextLayout
    }

    private weak var editor: EditorTextView?
    private var ranges: [NSRange] = []
    private var selected: NSRange?
    private var preview: (NSRange, String)?
    private var snapshot = ""
    private var matchRects: [NSRect] = []
    private var activeRects: [NSRect] = []
    private var previewAccessibility: NSView?
    private var proposedRows: PreviewRows?
    private var sourceBands: [NSRect] = []
    private var sourceChanges: [NSRect] = []
    private var proposedBand: NSRect?
    private var proposedChange = NSRange()
    private var previewSourceRange: NSRange?
    private var layingOut = false

    init(editor: EditorTextView) {
        self.editor = editor
        editor.onDrawFindHighlights = { [weak self] dirtyRect in self?.drawHighlights(in: dirtyRect) }
    }

    func update(snapshot: String, ranges: [NSRange], selected: NSRange?, preview: (NSRange, String)?) {
        self.snapshot = snapshot
        self.ranges = ranges
        self.selected = selected
        self.preview = preview
        layout()
    }

    func layout() {
        guard let editor, let manager = editor.textLayoutManager, !layingOut else { return }
        layingOut = true
        defer { layingOut = false }

        if (ranges.isEmpty && selected == nil && preview == nil) || editor.string != snapshot {
            setHighlightRects(matches: [], active: [], in: editor)
            clearPreview()
            return
        }

        updatePreview(in: editor)
        guard let viewport = manager.textViewportLayoutController.viewportRange else {
            setHighlightRects(matches: [], active: [], in: editor)
            return
        }
        let visible = editor.charRange(viewport, in: manager)
        guard visible.location >= 0, visible.location != NSNotFound, visible.length > 0 else {
            setHighlightRects(matches: [], active: [], in: editor)
            return
        }

        // Use TextKit's segment geometry while drawing the search background independently of syntax attributes.
        let origin = editor.textContainerOrigin
        func rects(for range: NSRange) -> [NSRect] {
            let intersection = NSIntersectionRange(visible, range)
            guard intersection.length > 0, let segment = editor.textRange(intersection, in: manager) else { return [] }
            var frames: [NSRect] = []
            manager.enumerateTextSegments(in: segment, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                if !frame.isEmpty { frames.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
            return frames
        }

        var matchRects: [NSRect] = []
        var index = firstRangeEnding(after: visible.location)
        while index < ranges.count && ranges[index].location < NSMaxRange(visible) {
            let range = ranges[index]
            if range != selected && previewSourceRange.map({ NSIntersectionRange($0, range).length == 0 }) != false {
                matchRects.append(contentsOf: rects(for: range))
            }
            index += 1
        }
        let activeRects = previewSourceRange == nil ? selected.map { rects(for: $0) } ?? [] : []
        setHighlightRects(matches: matchRects, active: activeRects, in: editor)
    }

    private func setHighlightRects(matches: [NSRect], active: [NSRect], in editor: EditorTextView) {
        guard matches != matchRects || active != activeRects else { return }
        let previous = (matchRects + activeRects).reduce(NSRect.null) { $0.union($1) }
        let next = (matches + active).reduce(NSRect.null) { $0.union($1) }
        matchRects = matches
        activeRects = active
        if !previous.isNull { editor.setNeedsDisplay(previous) }
        if !next.isNull && previous != next { editor.setNeedsDisplay(next) }
    }

    private func drawHighlights(in dirtyRect: NSRect) {
        drawPreview(in: dirtyRect)
        if !matchRects.isEmpty {
            NSColor.systemYellow.withAlphaComponent(0.30).setFill()
            for rect in matchRects where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        }
        if !activeRects.isEmpty {
            NSColor.systemOrange.withAlphaComponent(0.55).setFill()
            for rect in activeRects where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        }
    }

    private func firstRangeEnding(after offset: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(ranges[middle]) <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func updatePreview(in editor: EditorTextView) {
        guard let (range, replacement) = preview, let manager = editor.textLayoutManager else {
            clearPreview()
            return
        }
        let source = snapshot as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length, source.length > 0 else {
            clearPreview()
            return
        }
        let start = LineEditing.line(at: range.location, in: source).start
        let last = LineEditing.line(at: max(range.location, NSMaxRange(range) - 1), in: source)
        let end = max(last.contentEnd, NSMaxRange(range))
        let live = NSRange(location: start, length: end - start)
        let old = source.substring(with: live)
        let added = (old as NSString).replacingCharacters(
            in: NSRange(location: range.location - start, length: range.length), with: replacement
        )
        let style = EditorProjectedTextLayout.Style(editor: editor)
        let proposed: PreviewRows
        if let cached = proposedRows, cached.text == added, cached.layout.style == style {
            proposed = cached
        } else {
            let text = added as NSString
            let rows = EditorTextRows(in: text, range: NSRange(location: 0, length: text.length), includingTrailingLine: true)
            proposed = PreviewRows(text: added, rows: rows, layout: EditorProjectedTextLayout(text: added, style: style))
            proposedRows = proposed
        }

        let paragraph = source.lineRange(for: NSRange(location: min(last.start, source.length - 1), length: 0)).location
        let atEmptyLastLine = last.start == source.length
        let height = CGFloat(proposed.rows.count + (atEmptyLastLine ? 1 : 0)) * style.lineHeight
        editor.layoutSpacing.set([.init(id: .replacement, paragraph: paragraph, edge: .after, height: height)], for: .find)
        let previous = previewBounds
        let viewport = manager.textViewportLayoutController.viewportRange.map { editor.charRange($0, in: manager) }
        let origin = editor.textContainerOrigin
        let visible = viewport.flatMap { range -> NSRange? in
            let known = NSIntersectionRange(NSRange(location: start, length: last.end - start), range)
            guard known.length > 0 else { return nil }
            return source.lineRange(for: known)
        }
        var bands: [NSRect] = []
        if let visible {
            var offset = max(start, visible.location)
            let limit = min(last.end, NSMaxRange(visible))
            while offset < limit {
                if let line = editor.laidOutLineBounds(at: offset) {
                    bands.append(NSRect(x: editor.bounds.minX, y: line.minY, width: editor.bounds.width, height: line.height))
                }
                offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            }
        }
        var changes: [NSRect] = []
        if let visible, let segment = editor.textRange(NSIntersectionRange(range, visible), in: manager),
           !segment.isEmpty {
            manager.enumerateTextSegments(in: segment, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                if !rect.isEmpty { changes.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        let reserved = editor.layoutSpacing.rect(for: .replacement)
        if atEmptyLastLine, let reserved {
            bands.append(NSRect(x: reserved.minX, y: reserved.minY, width: reserved.width, height: style.lineHeight))
            proposedBand = NSRect(x: reserved.minX, y: reserved.minY + style.lineHeight,
                                  width: reserved.width, height: reserved.height - style.lineHeight)
        } else {
            proposedBand = reserved
        }
        previewSourceRange = live
        sourceBands = bands
        sourceChanges = changes
        proposedChange = NSRange(location: range.location - start, length: replacement.utf16.count)
        invalidatePreview(previous, editor: editor)
        updateAccessibility(label: "Replace \(old) with \(added)", editor: editor)
    }

    private var previewBounds: NSRect {
        sourceBands.reduce(proposedBand ?? .null) { $0.union($1) }
    }

    private func invalidatePreview(_ previous: NSRect, editor: EditorTextView) {
        let dirty = previous.union(previewBounds).intersection(editor.visibleRect)
        if !dirty.isEmpty { editor.setNeedsDisplay(dirty) }
    }

    private func updateAccessibility(label: String, editor: EditorTextView) {
        let frame = previewBounds.intersection(editor.visibleRect)
        guard !frame.isEmpty else {
            previewAccessibility?.isHidden = true
            return
        }
        let element = previewAccessibility ?? PreviewAccessibility()
        if previewAccessibility == nil {
            editor.addSubview(element)
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(.staticText)
            previewAccessibility = element
        }
        if element.frame != frame { element.frame = frame }
        element.setAccessibilityLabel(label)
        element.isHidden = false
    }

    func clearPreview() {
        guard let editor else { return }
        let previous = previewBounds
        previewAccessibility?.isHidden = true
        proposedRows = nil
        proposedBand = nil
        previewSourceRange = nil
        sourceBands = []
        sourceChanges = []
        editor.layoutSpacing.set([], for: .find)
        invalidatePreview(previous, editor: editor)
    }

    private func drawPreview(in dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.22).setFill()
        for band in sourceBands where band.intersects(dirtyRect) { band.intersection(dirtyRect).fill() }
        NSColor.systemRed.withAlphaComponent(0.42).setFill()
        for rect in sourceChanges where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        guard let editor, let band = proposedBand, let proposedRows, band.intersects(dirtyRect),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let clipped = band.intersection(dirtyRect)
        NSColor.systemGreen.withAlphaComponent(0.22).setFill()
        clipped.fill()
        proposedRows.layout.draw(proposedRows.rows, at: NSPoint(x: editor.textContainerOrigin.x, y: band.minY),
                                 dirtyRect: clipped, in: context, highlights: [proposedChange],
                                 highlightColor: NSColor.systemGreen.withAlphaComponent(0.42))
    }
}

// The painted preview follows the live text layout. This view only exposes its VoiceOver description.
private final class PreviewAccessibility: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
