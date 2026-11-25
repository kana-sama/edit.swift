import AppKit

@MainActor
final class ModeSelector: NSControl {
    static let height: CGFloat = 22
    static let cornerRadius: CGFloat = 6
    static let trackOpacity: CGFloat = 0.08
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let selectionInset: CGFloat = 1
    private let indicator = NSView()
    private let buttons: [ModeButton]
    private let widths: [CGFloat]
    private let equalWidths: Bool
    private(set) var selectedSegment = -1
    var onSelect: ((Int) -> Void)?

    init(_ titles: [String], equalWidths: Bool = false) {
        precondition(!titles.isEmpty)
        self.equalWidths = equalWidths
        let font = Self.titleFont
        widths = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 18 }
        buttons = titles.map { ModeButton(title: $0, target: nil, action: nil) }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        focusRingType = .exterior
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = Self.cornerRadius - Self.selectionInset
        indicator.isHidden = true
        indicator.setAccessibilityElement(false)
        addSubview(indicator)
        for (index, button) in buttons.enumerated() {
            button.tag = index
            button.setButtonType(.radio)
            button.imagePosition = .noImage
            button.isBordered = false
            button.font = font
            button.alignment = .center
            button.target = self
            button.action = #selector(choose(_:))
            addSubview(button)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Mode selectors are created in code.") }

    override var intrinsicContentSize: NSSize {
        let width = equalWidths ? (widths.max() ?? 0) * CGFloat(widths.count) : widths.reduce(0, +)
        return NSSize(width: width, height: Self.height)
    }

    override var isEnabled: Bool {
        didSet {
            buttons.forEach { $0.isEnabled = isEnabled }
            updateColors()
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() { button.frame = segmentFrame(at: index) }
        moveIndicator(from: nil)
    }

    func setSelection(_ index: Int) {
        let selection = buttons.indices.contains(index) ? index : -1
        guard selectedSegment != selection else { return }
        let inFlight = indicator.layer?.animation(forKey: "selection") != nil
        let prior = indicator.isHidden ? nil : ((inFlight ? indicator.layer?.presentation()?.frame : nil) ?? indicator.frame)
        selectedSegment = selection
        updateButtonStates()
        moveIndicator(from: prior)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        buttons.indices.contains(selectedSegment) ? [buttons[selectedSegment]] : []
    }

    override func moveLeft(_ sender: Any?) { moveSelection(by: userInterfaceLayoutDirection == .rightToLeft ? 1 : -1) }

    override func moveRight(_ sender: Any?) { moveSelection(by: userInterfaceLayoutDirection == .rightToLeft ? -1 : 1) }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    func segmentFrame(at index: Int) -> NSRect {
        let total = widths.reduce(0, +)
        let before = widths.prefix(index).reduce(0, +)
        let leftFraction = equalWidths ? CGFloat(index) / CGFloat(widths.count) : before / total
        let widthFraction = equalWidths ? 1 / CGFloat(widths.count) : widths[index] / total
        let left = round(bounds.width * leftFraction)
        let right = round(bounds.width * (leftFraction + widthFraction))
        let x = userInterfaceLayoutDirection == .rightToLeft ? bounds.maxX - right : bounds.minX + left
        return NSRect(x: x, y: bounds.minY, width: max(0, right - left), height: bounds.height)
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(Self.trackOpacity).cgColor
            indicator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isEnabled ? 0.12 : 0.08).cgColor
        }
    }

    private func moveIndicator(from prior: NSRect?) {
        let show = buttons.indices.contains(selectedSegment) && !bounds.isEmpty
        indicator.isHidden = !show
        guard let thumb = indicator.layer else { return }
        guard show else { thumb.removeAllAnimations(); return }
        let frame = segmentFrame(at: selectedSegment).insetBy(dx: Self.selectionInset, dy: Self.selectionInset)
        if frame == indicator.frame && prior == nil { return }
        thumb.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = frame
        CATransaction.commit()
        guard let prior, !prior.isEmpty, window != nil, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSPoint(x: prior.midX, y: prior.midY)
        movement.toValue = NSPoint(x: frame.midX, y: frame.midY)
        let resizing = CABasicAnimation(keyPath: "bounds.size")
        resizing.fromValue = prior.size
        resizing.toValue = frame.size
        let slide = CAAnimationGroup()
        slide.animations = [movement, resizing]
        slide.duration = 0.18
        movement.duration = slide.duration
        resizing.duration = slide.duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        thumb.add(slide, forKey: "selection")
    }

    private func moveSelection(by offset: Int) {
        guard isEnabled else { return }
        let start = selectedSegment < 0 && offset < 0 ? 0 : selectedSegment
        onSelect?((start + offset + buttons.count) % buttons.count)
    }

    @objc private func choose(_ sender: ModeButton) {
        // Native buttons track the click, while the owner commits the selection.
        updateButtonStates()
        guard isEnabled else { return }
        onSelect?(sender.tag)
    }

    private func updateButtonStates() {
        for button in buttons { button.state = button.tag == selectedSegment ? .on : .off }
    }

    #if EDIT_AGENT_CHECKS
    func buttonForCheck(at index: Int) -> NSButton { buttons[index] }

    func hasLocalSlideForCheck(from start: Int, to end: Int) -> Bool {
        let slide = indicator.layer?.animation(forKey: "selection") as? CAAnimationGroup
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return slide == nil }
        guard let movement = slide?.animations?.compactMap({ $0 as? CABasicAnimation }).first(where: { $0.keyPath == "position" }),
              let from = (movement.fromValue as? NSValue)?.pointValue,
              let to = (movement.toValue as? NSValue)?.pointValue else { return false }
        return abs(from.x - segmentFrame(at: start).midX) < 1 && abs(to.x - segmentFrame(at: end).midX) < 1 &&
            abs(from.y - bounds.midY) < 1 && abs(to.y - bounds.midY) < 1 && layer?.masksToBounds == true
    }
    #endif
}

@MainActor
private final class ModeButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
}
