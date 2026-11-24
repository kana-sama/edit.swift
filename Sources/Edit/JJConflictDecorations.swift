import AppKit

@MainActor
final class JJConflictDecorations {
    struct ActionBlock {
        let conflict: JJConflict
        let applied: [JJConflict.Segment.Kind]
    }

    private struct ActionRow {
        let conflict: JJConflict
        let buttons: [JJConflictActions.Action]
        let view: JJConflictActions
    }

    private struct Row: Equatable {
        let role: JJConflict.Role
        let band: NSRect
        let details: [NSRect]
    }

    var onAction: ((JJConflict, JJConflictActions.Action, NSView) -> Void)?
    private weak var editor: EditorTextView?
    private var highlights: [JJConflict.Highlight] = []
    private var rows: [Row] = []
    private var blocks: [ActionBlock] = []
    private var actionRows: [Int: ActionRow] = [:]
    private var actionsEnabled = true

    init(editor: EditorTextView) {
        self.editor = editor
    }

    var hasHighlights: Bool { !highlights.isEmpty }

    func update(_ highlights: [JJConflict.Highlight]) {
        guard self.highlights != highlights else { return }
        let previousMarkers = self.highlights.lazy.filter { $0.role == .marker }.map(\.range)
        let markers = highlights.lazy.filter { $0.role == .marker }.map(\.range)
        let changedMarkers = !previousMarkers.elementsEqual(markers)
        self.highlights = highlights
        if changedMarkers { editor?.syntaxHighlighting?.refreshColors() }
        layout()
    }

    func setActionBlocks(_ blocks: [ActionBlock]) {
        self.blocks = blocks
        if blocks.isEmpty { removeActionRows() }
        editor?.requestLineRefresh()
    }

    func setActionsEnabled(_ enabled: Bool) {
        guard actionsEnabled != enabled else { return }
        actionsEnabled = enabled
        for row in actionRows.values { row.view.setEnabled(enabled) }
    }

    func markerRanges(in visible: NSRange) -> [NSRange] {
        guard visible.length > 0 else { return [] }
        return highlightsInViewport(visible).compactMap {
            $0.role == .marker ? NSIntersectionRange(visible, $0.range) : nil
        }
    }

    func layout() {
        guard let editor, let scroll = editor.enclosingScrollView,
              let manager = editor.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else {
            display([])
            removeActionRows()
            return
        }
        let visible = editor.charRange(viewport, in: manager)
        let visibleRows = highlightsInViewport(visible).compactMap { highlight -> Row? in
            guard highlight.role != .marker else { return nil }
            let range = NSIntersectionRange(visible, highlight.range)
            guard let band = band(for: range, editor: editor) else { return nil }
            let details = JJInlineDiffLayout.detailRects(for: highlight.changes, in: range, editor: editor, manager: manager)
            return Row(role: highlight.role, band: band, details: details)
        }
        display(visibleRows)

        layoutActions(in: visible, editor: editor, scroll: scroll)
    }

    private func layoutActions(in visible: NSRange, editor: EditorTextView, scroll: NSScrollView) {
        let viewport = JJEditorActionBar.viewport(in: scroll)
        var visibleActions: [Int: ActionRow] = [:]
        func place(_ buttons: [JJConflictActions.Action], at location: Int, for conflict: JJConflict) {
            guard NSLocationInRange(location, visible),
                  let line = editor.laidOutLineBounds(at: location) else { return }
            let anchor = scroll.convert(line, from: editor)
            guard anchor.midY >= viewport.minY, anchor.midY <= viewport.maxY else { return }
            let row: ActionRow
            if let existing = actionRows[location], existing.conflict == conflict, existing.buttons == buttons {
                row = existing
            } else {
                let bar = JJConflictActions(buttons) { [weak self] action, anchor in
                    self?.onAction?(conflict, action, anchor)
                }
                bar.setEnabled(actionsEnabled)
                row = ActionRow(conflict: conflict, buttons: buttons, view: bar)
                actionRows[location]?.view.removeFromSuperview()
            }
            var frame = row.view.frame(over: anchor, in: viewport, scroll: scroll)
            frame.origin.y = floor(anchor.midY - frame.height / 2)
            if row.view.frame != frame { row.view.frame = frame }
            if row.view.superview !== scroll { scroll.addSubview(row.view, positioned: .above, relativeTo: nil) }
            visibleActions[location] = row
        }
        if editor.isEditable {
            for block in blocks where NSIntersectionRange(block.conflict.range, visible).length > 0 {
                let conflict = block.conflict
                for segment in conflict.segments {
                    let button: JJConflictActions.Action = switch segment.kind {
                    case let .snapshot(side): .useSide(side)
                    case .diff where block.applied.last == segment.kind: .undoDiff
                    case .diff where block.applied.contains(segment.kind): .applied
                    case .diff: .applyDiff(segment)
                    }
                    place([button], at: segment.anchor.location, for: conflict)
                }
                if let end = conflict.highlights.last?.range.location {
                    place(block.applied.isEmpty ? [.editResult] : [.editResult, .useResult], at: end, for: conflict)
                }
            }
        }
        for (location, old) in actionRows where visibleActions[location] == nil { old.view.removeFromSuperview() }
        actionRows = visibleActions
    }

    private func removeActionRows() {
        for row in actionRows.values { row.view.removeFromSuperview() }
        actionRows.removeAll()
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
            let background = row.role == .addition ? JJDiffColors.addedRow : JJDiffColors.removedRow
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
