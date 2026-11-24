import AppKit

@MainActor
final class JJConflictPanel: NSView {
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
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
    var onResolve: ((JJConflict, Int) -> Void)?
    var onEdit: (() -> Void)?
    var selected: JJConflict?
    private let resolveButton = NSButton(title: "Resolve…", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictActions")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conflict Actions")
        configure(resolveButton, identifier: "JujutsuConflictResolve",
                  label: "Resolve Conflict", action: #selector(showActions))
        installControls([resolveButton])
        resolveButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        resolveButton.heightAnchor.constraint(equalToConstant: 23).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showActions() {
        guard let selected else { return }
        let menu = NSMenu()
        for (index, side) in selected.sides.enumerated() {
            let title = side.subject.isEmpty ? "Use Side \(index + 1)" : "Use Side \(index + 1) · \(side.subject)"
            let item = NSMenuItem(title: title, action: #selector(resolve(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = selected
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Markers", action: #selector(editMarkers), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: resolveButton)
    }

    @objc private func resolve(_ item: NSMenuItem) {
        if let conflict = item.representedObject as? JJConflict, conflict == selected { onResolve?(conflict, item.tag) }
    }

    @objc private func editMarkers() { if selected != nil { onEdit?() } }
}
