import AppKit

@MainActor
final class JJInlineDiffControls: NSView {
    private let glass = NSGlassEffectView()
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let restore: () -> Void
    private let previous: () -> Void
    private let next: () -> Void
    private var hoverArea: NSTrackingArea?

    var onCancel: (() -> Bool)?
    var onHoverChange: ((Bool) -> Void)?

    init(restore: @escaping () -> Void, previous: @escaping () -> Void, next: @escaping () -> Void) {
        self.restore = restore
        self.previous = previous
        self.next = next
        super.init(frame: .zero)

        identifier = .init("Edit.Diff.Actions")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Change Actions")

        configure(restoreButton, identifier: "Edit.Diff.Restore", label: "Restore Change", action: #selector(restoreChange))
        configure(nextButton, identifier: "Edit.Diff.Next", label: "Next Change", action: #selector(nextChange), symbol: "arrow.down")
        configure(previousButton, identifier: "Edit.Diff.Previous", label: "Previous Change",
                  action: #selector(previousChange), symbol: "arrow.up")

        let buttons = NSStackView(views: [restoreButton, nextButton, previousButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 2
        buttons.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)

        glass.cornerRadius = 12
        glass.style = .regular
        glass.effectIsInteractive = true
        glass.contentView = buttons
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        for button in [restoreButton, nextButton, previousButton] {
            button.widthAnchor.constraint(equalToConstant: button === restoreButton ? 56 : 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        glass.contentView?.fittingSize ?? .zero
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

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

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

    @objc private func restoreChange() { restore() }
    @objc private func previousChange() { previous() }
    @objc private func nextChange() { next() }
}
