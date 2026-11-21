import AppKit

@MainActor
final class FindDecorations {
    private static let previewAttribute = NSAttributedString.Key("dev.edit.find-preview")

    private final class PreviewStyle: NSObject {
        let original: NSParagraphStyle?
        init(_ original: NSParagraphStyle?) { self.original = original }
    }
    private weak var editor: EditorTextView?
    private var ranges: [NSRange] = []
    private var selected: NSRange?
    private var preview: (NSRange, String)?
    private var snapshot = ""
    private var installed: [NSRange: Bool] = [:]
    private var previewView: FindPreviewView?
    private var layingOut = false
    private var previewPadding: (range: NSRange, height: CGFloat, source: String)?

    init(editor: EditorTextView) { self.editor = editor }

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

        if editor.string != snapshot {
            if !installed.isEmpty {
                manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
                installed.removeAll()
            }
            clearPreview()
            return
        }

        var desired: [NSRange: Bool] = [:]
        if let viewport = manager.textViewportLayoutController.viewportRange {
            let first = manager.offset(from: manager.documentRange.location, to: viewport.location)
            let last = manager.offset(from: manager.documentRange.location, to: viewport.endLocation)
            if first >= 0 && last >= first {
                var index = firstRangeEnding(after: first)
                while index < ranges.count && ranges[index].location < last {
                    let range = ranges[index]
                    if range.length > 0 { desired[range] = range == selected }
                    index += 1
                }
            }
        }
        if let selected, selected.length > 0 { desired[selected] = true }
        let length = editor.textStorage?.length ?? 0
        for (range, active) in installed where desired[range] != active {
            if let textRange = layoutRange(range, length: length, manager: manager) {
                manager.removeRenderingAttribute(.backgroundColor, for: textRange)
            }
        }
        for (range, active) in desired where installed[range] != active {
            if let textRange = layoutRange(range, length: length, manager: manager) {
                let color = active ? NSColor.systemOrange.withAlphaComponent(0.55)
                    : NSColor.systemYellow.withAlphaComponent(0.30)
                manager.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
            }
        }
        installed = desired
        updatePreview(in: editor)
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

    private func layoutRange(_ range: NSRange, length: Int, manager: NSTextLayoutManager) -> NSTextRange? {
        guard NSMaxRange(range) <= length,
              let start = manager.location(manager.documentRange.location, offsetBy: range.location),
              let end = manager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func updatePreview(in editor: EditorTextView) {
        guard let (range, replacement) = preview, let window = editor.window, let font = editor.font else {
            clearPreview()
            return
        }
        let source = snapshot as NSString
        guard NSMaxRange(range) <= source.length, source.length > 0 else {
            clearPreview()
            return
        }
        let start = LineEditing.line(at: range.location, in: source).start
        let last = LineEditing.line(at: max(range.location, NSMaxRange(range) - 1), in: source)
        let end = max(last.contentEnd, NSMaxRange(range))
        let removed = source.substring(with: NSRange(location: start, length: end - start))
        let added = source.substring(with: NSRange(location: start, length: range.location - start))
            + replacement + source.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))

        let screen = editor.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        let anchor = editor.convert(window.convertFromScreen(screen), from: nil)
        let visible = editor.visibleRect
        guard visible.width > 0 && visible.height > 0, anchor.height > 0 else {
            previewView?.isHidden = true
            return
        }

        let view = previewView ?? FindPreviewView(frame: .zero)
        if previewView == nil {
            editor.addSubview(view)
            previewView = view
        }
        let offset = range.location - start
        view.configure(removed: removed, removedRange: NSRange(location: offset, length: range.length),
                       added: added, addedRange: NSRange(location: offset, length: replacement.utf16.count),
                       font: font, lineHeight: anchor.height,
                       textOffset: editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0) - visible.minX,
                       paragraphStyle: editor.defaultParagraphStyle)
        if setPreviewPadding(range: last.range, height: view.addedHeight) {
            let updated = editor.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            view.frame = NSRect(x: visible.minX, y: editor.convert(window.convertFromScreen(updated), from: nil).minY,
                                width: visible.width, height: view.naturalHeight)
        } else {
            view.frame = NSRect(x: visible.minX, y: anchor.minY, width: visible.width, height: view.naturalHeight)
        }
        view.isHidden = !visible.intersects(view.frame)
    }

    func clearPreview() {
        previewView?.isHidden = true
        setPreviewPadding(range: nil, height: 0)
    }

    @discardableResult
    private func setPreviewPadding(range: NSRange?, height: CGFloat) -> Bool {
        guard let editor, let storage = editor.textStorage else { return false }
        let old = previewPadding
        let source = editor.string
        if old?.range == range && (old?.height ?? 0) == height && (old == nil || old?.source == source) { return false }
        previewPadding = range.map { ($0, height, source) }
        storage.beginEditing()
        if let old, storage.length > 0 {
            // If text changed from under the preview, the marked style may have moved with it.
            let affected = old.source == source && NSMaxRange(old.range) <= storage.length
                ? old.range : NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(Self.previewAttribute, in: affected) { value, span, _ in
                guard let style = value as? PreviewStyle else { return }
                storage.removeAttribute(Self.previewAttribute, range: span)
                if let original = style.original {
                    storage.addAttribute(.paragraphStyle, value: original, range: span)
                } else {
                    storage.removeAttribute(.paragraphStyle, range: span)
                }
            }
        }
        if let range, range.length > 0, NSMaxRange(range) <= storage.length {
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, span, _ in
                let original = value as? NSParagraphStyle
                let base = original ?? editor.defaultParagraphStyle ?? .default
                let padded = base.mutableCopy() as! NSMutableParagraphStyle
                padded.paragraphSpacing += height
                storage.addAttributes([.paragraphStyle: padded, Self.previewAttribute: PreviewStyle(original)], range: span)
            }
        }
        storage.endEditing()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        return true
    }
}

private final class FindPreviewView: NSView {
    private struct Line {
        let text: String
        let changed: NSRange
    }

    private var removed: [Line] = []
    private var added: [Line] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var lineHeight: CGFloat = 16
    private var textOffset: CGFloat = 0
    private var paragraphStyle: NSParagraphStyle?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var addedHeight: CGFloat { CGFloat(added.count) * lineHeight }

    var naturalHeight: CGFloat { CGFloat(removed.count + added.count) * lineHeight }

    func configure(
        removed: String, removedRange: NSRange, added: String, addedRange: NSRange,
        font: NSFont, lineHeight: CGFloat, textOffset: CGFloat, paragraphStyle: NSParagraphStyle?
    ) {
        clipsToBounds = true
        self.removed = Self.lines(in: removed, changed: removedRange)
        self.added = Self.lines(in: added, changed: addedRange)
        self.font = font
        self.lineHeight = lineHeight
        self.textOffset = textOffset
        self.paragraphStyle = paragraphStyle
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Replace \(removed) with \(added)")
        needsDisplay = true
    }

    private static func lines(in text: String, changed: NSRange) -> [Line] {
        let source = text as NSString
        var lines: [Line] = []
        var start = 0
        var end = 0
        var contentEnd = 0
        repeat {
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                                for: NSRange(location: end, length: 0))
            let range = NSRange(location: start, length: contentEnd - start)
            let intersection = NSIntersectionRange(changed, range)
            let relativeChange = intersection.length > 0
                ? NSRange(location: intersection.location - start, length: intersection.length)
                : NSRange(location: 0, length: 0)
            lines.append(Line(text: source.substring(with: range), changed: relativeChange))
        } while end < source.length
        if contentEnd < end { lines.append(Line(text: "", changed: NSRange(location: 0, length: 0))) }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawLines(removed, startingAt: 0, color: .systemRed, dirtyRect: dirtyRect)
        drawLines(added, startingAt: removed.count, color: .systemGreen, dirtyRect: dirtyRect)
    }

    private func drawLines(_ lines: [Line], startingAt offset: Int, color: NSColor, dirtyRect: NSRect) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        attributes[.paragraphStyle] = paragraphStyle
        color.withAlphaComponent(0.22).setFill()
        for (index, line) in lines.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index + offset) * lineHeight, width: bounds.width, height: lineHeight)
            guard row.intersects(dirtyRect) else { continue }
            row.fill()
            let text = NSMutableAttributedString(string: line.text, attributes: attributes)
            if line.changed.length > 0 {
                text.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.42), range: line.changed)
            }
            text.draw(at: NSPoint(x: textOffset, y: row.minY))
        }
    }
}
