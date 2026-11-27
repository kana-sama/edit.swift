import AppKit

@MainActor
private func makeAssistancePanel(frame: NSRect, owner: NSWindow) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = owner.ignoresMouseEvents
    panel.alphaValue = owner.alphaValue
    return panel
}

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
            let panel = makeAssistancePanel(frame: placement.frame, owner: owner)
            let surface = AnchoredPopoverSurface(frame: NSRect(origin: .zero, size: placement.frame.size))
            let scroll = NSScrollView(frame: placement.shape.contentFrame)
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            surface.addSubview(scroll)
            panel.contentView = surface
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
    struct Item: Equatable {
        let label: String
        let detail: String?
    }

    private let table = CompletionTable()
    private let scroll = NSScrollView()
    private let documentation = NSScrollView()
    private let divider = NSBox()
    private let surface = AnchoredPopoverSurface(frame: .zero)
    private let column = NSTableColumn(identifier: .init("Completion"))
    private let onAccept: (Int) -> Void
    private var items: [Item] = []
    private var panel: NSPanel?
    private var documentationContent: EditorHoverContent?
    private var documentationWidth: CGFloat?
    private var outlinedSize: NSSize?
    private var naturalListWidth: CGFloat = 230
    private var pending = false

    var frame: NSRect? { panel?.frame }

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
        divider.boxType = .separator
        divider.setAccessibilityElement(false)
        documentation.setAccessibilityLabel("Completion documentation")
        for view in [scroll, documentation] {
            view.drawsBackground = false
            view.scrollerStyle = .overlay
            view.autohidesScrollers = true
            view.hasVerticalScroller = true
            surface.addSubview(view)
        }
        surface.addSubview(divider)
    }

    func update(_ items: [Item], selected: Int, pending: Bool) {
        self.items = items
        setPending(pending)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let naturalWidth = items.prefix(30).map { item in
            (item.label as NSString).size(withAttributes: [.font: labelFont]).width +
                ((item.detail ?? "") as NSString).size(withAttributes: [.font: detailFont]).width
        }.max() ?? 0
        naturalListWidth = min(330, max(230, ceil(naturalWidth) + 42))
        table.reloadData()
        select(selected)
    }

    private func setPending(_ value: Bool) {
        pending = value
        table.alphaValue = value ? 0.58 : 1
    }

    func show(_ anchor: NSRect, in owner: NSWindow, appearance: NSAppearance) {
        guard let screen = owner.screen ?? NSScreen.main else { close(); return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 4
        let right = anchor.maxX + gap
        let left = anchor.minX - gap
        let wantedWidth = naturalListWidth + 320
        let rightSpace = bounds.maxX - right
        let leftSpace = left - bounds.minX
        let below = anchor.minY - gap - bounds.minY
        let above = bounds.maxY - anchor.maxY - gap
        let wantedHeight = CGFloat(min(8, max(6, items.count))) * table.rowHeight + 8
        let goesBelow = below >= wantedHeight || below >= above
        let height = min(wantedHeight, goesBelow ? below : above)
        // Keep the list on the caret's right whenever there is usable room for both columns.
        let width: CGFloat
        let x: CGFloat
        if rightSpace >= min(wantedWidth, 420) {
            width = min(wantedWidth, rightSpace)
            x = right
        } else if leftSpace >= min(wantedWidth, 420) {
            width = min(wantedWidth, leftSpace)
            x = left - width
        } else {
            width = min(wantedWidth, bounds.width)
            x = max(bounds.minX, min(right, bounds.maxX - width))
        }
        guard width > 0, height >= table.rowHeight else { close(); return }
        let y = goesBelow ? anchor.minY - gap - height : anchor.maxY + gap
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel == nil {
            let panel = makeAssistancePanel(frame: frame, owner: owner)
            panel.contentView = surface
            self.panel = panel
        }
        guard let panel else { return }
        panel.appearance = appearance
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if outlinedSize != frame.size {
            surface.setFrameSize(frame.size)
            surface.applyOutline(CGPath(roundedRect: surface.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil))
            outlinedSize = frame.size
        }
        let listWidth = min(naturalListWidth, floor(width * 0.54))
        let list = NSRect(x: 0, y: 4, width: listWidth, height: height - 8)
        if scroll.frame != list {
            scroll.frame = list
            column.width = listWidth
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        }
        divider.frame = NSRect(x: listWidth, y: 0, width: 1, height: height)
        let details = NSRect(x: listWidth + 1, y: 0, width: width - listWidth - 1, height: height)
        if documentation.frame != details { documentation.frame = details }
        if documentationWidth != details.width { layoutDocumentation() }
        if owner.isVisible, panel.parent == nil { owner.addChildWindow(panel, ordered: .above) }
    }

    func showDocumentation(_ content: EditorHoverContent?) {
        documentationContent = content
        layoutDocumentation()
    }

    private func layoutDocumentation() {
        let width = documentation.contentSize.width
        documentationWidth = documentation.frame.width
        guard width > 24, let documentationContent else {
            documentation.documentView = nil
            return
        }
        let text = documentationContent.attributedText(maximumWidth: width - 24)
        let view = HoverTextView(width: width, text: text, inset: NSSize(width: 12, height: 10))
        view.isSelectable = false
        if let height = view.measure(at: width)?.height {
            view.setFrameSize(NSSize(width: width, height: height))
        }
        documentation.documentView = view
        documentation.contentView.scroll(to: .zero)
        documentation.reflectScrolledClipView(documentation.contentView)
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        documentationWidth = nil
        documentation.documentView = nil
    }

#if EDIT_AGENT_CHECKS
    var documentationForCheck: String? { (documentation.documentView as? NSTextView)?.string }
    var documentationFrameForCheck: NSRect? { screenFrame(of: documentation) }
    var listFrameForCheck: NSRect? { screenFrame(of: scroll) }
    var listForCheck: NSTableView? { panel == nil ? nil : table }

    private func screenFrame(of child: NSView) -> NSRect? {
        panel?.convertToScreen(surface.convert(child.frame, to: nil))
    }
#endif

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
