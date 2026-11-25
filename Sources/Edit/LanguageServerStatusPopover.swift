import AppKit

@MainActor
final class LanguageServerStatusPopover: NSObject {
    enum Indicator: Equatable {
        case ready, stopped, partial, busy

        init?(states: [LanguageServerSession.State], hasProgress: Bool) {
            guard !states.isEmpty else { return nil }
            if hasProgress || states.contains(.starting) || states.contains(.stopping) { self = .busy }
            else if states.allSatisfy({ $0 == .ready }) { self = .ready }
            else if states.contains(.ready) { self = .partial }
            else { self = .stopped }
        }

        var color: NSColor? {
            switch self {
            case .ready: .systemGreen
            case .stopped: .systemRed
            case .partial: .systemYellow
            case .busy: nil
            }
        }
    }

    private let statusButton = StatusButton()
    var button: NSButton { statusButton }
    var indicator: Indicator? { statusButton.indicator }
    private let popover = NSPopover()
    private let stack = NSStackView()
    private let perform: (LanguageServer, LanguageServerCommand) -> Void
    private var rows: [LanguageServer: ServerPopoverRow] = [:]
    private var visibleServers: [LanguageServer] = []

    struct ServerStatus {
        let server: LanguageServer
        let state: LanguageServerSession.State
        let progress: [LSPWorkDoneActivity]
        let enabled: Set<LanguageServerCommand>
    }

    init(perform: @escaping (LanguageServer, LanguageServerCommand) -> Void) {
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

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    func update(_ statuses: [ServerStatus]) {
        if statuses.isEmpty { close() }
        button.isHidden = statuses.isEmpty
        statusButton.indicator = Indicator(states: statuses.map(\.state), hasProgress: statuses.contains { !$0.progress.isEmpty })
        let descriptions = statuses.map { status in
            let row: ServerPopoverRow
            if let existing = rows[status.server] {
                row = existing
            } else {
                let server = status.server
                row = ServerPopoverRow(server: server) { [perform] in perform(server, $0) }
                rows[server] = row
            }
            return row.update(status)
        }
        let summary = (["Language Servers"] + descriptions).joined(separator: ", ")
        button.setAccessibilityLabel(summary)
        button.toolTip = summary

        let servers = statuses.map(\.server)
        guard servers != visibleServers else { return }
        visibleServers = servers
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for server in servers {
            if let row = rows[server] { stack.addArrangedSubview(row) }
        }
        if popover.isShown { popover.contentSize = stack.fittingSize }
    }

    @objc private func toggle(_ sender: NSButton) {
        if popover.isShown {
            close()
            return
        }
        guard sender.window != nil, !sender.isHiddenOrHasHiddenAncestor else { return }
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func close() {
        if popover.isShown { popover.close() }
    }

#if EDIT_AGENT_CHECKS
    var contentForCheck: NSView {
        stack.setFrameSize(stack.fittingSize)
        stack.layoutSubtreeIfNeeded()
        return stack
    }
#endif
}

@MainActor
private final class ServerPopoverRow: NSView {
    private static let logos: [LanguageServer: NSImage] = {
        let folder = "LanguageServerLogos"
        let bundled = Bundle.main.resourceURL?.appending(path: folder, directoryHint: .isDirectory)
        let directory: URL?
        #if SWIFT_PACKAGE
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            directory = bundled
        } else {
            directory = Bundle.module.resourceURL?.appending(path: folder, directoryHint: .isDirectory)
        }
        #else
        directory = bundled
        #endif
        guard let directory else { return [:] }
        func load(_ name: String) -> NSImage? {
            let file = directory.appending(path: name, directoryHint: .notDirectory)
            guard let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 else { return nil }
            return image
        }
        var logos: [LanguageServer: NSImage] = [:]
        logos[.zig] = load("zls.svg")
        if let swiftlang = load("swiftlang.png"), let clangd = load("clangd.svg") {
            let height: CGFloat = 16
            let spacing: CGFloat = 4
            let swiftWidth = height * swiftlang.size.width / swiftlang.size.height
            let clangWidth = height * clangd.size.width / clangd.size.height
            let size = NSSize(width: swiftWidth + spacing + clangWidth, height: height)
            logos[.sourceKit] = NSImage(size: size, flipped: false) { rect in
                let scale = rect.height / height
                swiftlang.draw(in: NSRect(x: rect.minX, y: rect.minY, width: swiftWidth * scale, height: rect.height))
                clangd.draw(in: NSRect(x: rect.minX + (swiftWidth + spacing) * scale, y: rect.minY,
                                      width: clangWidth * scale, height: rect.height))
                return true
            }
        }
        return logos
    }()
    private static let logoAspectRatio = logos[.zig].map { $0.size.width / $0.size.height } ?? 1

    private let server: LanguageServer
    private let name: NSTextField
    private let detail = NSTextField(labelWithString: "")
    private let logo = NSImageView()
    private let toggleControl = ServerActionButton()
    private let restartControl = ServerActionButton()
    private let perform: (LanguageServerCommand) -> Void
    private var toggleCommand = LanguageServerCommand.start

    init(server: LanguageServer, perform: @escaping (LanguageServerCommand) -> Void) {
        self.server = server
        self.perform = perform
        name = NSTextField(labelWithString: server.name)
        super.init(frame: .zero)
        configure(toggleControl, identifier: "Edit.LanguageServer.toggle", action: #selector(performToggle(_:)))
        configure(restartControl, identifier: "Edit.LanguageServer.restart", action: #selector(performRestart(_:)))
        setActionImage("play.fill", for: toggleControl, command: .start)
        setActionImage("arrow.clockwise", for: restartControl, command: .restart)
        prepareContent()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ status: LanguageServerStatusPopover.ServerStatus) -> String {
        let state = status.state
        let progress = status.progress
        let work = progress.map { activity in
            var title = activity.title
            if let percentage = activity.percentage { title += " (\(percentage)%)" }
            return title
        }
        let activity = progress.count > 1 ? "\(progress.count) operations in progress" : work.first ?? state.title
        detail.stringValue = state == .starting ? state.title : activity
        let descriptions = zip(work, progress).map { title, activity in
            guard let message = activity.message, !message.isEmpty else { return title }
            return "\(title) — \(message)"
        }
        let statusDescription = descriptions.isEmpty
            ? state.failureReason ?? state.title
            : ([state.title] + descriptions).joined(separator: ", ")
        name.toolTip = statusDescription
        detail.toolTip = statusDescription
        detail.setAccessibilityLabel(statusDescription)

        let command: LanguageServerCommand = [.starting, .ready, .stopping].contains(state) ? .stop : .start
        if command != toggleCommand {
            toggleCommand = command
            setActionImage(command == .stop ? "stop.fill" : "play.fill", for: toggleControl, command: command)
        }
        toggleControl.isEnabled = status.enabled.contains(toggleCommand)
        restartControl.isEnabled = status.enabled.contains(.restart)
        return "\(server.name) \(statusDescription)"
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
            button.widthAnchor.constraint(equalToConstant: 26),
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
        detail.identifier = .init("Edit.LanguageServer.detail")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let identity = NSStackView(views: [name, detail])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1
        logo.identifier = .init("Edit.LanguageServer.logo")
        logo.image = Self.logos[server]
        logo.imageAlignment = .alignCenter
        logo.imageScaling = .scaleProportionallyUpOrDown
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            logo.setContentHuggingPriority(.fittingSizeCompression, for: orientation)
            logo.setContentCompressionResistancePriority(.fittingSizeCompression, for: orientation)
        }
        logo.setAccessibilityElement(false)

        setAccessibilityLabel(server.name)
        let actionBackground = NSBox()
        actionBackground.boxType = .custom
        actionBackground.titlePosition = .noTitle
        actionBackground.borderWidth = 0
        actionBackground.cornerRadius = 8
        actionBackground.fillColor = .labelColor.withAlphaComponent(0.08)
        actionBackground.setAccessibilityElement(false)
        for view in [logo, identity, actionBackground, toggleControl, restartControl] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Keep the label and control space independent of the logo width.
            widthAnchor.constraint(equalTo: logo.widthAnchor, constant: 249),
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            logo.centerYAnchor.constraint(equalTo: identity.centerYAnchor),
            logo.heightAnchor.constraint(equalTo: identity.heightAnchor, multiplier: 0.5),
            logo.widthAnchor.constraint(equalTo: logo.heightAnchor, multiplier: Self.logoAspectRatio),
            identity.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 6),
            identity.centerYAnchor.constraint(equalTo: centerYAnchor),
            identity.trailingAnchor.constraint(lessThanOrEqualTo: toggleControl.leadingAnchor, constant: -12),
            toggleControl.centerYAnchor.constraint(equalTo: restartControl.centerYAnchor),
            restartControl.leadingAnchor.constraint(equalTo: toggleControl.trailingAnchor, constant: 2),
            restartControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            restartControl.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            restartControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            actionBackground.leadingAnchor.constraint(equalTo: toggleControl.leadingAnchor),
            actionBackground.trailingAnchor.constraint(equalTo: restartControl.trailingAnchor),
            actionBackground.topAnchor.constraint(equalTo: restartControl.topAnchor),
            actionBackground.bottomAnchor.constraint(equalTo: restartControl.bottomAnchor),
        ])
    }

    @objc private func performToggle(_ sender: NSButton) { perform(toggleCommand) }

    @objc private func performRestart(_ sender: NSButton) { perform(.restart) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
}

@MainActor
private final class ServerActionButton: NSButton {
    // Keep the button frame independent of the current symbol's alignment insets.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

@MainActor
private final class StatusButton: NSButton {
    var indicator: LanguageServerStatusPopover.Indicator? {
        didSet {
            guard indicator != oldValue else { return }
            let busy = indicator == .busy
            let animated = busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let symbol = busy ? "hourglass" : "server.rack"
            image = animated ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if animated {
                spinner.startAnimation(nil)
            } else if oldValue == .busy {
                spinner.stopAnimation(nil)
            }
            needsDisplay = true
        }
    }

    private lazy var spinner: StatusSpinner = {
        let spinner = StatusSpinner()
        spinner.identifier = .init("Edit.LanguageServer.progress")
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalTo: spinner.widthAnchor),
        ])
        return spinner
    }()

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(29, size.width), height: max(21, size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let fill = indicator?.color else { return }
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

@MainActor
private final class StatusSpinner: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
