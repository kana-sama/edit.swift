import AppKit

@MainActor
final class EditorAssistancePopup {
    private let prefersAbove: Bool
    private var panel: NSPanel?
    private var surface: AnchoredPopoverSurface?
    private var scroll: NSScrollView?
    private var pointerX: CGFloat?
    var frame: NSRect? { panel?.frame }

    init(prefersAbove: Bool) {
        self.prefersAbove = prefersAbove
    }

    func show(_ content: NSView, anchoredAt anchor: NSRect, in owner: NSWindow, appearance: NSAppearance,
              avoiding other: NSRect? = nil) {
        guard let screen = owner.screen ?? NSScreen.main else { close(); return }
        let screenFrame = screen.visibleFrame
        let size = NSSize(width: min(content.frame.width, screenFrame.width - 2 * EditorHoverPlacement.screenInset),
                          height: content.frame.height)
        guard let placement = EditorHoverPlacement(anchor: anchor, contentSize: size, screen: screenFrame,
                                                  prefersAbove: prefersAbove),
              other?.intersects(placement.frame) != true else {
            close()
            return
        }

        if panel == nil {
            let panel = NSPanel(contentRect: placement.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            let surface = AnchoredPopoverSurface(frame: NSRect(origin: .zero, size: placement.frame.size))
            let scroll = NSScrollView(frame: placement.shape.contentFrame)
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            surface.addSubview(scroll)
            panel.contentView = surface
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.animationBehavior = .none
            panel.becomesKeyOnlyIfNeeded = true
            panel.ignoresMouseEvents = owner.ignoresMouseEvents
            panel.alphaValue = owner.alphaValue
            self.panel = panel
            self.surface = surface
            self.scroll = scroll
        }
        guard let panel, let surface, let scroll else { return }
        panel.appearance = appearance
        let frameChanged = panel.frame != placement.frame || surface.bounds.size != placement.frame.size
        if frameChanged { panel.setFrame(placement.frame, display: false) }
        if frameChanged || pointerX != placement.shape.pointerX || scroll.documentView !== content {
            surface.applyOutline(placement.shape)
            scroll.frame = placement.shape.contentFrame
            pointerX = placement.shape.pointerX
        }
        scroll.hasVerticalScroller = content.frame.height > scroll.frame.height
        if scroll.documentView !== content { scroll.documentView = content }
        if owner.isVisible, panel.parent == nil { owner.addChildWindow(panel, ordered: .above) }
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        scroll?.documentView = nil
        self.panel = nil
        surface = nil
        scroll = nil
        pointerX = nil
    }
}

@MainActor
final class EditorCompletionChoices: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let table = CompletionTable()
    private let scroll = NSScrollView()
    private let column = NSTableColumn(identifier: .init("Completion"))
    private let onAccept: (Int) -> Void
    private var items: [LSPCompletionItem] = []
    private var pending = false

    var view: NSView { scroll }

    init(onAccept: @escaping (Int) -> Void) {
        self.onAccept = onAccept
        super.init()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(acceptClickedRow)
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 24
        table.style = .plain
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Completions")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
    }

    func update(_ items: [LSPCompletionItem], selected: Int) {
        self.items = items
        setPending(false)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let naturalWidth = items.prefix(30).map { item in
            (item.label as NSString).size(withAttributes: [.font: labelFont]).width +
                ((item.detail ?? "") as NSString).size(withAttributes: [.font: detailFont]).width
        }.max() ?? 0
        let width = min(460, max(230, ceil(naturalWidth) + 42))
        let height = min(8, items.count) * Int(table.rowHeight)
        let size = NSSize(width: width, height: CGFloat(height))
        scroll.setFrameSize(size)
        scroll.hasVerticalScroller = items.count > 8
        table.setFrameSize(size)
        column.width = width
        table.reloadData()
        select(selected)
    }

    func setPending(_ value: Bool) {
        pending = value
        table.alphaValue = value ? 0.58 : 1
    }

    func select(_ row: Int) {
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !pending }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("CompletionCandidate")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.identifier = identifier
        cell.update(label: item.label, detail: item.detail)
        return cell
    }

    @objc private func acceptClickedRow() {
        let row = table.clickedRow
        guard !pending, items.indices.contains(row) else { return }
        onAccept(row)
    }
}

private final class CompletionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .pointingHand)
    }
}

private final class CompletionCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        for field in [name, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.47)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Completion cells are created in code.") }

    func update(label: String, detail: String?) {
        name.stringValue = label
        self.detail.stringValue = detail ?? ""
        setAccessibilityLabel([label, detail].compactMap { $0 }.joined(separator: ", "))
        toolTip = [label, detail].compactMap { $0 }.joined(separator: "\n")
    }
}
