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
        case folder(URL, depth: Int)
        case file(URL, count: Int, depth: Int)
        case reference(ReferenceResult, depth: Int)
    }

    let view = NSView()
    private let table = SidebarActionResultTable()
    private let symbol = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var results: [ReferenceResult] = []
    private var collapsedFolders: Set<URL> = []
    private var treeMode = false
    private var root: URL?
    private var isReplacingResults = false
    private var isPreviewing = false
    private var preview: ((ReferenceResult, [Int]) -> Void)?
    private var activate: ((ReferenceResult, [Int]) -> Void)?
    private var didHide: (() -> Void)?
    var focusResponder: NSView { table }

    init(onReturnFocus: @escaping () -> Void) {
        super.init()
        let scroll = SidebarActionResultScrollView()
        table.install(in: scroll, column: .init("ReferenceResult"), accessibilityLabel: "Reference Results")
        table.dataSource = self
        table.delegate = self
        table.isFileHeader = { [weak self] row in
            if case .file = self?.row(at: row) { return true }
            return false
        }
        table.onClickGroup = { [weak self] row in
            guard let self, case .folder(let folder, _) = self.row(at: row) else { return false }
            table.window?.makeFirstResponder(table)
            toggleFolder(folder)
            return true
        }
        table.onHorizontalNavigation = { [weak self] expand in self?.navigateTree(expand: expand) == true }
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
                root: URL?, results: [ReferenceResult], preview: @escaping (ReferenceResult, [Int]) -> Void,
                activate: @escaping (ReferenceResult, [Int]) -> Void, didHide: @escaping () -> Void) {
        clearPreview()
        self.root = root?.standardizedFileURL
        self.preview = preview
        self.activate = activate
        self.didHide = didHide
        self.results = results
        collapsedFolders.removeAll()
        buildRows()
        self.symbol.stringValue = symbol
        updateCount()

        let origin = originURL.standardizedFileURL
        let fromOrigin = rows.indices.filter { reference(at: $0)?.url.standardizedFileURL == origin }
        let nearest = fromOrigin.first { row in
            guard let result = reference(at: row) else { return false }
            return result.line > originLine || (result.line == originLine &&
                (result.column >= originColumn || result.match.length > originColumn - result.column))
        } ?? fromOrigin.last ?? rows.indices.first { reference(at: $0) != nil }
        reload(selecting: nearest)
    }

    func setTreeMode(_ enabled: Bool) {
        guard treeMode != enabled else { return }
        let selected = reference(at: table.selectedRow)?.index
        treeMode = enabled
        buildRows()
        let row = rows.indices.first { reference(at: $0)?.index == selected && selected != nil }
        reload(selecting: row ?? rows.indices.first { reference(at: $0) != nil })
        revealSelection(previewSelection: false)
    }

    private func buildRows() {
        rows.removeAll(keepingCapacity: true)
        let files = Dictionary(grouping: results, by: { $0.url.standardizedFileURL }).sorted { $0.key.path < $1.key.path }
        var previous: [URL] = []
        for (file, hits) in files {
            let folders = treeMode ? ancestors(of: file) : []
            let openFolders = folders.prefix { !collapsedFolders.contains($0) }
            let visibleCount = min(openFolders.count + 1, folders.count)
            let shared = zip(previous, folders).prefix { $0 == $1 }.count
            for depth in shared..<max(shared, visibleCount) {
                rows.append(.folder(folders[depth], depth: depth))
            }
            previous = folders
            guard openFolders.count == folders.count else { continue }
            rows.append(.file(file, count: hits.count, depth: folders.count))
            rows += hits.sorted { ($0.line, $0.column, $0.index) < ($1.line, $1.column, $1.index) }
                .map { .reference($0, depth: folders.count) }
        }
    }

    private func ancestors(of file: URL) -> [URL] {
        guard let root, WorktreeFileOperations.contains(file, in: root) else { return [] }
        var folders: [URL] = []
        var folder = file.deletingLastPathComponent()
        while folder.path != root.path {
            folders.append(folder)
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return [] }
            folder = parent
        }
        return folders.reversed()
    }

    private func reload(selecting row: Int?) {
        isReplacingResults = true
        table.reloadData()
        if let row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        isReplacingResults = false
        updateVisibleSelection()
        table.refreshHover()
    }

    private func updateCount() {
        count.stringValue = results.count == 1 ? "1 reference" : "\(results.count) references"
    }

    private func toggleFolder(_ folder: URL) {
        if !collapsedFolders.insert(folder).inserted { collapsedFolders.remove(folder) }
        clearPreview()
        buildRows()
        reload(selecting: folderRow(for: folder))
        revealSelection(previewSelection: false)
    }

    private func folderRow(for folder: URL) -> Int? {
        rows.firstIndex { row in
            guard case .folder(let url, _) = row else { return false }
            return url == folder
        }
    }

    private func navigateTree(expand: Bool) -> Bool {
        guard case .folder(let folder, _) = row(at: table.selectedRow) else { return false }
        if collapsedFolders.contains(folder) == expand { toggleFolder(folder) }
        return true
    }

    private func dismiss(_ index: Int) {
        guard let removed = rows.indices.first(where: { reference(at: $0)?.index == index }) else { return }
        let selection = row(at: table.selectedRow)
        let wasPreviewing = isPreviewing
        results.removeAll { $0.index == index }
        updateCount()
        buildRows()
        let retained: Int?
        switch selection {
        case .folder(let folder, _): retained = folderRow(for: folder)
        case .reference(let reference, _) where reference.index != index:
            retained = rows.indices.first { self.reference(at: $0)?.index == reference.index }
        default: retained = nil
        }
        let replacement = retained ?? rows.indices.first { $0 >= removed && reference(at: $0) != nil }
            ?? rows.indices.last { reference(at: $0) != nil }
        reload(selecting: replacement)
        if replacement == nil { clearPreview() }
        else if wasPreviewing { revealSelection(previewSelection: true) }
    }

    func revealSelection(previewSelection: Bool) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        view.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(row)
        if previewSelection { previewRow(row) }
    }

    func clearPreview() {
        isPreviewing = false
        didHide?()
    }

    private func row(at index: Int) -> Row? { rows.indices.contains(index) ? rows[index] : nil }

    private func reference(at row: Int) -> ReferenceResult? {
        guard case .reference(let result, _) = self.row(at: row) else { return nil }
        return result
    }

    private func previewRow(_ row: Int) {
        if let result = reference(at: row) {
            isPreviewing = true
            preview?(result, results.map(\.index))
        }
    }

    private func activateSelection() {
        switch row(at: table.selectedRow) {
        case .folder(let folder, _): toggleFolder(folder)
        case .reference(let result, _):
            isPreviewing = true
            activate?(result, results.map(\.index))
        default: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { table.isFileHeader?(row) == false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        SidebarResults.rowHeight + (row > 0 && reference(at: row - 1) != nil && reference(at: row) == nil
            ? SidebarResults.fileGroupSpacing : 0)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReplacingResults else { return }
        updateVisibleSelection()
        if reference(at: table.selectedRow) != nil { previewRow(table.selectedRow) }
        else { clearPreview() }
    }

    private func updateVisibleSelection() {
        table.enumerateAvailableRowViews { row, _ in
            (row.view(atColumn: 0) as? SidebarActionResultCell)?.updateSelection(row.isSelected)
        }
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
        case .folder(let folder, let depth):
            let identifier = NSUserInterfaceItemIdentifier("ReferenceFolder")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ReferenceFolderCell
                ?? ReferenceFolderCell()
            cell.identifier = identifier
            cell.update(folder: folder, depth: depth, expanded: !collapsedFolders.contains(folder))
            return cell
        case .file(let file, let count, let depth):
            let identifier = NSUserInterfaceItemIdentifier("ReferenceFile")
            let header = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarResultFileHeader
                ?? SidebarResultFileHeader(name: "", detail: "")
            header.identifier = identifier
            header.updateFile(file.lastPathComponent, url: file)
            header.setIndent(depth)
            header.updateCount(count, accessibilityLabel: count == 1 ? "1 reference" : "\(count) references")
            return header
        case .reference(let result, let depth):
            let identifier = NSUserInterfaceItemIdentifier("ReferenceExcerpt")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarActionResultCell
                ?? SidebarActionResultCell(frame: .zero)
            cell.identifier = identifier
            cell.excerptLeading.constant = SidebarResults.excerptLeading + SidebarResults.indentation(at: depth)
            cell.configure(text: SidebarResults.excerpt(of: result.excerpt as NSString, match: result.match),
                           replacementAvailable: false, acceptsActions: true, selected: table.selectedRow == row,
                           dismiss: { [weak self] in self?.dismiss(result.index) })
            table.configureHover(for: cell, row: row)
            cell.setAccessibilityLabel("Line \(result.line + 1), \(cell.excerpt.stringValue)")
            return cell
        }
    }

}

@MainActor
private final class ReferenceFolderCell: NSTableCellView {
    private let disclosure = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private lazy var leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor)

    init() {
        super.init(frame: .zero)
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.setAccessibilityElement(false)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        for view in [disclosure, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            leading,
            disclosure.widthAnchor.constraint(equalToConstant: 16),
            disclosure.heightAnchor.constraint(equalToConstant: 16),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 5),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(folder: URL, depth: Int, expanded: Bool) {
        leading.constant = SidebarResults.fileLeading + SidebarResults.indentation(at: depth)
        name.stringValue = folder.lastPathComponent
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toolTip = folder.path
        setAccessibilityLabel("\(folder.lastPathComponent), \(expanded ? "expanded" : "collapsed")")
    }
}
