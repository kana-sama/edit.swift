import AppKit

@MainActor
final class FindDecorations {
    private weak var editor: EditorTextView?
    private var ranges: [NSRange] = []
    private var selected: NSRange?
    private var preview: (NSRange, String)?
    private var snapshot = ""
    private var installed: [NSRange: Bool] = [:]
    private var previewView: FindPreviewView?
    private var layingOut = false

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
            previewView?.isHidden = true
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
            previewView?.isHidden = true
            return
        }
        let source = snapshot as NSString
        guard NSMaxRange(range) <= source.length, source.length > 0 else {
            previewView?.isHidden = true
            return
        }
        let start = LineEditing.line(at: range.location, in: source).start
        let last = LineEditing.line(at: max(range.location, NSMaxRange(range) - 1), in: source)
        let end = max(last.contentEnd, NSMaxRange(range))
        let removed = source.substring(with: NSRange(location: start, length: end - start))
        let added = source.substring(with: NSRange(location: start, length: range.location - start))
            + replacement + source.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))

        let screen = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let anchor = editor.convert(window.convertFromScreen(screen), from: nil)
        let visible = editor.visibleRect
        guard visible.width > 0 && visible.height > 0, anchor.height > 0,
              anchor.maxY >= visible.minY && anchor.minY <= visible.maxY else {
            previewView?.isHidden = true
            return
        }

        let view = previewView ?? FindPreviewView(frame: .zero)
        if previewView == nil {
            editor.addSubview(view)
            previewView = view
        }
        view.configure(removed: removed, added: added, font: font, lineHeight: anchor.height,
                       textOffset: editor.textContainerOrigin.x - visible.minX,
                       paragraphStyle: editor.defaultParagraphStyle)
        let height = min(view.naturalHeight, visible.height)
        let top = max(visible.minY, min(anchor.minY, visible.maxY - height))
        view.frame = NSRect(x: visible.minX, y: top, width: visible.width, height: height)
        view.isHidden = false
    }
}

private final class FindPreviewView: NSView {
    private var removed: [String] = []
    private var added: [String] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var lineHeight: CGFloat = 16
    private var textOffset: CGFloat = 0
    private var paragraphStyle: NSParagraphStyle?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var naturalHeight: CGFloat { CGFloat(removed.count + added.count) * lineHeight }

    func configure(
        removed: String, added: String, font: NSFont, lineHeight: CGFloat, textOffset: CGFloat,
        paragraphStyle: NSParagraphStyle?
    ) {
        self.removed = Self.lines(in: removed)
        self.added = Self.lines(in: added)
        self.font = font
        self.lineHeight = lineHeight
        self.textOffset = textOffset
        self.paragraphStyle = paragraphStyle
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Replace \(removed) with \(added)")
        needsDisplay = true
    }

    private static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawLines(removed, startingAt: 0, color: .systemRed, dirtyRect: dirtyRect)
        drawLines(added, startingAt: removed.count, color: .systemGreen, dirtyRect: dirtyRect)
    }

    private func drawLines(_ lines: [String], startingAt offset: Int, color: NSColor, dirtyRect: NSRect) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        attributes[.paragraphStyle] = paragraphStyle
        color.withAlphaComponent(0.22).setFill()
        for (index, line) in lines.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index + offset) * lineHeight, width: bounds.width, height: lineHeight)
            guard row.intersects(dirtyRect) else { continue }
            row.fill()
            (line as NSString).draw(at: NSPoint(x: textOffset, y: row.minY), withAttributes: attributes)
        }
    }
}
