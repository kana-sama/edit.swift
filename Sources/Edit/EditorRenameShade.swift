import AppKit

@MainActor
final class EditorRenameShade: NSView {
    private weak var editor: EditorTextView?
    private var openings: [NSRect] = []

    init(editor: EditorTextView) {
        self.editor = editor
        super.init(frame: .zero)
        identifier = .init("Edit.RenameSymbol.Shade")
        setAccessibilityElement(false)
        clipsToBounds = true
        wantsLayer = true
        layer?.zPosition = 1
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("Rename shading is created in code.") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update() {
        guard let editor, let range = editor.renameRange, !editor.visibleRect.isEmpty else {
            isHidden = true
            return
        }
        let viewport = editor.visibleRect
        let segments: [NSRect]
        if range.length == 0, let caret = editor.lineBounds(at: range.location) {
            // An empty name has no glyphs, but its insertion point still needs a cutout.
            let width = max(caret.width, 1.5)
            segments = [NSRect(x: caret.midX - width / 2, y: caret.minY, width: width, height: caret.height)]
        } else {
            segments = editor.highlightRects(for: [range])
        }
        let nextOpenings = segments.filter { $0.intersects(viewport) }.map {
            $0.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        }
        guard isHidden || frame != viewport || openings != nextOpenings else { return }
        frame = viewport
        openings = nextOpenings
        isHidden = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let context = NSGraphicsContext.current?.cgContext else { return }
        context.addRect(bounds)
        for opening in openings {
            if opening.width <= 2 {
                context.addRect(opening)
            } else {
                let radius = min(3, opening.width / 2, opening.height / 2)
                context.addPath(CGPath(roundedRect: opening, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        editor.backgroundColor.withAlphaComponent(contrast ? 0.48 : 0.72).setFill()
        context.fillPath(using: .evenOdd)
    }
}
