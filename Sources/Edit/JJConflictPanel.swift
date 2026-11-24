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

    func update(_ conflicts: [JJConflict], selected index: Int) {
        guard conflicts.indices.contains(index) else { return }
        status.stringValue = "Conflict \(index + 1) of \(conflicts.count)"
        let style = conflicts[index].style
        format.selectedSegment = style != .git && conflicts.allSatisfy { $0.style == style } ? style.rawValue : -1
        format.isEnabled = conflicts.allSatisfy(\.canChangeStyle)
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
        guard current, let selected = JJConflict.Style(rawValue: format.selectedSegment) else { return }
        onChangeStyle?(selected)
    }
}

@MainActor
final class JJConflictActions: JJEditorActionBar {
    enum Action: Equatable {
        case useSide(Int), applyDiff(JJConflict.Segment), undoDiff, editResult, useResult, applied

        var title: String {
            switch self {
            case .useSide: "Use Side"
            case .applyDiff: "Apply Diff"
            case .undoDiff: "Undo Diff"
            case .editResult: "Edit Result…"
            case .useResult: "Use Result"
            case .applied: "Applied"
            }
        }
    }

    private let onAction: (Action, NSView) -> Void
    private let actions: [Action]
    private var buttons: [NSButton] = []

    init(_ actions: [Action], onAction: @escaping (Action, NSView) -> Void) {
        self.actions = actions
        self.onAction = onAction
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictActions")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conflict Actions")
        buttons = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: nil, action: nil)
            configure(button, identifier: "JujutsuConflict\(action.title.filter(\.isLetter))",
                      label: action.title, action: #selector(performAction(_:)))
            button.tag = index
            button.font = .systemFont(ofSize: 11, weight: action == .useResult ? .semibold : .medium)
            button.isEnabled = action != .applied
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return button
        }
        installControls(buttons, edgeInsets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    required init?(coder: NSCoder) { nil }

    func setEnabled(_ enabled: Bool) {
        for (button, action) in zip(buttons, actions) { button.isEnabled = enabled && action != .applied }
    }

    @objc private func performAction(_ sender: NSButton) { onAction(actions[sender.tag], sender) }
}

@MainActor
final class JJConflictResultPopover: NSObject, NSPopoverDelegate {
    private let popover: SourceControlPopover
    private let editor: EditorTextView
    private let stack = NSStackView()
    private let notice = NSTextField(wrappingLabelWithString: "This diff overlaps the result. Edit the result to combine the changes.")
    private let use = NSButton(title: "Use Result", target: nil, action: nil)
    private var onUse: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    init(agentCheck: Bool) {
        popover = SourceControlPopover(agentCheck: agentCheck)
        let (scroll, editor) = EditorTextView.scrollingEditor(in: NSRect(x: 0, y: 0, width: 440, height: 156))
        self.editor = editor
        super.init()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        editor.identifier = .init("JujutsuConflictResultText")
        editor.setAccessibilityLabel("Conflict Result")

        let title = NSTextField(labelWithString: "Conflict Result")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        notice.identifier = .init("JujutsuConflictOverlap")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.preferredMaxLayoutWidth = 440

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        use.target = self
        use.action = #selector(useResult(_:))
        use.identifier = .init("JujutsuConflictUseEditedResult")
        use.bezelColor = .controlAccentColor
        use.keyEquivalent = "\r"
        use.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [NSView(), cancel, use])
        buttons.alignment = .centerY
        buttons.spacing = 8
        for child in [title, notice, scroll, buttons] { stack.addArrangedSubview(child) }
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 156).isActive = true
        let view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let controller = NSViewController()
        controller.view = view
        popover.native.contentViewController = controller
        popover.native.behavior = .semitransient
        popover.native.delegate = self
    }

    func show(_ text: String, lineEnding: String, overlaps: Bool, from anchor: NSView,
              onUse: @escaping (String) -> Void) -> Bool {
        guard !popover.isShown, anchor.window != nil,
              let view = popover.native.contentViewController?.view else { return false }
        notice.isHidden = !overlaps
        popover.contentSize = stack.fittingSize
        view.setFrameSize(popover.contentSize)
        editor.preferredLineEnding = lineEnding
        editor.resetMultiCarets()
        editor.string = text
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        self.onUse = onUse
        setUseEnabled(true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        editor.window?.makeFirstResponder(editor)
        return true
    }

    func close() {
        onUse = nil
        if popover.isShown { popover.close() }
    }

    func setUseEnabled(_ enabled: Bool) { use.isEnabled = enabled }

    func popoverWillClose(_ notification: Notification) {
        onUse = nil
        onDismiss?()
    }

    @objc private func cancel(_ sender: NSButton) { close() }

    @objc private func useResult(_ sender: NSButton) {
        let action = onUse
        let text = editor.string
        close()
        action?(text)
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView? { popover.isShown ? popover.native.contentViewController?.view : nil }
#endif
}
