import AppKit

@MainActor
final class SourceControlRevisionHover: NSObject {
    private static let delay: Duration = .milliseconds(450)
    private var pending: Task<Void, Never>?
    private var panel: SourceControlRevisionHoverPanel?
    private var eventMonitor: Any?
    private(set) var row: Int?

    func track(_ revision: JJSourceControlRevision, row: Int, in table: NSTableView) {
        guard self.row != row else { return }
        dismiss()
        guard let window = table.window, window.isKeyWindow, window.isVisible,
              let clip = table.enclosingScrollView?.contentView else { return }

        self.row = row
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(dismiss), name: NSView.boundsDidChangeNotification, object: clip)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(dismiss), name: name, object: window)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) {
            [weak self] event in
            self?.dismiss()
            return event
        }
        pending = Task { [weak self, weak table] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard let self, !Task.isCancelled, let table else { return }
            pending = nil
            show(revision, row: row, in: table)
        }
    }

    @objc func dismiss() {
        pending?.cancel()
        pending = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        row = nil
    }

    isolated deinit { dismiss() }

    private func show(_ revision: JJSourceControlRevision, row: Int, in table: NSTableView) {
        guard let owner = table.window, owner.isKeyWindow, owner.isVisible,
              owner.attachedSheet == nil, table.isEnabled, !table.isHiddenOrHasHiddenAncestor,
              row < table.numberOfRows, let screen = owner.screen ?? NSScreen.main else { dismiss(); return }
        let anchor = table.rect(ofRow: row).intersection(table.visibleRect)
        guard !anchor.isEmpty else { dismiss(); return }

        let card = SourceControlRevisionCard(revision: revision)
        let size = card.fittingSize
        let target = owner.convertToScreen(table.convert(anchor, to: nil))
        let frame = Self.frame(size: size, beside: target, on: screen.visibleFrame)
        let panel = SourceControlRevisionHoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                                    backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.alphaValue = owner.alphaValue
        panel.appearance = table.effectiveAppearance
        panel.contentView = Self.surface(for: card, size: size)
        owner.addChildWindow(panel, ordered: .above)
        self.panel = panel
    }

    private static func surface(for card: NSView, size: NSSize) -> NSVisualEffectView {
        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        surface.identifier = .init("JujutsuRevisionHoverCard")
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        card.frame = surface.bounds
        surface.addSubview(card)
        return surface
    }

    private static func frame(size: NSSize, beside anchor: NSRect, on screen: NSRect) -> NSRect {
        let area = screen.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8
        let right = anchor.maxX + gap
        let left = anchor.minX - size.width - gap
        var x = right
        var y = anchor.midY - size.height / 2
        if right + size.width > area.maxX {
            if left >= area.minX {
                x = left
            } else {
                let above = anchor.maxY + gap
                y = above + size.height <= area.maxY ? above : anchor.minY - gap - size.height
            }
        }
        return NSRect(x: max(area.minX, min(x, area.maxX - size.width)),
                      y: max(area.minY, min(y, area.maxY - size.height)), width: size.width, height: size.height)
    }
}

@MainActor
private final class SourceControlRevisionHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
