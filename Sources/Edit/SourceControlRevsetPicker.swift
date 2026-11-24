import AppKit

@MainActor
final class SourceControlRevsetPicker: NSObject, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let dragType = NSPasteboard.PasteboardType("dev.edit-swift.jujutsu-revset")
    private static let width: CGFloat = 312
    private static let inset: CGFloat = 5
    private static let rowHeight: CGFloat = 27
    private static let codeHeight: CGFloat = 69
    private static let nameInset: CGFloat = 23

    private struct Draft {
        let entry: SourceControlRevset?
        var isBuiltIn: Bool { entry?.isBuiltIn == true }
    }

    private weak var anchor: NSView?
    private let onSelect: (String) throws -> Void
    private let onSave: (String, String, String?) async throws -> Void
    private let onDelete: (String) throws -> Void
    private let onMove: (String, String?) throws -> Void
    private let readDefault: () async throws -> String
    private let popover: SourceControlPopover
    private let content = NSView()
    private let stack = NSStackView()
    private let table = RevsetTable()
    private let scroll = RevsetListScrollView()
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    private let code = SourceControlRevsetCode(height: codeHeight)
    private let codeMessage = NSTextField(wrappingLabelWithString: "")
    private let addRow = NSView()
    private let add = NSButton()
    private let name = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let delete = NSButton()
    private let save = NSButton()
    private let footer = NSStackView()
    private var settings = SourceControlRevsets()
    private var entries: [SourceControlRevset] = []
    private var draft: Draft?
    private var pendingSave: Task<Void, Never>?
    private var hoverRequest: Task<Void, Never>?
    private var defaultExpression: Result<String, Error>?
    private var defaultRequest: Task<Void, Never>?
    private var closing = false
    private var reopen = false

    init(anchor: NSView, agentCheck: Bool, onSelect: @escaping (String) throws -> Void,
         onSave: @escaping (String, String, String?) async throws -> Void,
         onDelete: @escaping (String) throws -> Void,
         onMove: @escaping (String, String?) throws -> Void,
         readDefault: @escaping () async throws -> String) {
        self.anchor = anchor
        popover = SourceControlPopover(agentCheck: agentCheck)
        self.onSelect = onSelect
        self.onSave = onSave
        self.onDelete = onDelete
        self.onMove = onMove
        self.readDefault = readDefault
        super.init()
        configure()
    }

    isolated deinit {
        hoverRequest?.cancel()
        defaultRequest?.cancel()
        pendingSave?.cancel()
    }

    func show() {
        if popover.isShown {
            if closing { reopen = true } else { close() }
            return
        }
        guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        clearDraft()
        defaultExpression = nil
        errorLabel.isHidden = true
        reloadList(preview: settings.selected.id)
        updatePreview()
        fit()
        let bottomEdge: NSRectEdge = anchor.isFlipped ? .maxY : .minY
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: bottomEdge)
        anchor.setAccessibilityExpanded(popover.isShown)
        table.window?.makeFirstResponder(table)
    }

    func close() {
        reopen = false
        cancelRequests()
        if popover.isShown && !closing {
            closing = true
            popover.close()
        }
    }

    func popoverWillClose(_ notification: Notification) {
        closing = true
        anchor?.setAccessibilityExpanded(false)
        cancelRequests()
    }

    func popoverDidClose(_ notification: Notification) {
        closing = false
        clearDraft()
        if reopen {
            reopen = false
            show()
        }
    }

    func update(_ settings: SourceControlRevsets) {
        self.settings = settings
        guard draft == nil else { return }
        reloadList(preview: selectedEntry?.id ?? settings.selected.id)
        if popover.isShown && !closing { updatePreview() }
        fit()
    }

    private var selectedEntry: SourceControlRevset? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    private func reloadList(preview id: String) {
        table.clearHover()
        entries = settings.entries
        listHeight.constant = min(6, CGFloat(entries.count)) * Self.rowHeight
        table.reloadData()
        if let row = entries.firstIndex(where: { $0.id == id }) ?? entries.firstIndex(where: { $0.id == settings.selected.id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    private func cancelRequests() {
        hoverRequest?.cancel()
        defaultRequest?.cancel()
        defaultRequest = nil
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func schedulePreview(at row: Int) {
        hoverRequest?.cancel()
        guard draft == nil, entries.indices.contains(row), row != table.selectedRow else { return }
        hoverRequest = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            guard let self, draft == nil, popover.isShown, !closing, entries.indices.contains(row) else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        hoverRequest?.cancel()
        guard draft == nil, popover.isShown, !closing else { return }
        updatePreview()
    }

    private func updatePreview() {
        guard draft == nil, let entry = selectedEntry else { return }
        showCode(for: entry, editable: false)
    }

    private func showCode(for entry: SourceControlRevset?, editable: Bool) {
        if let entry, entry.expression == nil {
            switch defaultExpression {
            case .success(let expression):
                codeMessage.isHidden = true
                code.install(expression, editable: false)
            case .failure(let error):
                code.install("", editable: false)
                codeMessage.stringValue = error.localizedDescription
                codeMessage.isHidden = false
            case nil:
                code.install("", editable: false)
                codeMessage.stringValue = "Loading the configured expression…"
                codeMessage.isHidden = false
                loadDefault()
            }
        } else {
            codeMessage.isHidden = true
            code.install(entry?.expression ?? "", editable: editable)
        }
    }

    private func loadDefault() {
        guard defaultRequest == nil else { return }
        defaultRequest = Task { [weak self, readDefault] in
            let result: Result<String, Error>
            do { result = .success(try await readDefault()) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            defaultRequest = nil
            defaultExpression = result
            if let draft {
                if let entry = draft.entry, entry.expression == nil { showCode(for: entry, editable: false) }
            } else if let entry = selectedEntry, entry.expression == nil {
                updatePreview()
            }
        }
    }

    @objc private func newRevset() {
        guard draft == nil else { return }
        openEditor(nil, in: addRow)
    }

    @objc private func editRow(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard draft == nil, entries.indices.contains(row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RevsetCell else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        cell.beginEditing()
        openEditor(entries[row], in: cell)
    }

    private func openEditor(_ entry: SourceControlRevset?, in host: NSView) {
        hoverRequest?.cancel()
        scroll.isLocked = true
        draft = Draft(entry: entry)
        errorLabel.isHidden = true
        name.stringValue = entry?.name ?? ""
        host.addSubview(name)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.nameInset),
            name.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        add.isHidden = entry == nil
        add.isEnabled = false
        footer.isHidden = false
        delete.isHidden = entry == nil || entry?.isBuiltIn == true
        for row in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RevsetCell)?.edit.isEnabled = false
        }
        showCode(for: entry, editable: entry?.isBuiltIn != true)
        updateEditorControls()
        fit()
        name.window?.makeFirstResponder(name)
        name.selectText(nil)
    }

    private var draftName: String { name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftExpression: String { code.editor.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    func controlTextDidChange(_ notification: Notification) { draftDidChange() }

    private func draftDidChange() {
        guard draft != nil else { return }
        if !errorLabel.isHidden {
            errorLabel.isHidden = true
            fit()
        }
        updateEditorControls()
    }

    private func updateEditorControls() {
        guard let draft else { return }
        let ready = pendingSave == nil
        name.isEnabled = ready
        code.editor.isEditable = ready && !draft.isBuiltIn
        delete.isEnabled = ready
        save.isEnabled = ready && !draftName.isEmpty && (draft.isBuiltIn || !draftExpression.isEmpty)
        save.bezelColor = save.isEnabled ? .controlAccentColor : nil
    }

    @objc private func submit() {
        guard let draft, save.isEnabled, pendingSave == nil else { return }
        let name = draftName
        let expression = draftExpression
        let id = draft.entry?.id
        pendingSave = Task { [weak self, onSave] in
            do {
                try await onSave(name, expression, id)
                guard let self, !Task.isCancelled else { return }
                pendingSave = nil
                finishEditing(preview: id ?? settings.selected.id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                pendingSave = nil
                report(error)
                updateEditorControls()
            }
        }
        updateEditorControls()
    }

    @objc private func removeRevset() {
        guard pendingSave == nil, let entry = draft?.entry, !entry.isBuiltIn else { return }
        do {
            try onDelete(entry.id)
            finishEditing(preview: settings.selected.id)
        } catch { report(error) }
    }

    @objc private func cancelEditing() {
        guard let draft else { return }
        finishEditing(preview: draft.entry?.id ?? settings.selected.id)
    }

    private func finishEditing(preview id: String) {
        pendingSave?.cancel()
        pendingSave = nil
        table.window?.makeFirstResponder(table)
        clearDraft()
        errorLabel.isHidden = true
        reloadList(preview: id)
        updatePreview()
        fit()
    }

    private func clearDraft() {
        draft = nil
        name.removeFromSuperview()
        scroll.isLocked = false
        add.isEnabled = true
        add.isHidden = false
        footer.isHidden = true
    }

    @objc private func activateRow() { activate(table.clickedRow) }

    private func activate(_ row: Int) {
        guard draft == nil, entries.indices.contains(row) else { return }
        do {
            try onSelect(entries[row].id)
            close()
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
        fit()
    }

    private func fit() {
        let height = ceil(stack.fittingSize.height) + 2 * Self.inset
        let size = NSSize(width: Self.width, height: height)
        popover.contentSize = size
        if !popover.isShown { content.setFrameSize(size) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { draft == nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RevsetRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RevsetCell.reuseID, owner: self) as? RevsetCell ?? RevsetCell()
        cell.install(entries[row], current: entries[row].id == settings.selected.id, allowsEditing: draft == nil)
        cell.edit.target = self
        cell.edit.action = #selector(editRow(_:))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard draft == nil, entries.indices.contains(row) else { return nil }
        hoverRequest?.cancel()
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
        guard draft == nil, (info.draggingSource as? NSTableView) === table, (0...entries.count).contains(row),
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
        table.style = .fullWidth
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateRow)
        table.onReturn = { [weak self] row in self?.activate(row) }
        table.onHover = { [weak self] row in self?.schedulePreview(at: row) }
        table.setAccessibilityLabel("Revsets")
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
        listHeight.isActive = true

        add.title = "New Revset…"
        add.target = self
        add.action = #selector(newRevset)
        add.isBordered = false
        add.alignment = .left
        add.font = .systemFont(ofSize: 12)
        add.contentTintColor = .secondaryLabelColor
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        add.imagePosition = .imageLeading
        add.imageHugsTitle = true
        addRow.addSubview(add)
        add.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            add.leadingAnchor.constraint(equalTo: addRow.leadingAnchor, constant: 3),
            add.trailingAnchor.constraint(equalTo: addRow.trailingAnchor, constant: -3),
            add.topAnchor.constraint(equalTo: addRow.topAnchor),
            add.bottomAnchor.constraint(equalTo: addRow.bottomAnchor)
        ])

        name.placeholderString = "Revset name"
        name.setAccessibilityLabel("Revset Name")
        name.font = .systemFont(ofSize: 12)
        name.cell?.usesSingleLineMode = true
        name.lineBreakMode = .byTruncatingTail
        name.delegate = self
        name.translatesAutoresizingMaskIntoConstraints = false
        name.nextKeyView = code.editor
        code.editor.onTextChange = { [weak self] in self?.draftDidChange() }
        let codeArea = NSView()
        codeArea.addSubview(code.scroll)
        codeArea.addSubview(codeMessage)
        code.scroll.translatesAutoresizingMaskIntoConstraints = false
        codeMessage.translatesAutoresizingMaskIntoConstraints = false
        codeMessage.font = .systemFont(ofSize: 11)
        codeMessage.textColor = .secondaryLabelColor
        codeMessage.maximumNumberOfLines = 3
        codeMessage.isHidden = true
        NSLayoutConstraint.activate([
            code.scroll.leadingAnchor.constraint(equalTo: codeArea.leadingAnchor),
            code.scroll.trailingAnchor.constraint(equalTo: codeArea.trailingAnchor),
            code.scroll.topAnchor.constraint(equalTo: codeArea.topAnchor),
            code.scroll.bottomAnchor.constraint(equalTo: codeArea.bottomAnchor),
            codeMessage.leadingAnchor.constraint(equalTo: codeArea.leadingAnchor, constant: 9),
            codeMessage.trailingAnchor.constraint(equalTo: codeArea.trailingAnchor, constant: -9),
            codeMessage.topAnchor.constraint(equalTo: codeArea.topAnchor, constant: 7)
        ])

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.maximumNumberOfLines = 6
        errorLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        errorLabel.isHidden = true
        delete.title = "Delete"
        delete.target = self
        delete.action = #selector(removeRevset)
        delete.hasDestructiveAction = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        cancel.keyEquivalent = "\u{1b}"
        save.title = "Save"
        save.target = self
        save.action = #selector(submit)
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        for control in [delete, cancel, save] {
            control.bezelStyle = .rounded
            control.controlSize = .small
        }
        footer.alignment = .centerY
        footer.spacing = 5
        for child in [delete, NSView(), cancel, save] { footer.addArrangedSubview(child) }
        footer.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for child in [scroll, addRow, codeArea, errorLabel, footer] {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.setCustomSpacing(4, after: addRow)
        stack.setCustomSpacing(5, after: codeArea)
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
            stack.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset)
        ])
        let controller = NSViewController()
        controller.view = content
        popover.native.contentViewController = controller
        popover.native.behavior = .transient
        popover.native.delegate = self
        update(settings)
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { content }
    var isShownForCheck: Bool { popover.isShown }
    var entriesForCheck: [SourceControlRevset] { entries }
    var currentIDForCheck: String { settings.selected.id }
#endif
}

@MainActor
private final class RevsetTable: NSTableView {
    var onReturn: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row != hovered else { return }
        hovered = row
        onHover?(row)
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    func clearHover() {
        hovered = -1
        onHover?(-1)
    }

    override func keyDown(with event: NSEvent) {
        clearHover()
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
           selectedRow >= 0 {
            onReturn?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class RevsetListScrollView: NSScrollView {
    var isLocked = false {
        didSet { verticalScroller?.isEnabled = !isLocked }
    }

    override func scrollWheel(with event: NSEvent) {
        if !isLocked { super.scrollWheel(with: event) }
    }
}

@MainActor
private final class RevsetRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

@MainActor
private final class RevsetCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("JujutsuRevsetRow")
    let edit = NSButton()
    private let check = NSImageView()
    private let name = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        edit.isBordered = false
        edit.imagePosition = .imageOnly
        edit.image = Self.symbol("pencil", size: 11)
        edit.contentTintColor = .secondaryLabelColor
        edit.widthAnchor.constraint(equalToConstant: 26).isActive = true
        edit.heightAnchor.constraint(equalToConstant: 24).isActive = true
        check.image = Self.symbol("checkmark", size: 10)
        check.contentTintColor = .controlAccentColor
        check.widthAnchor.constraint(equalToConstant: 13).isActive = true
        name.font = .systemFont(ofSize: 12)
        name.alignment = .left
        name.cell?.usesSingleLineMode = true
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [check, name, edit] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 5),
            name.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            edit.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Revset rows are created in code.") }

    func install(_ entry: SourceControlRevset, current: Bool, allowsEditing: Bool) {
        name.stringValue = entry.name
        name.isHidden = false
        edit.isHidden = false
        edit.isEnabled = allowsEditing
        check.alphaValue = current ? 1 : 0
        setAccessibilityLabel(current ? "\(entry.name), current revset" : entry.name)
        edit.setAccessibilityLabel("Edit \(entry.name)")
        edit.toolTip = "Edit \(entry.name)"
    }

    func beginEditing() {
        name.isHidden = true
        edit.isHidden = true
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
}
