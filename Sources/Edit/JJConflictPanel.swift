import AppKit

@MainActor
final class JJConflictPanel: NSView {
    enum Presentation {
        case segments, menu, compactMenu

        var dimTitle: String {
            switch self {
            case .segments: "Dim resolved"
            case .menu: "Dim"
            case .compactMenu: ""
            }
        }
    }

    private static let height = ModeSelector.height
    private static let spacing: CGFloat = 4
    private static let controlFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let dimSlideDuration: TimeInterval = 0.160
    private static let dimSlideKey = "dimSlide"

    var onNavigate: ((Int) -> Void)?
    var onChangeStyle: ((JJConflict.Style) -> Void)?
    var onShowPendingChanges: ((Bool) -> Void)?
    var onPreferredSizeChange: (() -> Void)?
    var presentation: Presentation = .segments {
        didSet { if presentation != oldValue { updatePresentation() } }
    }

    private let navigation = NSBox()
    private let previous = NSButton()
    private let next = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let format = ModeSelector(["Diff", "Snapshot"])
    private let formatMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatDisplay = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
    private let dimClip = NSView()
    private let pending = NSButton()
    private let pendingCell = ConflictDimmingCell()
    private var selectedFormat: JJConflict.Style?
    private var showsDim = false
    private var closingDim = false
    private var dimTransition: Task<Void, Never>?
    private var current = false

    init() {
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictPanel")
        translatesAutoresizingMaskIntoConstraints = false
        navigation.identifier = .init("JujutsuConflictNavigation")
        navigation.boxType = .custom
        navigation.titlePosition = .noTitle
        navigation.borderWidth = 0
        navigation.cornerRadius = ModeSelector.cornerRadius
        navigation.fillColor = .labelColor.withAlphaComponent(0.10)
        navigation.contentViewMargins = .zero
        navigation.wantsLayer = true
        navigation.setAccessibilityLabel("Navigate conflicts")
        configureNavigation(previous, symbol: "chevron.up", name: "Previous Conflict", identifier: "JujutsuPreviousConflict", offset: -1)
        configureNavigation(next, symbol: "chevron.down", name: "Next Conflict", identifier: "JujutsuNextConflict", offset: 1)
        status.identifier = .init("JujutsuConflictCount")
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        navigation.addSubview(status)

        format.identifier = .init("JujutsuConflictFormat")
        format.setAccessibilityLabel("Conflict format")
        format.onSelect = { [weak self] in self?.changeStyle(at: $0) }
        formatMenu.identifier = .init("JujutsuConflictFormatMenu")
        formatMenu.controlSize = .small
        formatMenu.borderShape = .roundedRectangle
        formatMenu.font = Self.controlFont
        formatMenu.usesItemFromMenu = false
        formatMenu.addItems(withTitles: ["Diff", "Snapshot"])
        (formatMenu.cell as? NSPopUpButtonCell)?.menuItem = formatDisplay
        formatMenu.setAccessibilityLabel("Conflict format")
        formatMenu.target = self
        formatMenu.action = #selector(changeStyleFromMenu)

        dimClip.clipsToBounds = true
        dimClip.wantsLayer = true
        dimClip.layer?.masksToBounds = true
        pending.identifier = .init("JujutsuPendingChanges")
        pending.cell = pendingCell
        pending.setButtonType(.pushOnPushOff)
        pending.isBordered = false
        pending.controlSize = .small
        pending.font = Self.controlFont
        pending.image = Self.symbol("circle.lefthalf.filled")
        pending.setAccessibilityLabel("Dim resolved diff fragments")
        pending.target = self
        pending.action = #selector(changePending)
        pending.wantsLayer = true
        dimClip.addSubview(pending)

        for control in [dimClip, navigation, format, formatMenu] { addSubview(control) }
        pending.setAccessibilityElement(false)
        updatePresentation()
        suspend()
    }

    required init?(coder: NSCoder) { fatalError("Conflict panels are created in code.") }

    deinit { dimTransition?.cancel() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(for: presentation), height: Self.height)
    }

    func width(for presentation: Presentation) -> CGFloat {
        navigationWidth(for: presentation) + Self.spacing + formatWidth(for: presentation)
            + (showsDim || closingDim ? dimTravel(for: presentation) : 0)
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.height) / 2
        let navWidth = navigationWidth(for: presentation)
        let arrow = arrowWidth(for: presentation)
        let dimSpace = showsDim || closingDim ? dimTravel(for: presentation) : 0
        navigation.frame = NSRect(x: closingDim ? dimSpace : 0, y: y, width: navWidth, height: Self.height)
        previous.frame = NSRect(x: 0, y: 0, width: arrow, height: Self.height)
        status.frame = NSRect(x: arrow, y: (Self.height - status.intrinsicContentSize.height) / 2,
                              width: navWidth - arrow * 2, height: status.intrinsicContentSize.height)
        next.frame = NSRect(x: navWidth - arrow, y: 0, width: arrow, height: Self.height)

        let x = navWidth + Self.spacing
        dimClip.frame = NSRect(x: x, y: y, width: dimSpace, height: Self.height)
        pending.frame = NSRect(x: showsDim ? 0 : dimSpace, y: 0, width: dimWidth(for: presentation), height: Self.height)
        let formatControl: NSControl = presentation == .segments ? format : formatMenu
        formatControl.frame = NSRect(x: x + dimSpace, y: y, width: formatWidth(for: presentation), height: Self.height)
    }

    private func arrowWidth(for presentation: Presentation) -> CGFloat {
        presentation == .compactMenu ? 19 : 22
    }

    private func navigationWidth(for presentation: Presentation) -> CGFloat {
        2 * arrowWidth(for: presentation) + ceil(status.intrinsicContentSize.width) + 2
    }

    private func dimWidth(for presentation: Presentation) -> CGFloat {
        pendingCell.width(for: presentation.dimTitle)
    }

    private func dimTravel(for presentation: Presentation) -> CGFloat {
        dimWidth(for: presentation) + Self.spacing
    }

    private func formatWidth(for presentation: Presentation) -> CGFloat {
        switch presentation {
        case .segments: ceil(format.intrinsicContentSize.width)
        case .menu: ceil(("Snapshot" as NSString).size(withAttributes: [.font: Self.controlFont]).width) + 30
        case .compactMenu: 31
        }
    }

    private static func symbol(_ name: String, size: CGFloat = 11) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    private func configureNavigation(_ button: NSButton, symbol: String, name: String, identifier: String, offset: Int) {
        button.identifier = .init(identifier)
        button.isBordered = false
        button.image = Self.symbol(symbol, size: 9)
        button.imagePosition = .imageOnly
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.tag = offset
        button.target = self
        button.action = #selector(navigate(_:))
        navigation.addSubview(button)
    }

    private func updatePresentation() {
        // The compact control can have a different travel distance during live resizing.
        navigation.layer?.removeAnimation(forKey: Self.dimSlideKey)
        pending.layer?.removeAnimation(forKey: Self.dimSlideKey)
        format.isHidden = presentation != .segments
        formatMenu.isHidden = presentation == .segments
        formatMenu.imagePosition = presentation == .compactMenu ? .imageOnly : .noImage
        pending.isHidden = !showsDim && !closingDim
        pending.title = presentation.dimTitle
        pending.imagePosition = presentation == .compactMenu ? .imageOnly : .imageLeading
        updateFormatSelection()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateFormatSelection() {
        format.setSelection(selectedFormat?.rawValue ?? -1)
        formatMenu.select(selectedFormat.flatMap { formatMenu.item(at: $0.rawValue) })
        let title = formatMenu.titleOfSelectedItem ?? "Format"
        formatDisplay.title = title
        let symbol = switch selectedFormat {
        case .diff: "plusminus"
        case .snapshot: "doc.text"
        default: "arrow.left.arrow.right"
        }
        formatDisplay.image = presentation == .compactMenu ? Self.symbol(symbol) : nil
        formatMenu.setAccessibilityValue(title)
        formatMenu.needsDisplay = true
    }

    func update(_ conflicts: [JJConflict], selected index: Int, hasDraft: Bool, pendingChanges: Bool, canShowPending: Bool) {
        guard conflicts.indices.contains(index) else { return }
        let oldWidth = width(for: presentation)
        let style = conflicts[index].style
        let showDim = style == .diff
        let visibilityChanged = showsDim != showDim
        let animateDim = visibilityChanged && window != nil && !isHiddenOrHasHiddenAncestor &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = animateDim ? dimSlideStart() : nil
        if visibilityChanged {
            dimTransition?.cancel()
            dimTransition = nil
            navigation.layer?.removeAnimation(forKey: Self.dimSlideKey)
            pending.layer?.removeAnimation(forKey: Self.dimSlideKey)
            showsDim = showDim
            closingDim = animateDim && !showDim
            pending.isHidden = !showsDim && !closingDim
            pending.setAccessibilityElement(showsDim)
            needsLayout = true
        }
        let count = "\(index + 1)/\(conflicts.count)"
        if status.stringValue != count {
            status.stringValue = count
            status.setAccessibilityLabel("Conflict \(index + 1) of \(conflicts.count)")
        }
        let newFormat = style != .git && conflicts.allSatisfy { $0.style == style } ? style : nil
        if selectedFormat != newFormat {
            selectedFormat = newFormat
            updateFormatSelection()
        }
        let canChangeFormat = !hasDraft && conflicts.allSatisfy(\.canChangeStyle)
        let formatHelp = hasDraft ? "Resolve or undo the snapshot edits to switch conflict format." : nil
        for control in [format as NSControl, formatMenu] {
            control.isEnabled = canChangeFormat
            control.toolTip = formatHelp
            control.setAccessibilityHelp(formatHelp)
        }
        previous.isEnabled = conflicts.count > 1
        next.isEnabled = conflicts.count > 1
        pending.state = pendingChanges ? .on : .off
        pending.isEnabled = showsDim && canShowPending
        updatePendingHelp()
        current = true
        preferredSizeChanged(from: oldWidth)
        if let start { slideDim(from: start) }
    }

    private func preferredSizeChanged(from oldWidth: CGFloat) {
        guard oldWidth != width(for: presentation) else { return }
        invalidateIntrinsicContentSize()
        needsLayout = true
        onPreferredSizeChange?()
    }

    private func dimSlideStart() -> (navigation: CGFloat, button: CGFloat) {
        let end: CGFloat = showsDim ? 0 : 1
        let travel = dimTravel(for: presentation)
        func fraction(_ view: NSView) -> CGFloat {
            guard let layer = view.layer, layer.animation(forKey: Self.dimSlideKey) != nil,
                  let x = layer.presentation()?.frame.minX else { return end }
            return min(1, max(0, x / travel))
        }
        return (fraction(navigation), fraction(pending))
    }

    private func slideDim(from start: (navigation: CGFloat, button: CGFloat)) {
        window?.layoutIfNeeded()
        layoutSubtreeIfNeeded()
        let travel = dimTravel(for: presentation)
        let end: CGFloat = showsDim ? 0 : 1
        let duration = Self.dimSlideDuration
        let navigationDuration = duration * 0.8
        let navigationDelay = showsDim ? 0 : duration - navigationDuration
        let now = CACurrentMediaTime()

        func slide(_ view: NSView, from fraction: CGFloat, duration: TimeInterval, delay: TimeInterval = 0) {
            guard let layer = view.layer, fraction != end else { return }
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.isAdditive = true
            animation.fromValue = (fraction - end) * travel
            animation.toValue = 0
            animation.beginTime = layer.convertTime(now, from: nil) + delay
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.74, 0.26, 1)
            animation.fillMode = .backwards
            layer.add(animation, forKey: Self.dimSlideKey)
        }
        slide(navigation, from: start.navigation, duration: navigationDuration, delay: navigationDelay)
        slide(pending, from: start.button, duration: duration)

        guard closingDim else { return }
        // Keep the toolbar item wide while Dim slides under the stationary format control.
        dimTransition = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            let oldWidth = width(for: presentation)
            closingDim = false
            pending.isHidden = true
            dimTransition = nil
            preferredSizeChanged(from: oldWidth)
        }
    }

    func suspend() {
        current = false
        format.isEnabled = false
        formatMenu.isEnabled = false
        previous.isEnabled = false
        next.isEnabled = false
        pending.isEnabled = false
    }

    @objc private func navigate(_ sender: NSButton) {
        guard current else { return }
        onNavigate?(sender.tag)
    }

    @objc private func changeStyleFromMenu() {
        guard formatMenu.isEnabled else { return }
        changeStyle(at: formatMenu.indexOfSelectedItem)
    }

    private func changeStyle(at index: Int) {
        guard current, let selected = JJConflict.Style(rawValue: index), selected != selectedFormat else { return }
        // The header keeps showing the current format while preparing the replacement text.
        updateFormatSelection()
        onChangeStyle?(selected)
    }

    private func updatePendingHelp() {
        let help = pending.state == .on ? "Show resolved diff fragments at full intensity" : "Dim resolved diff fragments"
        pending.toolTip = help
        pending.setAccessibilityHelp(help)
    }

    @objc private func changePending() {
        guard current, pending.isEnabled else { return }
        updatePendingHelp()
        onShowPendingChanges?(pending.state == .on)
    }
}

@MainActor
private final class ConflictDimmingCell: NSButtonCell {
    private static let padding: CGFloat = 7
    private static let spacing: CGFloat = 5

    func width(for title: String) -> CGFloat {
        if title.isEmpty { return ModeSelector.height }
        return (image?.size.width ?? 0) + Self.spacing + titleWidth(title) + 2 * Self.padding
    }

    private func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let size = image?.size else { return .zero }
        let textWidth = title.isEmpty ? 0 : Self.spacing + titleWidth(title)
        let offset = (controlView?.userInterfaceLayoutDirection == .rightToLeft ? textWidth : -textWidth) / 2
        return NSRect(x: rect.midX - size.width / 2 + offset, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard !title.isEmpty else { return .zero }
        let icon = imageRect(forBounds: rect)
        let width = titleWidth(title)
        let x = controlView?.userInterfaceLayoutDirection == .rightToLeft
            ? icon.minX - Self.spacing - width : icon.maxX + Self.spacing
        return NSRect(x: x, y: rect.minY, width: width, height: rect.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let emphasis = state == .on || isHighlighted
        let opacity = ModeSelector.trackOpacity + (emphasis ? 0.12 : 0)
        NSColor.labelColor.withAlphaComponent(isEnabled ? opacity : opacity * 0.5).setFill()
        let radius = ModeSelector.cornerRadius
        NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
        super.draw(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let image { drawImage(image, withFrame: imageRect(forBounds: cellFrame), in: controlView) }
        if !title.isEmpty { _ = drawTitle(attributedTitle, withFrame: titleRect(forBounds: cellFrame), in: controlView) }
    }
}

@MainActor
final class JJConflictActions: JJEditorActionBar {
    private static let failureTitle = "Can't Apply"

    enum Action: Hashable {
        case applyDiff(side: Int), markResolved

        var title: String {
            switch self {
            case .applyDiff: "Apply Diff"
            case .markResolved: "Mark Resolved"
            }
        }

        var isResolution: Bool { self == .markResolved }
    }

    private let onAction: () -> Void
    private let action: Action
    private let button: NSButton
    private var canAct = true
    private var hasAnchor = true
    private var applied = false

    init(_ action: Action, onAction: @escaping () -> Void) {
        self.action = action
        self.onAction = onAction
        button = NSButton(title: action.title, target: nil, action: nil)
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictActions")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conflict Actions")
        configure(button, identifier: "JujutsuConflict\(action.title.filter(\.isLetter))",
                  label: action.title, action: #selector(performAction))
        button.font = .systemFont(ofSize: 11, weight: action.isResolution ? .semibold : .medium)
        if !action.isResolution {
            let normalWidth = button.intrinsicContentSize.width
            button.title = Self.failureTitle
            let failureWidth = button.intrinsicContentSize.width
            button.title = action.title
            button.widthAnchor.constraint(equalToConstant: ceil(max(normalWidth, failureWidth))).isActive = true
        }
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        installControls([button], edgeInsets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    required init?(coder: NSCoder) { nil }

    func update(enabled: Bool, applied: Bool, failed: Bool, hasDraft: Bool) {
        self.applied = applied
        setEnabled(enabled)
        let showsFailure = failed && !applied
        let title = showsFailure ? Self.failureTitle : action.title
        if button.title != title {
            button.title = title
            button.setAccessibilityLabel(showsFailure ? "Apply Diff failed" : action.title)
        }
        let help: String
        if action.isResolution { help = "Replace the conflict with the current snapshot." }
        else if applied { help = "This diff has been applied. Undo the application to apply it again." }
        else if showsFailure { help = "This diff overlaps the result. Edit the snapshot to combine the changes." }
        else { help = action.title }
        if button.toolTip != help {
            button.toolTip = help
            button.setAccessibilityHelp(help)
        }
        let tint: NSColor? = if showsFailure { .systemRed }
        else if action.isResolution && hasDraft { .controlAccentColor }
        else { nil }
        if button.contentTintColor != tint { button.contentTintColor = tint }
    }

    func setEnabled(_ enabled: Bool) {
        canAct = enabled
        updateAvailability()
    }

    func setAnchorAvailable(_ available: Bool) {
        hasAnchor = available
        updateAvailability()
    }

    private func updateAvailability() {
        let enabled = canAct && hasAnchor && !applied
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    @objc private func performAction() {
        if button.isEnabled { onAction() }
    }
}
