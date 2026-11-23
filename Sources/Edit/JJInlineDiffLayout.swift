import AppKit
import os

@MainActor
final class JJInlineDiffLayout: NSObject, NSTextLayoutManagerDelegate {
    private static let gapAttribute = NSAttributedString.Key("dev.edit.jj-inline-gap")

    private struct Gap: Equatable, Sendable {
        var before: CGFloat = 0
        var after: CGFloat = 0
    }

    private struct Entry {
        let hunk: JJDiffHunk
        let removedLineCount: Int
        var removedRows: JJRemovedRows?
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
    private var removedCaret: JJInlineDiffSelection.Position?
    var onMouseDown: ((NSEvent) -> Bool)?
    var onSelectionChange: (() -> Void)?
    var onCancel: (() -> Bool)?

    init(editor: EditorTextView) {
        self.editor = editor
    }

    func display(_ hunks: [JJDiffHunk]) {
        guard hunks != entries.map(\.hunk), let editor else { return }
        var previous = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.removedRows.map { (entry.hunk.baseRange, $0) }
        })
        entries = hunks.map { hunk in
            let rows = hunk.removedText.isEmpty ? nil : previous.removeValue(forKey: hunk.baseRange)
            return Entry(hunk: hunk, removedLineCount: Self.lineCount(hunk.removedText), removedRows: rows)
        }
        for rows in previous.values {
            if editor.window?.firstResponder === rows.textView { editor.window?.makeFirstResponder(editor) }
            rows.removeFromSuperview()
        }
        layout()
        editor.setNeedsDisplay(editor.visibleRect)
    }

    func layout() {
        guard !layingOut, let editor, let scroll = editor.enclosingScrollView, let manager = editor.textLayoutManager,
              let source = editor.textStorage?.mutableString else { return }
        layingOut = true
        defer { layingOut = false }

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
                                         visibleRange: visible, viewport: viewport)
            entries[index].insertedRect = inserted.band
            entries[index].insertedHighlightRects = inserted.highlights
            if oldBand != inserted.band || oldHighlights != inserted.highlights {
                if let oldBand { invalidated = invalidated.union(oldBand) }
                if let band = inserted.band { invalidated = invalidated.union(band) }
            }

            let removed = removedRect(for: entries[index], source: source, editor: editor,
                                      manager: manager, viewport: viewport)
            entries[index].removedRect = removed
            if let removed, removed.intersects(viewport) {
                let rows = entries[index].removedRows ?? makeRemovedRows(in: editor)
                entries[index].removedRows = rows
                rows.isHidden = false
                if rows.frame != removed { rows.frame = removed }
                rows.configure(hunk: hunk, font: editor.font ?? EditorTextView.defaultFont,
                               paragraph: editor.defaultParagraphStyle ?? .default,
                               textX: editor.textContainerOrigin.x - removed.minX,
                               padding: editor.textContainer?.lineFragmentPadding ?? 0)
                updateSelection(in: rows, for: hunk.baseRange)
            } else if let rows = entries[index].removedRows, editor.window?.firstResponder !== rows.textView {
                rows.isHidden = true
            }
        }
        if !invalidated.isNull { editor.setNeedsDisplay(invalidated.intersection(viewport)) }
    }

    func drawBackground(in dirtyRect: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.13).setFill()
        for entry in entries {
            if let band = entry.insertedRect { band.intersection(dirtyRect).fill() }
        }
        NSColor.systemGreen.withAlphaComponent(0.33).setFill()
        for entry in entries {
            for rect in entry.insertedHighlightRects where rect.intersects(dirtyRect) {
                rect.intersection(dirtyRect).fill()
            }
        }
    }

    func rect(for hunk: JJDiffHunk) -> NSRect? {
        guard let entry = entries.first(where: { $0.hunk == hunk }) else { return nil }
        if let removed = entry.removedRect, let inserted = entry.insertedRect { return removed.union(inserted) }
        return entry.removedRect ?? entry.insertedRect
    }

    func hunk(for responder: NSResponder?) -> JJDiffHunk? {
        guard let responder else { return nil }
        return entries.first { $0.removedRows?.textView === responder }?.hunk
    }

    func removedPosition(at point: NSPoint) -> JJInlineDiffSelection.Position? {
        guard let editor else { return nil }
        for entry in entries where entry.removedRect?.contains(point) == true {
            guard let rows = entry.removedRows, !rows.isHidden else { continue }
            let textView = rows.textView
            let offset = textView.characterIndexForInsertion(at: textView.convert(point, from: editor))
            guard offset != NSNotFound else { return nil }
            return .removed(key: entry.hunk.baseRange, offset: min(offset, textView.string.utf16.count))
        }
        return nil
    }

    func showSelection(_ range: NSRange?, caret: JJInlineDiffSelection.Position?, in projection: JJInlineDiffSelection?) {
        removedCaret = caret
        removedSelections.removeAll(keepingCapacity: true)
        for entry in entries {
            let key = entry.hunk.baseRange
            if let range, let block = projection?.displayRange(forRemoved: key) {
                let selected = NSIntersectionRange(range, block)
                if selected.length > 0 {
                    removedSelections[key] = NSRange(location: selected.location - block.location, length: selected.length)
                }
            }
            if let rows = entry.removedRows { updateSelection(in: rows, for: key) }
        }
    }

    private func updateSelection(in rows: JJRemovedRows, for key: NSRange) {
        let active = editor.map { $0.window?.firstResponder === $0 && $0.window?.isKeyWindow == true } ?? false
        let offset: Int?
        if case .removed(let caretKey, let caretOffset) = removedCaret, caretKey == key {
            offset = caretOffset
        } else {
            offset = nil
        }
        rows.textView.showSelection(removedSelections[key], caret: offset, active: active)
    }

    func revealCaret(at position: JJInlineDiffSelection.Position) {
        guard case .removed(let key, let offset) = position, let editor, let scroll = editor.enclosingScrollView,
              let index = entries.firstIndex(where: { $0.hunk.baseRange == key }) else { return }
        if entries[index].removedRect == nil { reveal(entries[index].hunk) }
        guard let block = entries[index].removedRect else { return }
        let source = entries[index].hunk.removedText as NSString
        let end = min(offset, max(0, source.length - 1))
        let lineStart = LineEditing.line(at: end, in: source).start
        var start = 0
        var line = 0
        while start < lineStart {
            start = NSMaxRange(source.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        let y = block.minY + CGFloat(line) * lineHeight
        let visible = scroll.documentVisibleRect
        var origin = scroll.visibleContentOrigin
        let insets = scroll.contentInsets
        if y < visible.minY + insets.top {
            origin.y += y - visible.minY - insets.top
        } else if y + lineHeight > visible.maxY - insets.bottom {
            origin.y += y + lineHeight - visible.maxY + insets.bottom
        }
        if scroll.scrollToVisibleContentOrigin(origin) {
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            layout()
        }
        guard let textView = entries[index].removedRows?.textView, let caret = textView.caretRect(at: offset) else { return }
        let x = textView.convert(caret, to: editor).minX
        let exposed = scroll.documentVisibleRect
        let left = exposed.minX + insets.left
        let right = exposed.maxX - insets.right
        guard left < right else { return }
        origin = scroll.visibleContentOrigin
        if x < left { origin.x += x - left - editor.textContainerInset.width }
        if x > right { origin.x += x - right + editor.textContainerInset.width }
        if scroll.scrollToVisibleContentOrigin(origin) { layout() }
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

    private func removedRect(for entry: Entry, source: NSString, editor: EditorTextView, manager: NSTextLayoutManager,
                             viewport: NSRect) -> NSRect? {
        guard entry.removedLineCount > 0 else { return nil }
        let height = CGFloat(entry.removedLineCount) * lineHeight
        if let emptyEditorInset {
            return NSRect(x: viewport.minX, y: emptyEditorInset.height, width: viewport.width, height: height)
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
        return NSRect(x: viewport.minX, y: top + editor.textContainerOrigin.y - height,
                      width: viewport.width, height: height)
    }

    private func insertedRects(for hunk: JJDiffHunk, sourceLength: Int, in manager: NSTextLayoutManager,
                               editor: EditorTextView, visibleRange: NSRange?, viewport: NSRect)
        -> (band: NSRect?, highlights: [NSRect]) {
        guard let visibleRange, hunk.currentRange.length > 0, NSMaxRange(hunk.currentRange) <= sourceLength else {
            return (nil, [])
        }
        let visible = NSIntersectionRange(hunk.currentRange, visibleRange)
        guard visible.length > 0,
              let first = lineRect(at: visible.location, in: manager),
              let last = lineRect(at: NSMaxRange(visible) - 1, in: manager) else { return (nil, []) }
        let origin = editor.textContainerOrigin
        let band = NSRect(x: viewport.minX, y: first.minY + origin.y, width: viewport.width,
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

    private func makeRemovedRows(in editor: EditorTextView) -> JJRemovedRows {
        let rows = JJRemovedRows()
        rows.textView.onMouseDown = { [weak self] in self?.onMouseDown?($0) ?? false }
        rows.textView.onCancel = { [weak self] in self?.onCancel?() ?? false }
        rows.textView.onSelectionChange = { [weak self] in self?.onSelectionChange?() }
        rows.textView.onLeave = { [weak self, weak rows] forward in
            guard let self, let rows else { return false }
            return self.moveIntoSource(from: rows, forward: forward)
        }
        // Keep the gutter above removed rows as they scroll beneath it.
        editor.addSubview(rows, positioned: .below, relativeTo: nil)
        return rows
    }

    private func moveIntoSource(from rows: JJRemovedRows, forward: Bool) -> Bool {
        guard let editor, let hunk = hunk(for: rows.textView), let window = editor.window,
              let source = editor.textStorage?.mutableString else { return false }
        let boundary = min(hunk.currentRange.location, source.length)
        guard forward || boundary > 0 else { return false }
        if forward, boundary == source.length, source.length > 0 { return false }
        let terminalRowBeforeRemoval = boundary == source.length && LineEditing.line(at: boundary, in: source).start == boundary
        let target = LineEditing.line(at: forward || terminalRowBeforeRemoval ? boundary : boundary - 1, in: source)
        let removed = rows.textView.string as NSString
        let caret = rows.textView.selectedRange().location
        let column = caret - LineEditing.line(at: caret, in: removed).start
        let offset = Self.offset(in: target, column: column, source: source)
        let selection = NSRange(location: offset, length: 0)
        guard editor.focusAllowsEdits([selection]), window.makeFirstResponder(editor) else { return false }
        editor.setCaretSelections([selection], record: false)
        editor.scrollRangeToVisible(selection)
        onSelectionChange?()
        return true
    }

    private static func offset(in line: LineEditing.Line, column: Int, source: NSString) -> Int {
        let offset = min(line.start + column, line.contentEnd)
        return offset < source.length ? source.rangeOfComposedCharacterSequence(at: offset).location : offset
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

@MainActor
private final class JJRemovedRows: NSView {
    let textView = JJRemovedTextView(usingTextLayoutManager: true)
    private var text: String = ""
    private var highlights: [NSRange] = []
    private var font: NSFont?
    private var paragraph: NSParagraphStyle?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        textView.clipsToBounds = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = textView
        textView.setAccessibilityLabel("Removed text")
        addSubview(textView)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (NSColor.textBackgroundColor.blended(withFraction: 0.14, of: .systemRed) ?? .textBackgroundColor).setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(hunk: JJDiffHunk, font: NSFont, paragraph: NSParagraphStyle, textX: CGFloat, padding: CGFloat) {
        let left = min(0, textX)
        let frame = NSRect(x: left, y: 0, width: bounds.width - left, height: bounds.height)
        if textView.frame != frame { textView.frame = frame }
        let inset = NSSize(width: textX - left, height: 0)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        if textView.textContainer?.lineFragmentPadding != padding { textView.textContainer?.lineFragmentPadding = padding }
        guard text != hunk.removedText || highlights != hunk.removedHighlights || font != self.font || paragraph != self.paragraph else { return }
        let oldSelection = textView.selectedRange()
        text = hunk.removedText
        highlights = hunk.removedHighlights
        self.font = font
        self.paragraph = paragraph
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor,
        ])
        for highlight in highlights where NSMaxRange(highlight) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.36), range: highlight)
        }
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.setAttributedString(attributed)
        let start = min(oldSelection.location, attributed.length)
        let selection = NSRange(location: start, length: min(oldSelection.length, attributed.length - start))
        textView.setSelectedRange(selection)
    }
}

@MainActor
private final class JJRemovedTextView: NSTextView, NSTextViewDelegate {
    var onMouseDown: ((NSEvent) -> Bool)?
    var onCancel: (() -> Bool)?
    var onLeave: ((Bool) -> Bool)?
    var onSelectionChange: (() -> Void)?
    private var projectedSelection: NSRange?
    private var selectionIsActive = false
    private var caretOffset: Int?
    private var caretView: CaretIndicatorGroup?

    override func mouseDown(with event: NSEvent) {
        if onMouseDown?(event) != true { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let selection = projectedSelection, let layout = textLayoutManager,
              let start = layout.location(layout.documentRange.location, offsetBy: selection.location),
              let end = layout.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end) else { return }
        (selectionIsActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        let origin = textContainerOrigin
        layout.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) { _, rect, _, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).intersection(dirtyRect).fill()
            return true
        }
    }

    func showSelection(_ selection: NSRange?, caret: Int?, active: Bool) {
        if projectedSelection != selection || selectionIsActive != active {
            projectedSelection = selection
            selectionIsActive = active
            needsDisplay = true
        }
        let restartBlink = caret != caretOffset
        caretOffset = caret
        let viewport = visibleRect
        guard let caret, let rect = caretRect(at: caret), !viewport.isEmpty else {
            caretView?.removeFromSuperview()
            caretView = nil
            return
        }
        let group = caretView ?? CaretIndicatorGroup()
        if caretView == nil {
            group.wantsLayer = true
            group.clipsToBounds = true
            addSubview(group)
            caretView = group
        }
        group.isHidden = !active
        group.update([rect], viewport: viewport, color: .textColor, restartBlink: restartBlink)
    }

    func caretRect(at offset: Int) -> NSRect? {
        guard let window else { return nil }
        let source = string as NSString
        let offset = min(offset, source.length)
        // TextKit gives a block ending with a newline an extra insertion line.
        // A caret with trailing affinity to this block belongs on its last visible row.
        let location = offset == source.length && offset > 0
            ? LineEditing.line(at: offset - 1, in: source).contentEnd : offset
        let screenRect = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        guard screenRect.height > 0 else { return nil }
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused { onSelectionChange?() }
        return focused
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if window?.firstResponder === self { onSelectionChange?() }
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() != true { super.cancelOperation(sender) }
    }

    override func moveUp(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, (string as NSString).lineRange(for: selection).location == 0,
           onLeave?(false) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        if selection.length == 0, NSMaxRange(source.lineRange(for: selection)) == source.length,
           onLeave?(true) == true { return }
        super.moveDown(sender)
    }
}
