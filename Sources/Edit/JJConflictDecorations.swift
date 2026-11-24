import AppKit

@MainActor
final class JJConflictDecorations {
    private struct Row: Equatable {
        let role: JJConflict.Role
        let band: NSRect
        let details: [NSRect]
    }

    let actions = JJConflictActions()
    private weak var editor: EditorTextView?
    private var highlights: [JJConflict.Highlight] = []
    private var rows: [Row] = []

    init(editor: EditorTextView) {
        self.editor = editor
    }

    func update(_ highlights: [JJConflict.Highlight]) {
        guard self.highlights != highlights else { return }
        self.highlights = highlights
        layout()
    }

    func select(_ conflict: JJConflict?) {
        actions.selected = conflict
        if conflict == nil { actions.removeFromSuperview() }
        editor?.requestLineRefresh()
    }

    func layout() {
        guard let editor, let scroll = editor.enclosingScrollView,
              let manager = editor.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else {
            display([])
            actions.removeFromSuperview()
            return
        }
        let visible = editor.charRange(viewport, in: manager)
        let visibleRows = highlightsInViewport(visible).compactMap { highlight -> Row? in
            let range = NSIntersectionRange(visible, highlight.range)
            guard let band = band(for: range, editor: editor) else { return nil }
            let details = JJInlineDiffLayout.detailRects(for: highlight.changes, in: range, editor: editor, manager: manager)
            return Row(role: highlight.role, band: band, details: details)
        }
        display(visibleRows)

        let viewportFrame = JJEditorActionBar.viewport(in: scroll)
        guard editor.isEditable, let selected = actions.selected,
              let block = band(for: NSIntersectionRange(selected.range, visible), editor: editor) else {
            actions.removeFromSuperview()
            return
        }
        let anchor = scroll.convert(block, from: editor).intersection(viewportFrame)
        guard !anchor.isEmpty else {
            actions.removeFromSuperview()
            return
        }
        let frame = actions.frame(over: anchor, in: viewportFrame, scroll: scroll)
        if actions.frame != frame { actions.frame = frame }
        if actions.superview !== scroll { scroll.addSubview(actions, positioned: .above, relativeTo: nil) }
    }

    private func display(_ visibleRows: [Row]) {
        guard rows != visibleRows else { return }
        rows = visibleRows
        if let editor {
            editor.setNeedsDisplay(editor.visibleRect)
            editor.invalidateOverscrollBackground()
        }
    }

    func draw(in dirtyRect: NSRect, includesDetails: Bool = true) {
        for row in rows where row.band.minY < dirtyRect.maxY && row.band.maxY > dirtyRect.minY {
            let background: NSColor = switch row.role {
            case .marker: .systemPurple.withAlphaComponent(0.14)
            case .addition: JJDiffColors.addedRow
            case .removal: JJDiffColors.removedRow
            }
            background.setFill()
            NSRect(x: dirtyRect.minX, y: row.band.minY, width: dirtyRect.width, height: row.band.height)
                .intersection(dirtyRect).fill()
            guard includesDetails, !row.details.isEmpty else { continue }
            (row.role == .addition ? JJDiffColors.addedDetail : JJDiffColors.removedDetail).setFill()
            for rect in row.details where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        }
    }

    private func highlightsInViewport(_ visible: NSRange) -> ArraySlice<JJConflict.Highlight> {
        var first = 0
        var upper = highlights.count
        while first < upper {
            let middle = first + (upper - first) / 2
            if NSMaxRange(highlights[middle].range) <= visible.location { first = middle + 1 }
            else { upper = middle }
        }
        var last = first
        while last < highlights.count, highlights[last].range.location < NSMaxRange(visible) { last += 1 }
        return highlights[first..<last]
    }

    private func band(for range: NSRange, editor: EditorTextView) -> NSRect? {
        guard range.length > 0,
              let first = editor.laidOutLineBounds(at: range.location),
              let last = editor.laidOutLineBounds(at: NSMaxRange(range) - 1) else { return nil }
        return NSRect(x: editor.bounds.minX, y: first.minY, width: editor.bounds.width, height: last.maxY - first.minY)
    }
}
