import AppKit

@MainActor
final class LanguageServerStatusPopover: NSObject {
    let button = NSButton(title: "ZLS", target: nil, action: nil)
    private let popover = NSPopover()
    private let state = NSTextField(labelWithString: "Stopped")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let perform: (LanguageServerCommand) -> Void
    private var commands: [LanguageServerCommand: NSButton] = [:]
    private var enabled: Set<LanguageServerCommand> = []

    init(perform: @escaping (LanguageServerCommand) -> Void) {
        self.perform = perform
        super.init()
        button.identifier = .init("Edit.LanguageServer.Status")
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.target = self
        button.action = #selector(toggle(_:))
        button.toolTip = "Show Language Servers"
        button.isHidden = true
    }

    func update(visible: Bool, title: String, detail message: String?, enabled: Set<LanguageServerCommand>) {
        if !visible { close() }
        button.isHidden = !visible
        let summary = "ZLS · \(title)"
        if button.title != summary { button.title = summary }
        button.setAccessibilityLabel(summary)
        state.stringValue = title
        detail.stringValue = message ?? ""
        detail.isHidden = detail.stringValue.isEmpty
        for (command, control) in commands { control.isEnabled = enabled.contains(command) }
        self.enabled = enabled
        if popover.isShown { resize() }
    }

    private func prepareContent() {
        let name = NSTextField(labelWithString: "ZLS")
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        state.textColor = .secondaryLabelColor
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 280
        detail.isHidden = detail.stringValue.isEmpty

        let controls = LanguageServerCommand.allCases.map { command in
            let control = NSButton(title: command.title, target: self, action: #selector(performCommand(_:)))
            control.controlSize = .small
            control.bezelStyle = .rounded
            control.identifier = .init("Edit.LanguageServer.\(command.rawValue)")
            control.isEnabled = enabled.contains(command)
            commands[command] = control
            return control
        }

        let heading = NSStackView(views: [name, state])
        heading.spacing = 10
        heading.alignment = .firstBaseline
        let buttons = NSStackView(views: controls)
        buttons.spacing = 6
        let content = NSStackView(views: [heading, detail, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.setAccessibilityLabel("Language Servers")

        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    private func resize() {
        guard let content = popover.contentViewController?.view else { return }
        let size = content.fittingSize
        if size != popover.contentSize { popover.contentSize = size }
    }

    @objc private func toggle(_ sender: NSButton) {
        if popover.isShown {
            close()
            return
        }
        guard sender.window != nil, !sender.isHiddenOrHasHiddenAncestor else { return }
        if popover.contentViewController == nil { prepareContent() }
        resize()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func performCommand(_ sender: NSButton) {
        guard let command = commands.first(where: { $0.value === sender })?.key else { return }
        perform(command)
    }

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
