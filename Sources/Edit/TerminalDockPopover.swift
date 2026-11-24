import AppKit

struct TerminalDockPopoverLayout {
    static let pointerHeight = AnchoredPopoverShape.pointerHeight
    static let pointerHalfWidth = AnchoredPopoverShape.pointerHalfWidth

    let frame: NSRect
    let shape: AnchoredPopoverShape
    var content: NSRect { shape.contentFrame }
    var pointerX: CGFloat { shape.pointerX }

    init(anchor: NSRect, size: NSSize, screen: NSRect, preferAbove: Bool) {
        let available = screen.insetBy(dx: 4, dy: 4)
        let width = min(size.width, available.width)
        let height = size.height + Self.pointerHeight
        let gap: CGFloat = 4
        let aboveY = anchor.maxY + gap
        let belowY = anchor.minY - gap - height
        let fitsAbove = aboveY + height <= available.maxY
        let fitsBelow = belowY >= available.minY
        let above = preferAbove ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove
        let x = min(max(anchor.midX - width / 2, available.minX), available.maxX - width)
        let y = min(max(above ? aboveY : belowY, available.minY), available.maxY - height)
        frame = NSRect(x: x, y: y, width: width, height: height)
        shape = AnchoredPopoverShape(contentSize: NSSize(width: width, height: size.height),
                                     pointerX: anchor.midX - x, pointsDown: above)
    }

    func outline() -> CGPath { shape.outline() }
}

@MainActor
final class TerminalDockPopover: NSObject {
    private var panel: DockPopoverPanel?
    private var picker: TerminalDockPicker?
    private weak var anchor: NSView?
    private weak var owner: NSWindow?
    private weak var previousResponder: NSResponder?
    private var monitor: Any?
    private var preferAbove = false

    var isShown: Bool { panel != nil }

    func show(_ picker: TerminalDockPicker, from anchor: NSView, in owner: NSWindow, preferAbove: Bool) {
        guard let anchorWindow = anchor.window, owner.isVisible, anchorWindow.isVisible else { return }
        let panel = DockPopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.autorecalculatesKeyViewLoop = true
        panel.alphaValue = owner.alphaValue
        panel.ignoresMouseEvents = owner.ignoresMouseEvents
        panel.appearance = anchor.effectiveAppearance
        panel.contentView = DockPopoverSurface(content: picker.view)
        self.panel = panel
        self.picker = picker
        self.anchor = anchor
        self.owner = owner
        self.preferAbove = preferAbove
        previousResponder = owner.firstResponder
        updatePosition()
        guard self.panel === panel else { return }
        owner.addChildWindow(panel, ordered: .above)
        if owner.isKeyWindow || NSApp.isActive { panel.makeKeyAndOrderFront(nil) }
        picker.focusSelection()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            return handleEvent(event)
        }
        let notifications = NotificationCenter.default
        for window in anchorWindow === owner ? [owner] : [owner, anchorWindow] {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                notifications.addObserver(self, selector: #selector(updatePosition), name: name, object: window)
            }
            notifications.addObserver(self, selector: #selector(dismiss), name: NSWindow.willCloseNotification, object: window)
        }
        notifications.addObserver(self, selector: #selector(dismiss), name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    func close(restoreFocus: Bool = true) {
        guard let panel else { return }
        let wasKey = panel.isKeyWindow
        let owner = self.owner
        let responder = previousResponder
        self.panel = nil
        picker = nil
        anchor = nil
        self.owner = nil
        previousResponder = nil
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus, wasKey, let owner, owner.isVisible {
            owner.makeKey()
            if let responder { owner.makeFirstResponder(responder) }
        }
    }

    @objc private func dismiss() { close(restoreFocus: false) }

    @objc private func updatePosition() {
        guard let panel, let picker, let anchor, let anchorWindow = anchor.window,
              let screen = anchorWindow.screen ?? owner?.screen,
              let surface = panel.contentView as? DockPopoverSurface else {
            close(restoreFocus: false)
            return
        }
        let target = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let layout = TerminalDockPopoverLayout(anchor: target, size: picker.view.fittingSize,
                                               screen: screen.visibleFrame, preferAbove: preferAbove)
        panel.setFrame(layout.frame, display: false)
        surface.apply(layout)
        panel.invalidateShadow()
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            if event.window === panel && event.keyCode == 53 {
                close()
                return nil
            }
        } else if event.window !== panel {
            // Let the ellipsis action close its own picker.
            if let anchor, event.type == .leftMouseDown, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            close(restoreFocus: false)
        }
        return event
    }
}

@MainActor
private final class DockPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DockPopoverSurface: AnchoredPopoverSurface {
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        identifier = .init("Edit.Terminal.DockPicker")
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ layout: TerminalDockPopoverLayout) {
        content.frame = layout.content
        applyOutline(layout.shape)
    }
}
