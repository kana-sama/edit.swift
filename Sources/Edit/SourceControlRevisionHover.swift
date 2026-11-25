import AppKit

@MainActor
final class SourceControlRevisionHover: NSObject {
    struct LinkContext: Equatable {
        let workspace: JJWorkspace
        let operationID: String
    }

    static let settleDelay: Duration = .milliseconds(450)
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
    private var anchorPointer: NSPoint?
    private weak var indicator: NSView?
    private var selectingText = false
    private var eventMonitor: Any?
    private(set) var row: Int?

    func track(_ revision: JJSourceControlRevision, row: Int, at point: NSPoint, in table: NSTableView,
               linkContext: LinkContext?, settled: Bool = false) {
        guard self.row != row else { anchorPointer = point; return }
        dismiss()
        guard let window = table.window, window.isKeyWindow, window.isVisible,
              let clip = table.enclosingScrollView?.contentView else { return }

        self.row = row
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss), name: NSView.boundsDidChangeNotification, object: clip)
        beginTracking(revision, at: point, owner: window, linkContext: linkContext, settled: settled) { [weak self, weak table] in
            guard let self, let table else { return }
            guard table.isEnabled, row < table.numberOfRows else { dismiss(); return }
            show(in: table, target: table.rect(ofRow: row))
        }
    }

    func track(_ revision: JJSourceControlRevision, at point: NSPoint, in indicator: NSView,
               owner window: NSWindow, linkContext: LinkContext?) {
        guard self.indicator !== indicator, window.isKeyWindow, window.isVisible else { return }
        dismiss()
        self.indicator = indicator
        indicator.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss), name: NSView.frameDidChangeNotification, object: indicator)
        beginTracking(revision, at: point, owner: window, linkContext: linkContext) { [weak self, weak indicator] in
            guard let self, let indicator else { return }
            show(in: indicator, target: indicator.bounds, prefersVertical: true)
        }
    }

    private func beginTracking(_ revision: JJSourceControlRevision, at point: NSPoint, owner window: NSWindow,
                               linkContext: LinkContext?, settled: Bool = false, show: @escaping () -> Void) {
        self.revision = revision
        self.linkContext = linkContext
        anchorPointer = point
        owner = window
        let center = NotificationCenter.default
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
        if settled {
            show()
            return
        }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleDelay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pending = nil
            show()
        }
    }

    func isApproachingCard(at point: NSPoint) -> Bool {
        guard let corridor, let anchorPointer else { return false }
        return corridor.isApproach(point, from: anchorPointer)
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
        anchorPointer = nil
        indicator = nil
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
        if corridor.contains(point, from: anchorPointer) || !owner.frame.contains(point) { watchCrossing() }
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
                if corridor.anchor.contains(location) || corridor.card.contains(location) ||
                    !corridor.contains(location, from: anchorPointer) { break }
            }
            if !Task.isCancelled { self?.crossing = nil }
        }
    }

    private func pointerMoved(to point: NSPoint) {
        guard let corridor, !selectingText else { return }
        if corridor.anchor.contains(point) { anchorPointer = point }
        if corridor.contains(point, from: anchorPointer) {
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

    private func show(in anchorView: NSView, target: NSRect, prefersVertical: Bool = false) {
        guard let revision, let owner, let anchorWindow = anchorView.window, owner.isKeyWindow, owner.isVisible,
              owner.attachedSheet == nil, !anchorView.isHiddenOrHasHiddenAncestor,
              let screen = anchorWindow.screen ?? owner.screen ?? NSScreen.main else { dismiss(); return }
        let anchor = target.intersection(anchorView.visibleRect)
        guard !anchor.isEmpty else { dismiss(); return }

        let card = SourceControlRevisionCard(revision: revision)
        let contentSize = card.fittingSize
        let target = anchorWindow.convertToScreen(anchorView.convert(anchor, to: nil))
        guard let placement = SourceControlRevisionHoverPlacement(size: contentSize, anchor: target,
                                                                  screen: screen.visibleFrame, prefersVertical: prefersVertical) else {
            dismiss()
            return
        }
        let panel = SourceControlRevisionHoverPanel(contentRect: placement.frame, styleMask: [.borderless, .nonactivatingPanel],
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
        panel.appearance = anchorView.effectiveAppearance
        panel.contentView = SourceControlRevisionHoverSurface(card: card, contentSize: contentSize, placement: placement,
            pointerEntered: { [weak self] point in self?.pointerMoved(to: point) },
            pointerLeft: { [weak self] point in self?.pointerLeft(at: point) })
        corridor = SourceControlRevisionCorridor(anchor: target, card: placement.body)
        self.panel = panel
        self.card = card
        NotificationCenter.default.addObserver(self, selector: #selector(checkFocus), name: NSWindow.didResignKeyNotification, object: panel)
        owner.addChildWindow(panel, ordered: .above)
        updateLinkContext(linkContext)
    }

}

@MainActor
private final class SourceControlRevisionHoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct SourceControlRevisionHoverPlacement {
    private enum Side {
        case right, left, above, below
    }

    private static let length: CGFloat = 8
    private static let halfBase: CGFloat = 7
    fileprivate static let cornerRadius: CGFloat = 12

    let body: NSRect
    let tip: NSPoint
    private let baseStart: NSPoint
    private let baseEnd: NSPoint

    var frame: NSRect {
        NSRect(x: min(body.minX, tip.x), y: min(body.minY, tip.y),
               width: max(body.maxX, tip.x) - min(body.minX, tip.x),
               height: max(body.maxY, tip.y) - min(body.minY, tip.y))
    }

    init?(size: NSSize, anchor: NSRect, screen: NSRect, prefersVertical: Bool = false) {
        let area = screen.insetBy(dx: 8, dy: 8)
        guard size.width <= area.width else { return nil }
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            max(lower, min(value, upper))
        }
        let visibleAnchor = anchor.intersection(screen)
        let target = visibleAnchor.isEmpty
            ? NSRect(x: clamp(anchor.midX, area.minX, area.maxX), y: clamp(anchor.midY, area.minY, area.maxY), width: 0, height: 0)
            : visibleAnchor
        let gap = Self.length
        let below = target.minY - gap - area.minY
        let above = area.maxY - target.maxY - gap
        let minimumHeight = min(size.height, 78)
        let canPlaceRight = target.maxX + gap + size.width <= area.maxX
        let canPlaceLeft = target.minX - gap - size.width >= area.minX
        let side: Side
        if prefersVertical && below >= minimumHeight { side = .below }
        else if prefersVertical && above >= minimumHeight { side = .above }
        else if canPlaceRight { side = .right }
        else if canPlaceLeft { side = .left }
        else if max(above, below) >= minimumHeight { side = above >= below ? .above : .below }
        else { return nil }

        let height: CGFloat
        switch side {
        case .right, .left: height = min(size.height, area.height)
        case .above: height = min(size.height, above)
        case .below: height = min(size.height, below)
        }
        let x = clamp(target.midX - size.width / 2, area.minX, area.maxX - size.width)
        let y = clamp(target.midY - height / 2, area.minY, area.maxY - height)
        let cornerAndBase = Self.cornerRadius + Self.halfBase
        switch side {
        case .right, .left:
            let edge = side == .right ? target.maxX : target.minX
            let bodyX = side == .right ? edge + gap : edge - gap - size.width
            body = NSRect(x: bodyX, y: y, width: size.width, height: height)
            tip = NSPoint(x: edge, y: target.midY)
            let baseX = side == .right ? body.minX : body.maxX
            let baseY = clamp(tip.y, body.minY + cornerAndBase, body.maxY - cornerAndBase)
            baseStart = NSPoint(x: baseX, y: baseY - Self.halfBase)
            baseEnd = NSPoint(x: baseX, y: baseY + Self.halfBase)
        case .above, .below:
            let edge = side == .above ? target.maxY : target.minY
            let bodyY = side == .above ? edge + gap : edge - gap - height
            body = NSRect(x: x, y: bodyY, width: size.width, height: height)
            tip = NSPoint(x: target.midX, y: edge)
            let baseX = clamp(tip.x, body.minX + cornerAndBase, body.maxX - cornerAndBase)
            let baseY = side == .above ? body.minY : body.maxY
            baseStart = NSPoint(x: baseX - Self.halfBase, y: baseY)
            baseEnd = NSPoint(x: baseX + Self.halfBase, y: baseY)
        }
    }

    fileprivate func mask() -> NSImage {
        let frame = self.frame
        func local(_ point: NSPoint) -> NSPoint { NSPoint(x: point.x - frame.minX, y: point.y - frame.minY) }
        let roundedBody = body.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let points = [local(baseStart), local(tip), local(baseEnd)]
        return NSImage(size: frame.size, flipped: false) { _ in
            NSColor.white.setFill()
            let outline = NSBezierPath(roundedRect: roundedBody, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            outline.move(to: points[0])
            outline.line(to: points[1])
            outline.line(to: points[2])
            outline.close()
            outline.fill()
            return true
        }
    }
}

@MainActor
private final class SourceControlRevisionHoverSurface: NSVisualEffectView {
    private let pointerEntered: (NSPoint) -> Void
    private let pointerLeft: (NSPoint) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(card: NSView, contentSize: NSSize, placement: SourceControlRevisionHoverPlacement,
         pointerEntered: @escaping (NSPoint) -> Void, pointerLeft: @escaping (NSPoint) -> Void) {
        self.pointerEntered = pointerEntered
        self.pointerLeft = pointerLeft
        let frame = placement.frame
        super.init(frame: NSRect(origin: .zero, size: frame.size))
        identifier = .init("JujutsuRevisionHoverCard")
        material = .popover
        blendingMode = .behindWindow
        state = .active
        maskImage = placement.mask()
        let body = NSView(frame: placement.body.offsetBy(dx: -frame.minX, dy: -frame.minY))
        body.identifier = .init("JujutsuRevisionHoverBody")
        body.wantsLayer = true
        body.layer?.cornerRadius = SourceControlRevisionHoverPlacement.cornerRadius
        body.layer?.masksToBounds = true
        addSubview(body)
        card.frame = NSRect(origin: .zero, size: contentSize)
        if contentSize.height > body.bounds.height {
            let scrollView = NSScrollView(frame: body.bounds)
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.documentView = card
            body.addSubview(scrollView)
            let clip = scrollView.contentView
            let top = clip.isFlipped ? 0 : contentSize.height - clip.bounds.height
            clip.scroll(to: NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(clip)
        } else {
            body.addSubview(card)
        }
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

    private static let edgePadding: CGFloat = 24

    func contains(_ point: NSPoint, from origin: NSPoint? = nil) -> Bool {
        if anchor.contains(point) || card.contains(point) { return true }
        guard let direction else { return false }
        let row = anchor.applying(direction)
        let popup = card.applying(direction)
        let target = point.applying(direction)
        let lower = min(row.minY, popup.minY) - Self.edgePadding
        let upper = max(row.maxY, popup.maxY) + Self.edgePadding
        // Permit reaching either end of the card throughout the gap, including at the row edge.
        if (row.maxX...popup.minX).contains(target.x) { return (lower...upper).contains(target.y) }
        guard let origin else { return false }
        let start = origin.applying(direction).x
        guard target.x >= start, target.x < row.maxX else { return false }
        // Open the approach toward the card starting at the pointer, even over an adjacent row.
        let fraction = (target.x - start) / (row.maxX - start)
        let bottom = row.minY - Self.edgePadding
        let top = row.maxY + Self.edgePadding
        let minY = bottom + (lower - bottom) * fraction
        let maxY = top + (upper - top) * fraction
        return (minY...maxY).contains(target.y)
    }

    func isApproach(_ point: NSPoint, from origin: NSPoint) -> Bool {
        guard let direction, point.applying(direction).x > origin.applying(direction).x else { return false }
        return contains(point, from: origin)
    }

    // Normalize the supported placements so that travel toward the card increases x.
    private var direction: CGAffineTransform? {
        if anchor.maxX < card.minX { return .identity }
        if card.maxX < anchor.minX { return CGAffineTransform(scaleX: -1, y: 1) }
        if anchor.maxY < card.minY { return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0) }
        if card.maxY < anchor.minY { return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) }
        return nil
    }
}
