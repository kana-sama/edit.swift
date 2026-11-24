import AppKit

struct ReferenceResult: Sendable {
    let index: Int
    let url: URL
    let line: Int
    let column: Int
    let excerpt: String
    let match: NSRange
}

@MainActor
final class ReferencesSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class FileGroup: NSObject {
        let file: URL
        let rows: [Row]

        init(file: URL, results: [ReferenceResult]) {
            self.file = file
            rows = results.map(Row.init)
        }
    }

    private final class Row: NSObject {
        let result: ReferenceResult

        init(_ result: ReferenceResult) { self.result = result }
    }

    let view = NSView()
    private let outline = ReferencesOutline()
    private let symbol = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var files: [FileGroup] = []
    private var root: URL?
    private var open: ((ReferenceResult) -> Void)?
    var focusResponder: NSView { outline }

    init(onReturnFocus: @escaping () -> Void) {
        super.init()
        let identifier = NSUserInterfaceItemIdentifier("ReferenceResult")
        let column = NSTableColumn(identifier: identifier)
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 12
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Reference Results")
        outline.onActivate = { [weak self] row in self?.activate(row) }
        outline.onEscape = onReturnFocus

        let scroll = NSScrollView()
        SidebarResults.configure(outline, in: scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        symbol.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        symbol.lineBreakMode = .byTruncatingMiddle
        symbol.maximumNumberOfLines = 1
        symbol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        count.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [symbol, count])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.heightAnchor.constraint(equalToConstant: SidebarResults.rowHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func update(symbol: String, originURL: URL, originLine: Int, originColumn: Int,
                root: URL?, results: [ReferenceResult], open: @escaping (ReferenceResult) -> Void) {
        self.root = root?.standardizedFileURL
        self.open = open
        files = Dictionary(grouping: results, by: { $0.url.standardizedFileURL })
            .sorted { $0.key.path < $1.key.path }
            .map { file, hits in
                FileGroup(file: file, results: hits.sorted { ($0.line, $0.column, $0.index) < ($1.line, $1.column, $1.index) })
            }
        self.symbol.stringValue = symbol
        count.stringValue = results.count == 1 ? "1 reference" : "\(results.count) references"
        outline.reloadData()
        if let file = files.first(where: { $0.file == originURL.standardizedFileURL }) {
            outline.expandItem(file)
            let nearest = file.rows.first { row in
                let result = row.result
                return result.line > originLine || (result.line == originLine &&
                    (result.column >= originColumn || result.match.length > originColumn - result.column))
            } ?? file.rows.last
            if let nearest { select(nearest) }
        } else if let first = files.first {
            select(first)
        }
    }

    func revealSelection() {
        guard outline.selectedRow >= 0 else { return }
        view.layoutSubtreeIfNeeded()
        outline.scrollRowToVisible(outline.selectedRow)
    }

    private func select(_ item: NSObject) {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func activate(_ row: Int) {
        guard row >= 0 else { return }
        switch outline.item(atRow: row) {
        case let file as FileGroup:
            if outline.isItemExpanded(file) { outline.collapseItem(file) }
            else { outline.expandItem(file) }
        case let hit as Row:
            open?(hit.result)
        default:
            break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return files.count }
        return (item as? FileGroup)?.rows.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let file = item as? FileGroup { return file.rows[index] }
        return files[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileGroup }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ReferenceResultRow")
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultRow { return reused }
        let row = SidebarResultRow()
        row.identifier = identifier
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let file = item as? FileGroup {
            let identifier = NSUserInterfaceItemIdentifier("ReferenceFile")
            let header = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultFileHeader
                ?? SidebarResultFileHeader(name: "", detail: "", prioritizesName: true)
            header.identifier = identifier
            header.updateFile(file.file.lastPathComponent, url: file.file)
            header.detailText = containingPath(for: file.file)
            header.toolTip = file.file.path
            return header
        }
        guard let hit = (item as? Row)?.result else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ReferenceExcerpt")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultExcerptCell
            ?? SidebarResultExcerptCell(frame: .zero)
        cell.identifier = identifier
        cell.configureExcerpt(SidebarResults.excerpt(of: hit.excerpt as NSString, match: hit.match))
        cell.setAccessibilityLabel("Line \(hit.line + 1), \(cell.excerpt.stringValue)")
        return cell
    }

    private func containingPath(for file: URL) -> String {
        let path = file.deletingLastPathComponent().path
        guard let root = root?.path else { return path }
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private final class ReferencesOutline: NSOutlineView {
    var onActivate: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let disclosure = row >= 0 && frameOfOutlineCell(atRow: row).contains(point)
        super.mouseDown(with: event)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard row >= 0, !disclosure, event.clickCount == 1, modifiers.isEmpty,
              let release = NSApp.currentEvent, release.type == .leftMouseUp, release.window === window,
              release.timestamp >= event.timestamp,
              self.row(at: convert(release.locationInWindow, from: nil)) == row else { return }
        onActivate?(row)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 36, 76:
                if !event.isARepeat { onActivate?(selectedRow) }
                return
            case 53:
                if !event.isARepeat { onEscape?() }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
