import AppKit

@MainActor
enum JJDiffColors {
    static var addedRow: NSColor { .systemGreen.withAlphaComponent(0.13) }
    static var removedRow: NSColor { NSColor.textBackgroundColor.blended(withFraction: 0.14, of: .systemRed) ?? .textBackgroundColor }
    static var addedDetail: NSColor { .systemGreen.withAlphaComponent(0.33) }
    static var removedDetail: NSColor { .systemRed.withAlphaComponent(0.36) }
}

@MainActor
final class JJInlineDiffLayout {
    private struct Entry {
        let hunk: JJDiffHunk
        var removedRect: NSRect?
        var insertedRect: NSRect?
        var insertedHighlightRects: [NSRect] = []
    }

    private weak var editor: EditorTextView?
    private var entries: [Entry] = []
    private var layingOut = false
    private var removedSelections: [NSRange: NSRange] = [:]
    private var selectionIsActive = false
    private var projection: JJInlineDiffSelection?
    private var projectedLayout: EditorProjectedTextLayout?
    private(set) var projectionRevision: UInt = 0

    init(editor: EditorTextView) {
        self.editor = editor
    }

    func display(_ hunks: [JJDiffHunk]) {
        guard hunks != entries.map(\.hunk), let editor else { return }
        sourceTextChanged()
        entries = hunks.map { Entry(hunk: $0) }
        layout()
        editor.setNeedsDisplay(editor.visibleRect)
        editor.invalidateOverscrollBackground()
    }

    func layout() {
        guard !layingOut, let editor, let scroll = editor.enclosingScrollView, let manager = editor.textLayoutManager,
              let source = editor.textStorage?.mutableString else { return }
        layingOut = true
        defer { layingOut = false }

        let previousLayout = projectedLayout
        let projection = currentProjection()
        let style = EditorProjectedTextLayout.Style(editor: editor, wrapsToEditor: true)
        let wrappedLayout = style.wrapWidth == nil ? nil : textLayout(for: style)
        let blocks: [EditorLayoutSpacing.Block] = entries.compactMap { entry in
            let key = entry.hunk.baseRange
            guard let rows = projection?.removedRows(for: key) else { return nil }
            let boundary = min(entry.hunk.currentRange.location, source.length)
            let endsDocument = boundary == source.length
            let offset = max(0, endsDocument ? boundary - 1 : boundary)
            let paragraph = source.lineRange(for: NSRange(location: offset, length: 0)).location
            return EditorLayoutSpacing.Block(id: .removed(key), paragraph: paragraph,
                                             edge: endsDocument && source.length > 0 ? .after : .before,
                                             height: CGFloat(wrappedLayout?.displayRows(for: rows).count ?? rows.count) * style.lineHeight)
        }
        editor.layoutSpacing.set(blocks, for: .diff)
        let viewport = scroll.documentVisibleRect
        let visible = manager.textViewportLayoutController.viewportRange.map { editor.charRange($0, in: manager) }
        var invalidated = NSRect.null
        for index in entries.indices {
            let hunk = entries[index].hunk
            let oldBand = entries[index].insertedRect
            let oldHighlights = entries[index].insertedHighlightRects
            let inserted = insertedRects(for: hunk, sourceLength: source.length, in: manager, editor: editor,
                                         visibleRange: visible)
            entries[index].insertedRect = inserted.band
            entries[index].insertedHighlightRects = inserted.highlights
            if oldBand != inserted.band || oldHighlights != inserted.highlights {
                if let oldBand { invalidated = invalidated.union(oldBand) }
                if let band = inserted.band { invalidated = invalidated.union(band) }
            }

            let oldRemoved = entries[index].removedRect
            let removed = editor.layoutSpacing.rect(for: .removed(hunk.baseRange))
            entries[index].removedRect = removed
            if let removed, removed.intersects(viewport),
               textLayout(for: style) !== previousLayout {
                invalidated = invalidated.union(removed)
            }
            if oldRemoved != removed {
                if let oldRemoved { invalidated = invalidated.union(oldRemoved) }
                if let removed { invalidated = invalidated.union(removed) }
            }
        }
        if !invalidated.isNull {
            editor.setNeedsDisplay(fullWidth(of: invalidated, in: editor).intersection(viewport))
            editor.invalidateOverscrollBackground()
        }
    }

    func drawBackground(in dirtyRect: NSRect, includesText: Bool) {
        guard let editor else { return }
        func clippedBand(_ band: NSRect) -> NSRect {
            NSRect(x: dirtyRect.minX, y: band.minY, width: dirtyRect.width, height: band.height)
                .intersection(dirtyRect)
        }
        let removedColor = JJDiffColors.removedRow
        let insertedColor = JJDiffColors.addedRow
        let insertedDetail = JJDiffColors.addedDetail
        let context = NSGraphicsContext.current?.cgContext
        for entry in entries {
            if let band = entry.insertedRect {
                insertedColor.setFill()
                clippedBand(band).fill()
                if includesText {
                    insertedDetail.setFill()
                    for rect in entry.insertedHighlightRects where rect.intersects(dirtyRect) {
                        rect.intersection(dirtyRect).fill()
                    }
                }
            }
            if let band = entry.removedRect {
                let clipped = clippedBand(band)
                guard !clipped.isEmpty else { continue }
                removedColor.setFill()
                clipped.fill()
                let key = entry.hunk.baseRange
                guard includesText, let context, let text = projectedLayout,
                      let rows = projection?.removedRows(for: key) else { continue }
                let highlights = entry.hunk.removedHighlights.map {
                    NSRange(location: rows.range.location + $0.location, length: $0.length)
                }
                text.draw(text.displayRows(for: rows), at: NSPoint(x: editor.textContainerOrigin.x, y: band.minY),
                          dirtyRect: clipped, in: context, highlights: highlights,
                          highlightColor: JJDiffColors.removedDetail,
                          selection: removedSelections[key], selectionIsActive: selectionIsActive)
            }
        }
    }

    private func fullWidth(of rect: NSRect, in editor: EditorTextView) -> NSRect {
        NSRect(x: editor.bounds.minX, y: rect.minY, width: editor.bounds.width, height: rect.height)
    }

    func rect(for hunk: JJDiffHunk) -> NSRect? {
        guard let entry = entries.first(where: { $0.hunk == hunk }) else { return nil }
        guard var region = entry.removedRect ?? entry.insertedRect else { return nil }
        if let inserted = entry.insertedRect { region = region.union(inserted) }
        // The gutter and hovering controls use the visible span, even when a painted row is wider.
        if let viewport = editor?.enclosingScrollView?.documentVisibleRect {
            region.origin.x = viewport.minX
            region.size.width = viewport.width
        }
        return region
    }

    func removedPosition(at point: NSPoint) -> JJInlineDiffSelection.Position? {
        guard let editor else { return nil }
        for entry in entries {
            guard let rect = entry.removedRect, fullWidth(of: rect, in: editor).contains(point),
                  let rows = currentProjection()?.removedRows(for: entry.hunk.baseRange),
                  let text = textLayout() else { continue }
            let local = NSPoint(x: point.x - editor.textContainerOrigin.x, y: point.y - rect.minY)
            return .removed(key: entry.hunk.baseRange,
                            offset: text.insertionOffset(at: local, in: text.displayRows(for: rows)) - rows.range.location)
        }
        return nil
    }

    func removedCaretRect(key: NSRange, offset: Int) -> NSRect? {
        guard let editor, let entry = entries.first(where: { $0.hunk.baseRange == key }),
              let row = entry.removedRect, let rows = currentProjection()?.removedRows(for: key),
              let text = textLayout(),
              let rect = text.caretRect(at: rows.range.location + offset, in: text.displayRows(for: rows)) else { return nil }
        return rect.offsetBy(dx: editor.textContainerOrigin.x, dy: row.minY)
    }

    func showSelection(_ range: NSRange?, in projection: JJInlineDiffSelection?) {
        guard let editor else { return }
        var next: [NSRange: NSRange] = [:]
        if let range, let projection {
            for entry in entries {
                let key = entry.hunk.baseRange
                guard let block = projection.displayRange(forRemoved: key) else { continue }
                let selected = NSIntersectionRange(range, block)
                if selected.length > 0 {
                    next[key] = selected
                }
            }
        }
        let active = editor.window?.firstResponder === editor && editor.window?.isKeyWindow == true
        guard next != removedSelections || active != selectionIsActive else { return }
        for entry in entries {
            let key = entry.hunk.baseRange
            if let rect = entry.removedRect, next[key] != nil || removedSelections[key] != nil {
                editor.setNeedsDisplay(fullWidth(of: rect, in: editor).intersection(editor.visibleRect))
            }
        }
        removedSelections = next
        selectionIsActive = active
    }

    func revealCaret(at position: JJInlineDiffSelection.Position) {
        guard case .removed(let key, let offset) = position, let editor, let scroll = editor.enclosingScrollView,
              let entry = entries.first(where: { $0.hunk.baseRange == key }) else { return }
        if removedCaretRect(key: key, offset: offset) == nil {
            reveal(entry.hunk)
            layout()
        }
        guard let caret = removedCaretRect(key: key, offset: offset) else { return }

        let visible = scroll.documentVisibleRect
        let insets = scroll.contentInsets
        let left = visible.minX + insets.left
        let right = visible.maxX - insets.right
        let top = visible.minY + insets.top
        let bottom = visible.maxY - insets.bottom
        var origin = scroll.visibleContentOrigin
        if caret.minX < left { origin.x += caret.minX - left - editor.textContainerInset.width }
        if caret.maxX > right { origin.x += caret.maxX - right + editor.textContainerInset.width }
        if caret.minY < top { origin.y += caret.minY - top }
        if caret.maxY > bottom { origin.y += caret.maxY - bottom }
        if scroll.scrollToVisibleContentOrigin(origin) {
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            layout()
        }
    }

    func reveal(_ hunk: JJDiffHunk) {
        guard let editor, let scroll = editor.enclosingScrollView else { return }
        let horizontal = scroll.visibleContentOrigin.x
        let anchor = NSRange(location: hunk.currentRange.location, length: 0)
        if rect(for: hunk) == nil {
            editor.scrollRangeToVisible(anchor)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            layout()
        }
        var origin = scroll.visibleContentOrigin
        origin.x = horizontal
        if let region = rect(for: hunk) {
            let height = max(1, scroll.documentVisibleRect.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
            let padding = min(12, max(0, (height - region.height) / 2))
            if region.minY < origin.y || region.maxY > origin.y + height {
                origin.y = region.minY - padding
            }
        }
        if scroll.scrollToVisibleContentOrigin(origin) {
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            layout()
        }
    }

    func sourceTextChanged() {
        projection = nil
        projectedLayout = nil
        projectionRevision &+= 1
    }

    func currentProjection() -> JJInlineDiffSelection? {
        if let projection { return projection }
        guard let editor, entries.contains(where: { !$0.hunk.removedText.isEmpty }) else { return nil }
        let projection = JJInlineDiffSelection(source: editor.string, hunks: entries.map(\.hunk),
                                               lineEnding: editor.preferredLineEnding)
        self.projection = projection
        return projection
    }

    func textLayout(for style: EditorProjectedTextLayout.Style? = nil) -> EditorProjectedTextLayout? {
        guard let editor, let projection = currentProjection() else { return nil }
        let style = style ?? .init(editor: editor, wrapsToEditor: true)
        if let projectedLayout, projectedLayout.style == style { return projectedLayout }
        let layout = EditorProjectedTextLayout(text: projection.string, style: style)
        projectedLayout = layout
        return layout
    }

    private func insertedRects(for hunk: JJDiffHunk, sourceLength: Int, in manager: NSTextLayoutManager,
                               editor: EditorTextView, visibleRange: NSRange?)
        -> (band: NSRect?, highlights: [NSRect]) {
        guard let visibleRange, hunk.currentRange.length > 0, NSMaxRange(hunk.currentRange) <= sourceLength else {
            return (nil, [])
        }
        let visible = NSIntersectionRange(hunk.currentRange, visibleRange)
        guard visible.length > 0,
              let first = editor.laidOutLineBounds(at: visible.location),
              let last = editor.laidOutLineBounds(at: NSMaxRange(visible) - 1) else { return (nil, []) }
        let band = NSRect(x: editor.bounds.minX, y: first.minY, width: editor.bounds.width,
                          height: last.maxY - first.minY)
        let changes = hunk.insertedHighlights.map {
            NSRange(location: hunk.currentRange.location + $0.location, length: $0.length)
        }
        return (band, Self.detailRects(for: changes, in: visible, editor: editor, manager: manager))
    }

    static func detailRects(for changes: [NSRange], in visible: NSRange, editor: EditorTextView,
                            manager: NSTextLayoutManager) -> [NSRect] {
        let origin = editor.textContainerOrigin
        var highlights: [NSRect] = []
        for absolute in changes {
            let range = NSIntersectionRange(visible, absolute)
            guard range.length > 0, let textRange = editor.textRange(range, in: manager) else { continue }
            manager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                if !rect.isEmpty { highlights.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return highlights
    }

}
