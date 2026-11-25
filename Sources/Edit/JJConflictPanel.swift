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

    private static let height: CGFloat = 22
    private static let spacing: CGFloat = 4
    private static let controlFont = NSFont.systemFont(ofSize: 11, weight: .medium)

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
    private let format = NSSegmentedControl(labels: ["Diff", "Snapshot"], trackingMode: .selectOne, target: nil, action: nil)
    private let formatMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatDisplay = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
    private let pending = NSButton()
    private var selectedFormat: JJConflict.Style?
    private var showsDim = false
    private var current = false

    init() {
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictPanel")
        translatesAutoresizingMaskIntoConstraints = false
        navigation.identifier = .init("JujutsuConflictNavigation")
        navigation.boxType = .custom
        navigation.titlePosition = .noTitle
        navigation.borderWidth = 0
        navigation.cornerRadius = 6
        navigation.fillColor = .labelColor.withAlphaComponent(0.10)
        navigation.contentViewMargins = .zero
        navigation.setAccessibilityLabel("Navigate conflicts")
        configureNavigation(previous, symbol: "chevron.up", name: "Previous Conflict", identifier: "JujutsuPreviousConflict", offset: -1)
        configureNavigation(next, symbol: "chevron.down", name: "Next Conflict", identifier: "JujutsuNextConflict", offset: 1)
        status.identifier = .init("JujutsuConflictCount")
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        navigation.addSubview(status)

        format.identifier = .init("JujutsuConflictFormat")
        format.controlSize = .small
        format.setAccessibilityLabel("Conflict format")
        format.target = self
        format.action = #selector(changeStyleFromSegments)
        formatMenu.identifier = .init("JujutsuConflictFormatMenu")
        formatMenu.controlSize = .small
        formatMenu.font = Self.controlFont
        formatMenu.usesItemFromMenu = false
        formatMenu.addItems(withTitles: ["Diff", "Snapshot"])
        (formatMenu.cell as? NSPopUpButtonCell)?.menuItem = formatDisplay
        formatMenu.setAccessibilityLabel("Conflict format")
        formatMenu.target = self
        formatMenu.action = #selector(changeStyleFromMenu)

        pending.identifier = .init("JujutsuPendingChanges")
        pending.setButtonType(.pushOnPushOff)
        pending.bezelStyle = .accessoryBar
        pending.controlSize = .small
        pending.font = Self.controlFont
        pending.image = Self.symbol("circle.lefthalf.filled")
        pending.setAccessibilityLabel("Dim resolved diff fragments")
        pending.target = self
        pending.action = #selector(changePending)

        for control in [navigation as NSView, pending, format, formatMenu] { addSubview(control) }
        updatePresentation()
        suspend()
    }

    required init?(coder: NSCoder) { fatalError("Conflict panels are created in code.") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(for: presentation), height: Self.height)
    }

    func width(for presentation: Presentation) -> CGFloat {
        navigationWidth(for: presentation) + Self.spacing + formatWidth(for: presentation)
            + (showsDim ? Self.spacing + dimWidth(for: presentation) : 0)
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.height) / 2
        let navWidth = navigationWidth(for: presentation)
        let arrow = arrowWidth(for: presentation)
        navigation.frame = NSRect(x: 0, y: y, width: navWidth, height: Self.height)
        previous.frame = NSRect(x: 0, y: 0, width: arrow, height: Self.height)
        status.frame = NSRect(x: arrow, y: (Self.height - status.intrinsicContentSize.height) / 2,
                              width: navWidth - arrow * 2, height: status.intrinsicContentSize.height)
        next.frame = NSRect(x: navWidth - arrow, y: 0, width: arrow, height: Self.height)

        var x = navWidth + Self.spacing
        if showsDim {
            let dimWidth = dimWidth(for: presentation)
            pending.frame = NSRect(x: x, y: y, width: dimWidth, height: Self.height)
            x += dimWidth + Self.spacing
        }
        let formatControl: NSControl = presentation == .segments ? format : formatMenu
        formatControl.frame = NSRect(x: x, y: y, width: formatWidth(for: presentation), height: Self.height)
    }

    private func arrowWidth(for presentation: Presentation) -> CGFloat {
        presentation == .compactMenu ? 19 : 22
    }

    private func navigationWidth(for presentation: Presentation) -> CGFloat {
        2 * arrowWidth(for: presentation) + ceil(status.intrinsicContentSize.width) + 2
    }

    private func dimWidth(for presentation: Presentation) -> CGFloat {
        if presentation == .compactMenu { return 22 }
        let titleWidth = (presentation.dimTitle as NSString).size(withAttributes: [.font: Self.controlFont]).width
        return ceil(titleWidth) + 28
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
        format.isHidden = presentation != .segments
        formatMenu.isHidden = presentation == .segments
        formatMenu.imagePosition = presentation == .compactMenu ? .imageOnly : .noImage
        pending.isHidden = !showsDim
        pending.title = presentation.dimTitle
        pending.imagePosition = presentation == .compactMenu ? .imageOnly : .imageLeading
        updateFormatSelection()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateFormatSelection() {
        format.selectedSegment = selectedFormat?.rawValue ?? -1
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
        let count = "\(index + 1)/\(conflicts.count)"
        if status.stringValue != count {
            status.stringValue = count
            status.setAccessibilityLabel("Conflict \(index + 1) of \(conflicts.count)")
        }
        let style = conflicts[index].style
        let newFormat = style != .git && conflicts.allSatisfy { $0.style == style } ? style : nil
        if selectedFormat != newFormat {
            selectedFormat = newFormat
            updateFormatSelection()
        }
        showsDim = style == .diff
        pending.isHidden = !showsDim
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
        pending.isEnabled = canShowPending
        updatePendingHelp()
        current = true
        if oldWidth != width(for: presentation) {
            invalidateIntrinsicContentSize()
            needsLayout = true
            onPreferredSizeChange?()
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

    @objc private func changeStyleFromSegments() {
        guard format.isEnabled else { return }
        changeStyle(at: format.selectedSegment)
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
