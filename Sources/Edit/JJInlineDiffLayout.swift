import AppKit
import os

@MainActor
final class JJInlineDiffLayout: NSObject, NSTextLayoutManagerDelegate {
    private static let gapAttribute = NSAttributedString.Key("dev.edit.jj-inline-gap")

    private struct Gap: Equatable, Sendable {
        var before: CGFloat = 0
        var after: CGFloat = 0
    }

    private struct TextStyle: Equatable {
        let font: NSFont
        let paragraph: NSParagraphStyle
        let padding: CGFloat
    }

    private struct Entry {
        let hunk: JJDiffHunk
        let removedLineCount: Int
        var removedTextLayout: JJRemovedTextLayout?
        var removedRect: NSRect?
        var insertedRect: NSRect?
        var insertedHighlightRects: [NSRect] = []
    }

    private weak var editor: EditorTextView?
    private var entries: [Entry] = []
    private nonisolated let layoutGaps = OSAllocatedUnfairLock(initialState: [Int: Gap]())
    private var lineHeight: CGFloat = 18
    private var emptyEditorInset: NSSize?
    private var layingOut = false
    private var removedSelections: [NSRange: NSRange] = [:]
    private var selectionIsActive = false
    private var textStyle: TextStyle?

    init(editor: EditorTextView) {
        self.editor = editor
    }

    func display(_ hunks: [JJDiffHunk]) {
        guard hunks != entries.map(\.hunk), let editor else { return }
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.hunk.baseRange, $0) })
        entries = hunks.map { hunk in
            let old = previous[hunk.baseRange]
            let reusable = old?.hunk.removedText == hunk.removedText && old?.hunk.removedHighlights == hunk.removedHighlights
            return Entry(hunk: hunk, removedLineCount: Self.lineCount(hunk.removedText),
                         removedTextLayout: reusable ? old?.removedTextLayout : nil)
        }
        layout()
        editor.setNeedsDisplay(editor.visibleRect)
        editor.invalidateOverscrollBackground()
    }

    func layout() {
        guard !layingOut, let editor, let scroll = editor.enclosingScrollView, let manager = editor.textLayoutManager,
              let source = editor.textStorage?.mutableString else { return }
        layingOut = true
        defer { layingOut = false }

        let style = TextStyle(font: editor.font ?? EditorTextView.defaultFont,
                              paragraph: editor.defaultParagraphStyle ?? .default,
                              padding: editor.textContainer?.lineFragmentPadding ?? 0)
        let styleChanged = textStyle != style
        textStyle = style
        lineHeight = max(1, editor.defaultParagraphStyle?.minimumLineHeight ?? 18)
        updateEmptyEditorInset(sourceLength: source.length, editor: editor)
        let newGaps = gaps(for: source)
        let spacingChanged = layoutGaps.withLock { gaps in
            guard newGaps != gaps else { return false }
            gaps = newGaps
            return true
        }
        if spacingChanged {
            if newGaps.isEmpty {
                if manager.delegate === self { manager.delegate = nil }
            } else {
                manager.delegate = self
            }
            refreshGapParagraphs(newGaps, source: source, editor: editor)
            manager.textViewportLayoutController.layoutViewport()
        }
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
            let removed = removedRect(for: entries[index], source: source, editor: editor, manager: manager)
            entries[index].removedRect = removed
            if styleChanged { entries[index].removedTextLayout = nil }
            if let removed, removed.intersects(viewport), entries[index].removedTextLayout == nil {
                entries[index].removedTextLayout = JJRemovedTextLayout(hunk: hunk, font: style.font,
                                                                      paragraph: style.paragraph, padding: style.padding)
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
        let removedColor = NSColor.textBackgroundColor.blended(withFraction: 0.14, of: .systemRed) ?? .textBackgroundColor
        let insertedColor = NSColor.systemGreen.withAlphaComponent(0.13)
        let insertedDetail = NSColor.systemGreen.withAlphaComponent(0.33)
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
                guard includesText, let context, let text = entry.removedTextLayout else { continue }
                // Red paragraphs use TextKit glyphs in this editor's drawing pass and document coordinates.
                context.saveGState()
                context.clip(to: clipped)
                text.draw(at: NSPoint(x: editor.textContainerOrigin.x, y: band.minY), dirtyRect: clipped, in: context,
                          selection: removedSelections[entry.hunk.baseRange], selectionIsActive: selectionIsActive)
                context.restoreGState()
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
                  let text = entry.removedTextLayout else { continue }
            let local = NSPoint(x: point.x - editor.textContainerOrigin.x, y: point.y - rect.minY)
            return .removed(key: entry.hunk.baseRange, offset: text.insertionOffset(at: local))
        }
        return nil
    }

    func removedCaretRect(key: NSRange, offset: Int) -> NSRect? {
        guard let editor, let entry = entries.first(where: { $0.hunk.baseRange == key }),
              let row = entry.removedRect, let rect = entry.removedTextLayout?.caretRect(at: offset) else { return nil }
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
                    next[key] = NSRange(location: selected.location - block.location, length: selected.length)
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

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
        guard let gap = layoutGaps.withLock({ $0[offset] }) else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let fragment = JJDiffLayoutFragment(textElement: textElement, range: nil)
        fragment.before = gap.before
        fragment.after = gap.after
        return fragment
    }

    private func gaps(for source: NSString) -> [Int: Gap] {
        guard source.length > 0 else { return [:] }
        var result: [Int: Gap] = [:]
        for entry in entries where entry.removedLineCount > 0 {
            let height = CGFloat(entry.removedLineCount) * lineHeight
            let boundary = min(entry.hunk.currentRange.location, source.length)
            if boundary == source.length {
                let last = source.lineRange(for: NSRange(location: source.length - 1, length: 0))
                result[last.location, default: Gap()].after += height
            } else {
                let paragraph = source.lineRange(for: NSRange(location: boundary, length: 0))
                result[paragraph.location, default: Gap()].before += height
            }
        }
        return result
    }

    private func refreshGapParagraphs(_ gaps: [Int: Gap], source: NSString, editor: EditorTextView) {
        guard let storage = editor.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        // A text-layout invalidation alone reuses the existing fragments. This private attribute
        // rebuilds the affected paragraphs through the delegate without changing source or style.
        storage.enumerateAttribute(Self.gapAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { storage.removeAttribute(Self.gapAttribute, range: range) }
        }
        for offset in gaps.keys {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            storage.addAttribute(Self.gapAttribute, value: true, range: range)
        }
    }

    private func updateEmptyEditorInset(sourceLength: Int, editor: EditorTextView) {
        if sourceLength == 0, let entry = entries.first(where: { $0.removedLineCount > 0 }) {
            // TextKit owns the empty document's insertion row and does not rebuild it for a new delegate.
            let original = emptyEditorInset ?? editor.textContainerInset
            emptyEditorInset = original
            let inset = NSSize(width: original.width, height: original.height + CGFloat(entry.removedLineCount) * lineHeight)
            if editor.textContainerInset != inset { editor.textContainerInset = inset }
        } else if let original = emptyEditorInset {
            emptyEditorInset = nil
            editor.textContainerInset = original
        }
    }

    private func removedRect(for entry: Entry, source: NSString, editor: EditorTextView,
                             manager: NSTextLayoutManager) -> NSRect? {
        guard entry.removedLineCount > 0 else { return nil }
        let height = CGFloat(entry.removedLineCount) * lineHeight
        var rows = NSRect(x: editor.bounds.minX, y: 0, width: editor.bounds.width, height: height)
        if let emptyEditorInset {
            rows.origin.y = emptyEditorInset.height
            return rows
        }
        let boundary = min(entry.hunk.currentRange.location, source.length)
        let endsDocument = boundary == source.length
        let offset = endsDocument ? source.length - 1 : boundary
        let paragraph = source.lineRange(for: NSRange(location: offset, length: 0)).location
        guard let location = manager.location(manager.documentRange.location, offsetBy: paragraph),
              let fragment = manager.textLayoutFragment(for: location) as? JJDiffLayoutFragment,
              fragment.state == .layoutAvailable else { return nil }
        let frame = fragment.layoutFragmentFrame
        let top = endsDocument ? frame.maxY : frame.minY + fragment.topMargin
        rows.origin.y = top + editor.textContainerOrigin.y - height
        return rows
    }

    private func insertedRects(for hunk: JJDiffHunk, sourceLength: Int, in manager: NSTextLayoutManager,
                               editor: EditorTextView, visibleRange: NSRange?)
        -> (band: NSRect?, highlights: [NSRect]) {
        guard let visibleRange, hunk.currentRange.length > 0, NSMaxRange(hunk.currentRange) <= sourceLength else {
            return (nil, [])
        }
        let visible = NSIntersectionRange(hunk.currentRange, visibleRange)
        guard visible.length > 0,
              let first = lineRect(at: visible.location, in: manager),
              let last = lineRect(at: NSMaxRange(visible) - 1, in: manager) else { return (nil, []) }
        let origin = editor.textContainerOrigin
        let band = NSRect(x: editor.bounds.minX, y: first.minY + origin.y, width: editor.bounds.width,
                          height: last.maxY - first.minY)
        var highlights: [NSRect] = []
        for changed in hunk.insertedHighlights {
            let absolute = NSRange(location: hunk.currentRange.location + changed.location, length: changed.length)
            let range = NSIntersectionRange(visible, absolute)
            guard range.length > 0, let textRange = editor.textRange(range, in: manager) else { continue }
            manager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
                if !rect.isEmpty { highlights.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return (band, highlights)
    }

    private func lineRect(at offset: Int, in manager: NSTextLayoutManager) -> NSRect? {
        guard let location = manager.location(manager.documentRange.location, offsetBy: offset),
              let fragment = manager.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    private static func lineCount(_ text: String) -> Int {
        let source = text as NSString
        var count = 0
        var offset = 0
        while offset < source.length {
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            count += 1
        }
        return count
    }
}

private final class JJDiffLayoutFragment: NSTextLayoutFragment {
    var before: CGFloat = 0
    var after: CGFloat = 0
    override var topMargin: CGFloat { super.topMargin + before }
    override var bottomMargin: CGFloat { super.bottomMargin + after }
}
