import AppKit

@MainActor
final class JJConflictPanel: NSView {
    private static let inset: CGFloat = 12

    var onNavigate: ((Int) -> Void)?
    var onChangeStyle: ((JJConflict.Style) -> Void)?

    private let status = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl(
        images: ["chevron.up", "chevron.down"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
        trackingMode: .momentary, target: nil, action: nil
    )
    private let format = NSSegmentedControl(labels: ["Diff", "Snapshot"], trackingMode: .selectOne, target: nil, action: nil)
    private let spacer = NSView()
    private var current = false

    init() {
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictPanel")
        translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigation.identifier = .init("JujutsuConflictNavigation")
        navigation.controlSize = .small
        navigation.setToolTip("Previous Conflict", forSegment: 0)
        navigation.setToolTip("Next Conflict", forSegment: 1)
        navigation.setAccessibilityLabel("Navigate conflicts")
        navigation.target = self
        navigation.action = #selector(navigate)
        format.identifier = .init("JujutsuConflictFormat")
        format.controlSize = .small
        format.setAccessibilityLabel("Conflict format")
        format.target = self
        format.action = #selector(changeStyle)

        let controls = NSStackView(views: [status, navigation, spacer, format])
        controls.spacing = 4
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Conflict panels are created in code.") }

    override func layout() {
        let compact = bounds.width < 205
        if status.isHidden != compact {
            status.isHidden = compact
            spacer.isHidden = compact
            navigation.controlSize = compact ? .mini : .small
            format.controlSize = compact ? .mini : .small
            for segment in 0..<navigation.segmentCount {
                navigation.setWidth(compact ? 18 : 0, forSegment: segment)
            }
            format.setWidth(compact ? 25 : 0, forSegment: 0)
            format.setWidth(compact ? 45 : 0, forSegment: 1)
        }
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    func update(_ conflicts: [JJConflict], selected index: Int, hasDraft: Bool = false) {
        guard conflicts.indices.contains(index) else { return }
        status.stringValue = "Conflict \(index + 1) of \(conflicts.count)"
        let style = conflicts[index].style
        format.selectedSegment = style != .git && conflicts.allSatisfy { $0.style == style } ? style.rawValue : -1
        format.isEnabled = !hasDraft && conflicts.allSatisfy(\.canChangeStyle)
        let formatHelp = hasDraft ? "Resolve or undo the snapshot edits to switch conflict format." : nil
        format.toolTip = formatHelp
        format.setAccessibilityHelp(formatHelp)
        navigation.isEnabled = conflicts.count > 1
        current = true
    }

    func suspend() {
        current = false
        format.isEnabled = false
        navigation.isEnabled = false
    }

    @objc private func navigate() {
        guard current else { return }
        onNavigate?(navigation.selectedSegment == 0 ? -1 : 1)
    }

    @objc private func changeStyle() {
        guard current, format.isEnabled, let selected = JJConflict.Style(rawValue: format.selectedSegment) else { return }
        onChangeStyle?(selected)
    }
}

@MainActor
final class JJConflictActions: JJEditorActionBar {
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
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        installControls([button], edgeInsets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    required init?(coder: NSCoder) { nil }

    func update(enabled: Bool, applied: Bool, overlaps: Bool, hasDraft: Bool) {
        self.applied = applied
        setEnabled(enabled)
        let help: String
        if action.isResolution { help = "Replace the conflict with the current snapshot." }
        else if applied { help = "This diff has been applied. Undo the application to apply it again." }
        else if overlaps { help = "This diff overlaps the result. Edit the snapshot to combine the changes." }
        else { help = action.title }
        if button.toolTip != help {
            button.toolTip = help
            button.setAccessibilityHelp(help)
        }
        let tint: NSColor? = action.isResolution && hasDraft ? .controlAccentColor : nil
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
