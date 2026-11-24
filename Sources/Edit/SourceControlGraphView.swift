import AppKit

@MainActor
final class SourceControlGraphView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSScrollView()
    let table = SourceControlGraphTable()
    var onSelect: ((JJSourceControlRevision) -> Void)?
    var onEdit: ((JJSourceControlRevision) -> Void)?
    var menu: ((JJSourceControlRevision) -> NSMenu?)?
    private let revisionHover = SourceControlRevisionHover()
    private var linkContext: SourceControlRevisionHover.LinkContext?

    private(set) var revisions: [JJSourceControlRevision] = []
    private var paths: [SourceControlGraphRow] = []
    private var laneCount = 1
    private var restoring = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("Change"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.headerView = nil
        table.rowHeight = 38
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editRow(_:))
        table.setAccessibilityLabel("Change graph")
        table.hoverRowChanged = { [weak self] row in
            guard let self else { return }
            if let row, revisions.indices.contains(row) {
                revisionHover.track(revisions[row], row: row, in: table, linkContext: linkContext)
            } else {
                dismissRevisionCard()
            }
        }
        table.hoverPointerLeft = { [weak self] point in self?.revisionHover.pointerLeft(at: point) }
        table.menuForRow = { [weak self] row in
            guard let self, revisions.indices.contains(row), table.isEnabled else { return nil }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return menu?(revisions[row])
        }
        view.drawsBackground = false
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.documentView = table
    }

    func install(_ revisions: [JJSourceControlRevision], selected: String?, linkContext: SourceControlRevisionHover.LinkContext? = nil) {
        if let row = revisionHover.row,
           !revisions.indices.contains(row) || self.revisions[row] != revisions[row] {
            dismissRevisionCard()
        }
        if self.linkContext != linkContext {
            self.linkContext = linkContext
            revisionHover.updateLinkContext(linkContext)
        }
        let top = table.rows(in: view.documentVisibleRect).location
        let oldAnchor = self.revisions.indices.contains(top) ? self.revisions[top].changeID : nil
        let offset = oldAnchor == nil ? 0 : view.documentVisibleRect.minY - table.rect(ofRow: top).minY
        self.revisions = revisions
        (paths, laneCount) = Self.connections(revisions)
        restoring = true
        table.reloadData()
        select(selected, revealing: false)
        if let oldAnchor, let row = revisions.firstIndex(where: { $0.changeID == oldAnchor }) {
            let clip = view.contentView
            let requested = NSRect(origin: NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(requested).origin)
            view.reflectScrolledClipView(clip)
        }
        restoring = false
    }

    func dismissRevisionCard() { revisionHover.dismiss() }

    func select(_ id: String?, revealing: Bool) {
        let previous = restoring
        restoring = true
        if let id, let row = revisions.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if revealing { table.scrollRowToVisible(row) }
        } else {
            table.deselectAll(nil)
        }
        restoring = previous
    }

    func numberOfRows(in tableView: NSTableView) -> Int { revisions.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: SourceControlGraphSelectionRow.identifier, owner: self) as? SourceControlGraphSelectionRow
            ?? SourceControlGraphSelectionRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SourceControlGraphCell.identifier, owner: self) as? SourceControlGraphCell
            ?? SourceControlGraphCell()
        cell.setRevision(revisions[row], path: paths[row], laneCount: laneCount)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, revisions.indices.contains(table.selectedRow) else { return }
        onSelect?(revisions[table.selectedRow])
    }

    @objc private func editRow(_ sender: Any?) {
        guard table.isEnabled, revisions.indices.contains(table.clickedRow) else { return }
        onEdit?(revisions[table.clickedRow])
    }

    private static func connections(_ revisions: [JJSourceControlRevision]) -> ([SourceControlGraphRow], Int) {
        var lanes: [String?] = []
        var remaining = Set(revisions.map(\.id))
        var width = 1
        let rows = revisions.map { revision in
            remaining.remove(revision.id)
            let incoming = lanes.indices.filter { lanes[$0] != nil }
            let own = lanes.firstIndex(of: revision.id) ?? nextLane(in: &lanes)
            lanes[own] = nil
            var outgoing: [SourceControlGraphRow.Edge] = []
            for edge in revision.edges {
                guard let id = edge.target, remaining.contains(id) else {
                    outgoing.append(.init(lane: own, indirect: true, elided: true))
                    continue
                }
                let lane = lanes.firstIndex(of: id) ?? nextLane(in: &lanes)
                lanes[lane] = id
                outgoing.append(.init(lane: lane, indirect: edge.indirect, elided: false))
            }
            width = max(width, lanes.count)
            while lanes.last == .some(nil) { lanes.removeLast() }
            return SourceControlGraphRow(lane: own, incoming: incoming, outgoing: outgoing)
        }
        return (rows, width)
    }

    private static func nextLane(in lanes: inout [String?]) -> Int {
        if let free = lanes.firstIndex(of: nil) { return free }
        lanes.append(nil)
        return lanes.count - 1
    }
}

@MainActor
final class SourceControlGraphTable: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    var hoverRowChanged: ((Int?) -> Void)?
    var hoverPointerLeft: ((NSPoint) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { if !isEnabled { hoverRowChanged?(nil) } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) { pointerLeft(with: event) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { hoverRowChanged?(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard isEnabled, visibleRect.contains(point), row >= 0 else {
            pointerLeft(with: event)
            return
        }
        hoverRowChanged?(row)
    }

    private func pointerLeft(with event: NSEvent) {
        if let window { hoverPointerLeft?(window.convertPoint(toScreen: event.locationInWindow)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        hoverRowChanged?(nil)
        return menuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

@MainActor
private final class SourceControlGraphSelectionRow: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SourceControlGraphRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("Change graph rows are created in code.") }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

private struct SourceControlGraphRow {
    struct Edge {
        let lane: Int
        let indirect: Bool
        let elided: Bool
    }

    let lane: Int
    let incoming: [Int]
    let outgoing: [Edge]

    var rightmostLane: Int { max(lane, incoming.max() ?? 0, outgoing.map(\.lane).max() ?? 0) }
}

@MainActor
private final class SourceControlGraphCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SourceControlRevision")
    private let subject = NSTextField(labelWithString: "")
    private let metadata = SourceControlRevisionIdentity()
    private let graph = SourceControlGraphGutter()
    private var graphWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        subject.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionSubject")
        subject.allowsExpansionToolTips = false
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.maximumNumberOfLines = 1
        subject.cell?.usesSingleLineMode = true
        subject.lineBreakMode = .byTruncatingTail
        for view in [graph, subject, metadata] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        graphWidth = graph.widthAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), graph.topAnchor.constraint(equalTo: topAnchor),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor), graphWidth,
            subject.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 4),
            subject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subject.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1), subject.heightAnchor.constraint(equalToConstant: 15),
            metadata.leadingAnchor.constraint(equalTo: subject.leadingAnchor), metadata.trailingAnchor.constraint(equalTo: subject.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: centerYAnchor, constant: 1), metadata.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Change graph cells are created in code.") }

    func setRevision(_ revision: JJSourceControlRevision, path: SourceControlGraphRow, laneCount: Int) {
        subject.stringValue = revision.subject
        let bookmarkNames = revision.bookmarks.isEmpty ? nil : "Bookmarks: \(revision.bookmarks.joined(separator: ", "))"
        // Keep lanes connected across rows while reserving text space only for the lanes this row uses.
        graph.laneSpacing = min(9, 54 / CGFloat(max(1, laneCount - 1)))
        graphWidth.constant = 18 + CGFloat(path.rightmostLane) * graph.laneSpacing
        graph.row = path
        graph.isWorkingCopy = revision.isWorkingCopy
        graph.isImmutable = revision.isImmutable
        graph.isConflicted = revision.isConflicted
        metadata.update(revision)
        updateColors()
        let identity = metadata.accessibilityLabel()
        setAccessibilityLabel([revision.subject, identity, bookmarkNames].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityHelp(SourceControlRevisionCard.creationDates(for: revision).joined(separator: "\n"))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        subject.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        metadata.setEmphasized(emphasized)
        graph.emphasized = emphasized
        graph.needsDisplay = true
    }
}

@MainActor
private final class SourceControlGraphGutter: NSView {
    var row: SourceControlGraphRow?
    var laneSpacing: CGFloat = 9
    var isWorkingCopy = false
    var isImmutable = false
    var isConflicted = false
    var emphasized = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let center = bounds.midY
        func x(_ lane: Int) -> CGFloat { 10 + CGFloat(lane) * laneSpacing }
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        color.withAlphaComponent(0.6).setStroke()
        let through = NSBezierPath()
        through.lineWidth = 1
        for lane in row.incoming {
            through.move(to: NSPoint(x: x(lane), y: bounds.maxY))
            through.line(to: NSPoint(x: x(lane), y: lane == row.lane ? center : bounds.minY))
        }
        through.stroke()
        for edge in row.outgoing {
            let path = NSBezierPath()
            path.lineWidth = 1
            if edge.indirect { path.setLineDash([2, 2], count: 2, phase: 0) }
            path.move(to: NSPoint(x: x(row.lane), y: center))
            path.curve(to: NSPoint(x: x(edge.lane), y: edge.elided ? 3 : bounds.minY),
                       controlPoint1: NSPoint(x: x(row.lane), y: center - 8),
                       controlPoint2: NSPoint(x: x(edge.lane), y: center - 8))
            path.stroke()
        }
        let nodeX = x(row.lane)
        if isWorkingCopy {
            (emphasized ? color : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: nodeX - 7, y: center - 7, width: 14, height: 14)).fill()
            let glyph = NSAttributedString(string: "@", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: emphasized ? NSColor.selectedContentBackgroundColor : NSColor.alternateSelectedControlTextColor
            ])
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: nodeX - size.width / 2, y: center - size.height / 2))
        } else if isConflicted {
            (emphasized ? color : NSColor.systemPurple).setFill()
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: nodeX, y: center + 5))
            diamond.line(to: NSPoint(x: nodeX + 5, y: center))
            diamond.line(to: NSPoint(x: nodeX, y: center - 5))
            diamond.line(to: NSPoint(x: nodeX - 5, y: center))
            diamond.close()
            diamond.fill()
        } else {
            let circle = NSBezierPath(ovalIn: NSRect(x: nodeX - 4, y: center - 4, width: 8, height: 8))
            color.setStroke()
            (isImmutable ? (emphasized ? color : NSColor.systemTeal) : NSColor.controlBackgroundColor).setFill()
            circle.fill()
            if !isImmutable { circle.stroke() }
        }
    }
}
