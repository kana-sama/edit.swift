import AppKit

struct AnchoredPopoverShape {
    static let pointerHeight: CGFloat = 6
    static let pointerHalfWidth: CGFloat = 7
    static let pointerEdgeInset: CGFloat = 2
    private static let cornerRadius: CGFloat = 12

    let contentFrame: NSRect
    let pointerX: CGFloat
    private let pointsDown: Bool

    init(contentSize: NSSize, pointerX: CGFloat, pointsDown: Bool) {
        contentFrame = NSRect(x: 0, y: pointsDown ? Self.pointerHeight : 0,
                              width: contentSize.width, height: contentSize.height)
        self.pointerX = min(max(pointerX, Self.pointerEdgeInset), contentSize.width - Self.pointerEdgeInset)
        self.pointsDown = pointsDown
    }

    func outline() -> CGPath {
        let width = contentFrame.width
        let height = contentFrame.height
        let radius = Self.cornerRadius
        let clearance = radius + Self.pointerHalfWidth + 1
        let pointerBaseX = min(max(pointerX, clearance), width - clearance)
        let rightBase = pointerBaseX + Self.pointerHalfWidth
        let leftBase = pointerBaseX - Self.pointerHalfWidth
        let tip = height + Self.pointerHeight
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: height), radius: radius)
        path.addArc(tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: rightBase, y: height), radius: radius)
        path.addLine(to: CGPoint(x: rightBase, y: height))
        path.addLine(to: CGPoint(x: pointerX + 1.5, y: tip - 0.6))
        path.addQuadCurve(to: CGPoint(x: pointerX - 1.5, y: tip - 0.6),
                          control: CGPoint(x: pointerX, y: tip + 0.6))
        path.addLine(to: CGPoint(x: leftBase, y: height))
        path.addArc(tangent1End: CGPoint(x: 0, y: height), tangent2End: .zero, radius: radius)
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()
        guard pointsDown else { return path }
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: tip)
        return path.copy(using: &flip) ?? path
    }
}

@MainActor
class AnchoredPopoverSurface: NSVisualEffectView {
    private let outline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 1
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError("Anchored popover surfaces are created in code.") }

    func applyOutline(_ shape: AnchoredPopoverShape) {
        applyOutline(shape.outline())
    }

    func applyOutline(_ path: CGPath) {
        maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(path)
            context.fillPath()
            return true
        }
        outline.frame = bounds
        outline.path = path
        updateOutlineColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOutlineColor()
    }

    private func updateOutlineColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = NSColor.separatorColor.cgColor
        }
    }
}
