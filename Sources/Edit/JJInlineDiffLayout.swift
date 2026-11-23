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
        guard !layingOut, let editor, let manager = editor.textLayoutManager,
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
        let viewport = editor.enclosingScrollView?.documentVisibleRect ?? editor.visibleRect
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

    func moveFromSource(forward: Bool) -> Bool {
        guard let editor, let window = editor.window, window.firstResponder === editor,
              let source = editor.textStorage?.mutableString else { return false }
        let caret = editor.selectedRange()
        guard caret.length == 0, caret.location <= source.length else { return false }
        let line = LineEditing.line(at: caret.location, in: source)
        if forward, line.end == source.length, line.contentEnd < line.end { return false }
        let boundary = forward ? line.end : line.start
        guard let hunk = entries.first(where: {
            $0.removedLineCount > 0 && $0.hunk.currentRange.location == boundary
        })?.hunk, forward || boundary < source.length || source.length == 0 else { return false }

        if entries.first(where: { $0.hunk == hunk })?.removedRows?.isHidden != false {
            reveal(hunk)
            layout()
        }
        guard let rows = entries.first(where: { $0.hunk == hunk })?.removedRows,
              window.makeFirstResponder(rows.textView) else { return false }
        let removed = rows.textView.string as NSString
        let destination = LineEditing.line(at: forward ? 0 : max(0, removed.length - 1), in: removed)
        let offset = Self.offset(in: destination, column: caret.location - line.start, source: removed)
        let selection = NSRange(location: offset, length: 0)
        rows.textView.setSelectedRange(selection)
        rows.textView.scrollRangeToVisible(selection)
        return true
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
    var onCancel: (() -> Bool)?
    var onLeave: ((Bool) -> Bool)?
    var onSelectionChange: (() -> Void)?

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
