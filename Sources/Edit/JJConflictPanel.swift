import AppKit

@MainActor
final class JJConflictPanel: NSView {
    var onNavigate: ((Int) -> Void)?
    var onResolve: ((JJConflict, Int) -> Void)?
    var onEdit: (() -> Void)?
    var onChangeStyle: ((JJConflict.Style) -> Void)?

    private let status = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl(
        images: ["chevron.up", "chevron.down"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() },
        trackingMode: .momentary, target: nil, action: nil
    )
    private let format = NSPopUpButton(frame: .zero)
    private let actions = NSButton(title: "Resolve…", target: nil, action: nil)
    private var selected: JJConflict?
    private var editable = false
    private var canNavigate = false
    private var current = false

    init() {
        super.init(frame: .zero)
        identifier = .init("JujutsuConflictPanel")
        translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.textColor = SyntaxColor.conflictMarker.nativeColor
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
        format.addItems(withTitles: ["Format", "Diff", "Snapshot"])
        format.menu?.autoenablesItems = false
        format.item(at: 0)?.isEnabled = false
        format.setAccessibilityLabel("Conflict format")
        format.target = self
        format.action = #selector(changeStyle)
        actions.identifier = .init("JujutsuConflictActions")
        actions.controlSize = .small
        actions.bezelStyle = .rounded
        actions.target = self
        actions.action = #selector(showActions)
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        actions.imagePosition = .noImage
        actions.setAccessibilityLabel("Conflict actions")

        let controls = NSStackView(views: [status, navigation, NSView(), format, actions])
        controls.spacing = 6
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Conflict panels are created in code.") }

    override func layout() {
        let compact = bounds.width < 300
        let iconOnly = bounds.width < 218
        if navigation.isHidden != compact { navigation.isHidden = compact }
        if status.isHidden != iconOnly {
            status.isHidden = iconOnly
            actions.imagePosition = iconOnly ? .imageOnly : .noImage
            format.controlSize = iconOnly ? .mini : .small
            actions.controlSize = iconOnly ? .mini : .small
        }
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    func update(_ conflicts: [JJConflict], selected index: Int, editable: Bool) {
        guard conflicts.indices.contains(index) else { return }
        selected = conflicts[index]
        self.editable = editable
        canNavigate = conflicts.count > 1
        status.stringValue = "Conflict \(index + 1) of \(conflicts.count)"
        let style = conflicts[index].style
        format.selectItem(at: style != .git && conflicts.allSatisfy { $0.style == style } ? style.rawValue + 1 : 0)
        format.isEnabled = conflicts.allSatisfy(\.canChangeStyle)
        navigation.isEnabled = canNavigate
        actions.title = editable ? "Resolve…" : "Conflicts"
        current = true
        actions.isEnabled = true
    }

    func suspend() {
        current = false
        actions.isEnabled = false
        format.isEnabled = false
        navigation.isEnabled = false
    }

    @objc private func navigate() {
        guard current else { return }
        onNavigate?(navigation.selectedSegment == 0 ? -1 : 1)
    }

    @objc private func changeStyle() {
        guard current, let selected = JJConflict.Style(rawValue: format.indexOfSelectedItem - 1) else { return }
        onChangeStyle?(selected)
    }

    @objc private func showActions() {
        guard current else { return }
        let menu = NSMenu()
        if editable, let selected {
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
        }
        if canNavigate || !editable {
            if editable { menu.addItem(.separator()) }
            for (title, offset) in [("Previous Conflict", -1), ("Next Conflict", 1)] {
                let item = NSMenuItem(title: title, action: #selector(navigateMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = offset
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: actions)
    }

    @objc private func resolve(_ item: NSMenuItem) {
        if current, let conflict = item.representedObject as? JJConflict { onResolve?(conflict, item.tag) }
    }
    @objc private func editMarkers() { if current { onEdit?() } }
    @objc private func navigateMenu(_ item: NSMenuItem) { if current { onNavigate?(item.tag) } }
}
