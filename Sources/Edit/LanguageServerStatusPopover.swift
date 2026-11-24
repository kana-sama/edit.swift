import AppKit

@MainActor
final class LanguageServerStatusPopover: NSObject {
    enum Indicator: Equatable {
        case ready, stopped, partial

        init?(states: [LanguageServerSession.State]) {
            guard !states.isEmpty else { return nil }
            if states.allSatisfy({ $0 == .ready }) { self = .ready }
            else if states.contains(where: { [.ready, .starting, .stopping].contains($0) }) { self = .partial }
            else { self = .stopped }
        }

        var color: NSColor {
            switch self {
            case .ready: .systemGreen
            case .stopped: .systemRed
            case .partial: .systemYellow
            }
        }
    }

    private let statusButton = StatusButton()
    var button: NSButton { statusButton }
    var indicator: Indicator? { statusButton.indicator }
    private let popover = NSPopover()
    private let name = NSTextField(labelWithString: "ZLS")
    private let icon = NSImageView()
    private let toggleControl = NSButton()
    private let restartControl = NSButton()
    private let perform: (LanguageServerCommand) -> Void
    private var toggleCommand = LanguageServerCommand.start

    init(perform: @escaping (LanguageServerCommand) -> Void) {
        self.perform = perform
        super.init()

        button.identifier = .init("Edit.LanguageServer.Status")
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.title = ""
        button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggle(_:))
        button.isHidden = true

        configure(toggleControl, identifier: "Edit.LanguageServer.toggle", action: #selector(performToggle(_:)))
        configure(restartControl, identifier: "Edit.LanguageServer.restart", action: #selector(performRestart(_:)))
        setActionImage("arrow.clockwise", for: restartControl, command: .restart)
    }

    func update(visible: Bool, state: LanguageServerSession.State, enabled: Set<LanguageServerCommand>) {
        if !visible { close() }
        button.isHidden = !visible
        statusButton.indicator = Indicator(states: visible ? [state] : [])
        let summary = "Language Servers, ZLS \(state.title)"
        button.setAccessibilityLabel(summary)
        button.toolTip = summary
        name.toolTip = state.failureReason ?? state.title
        name.setAccessibilityLabel("ZLS, \(state.title)")
        icon.image = FileIcons.image(for: nil, appearance: button.effectiveAppearance, language: "zig")

        toggleCommand = [.starting, .ready, .stopping].contains(state) ? .stop : .start
        setActionImage(toggleCommand == .stop ? "stop.fill" : "play.fill", for: toggleControl, command: toggleCommand)
        toggleControl.isEnabled = enabled.contains(toggleCommand)
        restartControl.isEnabled = enabled.contains(.restart)
    }

    private func configure(_ button: NSButton, identifier: String, action: Selector) {
        button.identifier = .init(identifier)
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.controlSize = .small
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func setActionImage(_ symbol: String, for button: NSButton, command: LanguageServerCommand) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        button.setAccessibilityLabel(command.title)
        button.toolTip = command.title
    }

    private func prepareContent() {
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
        icon.setAccessibilityElement(false)

        let row = NSStackView(views: [icon, name, toggleControl, restartControl])
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(18, after: name)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        row.setAccessibilityLabel("Language Servers")

        let controller = NSViewController()
        controller.view = row
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    @objc private func toggle(_ sender: NSButton) {
        if popover.isShown {
            close()
            return
        }
        guard sender.window != nil, !sender.isHiddenOrHasHiddenAncestor else { return }
        if popover.contentViewController == nil { prepareContent() }
        if let content = popover.contentViewController?.view { popover.contentSize = content.fittingSize }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func performToggle(_ sender: NSButton) { perform(toggleCommand) }

    @objc private func performRestart(_ sender: NSButton) { perform(.restart) }

    func close() {
        if popover.isShown { popover.close() }
    }

#if EDIT_AGENT_CHECKS
    var contentForCheck: NSView? {
        if popover.contentViewController == nil { prepareContent() }
        guard let view = popover.contentViewController?.view else { return nil }
        view.setFrameSize(view.fittingSize)
        return view
    }
#endif
}

@MainActor
private final class StatusButton: NSButton {
    var indicator: LanguageServerStatusPopover.Indicator? {
        didSet { if indicator != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(29, size.width), height: max(21, size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let indicator else { return }
        let fill = indicator.color
        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX + 4, y: bounds.midY - 8, width: 6, height: 6))
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = fill.withAlphaComponent(0.72)
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 3
        glow.set()
        fill.setFill()
        dot.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
