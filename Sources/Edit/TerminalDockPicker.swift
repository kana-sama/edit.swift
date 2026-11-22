import AppKit

@MainActor
final class TerminalDockPicker: NSViewController {
    private let selected: TerminalDock
    private let onSelect: (TerminalDock) -> Void
    private weak var selectedButton: NSButton?

    init(selected: TerminalDock, onSelect: @escaping (TerminalDock) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let choices = [TerminalDock.below, .right].map { dock in
            let button = DockPreviewButton(dock: dock, selected: dock == selected)
            button.target = self
            button.action = #selector(selectDock(_:))
            if dock == selected { selectedButton = button }
            return button
        }
        let stack = NSStackView(views: choices)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        view = stack
        preferredContentSize = stack.fittingSize
    }

    func focusSelection() {
        view.window?.makeFirstResponder(selectedButton)
    }

    @objc private func selectDock(_ sender: DockPreviewButton) {
        onSelect(sender.dock)
    }
}

@MainActor
private final class DockPreviewButton: NSButton {
    let dock: TerminalDock

    init(dock: TerminalDock, selected: Bool) {
        self.dock = dock
        super.init(frame: .zero)
        title = dock == .below ? "Dock Below" : "Dock Right"
        identifier = .init(dock == .below ? "Edit.Terminal.DockBelow" : "Edit.Terminal.DockRight")
        setButtonType(.radio)
        isBordered = false
        state = selected ? .on : .off
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 82) }

    private var miniature: NSRect {
        NSRect(x: 4, y: 5, width: bounds.width - 8, height: bounds.height - 28)
    }

    override var focusRingMaskBounds: NSRect { miniature.insetBy(dx: -2, dy: -2) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let accent = NSColor.controlAccentColor
        let shape = NSBezierPath(roundedRect: miniature, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.textBackgroundColor.setFill()
        miniature.fill()

        let toolbar = NSRect(x: miniature.minX, y: miniature.minY, width: miniature.width, height: 11)
        let body = NSRect(x: miniature.minX, y: toolbar.maxY, width: miniature.width, height: miniature.height - toolbar.height)
        let pane = dock == .below
            ? NSRect(x: body.minX, y: body.maxY - 16, width: body.width, height: 16)
            : NSRect(x: body.maxX - 27, y: body.minY, width: 27, height: body.height)
        NSColor.windowBackgroundColor.setFill()
        toolbar.fill()
        accent.withAlphaComponent(isHighlighted ? 0.3 : 0.16).setFill()
        pane.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: toolbar.minX, y: toolbar.maxY - 1, width: toolbar.width, height: 1).fill()
        if dock == .below {
            NSRect(x: pane.minX, y: pane.minY, width: pane.width, height: 1).fill()
        } else {
            NSRect(x: pane.minX, y: pane.minY, width: 1, height: pane.height).fill()
        }
        NSColor.tertiaryLabelColor.setFill()
        for index in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: miniature.minX + 6 + CGFloat(index) * 5,
                                       y: toolbar.minY + 4, width: 3, height: 3)).fill()
        }
        for (index, length) in [26.0, 17.0, 22.0].enumerated() {
            NSRect(x: body.minX + 7, y: body.minY + 7 + CGFloat(index) * 4, width: length, height: 1).fill()
        }

        accent.setStroke()
        let prompt = NSBezierPath()
        let promptY = pane.minY + 8
        prompt.move(to: NSPoint(x: pane.minX + 5, y: promptY + 2))
        prompt.line(to: NSPoint(x: pane.minX + 8, y: promptY))
        prompt.line(to: NSPoint(x: pane.minX + 5, y: promptY - 2))
        prompt.move(to: NSPoint(x: pane.minX + 10, y: promptY - 2))
        prompt.line(to: NSPoint(x: pane.minX + 15, y: promptY - 2))
        prompt.lineWidth = 1.5
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if selected {
            accent.setStroke()
            let outline = NSBezierPath(roundedRect: miniature.insetBy(dx: -1.5, dy: -1.5), xRadius: 7.5, yRadius: 7.5)
            outline.lineWidth = 2.5
            outline.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        label.draw(at: NSPoint(x: bounds.midX - label.size().width / 2, y: miniature.maxY + 6))
    }
}
