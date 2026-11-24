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
final class ReferencesSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case file(URL)
        case reference(ReferenceResult)
    }

    let view = NSView()
    private let table = SidebarResultTable()
    private let symbol = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var root: URL?
    private var isReplacingResults = false
    private var preview: ((ReferenceResult) -> Void)?
    private var activate: ((ReferenceResult) -> Void)?
    private var didHide: (() -> Void)?
    var focusResponder: NSView { table }

    init(onReturnFocus: @escaping () -> Void) {
        super.init()
        let scroll = NSScrollView()
        table.install(in: scroll, column: .init("ReferenceResult"), accessibilityLabel: "Reference Results")
        table.dataSource = self
        table.delegate = self
        table.isFileHeader = { [weak self] row in self?.reference(at: row) == nil }
        table.onClickSelectedRow = { [weak self] row in self?.previewRow(row) }
        table.onReturn = { [weak self] in self?.activateSelection() }
        table.onSpace = { [weak self] in self?.activateSelection() }
        table.onEscape = { [weak self] in
            self?.clearPreview()
            onReturnFocus()
        }

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
                root: URL?, results: [ReferenceResult], preview: @escaping (ReferenceResult) -> Void,
                activate: @escaping (ReferenceResult) -> Void, didHide: @escaping () -> Void) {
        self.root = root?.standardizedFileURL
        self.preview = preview
        self.activate = activate
        self.didHide = didHide
        rows = Dictionary(grouping: results, by: { $0.url.standardizedFileURL })
            .sorted { $0.key.path < $1.key.path }
            .flatMap { file, hits -> [Row] in
                [.file(file)] + hits.sorted { ($0.line, $0.column, $0.index) < ($1.line, $1.column, $1.index) }
                    .map(Row.reference)
            }
        self.symbol.stringValue = symbol
        count.stringValue = results.count == 1 ? "1 reference" : "\(results.count) references"

        let origin = originURL.standardizedFileURL
        let fromOrigin = rows.indices.filter { reference(at: $0)?.url.standardizedFileURL == origin }
        let nearest = fromOrigin.first { row in
            guard let result = reference(at: row) else { return false }
            return result.line > originLine || (result.line == originLine &&
                (result.column >= originColumn || result.match.length > originColumn - result.column))
        } ?? fromOrigin.last ?? rows.indices.first { reference(at: $0) != nil }
        isReplacingResults = true
        table.reloadData()
        if let nearest { table.selectRowIndexes(IndexSet(integer: nearest), byExtendingSelection: false) }
        isReplacingResults = false
    }

    func revealSelection(previewSelection: Bool) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        view.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(row)
        if previewSelection { previewRow(row) }
    }

    func clearPreview() { didHide?() }

    private func reference(at row: Int) -> ReferenceResult? {
        guard rows.indices.contains(row), case .reference(let result) = rows[row] else { return nil }
        return result
    }

    private func previewRow(_ row: Int) {
        if let result = reference(at: row) { preview?(result) }
    }

    private func activateSelection() {
        if let result = reference(at: table.selectedRow) { activate?(result) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { reference(at: row) != nil }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isReplacingResults { previewRow(table.selectedRow) }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ReferenceResultRow")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultRow { return reused }
        let row = SidebarResultRow()
        row.identifier = identifier
        return row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .file(let file):
            let identifier = NSUserInterfaceItemIdentifier("ReferenceFile")
            let header = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultFileHeader
                ?? SidebarResultFileHeader(name: "", detail: "", prioritizesName: true, leadingInset: 1)
            header.identifier = identifier
            header.updateFile(file.lastPathComponent, url: file)
            header.detailText = containingPath(for: file)
            header.toolTip = file.path
            return header
        case .reference(let result):
            let identifier = NSUserInterfaceItemIdentifier("ReferenceExcerpt")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultExcerptCell
                ?? SidebarResultExcerptCell(frame: .zero)
            cell.identifier = identifier
            cell.excerptLeading.constant = 12
            cell.configureExcerpt(SidebarResults.excerpt(of: result.excerpt as NSString, match: result.match))
            cell.setAccessibilityLabel("Line \(result.line + 1), \(cell.excerpt.stringValue)")
            return cell
        }
    }

    private func containingPath(for file: URL) -> String {
        let path = file.deletingLastPathComponent().path
        guard let root = root?.path else { return path }
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
