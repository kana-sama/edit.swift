import AppKit

@MainActor
final class SourceControlRevisionHover: NSObject {
    struct LinkContext: Equatable {
        let workspace: JJWorkspace
        let operationID: String
    }

    private static let delay: Duration = .milliseconds(450)
    private static let departureGrace: Duration = .milliseconds(180)
    private var pending: Task<Void, Never>?
    private var departure: Task<Void, Never>?
    private var crossing: Task<Void, Never>?
    private var linkRequest: Task<Void, Never>?
    private var panel: SourceControlRevisionHoverPanel?
    private weak var owner: NSWindow?
    private weak var card: SourceControlRevisionCard?
    private var revision: JJSourceControlRevision?
    private var linkContext: LinkContext?
    private var corridor: SourceControlRevisionCorridor?
    private var selectingText = false
    private var eventMonitor: Any?
    private(set) var row: Int?

    func track(_ revision: JJSourceControlRevision, row: Int, in table: NSTableView, linkContext: LinkContext?) {
        guard self.row != row else { return }
        dismiss()
        guard let window = table.window, window.isKeyWindow, window.isVisible,
              let clip = table.enclosingScrollView?.contentView else { return }

        self.row = row
        self.revision = revision
        self.linkContext = linkContext
        owner = window
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(dismiss), name: NSView.boundsDidChangeNotification, object: clip)
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(dismiss), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(checkFocus), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(deactivate), name: NSApplication.didResignActiveNotification, object: NSApp)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp,
                                                                    .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) {
            [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
        pending = Task { [weak self, weak table] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard let self, !Task.isCancelled, let table else { return }
            pending = nil
            show(revision, row: row, in: table)
        }
    }

    func updateLinkContext(_ context: LinkContext?) {
        linkContext = context
        linkRequest?.cancel()
        linkRequest = nil
        guard let card, let revision else { return }
        guard let context else { card.setCommitLink(nil); return }
        linkRequest = Task { [weak self, weak card] in
            let link = await JJSourceControlCommitLink.lookup(for: revision, in: context.workspace, at: context.operationID)
            guard let self, !Task.isCancelled, let card else { return }
            linkRequest = nil
            card.setCommitLink(link)
        }
    }

    @objc func dismiss() { close(restoreFocus: true) }

    @objc private func deactivate() { close(restoreFocus: false) }

    @objc private func checkFocus() {
        // A click can move key status from the document to the selectable card.
        Task { [weak self, weak owner] in
            guard let self, let owner, self.owner === owner, !owner.isKeyWindow, panel?.isKeyWindow != true else { return }
            close(restoreFocus: false)
        }
    }

    private func close(restoreFocus: Bool) {
        pending?.cancel()
        pending = nil
        departure?.cancel()
        departure = nil
        crossing?.cancel()
        crossing = nil
        linkRequest?.cancel()
        linkRequest = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        if let panel {
            let wasKey = panel.isKeyWindow
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            if restoreFocus, wasKey, NSApp.isActive, let owner, owner.isVisible { owner.makeKey() }
        }
        panel = nil
        card = nil
        owner = nil
        revision = nil
        linkContext = nil
        corridor = nil
        selectingText = false
        row = nil
    }

    isolated deinit { close(restoreFocus: false) }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let inCard = panel != nil && event.window === panel
        switch event.type {
        case .mouseMoved:
            if let window = event.window { pointerMoved(to: window.convertPoint(toScreen: event.locationInWindow)) }
        case .leftMouseDown where inCard:
            selectingText = true
            departure?.cancel()
            departure = nil
            crossing?.cancel()
            crossing = nil
        case .leftMouseUp where selectingText:
            selectingText = false
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            pointerLeft(at: point)
        case .keyDown where inCard:
            if event.keyCode == 53 { dismiss(); return nil }
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            if !inCard { close(restoreFocus: event.window === owner) }
        default:
            break
        }
        return event
    }

    func pointerLeft(at point: NSPoint) {
        guard let corridor, let owner else { dismiss(); return }
        pointerMoved(to: point)
        if corridor.contains(point) || !owner.frame.contains(point) { watchCrossing() }
    }

    private func watchCrossing() {
        guard !selectingText, crossing == nil else { return }
        // Outside both windows AppKit may stop delivering motion until the pointer re-enters.
        crossing = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let corridor = self.corridor else { return }
                let location = NSEvent.mouseLocation
                pointerMoved(to: location)
                if corridor.anchor.contains(location) || corridor.card.contains(location) || !corridor.contains(location) { break }
            }
            if !Task.isCancelled { self?.crossing = nil }
        }
    }

    private func pointerMoved(to point: NSPoint) {
        guard let corridor, !selectingText else { return }
        if corridor.contains(point) {
            departure?.cancel()
            departure = nil
            if corridor.anchor.contains(point) || corridor.card.contains(point) {
                crossing?.cancel()
                crossing = nil
            } else {
                watchCrossing()
            }
        } else if departure == nil {
            departure = Task { [weak self] in
                do { try await Task.sleep(for: Self.departureGrace) } catch { return }
                self?.dismiss()
            }
        }
    }

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
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = owner.ignoresMouseEvents
        panel.alphaValue = owner.alphaValue
        panel.appearance = table.effectiveAppearance
        panel.contentView = SourceControlRevisionHoverSurface(card: card, size: size,
            pointerEntered: { [weak self] point in self?.pointerMoved(to: point) },
            pointerLeft: { [weak self] point in self?.pointerLeft(at: point) })
        corridor = SourceControlRevisionCorridor(anchor: target, card: frame)
        self.panel = panel
        self.card = card
        NotificationCenter.default.addObserver(self, selector: #selector(checkFocus), name: NSWindow.didResignKeyNotification, object: panel)
        owner.addChildWindow(panel, ordered: .above)
        updateLinkContext(linkContext)
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SourceControlRevisionHoverSurface: NSVisualEffectView {
    private let pointerEntered: (NSPoint) -> Void
    private let pointerLeft: (NSPoint) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(card: NSView, size: NSSize, pointerEntered: @escaping (NSPoint) -> Void, pointerLeft: @escaping (NSPoint) -> Void) {
        self.pointerEntered = pointerEntered
        self.pointerLeft = pointerLeft
        super.init(frame: NSRect(origin: .zero, size: size))
        identifier = .init("JujutsuRevisionHoverCard")
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        card.frame = bounds
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("Revision hover surfaces are created in code.") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        if let window { pointerLeft(window.convertPoint(toScreen: event.locationInWindow)) }
    }

    override func mouseEntered(with event: NSEvent) {
        if let window { pointerEntered(window.convertPoint(toScreen: event.locationInWindow)) }
    }
}

struct SourceControlRevisionCorridor {
    let anchor: NSRect
    let card: NSRect

    func contains(_ point: NSPoint) -> Bool {
        if anchor.contains(point) || card.contains(point) { return true }
        if anchor.maxX < card.minX { return Self.between(point, left: anchor, right: card) }
        if card.maxX < anchor.minX { return Self.between(point, left: card, right: anchor) }
        // A narrow display can put the card above or below the row instead.
        let row = NSRect(x: anchor.minY, y: anchor.minX, width: anchor.height, height: anchor.width)
        let popup = NSRect(x: card.minY, y: card.minX, width: card.height, height: card.width)
        let transposed = NSPoint(x: point.y, y: point.x)
        if row.maxX < popup.minX { return Self.between(transposed, left: row, right: popup) }
        if popup.maxX < row.minX { return Self.between(transposed, left: popup, right: row) }
        return false
    }

    private static func between(_ point: NSPoint, left: NSRect, right: NSRect) -> Bool {
        guard (left.maxX...right.minX).contains(point.x) else { return false }
        let fraction = (point.x - left.maxX) / (right.minX - left.maxX)
        let lower = left.minY + (right.minY - left.minY) * fraction
        let upper = left.maxY + (right.maxY - left.maxY) * fraction
        return (lower...upper).contains(point.y)
    }
}
