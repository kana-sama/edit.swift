import AppKit

@MainActor
final class JJInlineDiffControls: NSView {
    let hunkKey: NSRange
    private let buttons = NSStackView()
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let restore: (NSRange) -> Void
    private let navigate: (NSRange, Int) -> Void
    private var hoverArea: NSTrackingArea?

    var onCancel: (() -> Bool)?
    var onPointerChange: ((NSEvent) -> Void)?

    init(hunkKey: NSRange, restore: @escaping (NSRange) -> Void, navigate: @escaping (NSRange, Int) -> Void) {
        self.hunkKey = hunkKey
        self.restore = restore
        self.navigate = navigate
        super.init(frame: .zero)

        identifier = .init("Edit.Diff.Actions")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Change Actions")

        configure(restoreButton, identifier: "Edit.Diff.Restore", label: "Restore Change", action: #selector(restoreChange))
        configure(nextButton, identifier: "Edit.Diff.Next", label: "Next Change", action: #selector(nextChange), symbol: "arrow.down")
        configure(previousButton, identifier: "Edit.Diff.Previous", label: "Previous Change",
                  action: #selector(previousChange), symbol: "arrow.up")

        let separator = NSBox()
        separator.boxType = .separator
        for view in [restoreButton, separator, previousButton, nextButton] as [NSView] {
            buttons.addArrangedSubview(view)
        }
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 2
        buttons.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        for button in [restoreButton, nextButton, previousButton] {
            button.widthAnchor.constraint(equalToConstant: button === restoreButton ? 56 : 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        }
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 17),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: topAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { buttons.fittingSize }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor.controlBackgroundColor.blended(withFraction: 0.06, of: .textColor)
            ?? .controlBackgroundColor
        background.withAlphaComponent(1).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.stroke()
    }

    func setAvailability(restore: Bool, previous: Bool, next: Bool) {
        restoreButton.isEnabled = restore
        previousButton.isEnabled = previous
        nextButton.isEnabled = next
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onPointerChange?(event) }
    override func mouseExited(with event: NSEvent) { onPointerChange?(event) }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() != true { super.cancelOperation(sender) }
    }

    private func configure(_ button: NSButton, identifier: String, label: String, action: Selector, symbol: String? = nil) {
        button.identifier = .init(identifier)
        button.target = self
        button.action = action
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.imagePosition = .imageOnly
        }
    }

    @objc private func restoreChange() { restore(hunkKey) }
    @objc private func previousChange() { navigate(hunkKey, -1) }
    @objc private func nextChange() { navigate(hunkKey, 1) }
}
