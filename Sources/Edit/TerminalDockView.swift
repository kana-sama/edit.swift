import AppKit
import Carbon

enum TerminalShortcuts {
    static var toggleKeyCode: UInt16 {
        keyAboveTab(keyboardType: Int16(LMGetKbdType()))
    }

    static func isToggle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control else { return false }
        let keyboardType = event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) ?? 0
        let keyCode = keyboardType == 0 ? toggleKeyCode : keyAboveTab(keyboardType: Int16(truncatingIfNeeded: keyboardType))
        return event.keyCode == keyCode
    }

    static func zoom(_ event: NSEvent) -> TerminalZoom? {
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        switch (event.charactersIgnoringModifiers, modifiers) {
        case ("=", .command), ("+", .command), ("+", [.command, .shift]): return .increase
        case ("-", .command): return .decrease
        case ("0", .command): return .reset
        default: return nil
        }
    }

    static func isToggleContentWidth(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.control, .command, .option, .shift]) == .option &&
            (event.keyCode == UInt16(kVK_ANSI_Z) || event.charactersIgnoringModifiers?.lowercased() == "z")
    }

    static func isClear(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.control, .command, .option, .shift]) == .command &&
            (event.keyCode == UInt16(kVK_ANSI_K) || event.charactersIgnoringModifiers?.lowercased() == "k")
    }

    private static func keyAboveTab(keyboardType: Int16) -> UInt16 {
        // macOS swaps the grave and section key codes on ISO hardware.
        UInt16(KBGetLayoutType(keyboardType) == kKeyboardISO ? kVK_ISO_Section : kVK_ANSI_Grave)
    }
}

struct TerminalDockSizes: Codable, Sendable, Equatable {
    var belowHeight: CGFloat = 224
    var rightWidth: CGFloat = 360
}

@MainActor
final class TerminalDockView: NSSplitView, NSSplitViewDelegate {
    private let buffer = NSView()
    private let terminal: NSView
    private let holder = NSView()
    private let glass = NSGlassEffectView()
    private let onHeightChange: (CGFloat) -> Void
    private var hostConstraints: [NSLayoutConstraint] = []
    private var terminalConstraints: [NSLayoutConstraint] = []
    private(set) var savedHeight: CGFloat

    init(terminal: NSView, height: CGFloat, onHeightChange: @escaping (CGFloat) -> Void) {
        self.terminal = terminal
        self.onHeightChange = onHeightChange
        savedHeight = height.isFinite && height > 0 ? height : TerminalDockSizes().belowHeight
        super.init(frame: .zero)
        identifier = .init("Edit.Terminal.Dock")
        translatesAutoresizingMaskIntoConstraints = false
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(buffer)
        addArrangedSubview(holder)
        holder.clipsToBounds = true
        glass.cornerRadius = 0
        glass.style = .regular
        glass.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(glass)
        // The surface continues past the clip so the glass rim never borders the panel.
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: -4),
            glass.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: 4),
            glass.topAnchor.constraint(equalTo: holder.topAnchor, constant: -4),
            glass.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(in host: NSView) {
        guard superview == nil else { return }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(terminal, positioned: .above, relativeTo: glass)
        terminalConstraints = [
            terminal.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: holder.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ]
        NSLayoutConstraint.activate(terminalConstraints)
        host.addSubview(self, positioned: .above, relativeTo: nil)
        hostConstraints = [
            leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostConstraints)
        host.layoutSubtreeIfNeeded()
        layoutPanes()
        onHeightChange(coveredHeight)
    }

    func hide() {
        guard superview != nil else { return }
        NSLayoutConstraint.deactivate(terminalConstraints + hostConstraints)
        terminalConstraints.removeAll()
        hostConstraints.removeAll()
        terminal.removeFromSuperview()
        removeFromSuperview()
        onHeightChange(0)
    }

    var coveredHeight: CGFloat {
        guard superview != nil else { return 0 }
        return max(0, bounds.height - buffer.frame.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Keep the editor interactive in the transparent part of this split view.
        return hit === buffer ? nil : hit
    }

    override func mouseDown(with event: NSEvent) {
        let before = holder.frame.height
        super.mouseDown(with: event)
        rememberDividerChange(from: before)
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        let before = holder.frame.height
        super.setPosition(position, ofDividerAt: dividerIndex)
        rememberDividerChange(from: before)
    }

    private func rememberDividerChange(from previous: CGFloat) {
        let current = holder.frame.height
        if current > 0 && current != previous { savedHeight = current }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutPanes()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onHeightChange(coveredHeight)
    }

    override func drawDivider(in rect: NSRect) {
        if holder.frame.height > 0 { super.drawDivider(in: rect) }
    }

    private func layoutPanes() {
        let panelHeight = expandedHeight
        let bufferHeight = panelHeight > 0 ? available - panelHeight : bounds.height
        buffer.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bufferHeight)
        holder.frame = NSRect(x: bounds.minX, y: bounds.maxY - panelHeight, width: bounds.width, height: panelHeight)
    }

    private var available: CGFloat { max(0, bounds.height - dividerThickness) }
    private var minimumHeight: CGFloat { min(110, available * 0.44) }
    private var expandedHeight: CGFloat { min(savedHeight, available - minimumHeight) }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, minimumHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, available - minimumHeight)
    }
}
