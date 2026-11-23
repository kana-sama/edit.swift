import AppKit

@MainActor
final class SourceControlRevsetPicker: NSObject, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("dev.edit-swift.jujutsu-revset")
    private static let width: CGFloat = 372
    private static let inset: CGFloat = 14

    private weak var anchor: NSView?
    private let onSelect: (String) throws -> Void
    private let onSave: (String, String, String?) async throws -> Void
    private let onDelete: (String) throws -> Void
    private let onMove: (String, String?) throws -> Void
    private let readDefault: () async throws -> String
    private let popover = NSPopover()
    private let content = NSView()
    private weak var currentPage: NSView?
    private var pageWidth: NSLayoutConstraint?
    private let list = NSStackView()
    private let table = RevsetTable()
    private let scroll = NSScrollView()
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: 88)
    private let listError = NSTextField(wrappingLabelWithString: "")
    private let preview = NSStackView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewMessage = NSTextField(wrappingLabelWithString: "")
    private let previewCode = SourceControlRevsetCode(height: 164)
    private lazy var editor = SourceControlRevsetEditor(
        onSave: onSave, onDelete: onDelete,
        onDone: { [weak self] in self?.showList(revealCurrent: true) },
        onResize: { [weak self] in self?.fit() }
    )
    private var settings = SourceControlRevsets()
    private var entries: [SourceControlRevset] = []
    private var defaultExpression: String?
    private var defaultRequest: Task<Void, Never>?

    init(anchor: NSView, onSelect: @escaping (String) throws -> Void,
         onSave: @escaping (String, String, String?) async throws -> Void,
         onDelete: @escaping (String) throws -> Void,
         onMove: @escaping (String, String?) throws -> Void,
         readDefault: @escaping () async throws -> String) {
        self.anchor = anchor
        self.onSelect = onSelect
        self.onSave = onSave
        self.onDelete = onDelete
        self.onMove = onMove
        self.readDefault = readDefault
        super.init()
        configure()
    }

    isolated deinit { defaultRequest?.cancel() }

    func show() {
        if popover.isShown { close(); return }
        guard let anchor, anchor.window != nil else { return }
        defaultExpression = nil
        showList(revealCurrent: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        table.window?.makeFirstResponder(table)
    }

    func close() {
        stopRequests()
        if popover.isShown { popover.close() }
    }

    func popoverWillClose(_ notification: Notification) { stopRequests() }

    func update(_ settings: SourceControlRevsets) {
        self.settings = settings
        entries = settings.entries
        table.reloadData()
        listHeight.constant = min(264, CGFloat(entries.count) * table.rowHeight)
        selectCurrent(revealing: false)
        if currentPage === list { fit() }
    }

    private func stopRequests() {
        defaultRequest?.cancel()
        defaultRequest = nil
        if let currentPage, currentPage !== list, currentPage !== preview { editor.stop() }
    }

    private func selectCurrent(revealing: Bool) {
        guard let row = entries.firstIndex(where: { $0.id == settings.selected.id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if revealing { table.scrollRowToVisible(row) }
    }

    private func showList(revealCurrent: Bool) {
        defaultRequest?.cancel()
        defaultRequest = nil
        listError.isHidden = true
        present(list)
        if revealCurrent { selectCurrent(revealing: true) }
        table.window?.makeFirstResponder(table)
    }

    @objc private func backFromPreview() { showList(revealCurrent: false) }

    @objc private func newRevset() { openEditor(nil) }

    @objc private func editRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard entries.indices.contains(row) else { return }
        openEditor(entries[row])
    }

    private func openEditor(_ entry: SourceControlRevset?) {
        editor.install(entry, configuredExpression: entry?.id == SourceControlRevset.defaultLog.id ? defaultExpression : nil)
        present(editor.view)
        editor.focusName()
        if let entry, entry.expression == nil, defaultExpression == nil {
            loadDefault { [weak self] result in self?.editor.installConfiguredExpression(result) }
        }
    }

    @objc private func previewRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        previewTitle.stringValue = entry.name
        showExpression(entry.expression ?? defaultExpression)
        present(preview)
        previewCode.editor.window?.makeFirstResponder(previewCode.editor)
        if entry.expression == nil, defaultExpression == nil {
            loadDefault { [weak self] result in
                switch result {
                case .success(let expression): self?.showExpression(expression)
                case .failure(let error): self?.showExpression(nil, message: error.localizedDescription)
                }
            }
        }
    }

    private func showExpression(_ expression: String?, message: String = "Loading the configured expression…") {
        previewMessage.stringValue = message
        previewMessage.isHidden = expression != nil
        previewCode.scroll.isHidden = expression == nil
        if let expression {
            let lines = expression.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            previewCode.resizeViewport(to: min(190, max(76, CGFloat(lines) * 18 + 20)))
            previewCode.install(expression, editable: false)
        }
        fit()
    }

    private func loadDefault(_ completion: @escaping (Result<String, Error>) -> Void) {
        defaultRequest?.cancel()
        defaultRequest = Task { [weak self, readDefault] in
            do {
                let expression = try await readDefault()
                guard let self, !Task.isCancelled else { return }
                defaultRequest = nil
                defaultExpression = expression
                completion(.success(expression))
            } catch {
                guard let self, !Task.isCancelled else { return }
                defaultRequest = nil
                completion(.failure(error))
            }
        }
    }

    @objc private func activateRow() { activate(table.clickedRow) }

    private func activate(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        do {
            try onSelect(entries[row].id)
            close()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        listError.stringValue = error.localizedDescription
        listError.isHidden = false
        fit()
    }

    private func present(_ page: NSView) {
        if currentPage !== page {
            pageWidth?.isActive = false
            currentPage?.removeFromSuperview()
            content.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            let width = page.widthAnchor.constraint(equalToConstant: Self.width)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
                page.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
                width
            ])
            currentPage = page
            pageWidth = width
        }
        fit()
    }

    private func fit() {
        guard let currentPage else { return }
        let height = ceil(currentPage.fittingSize.height) + 2 * Self.inset
        let size = NSSize(width: Self.width + 2 * Self.inset, height: height)
        popover.contentSize = size
        if !popover.isShown { popover.contentViewController?.view.setFrameSize(size) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RevsetCell.reuseID, owner: self) as? RevsetCell ?? RevsetCell()
        cell.install(entries[row], current: entries[row].id == settings.selected.id)
        cell.preview.target = self
        cell.preview.action = #selector(previewRow(_:))
        cell.edit.target = self
        cell.edit.action = #selector(editRow(_:))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard entries.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(entries[row].id, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let drop = drop(info, row: row, operation: operation) else { return [] }
        tableView.setDropRow(drop.boundary, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let drop = drop(info, row: row, operation: dropOperation) else { return false }
        let next = entries.indices.contains(drop.boundary) ? entries[drop.boundary].id : nil
        do {
            try onMove(entries[drop.source].id, next)
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func drop(_ info: any NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> (source: Int, boundary: Int)? {
        guard (info.draggingSource as? NSTableView) === table, (0...entries.count).contains(row),
              let id = info.draggingPasteboard.string(forType: Self.dragType),
              let source = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var boundary = row
        if operation == .on, entries.indices.contains(row) {
            let point = table.convert(info.draggingLocation, from: nil)
            if point.y >= table.rect(ofRow: row).midY { boundary += 1 }
        }
        guard boundary != source, boundary != source + 1 else { return nil }
        return (source, boundary)
    }

    private func configure() {
        let column = NSTableColumn(identifier: .init("Revset"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.headerView = nil
        table.rowHeight = 44
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateRow)
        table.onReturn = { [weak self] row in self?.activate(row) }
        table.setAccessibilityLabel("Revsets")
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        listHeight.isActive = true

        let title = NSTextField(labelWithString: "Revsets")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let add = NSButton(title: "New Revset", target: self, action: #selector(newRevset))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        let header = NSStackView(views: [title, NSView(), add])
        header.alignment = .centerY
        listError.textColor = .systemRed
        listError.font = .systemFont(ofSize: 11)
        listError.preferredMaxLayoutWidth = Self.width
        listError.isHidden = true
        configurePage(list, views: [header, scroll, listError])

        let back = RevsetCell.iconButton("chevron.left", label: "Back to Revsets")
        back.target = self
        back.action = #selector(backFromPreview)
        back.keyEquivalent = "\u{1b}"
        previewTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        previewTitle.lineBreakMode = .byTruncatingTail
        previewTitle.cell?.usesSingleLineMode = true
        previewTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewHeader = NSStackView(views: [back, previewTitle, NSView()])
        previewHeader.alignment = .centerY
        previewHeader.spacing = 6
        previewMessage.font = .systemFont(ofSize: 12)
        previewMessage.textColor = .secondaryLabelColor
        previewMessage.preferredMaxLayoutWidth = Self.width
        configurePage(preview, views: [previewHeader, previewMessage, previewCode.scroll])

        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        update(settings)
        present(list)
    }

    private func configurePage(_ page: NSStackView, views: [NSView]) {
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 9
        for view in views {
            page.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { popover.contentViewController!.view }
    var isShownForCheck: Bool { popover.isShown }
    var entriesForCheck: [SourceControlRevset] { entries }
    var currentIDForCheck: String { settings.selected.id }
#endif
}

@MainActor
private final class RevsetTable: NSTableView {
    var onReturn: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
           selectedRow >= 0 {
            onReturn?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class RevsetCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("JujutsuRevsetRow")
    let preview = iconButton("chevron.left.forwardslash.chevron.right", label: "Preview Revset")
    let edit = iconButton("pencil", label: "Edit Revset")

    private let grip = NSImageView()
    private let check = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        grip.image = Self.symbol("line.3.horizontal", size: 10)
        grip.widthAnchor.constraint(equalToConstant: 13).isActive = true
        check.image = Self.symbol("checkmark", size: 10)
        check.widthAnchor.constraint(equalToConstant: 13).isActive = true
        name.font = .systemFont(ofSize: 12, weight: .medium)
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for label in [name, summary] {
            label.alignment = .left
            label.cell?.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for child in [grip, check, name, summary, preview, edit] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 7),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 7),
            name.trailingAnchor.constraint(equalTo: preview.leadingAnchor, constant: -8),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            summary.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            summary.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            edit.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            edit.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -3),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Revset rows are created in code.") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        let foreground = NSColor.alternateSelectedControlTextColor
        name.textColor = emphasized ? foreground : .labelColor
        summary.textColor = emphasized ? foreground.withAlphaComponent(0.85) : .secondaryLabelColor
        grip.contentTintColor = (emphasized ? foreground : NSColor.secondaryLabelColor).withAlphaComponent(0.75)
        check.contentTintColor = emphasized ? foreground : .controlAccentColor
        for button in [preview, edit] { button.contentTintColor = emphasized ? foreground : .secondaryLabelColor }
    }

    func install(_ entry: SourceControlRevset, current: Bool) {
        name.stringValue = entry.name
        if let expression = entry.expression {
            let lines = expression.split(maxSplits: 1, whereSeparator: \.isNewline)
            let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            summary.stringValue = lines.count > 1 ? first + " …" : first
        } else {
            summary.stringValue = "Configured jj log"
        }
        check.alphaValue = current ? 1 : 0
        setAccessibilityLabel(current ? "\(entry.name), current revset" : entry.name)
        preview.setAccessibilityLabel("Preview \(entry.name)")
        edit.setAccessibilityLabel("Edit \(entry.name)")
    }

    static func iconButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = Self.symbol(symbol, size: 12)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) ?? NSImage()
    }
}
