import AppKit

@MainActor
final class JJConflictDecorations {
    struct ActionBlock {
        let conflict: JJConflict
        let id: UUID
        var appliedSides: Set<Int> = []
        var failedSides: Set<Int> = []
        var hasDraft = false
    }

    private struct ActionKey: Hashable {
        // Replacing the snapshot can move every following marker to a different offset.
        let blockID: UUID
        let action: JJConflictActions.Action
    }

    private struct Row: Equatable {
        let role: JJConflict.Role
        let band: NSRect
        let details: [NSRect]
    }

    var onAction: ((JJConflict, JJConflictActions.Action) -> Void)?
    private weak var editor: EditorTextView?
    private var highlights: [JJConflict.Highlight] = []
    private var rows: [Row] = []
    private var blocks: [ActionBlock] = []
    private var actionRows: [ActionKey: JJConflictActions] = [:]
    private var actionsEnabled = true

    init(editor: EditorTextView) {
        self.editor = editor
    }

    var hasHighlights: Bool { !highlights.isEmpty }

    func update(_ highlights: [JJConflict.Highlight]) {
        guard self.highlights != highlights else { return }
        let foregroundChanged = !self.highlights.elementsEqual(highlights) { first, second in
            first.range == second.range && first.role == second.role
        }
        self.highlights = highlights
        if foregroundChanged { editor?.syntaxHighlighting?.refreshColors() }
        layout(positionsActions: false)
    }

    func setActionBlocks(_ blocks: [ActionBlock]) {
        self.blocks = blocks
        if blocks.isEmpty { removeActionRows() }
        else { layout() }
        editor?.requestLineRefresh()
    }

    func setActionsEnabled(_ enabled: Bool) {
        guard actionsEnabled != enabled else { return }
        actionsEnabled = enabled
        for row in actionRows.values { row.setEnabled(enabled) }
    }

    func foregrounds(in visible: NSRange) -> [(range: NSRange, color: NSColor)] {
        guard visible.length > 0 else { return [] }
        return highlightsInViewport(visible).map { highlight in
            let color = switch highlight.role {
            case .marker: NSColor.textColor
            case .addition: Self.addedText
            case .removal: Self.removedText
            }
            return (NSIntersectionRange(visible, highlight.range), color)
        }
    }

    private static let addedText = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.53, green: 0.83, blue: 0.57, alpha: 1)
        }
        return NSColor(srgbRed: 0.07, green: 0.39, blue: 0.20, alpha: 1)
    }

    private static let removedText = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 1, green: 0.56, blue: 0.58, alpha: 1)
        }
        return NSColor(srgbRed: 0.68, green: 0.15, blue: 0.20, alpha: 1)
    }

    func layout(positionsActions: Bool = true) {
        guard let editor, let scroll = editor.enclosingScrollView,
              let manager = editor.textLayoutManager else {
            display([])
            removeActionRows()
            return
        }
        guard let viewport = manager.textViewportLayoutController.viewportRange else {
            for row in actionRows.values { row.setAnchorAvailable(false) }
            return
        }
        let visible = editor.charRange(viewport, in: manager)
        let visibleRows = highlightsInViewport(visible).compactMap { highlight -> Row? in
            guard highlight.role == .marker || !highlight.changes.isEmpty else { return nil }
            let range = NSIntersectionRange(visible, highlight.range)
            guard let band = band(for: range, editor: editor) else { return nil }
            let details = JJInlineDiffLayout.detailRects(for: highlight.changes, in: range, editor: editor, manager: manager)
            return Row(role: highlight.role, band: band, details: details)
        }
        display(visibleRows)

        if positionsActions { layoutActions(in: visible, editor: editor, scroll: scroll) }
    }

    private func layoutActions(in visible: NSRange, editor: EditorTextView, scroll: NSScrollView) {
        let viewport = JJEditorActionBar.viewport(in: scroll)
        var visibleActions: [ActionKey: JJConflictActions] = [:]
        func place(_ action: JJConflictActions.Action, at location: Int, in block: ActionBlock,
                   applied: Bool = false, failed: Bool = false) {
            let key = ActionKey(blockID: block.id, action: action)
            guard NSLocationInRange(location, visible) else { return }
            guard let line = editor.laidOutLineBounds(at: location) else {
                // Keep the last position across transient TextKit invalidation.
                actionRows[key]?.setAnchorAvailable(false)
                visibleActions[key] = actionRows[key]
                return
            }
            let anchor = scroll.convert(line, from: editor)
            guard anchor.midY >= viewport.minY, anchor.midY <= viewport.maxY else { return }
            let row = actionRows[key] ?? JJConflictActions(action) { [weak self] in self?.perform(key) }
            row.setAnchorAvailable(true)
            row.update(enabled: actionsEnabled, applied: applied, failed: failed, hasDraft: block.hasDraft)
            var frame = row.frame(over: anchor, in: viewport, scroll: scroll)
            frame.origin.y = floor(anchor.midY - frame.height / 2)
            if row.frame != frame { row.frame = frame }
            if row.superview !== scroll { scroll.addSubview(row, positioned: .above, relativeTo: nil) }
            visibleActions[key] = row
        }
        if editor.isEditable {
            for block in blocks where NSIntersectionRange(block.conflict.range, visible).length > 0 {
                for segment in block.conflict.segments {
                    switch segment.kind {
                    case .snapshot(let side) where side == block.conflict.resultSide:
                        place(.markResolved, at: segment.anchor.location, in: block)
                    case .snapshot:
                        break
                    case .diff(_, let side):
                        place(.applyDiff(side: side), at: segment.anchor.location, in: block,
                              applied: block.appliedSides.contains(side), failed: block.failedSides.contains(side))
                    }
                }
            }
        }
        for (key, old) in actionRows where visibleActions[key] == nil { old.removeFromSuperview() }
        actionRows = visibleActions
    }

    private func perform(_ key: ActionKey) {
        guard actionsEnabled, let block = blocks.first(where: { $0.id == key.blockID }) else { return }
        if case .applyDiff(let side) = key.action, block.appliedSides.contains(side) { return }
        onAction?(block.conflict, key.action)
    }

    private func removeActionRows() {
        for row in actionRows.values { row.removeFromSuperview() }
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
            if row.role == .marker {
                NSColor.systemPurple.withAlphaComponent(0.21).setFill()
                NSRect(x: dirtyRect.minX, y: row.band.minY, width: dirtyRect.width, height: row.band.height)
                    .intersection(dirtyRect).fill()
            } else if includesDetails {
                let color = row.role == .addition ? Self.addedText : Self.removedText
                color.withAlphaComponent(0.20).setFill()
                for rect in row.details where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
            }
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
