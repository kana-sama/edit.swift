import AppKit
import CoreServices

@MainActor
final class WorktreeSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Item: NSObject {
        let url: URL
        let isDirectory: Bool
        let path: String
        let outside: Bool
        var isIgnored = false
        var isSystemHidden = false
        var hasHiddenParent = false
        var children: [Item] = []
        var visibleChildren: [Item] = []
        var isLoaded = false

        init(_ url: URL, directory: Bool, outside: Bool = false) {
            self.url = url
            path = WorktreeFileOperations.path(url)
            self.isDirectory = directory
            self.outside = outside
        }

        var name: String {
            if outside && isDirectory { return (path as NSString).abbreviatingWithTildeInPath }
            return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        }
    }

    private static let hiddenItemsKey = "WorktreeHiddenItems"
    private static let hiddenItemsChanged = Notification.Name("Edit.WorktreeHiddenItemsChanged")
    private let container = NSView()
    private let scroll = NSScrollView()
    private let tree = WorktreeOutline()
    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private var root: Item?
    private var outside: Item?
    private var currentPath: String?
    private var currentDirectories: Set<String> = []
    private var needsReveal = false
    private var manualHidden: Set<String> = []
    private var expanded: Set<String> = []
    private var requests: [String: Task<Void, Never>] = [:]
    private var isActive = false
    private var monitor: WorktreeMonitor?
    private var reloading = false
    private var pendingOpen: URL?
    private var openingFile: Task<Void, Never>?

    private lazy var actions = WorktreeActions(
        document: document, app: app,
        refresh: { [weak self] in self?.refresh() },
        isHidden: { [weak self] in self?.manualHidden.contains(WorktreeFileOperations.path($0)) ?? false },
        toggleHidden: { [weak self] in self?.toggleHidden($0) }
    )

    var view: NSView { container }
    var outline: NSOutlineView { tree }
    private(set) var showsHidden = false

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        super.init()

        let column = NSTableColumn(identifier: .init("Name"))
        column.resizingMask = .autoresizingMask
        tree.addTableColumn(column)
        tree.outlineTableColumn = column
        tree.headerView = nil
        // The source-list style makes selected labels heavier even with a regular font.
        tree.style = .inset
        tree.indentationPerLevel = 12
        column.minWidth = 0
        tree.backgroundColor = .clear
        tree.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tree.intercellSpacing.width = 0
        tree.allowsMultipleSelection = true
        tree.allowsEmptySelection = true
        tree.floatsGroupRows = false
        tree.setAccessibilityLabel("Worktree")
        tree.dataSource = self
        tree.delegate = self
        tree.owner = self
        tree.target = self
        tree.doubleAction = #selector(activateClickedDirectory(_:))
        tree.registerForDraggedTypes([.fileURL])
        tree.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tree.setDraggingSourceOperationMask(.copy, forLocal: false)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.clipsToBounds = true
        scroll.documentView = tree
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if !app.isAgentCheck {
            NotificationCenter.default.addObserver(self, selector: #selector(hiddenItemsChanged(_:)),
                                                   name: Self.hiddenItemsChanged, object: nil)
        }
    }

    isolated deinit {
        for request in requests.values { request.cancel() }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { pendingOpen = nil }
        startMonitoring()
        if active {
            needsReveal = currentPath != nil
            revealCurrent()
            if root?.isLoaded == true { refresh() }
        }
    }

    func update(folder: URL, currentFile: URL?) {
        let folder = folder.standardizedFileURL
        let folderPath = WorktreeFileOperations.path(folder)
        let rootChanged = root?.path != folderPath
        if rootChanged {
            for request in requests.values { request.cancel() }
            requests.removeAll()
            root = Item(folder, directory: true)
            expanded.removeAll()
            readHiddenItems()
            startMonitoring()
        }

        let file = currentFile?.standardizedFileURL
        let filePath = file.map(WorktreeFileOperations.path)
        guard rootChanged || currentPath != filePath else { return }
        currentPath = filePath
        currentDirectories = []
        if !rootChanged, let outside { expanded.remove(outside.path) }
        outside = nil
        // Loading a previous selection must not move the highlight back during rapid navigation.
        needsReveal = file != nil && openingFile == nil
        if let file, WorktreeFileOperations.contains(file, in: folder) {
            var ancestor = file.deletingLastPathComponent()
            while WorktreeFileOperations.contains(ancestor, in: folder) {
                let ancestorPath = WorktreeFileOperations.path(ancestor)
                currentDirectories.insert(ancestorPath)
                if ancestorPath == folderPath { break }
                ancestor.deleteLastPathComponent()
            }
            expanded.formUnion(currentDirectories.subtracting([folderPath]))
        } else if let file {
            let parent = Item(file.deletingLastPathComponent(), directory: true, outside: true)
            parent.visibleChildren = [Item(file, directory: false, outside: true)]
            outside = parent
            expanded.insert(parent.path)
        }
        reloadTree()
    }

    func setShowsHidden(_ enabled: Bool) {
        guard showsHidden != enabled else { return }
        showsHidden = enabled
        reloadTree()
    }

    func refresh() {
        guard let root else { return }
        for item in expandedDirectories(from: root) { load(item, force: true) }
    }

    private func startMonitoring() {
        monitor = nil
        guard isActive, let root else { return }
        monitor = WorktreeMonitor(directory: root.url) { [weak self] paths, reload in
            guard let self, let root = self.root else { return }
            if reload {
                refresh()
            } else {
                for item in expandedDirectories(from: root) where paths.contains(item.path) {
                    load(item, force: true)
                }
            }
        }
    }

    private func expandedDirectories(from item: Item) -> [Item] {
        var pending = [item]
        var directories: [Item] = []
        while let next = pending.popLast() {
            guard next === root || tree.isItemExpanded(next) else { continue }
            directories.append(next)
            pending.append(contentsOf: next.visibleChildren.filter(\.isDirectory))
        }
        return directories
    }

    private func load(_ item: Item, force: Bool = false) {
        guard let root, !item.outside, item.isDirectory else { return }
        let path = item.path
        if force { requests[path]?.cancel() }
        else if item.isLoaded || requests[path] != nil { return }
        let directoryURL = item.url
        let rootURL = root.url
        requests[path] = Task { [weak self, weak item] in
            let work = Task.detached(priority: .userInitiated) {
                Result { try WorktreeDirectory.read(directoryURL, within: rootURL) }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            requests.removeValue(forKey: path)
            guard let item else { return }
            item.isLoaded = true
            switch result {
            case .success(let entries):
                apply(entries, to: item)
            case .failure:
                // A previously loaded directory can disappear before its parent's event arrives.
                apply([], to: item)
            }
        }
    }

    private func apply(_ entries: [WorktreeDirectory.Entry], to item: Item) {
        let previous = Dictionary(uniqueKeysWithValues: item.children.map { ($0.path, $0) })
        item.children = entries.map { entry in
            let child: Item
            if let existing = previous[WorktreeFileOperations.path(entry.url)], existing.isDirectory == entry.isDirectory {
                child = existing
            } else {
                child = Item(entry.url, directory: entry.isDirectory)
            }
            child.isIgnored = entry.isIgnored
            child.isSystemHidden = entry.isHidden
            return child
        }
        if item === root {
            reloadTree()
            return
        }
        updateVisibleChildren(of: item)
        guard tree.row(forItem: item) >= 0 else { return }
        let selection = selectedItems.map(\.path)
        reloading = true
        tree.reloadItem(item, reloadChildren: true)
        restoreExpansion(from: item)
        reloading = false
        restoreSelection(selection)
        revealCurrent()
    }

    private func updateVisibleChildren(of item: Item) {
        let parentHidden = item !== root && (item.hasHiddenParent || isHidden(item))
        item.visibleChildren = item.children.filter { child in
            child.hasHiddenParent = parentHidden
            return showsHidden || (!parentHidden && !isHidden(child))
                || child.path == currentPath || currentDirectories.contains(child.path)
        }
        // The CLI can open a new path before the file exists on disk.
        if let currentPath, item.isLoaded, currentDirectories.contains(item.path),
           URL(filePath: currentPath).deletingLastPathComponent().path == item.path,
           !item.visibleChildren.contains(where: { $0.path == currentPath }) {
            item.visibleChildren.append(Item(URL(filePath: currentPath), directory: false))
        }
    }

    private func reloadTree() {
        let selection = selectedItems.map(\.path)
        if let root {
            var pending = [root]
            while let item = pending.popLast() {
                updateVisibleChildren(of: item)
                pending.append(contentsOf: item.children.filter(\.isDirectory))
            }
        }

        reloading = true
        tree.reloadData()
        if let root {
            load(root)
            for item in root.visibleChildren { restoreExpansion(from: item) }
        }
        if let outside { restoreExpansion(from: outside) }
        reloading = false
        restoreSelection(selection)
        revealCurrent()
    }

    private func restoreExpansion(from item: Item) {
        guard item.isDirectory, expanded.contains(item.path) else { return }
        tree.expandItem(item)
        load(item)
        for child in item.visibleChildren where child.isDirectory {
            restoreExpansion(from: child)
        }
    }

    private func restoreSelection(_ paths: [String]) {
        let rows = IndexSet(paths.compactMap { path in
            guard let item = item(at: path) else { return nil }
            let row = tree.row(forItem: item)
            return row >= 0 ? row : nil
        })
        tree.selectRowIndexes(rows, byExtendingSelection: false)
    }

    private func revealCurrent() {
        guard needsReveal, let currentPath, let item = item(at: currentPath) else { return }
        let row = tree.row(forItem: item)
        guard row >= 0 else { return }
        needsReveal = false
        tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tree.scrollRowToVisible(row)
    }

    private func item(at path: String) -> Item? {
        if let file = outside?.visibleChildren.first, file.path == path { return file }
        if let outside, outside.path == path { return outside }
        guard var item = root else { return nil }
        while item.path != path {
            let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
            guard path.hasPrefix(prefix) else { return nil }
            let next = path.dropFirst(prefix.count).prefix { $0 != "/" }
            guard let child = item.visibleChildren.first(where: { $0.path == prefix + next }) else { return nil }
            item = child
        }
        return item
    }

    private func readHiddenItems() {
        guard !app.isAgentCheck, let root else {
            manualHidden = []
            return
        }
        manualHidden = Set(UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey)?[root.path] as? [String] ?? [])
    }

    private func toggleHidden(_ url: URL) {
        guard let root else { return }
        if !app.isAgentCheck { readHiddenItems() }
        let path = WorktreeFileOperations.path(url)
        if manualHidden.remove(path) == nil { manualHidden.insert(path) }
        if !app.isAgentCheck {
            var folders = UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey) ?? [:]
            folders[root.path] = manualHidden.isEmpty ? nil : manualHidden.sorted()
            UserDefaults.standard.set(folders, forKey: Self.hiddenItemsKey)
            NotificationCenter.default.post(name: Self.hiddenItemsChanged, object: nil, userInfo: ["root": root.path])
        }
        reloadTree()
    }

    @objc private func hiddenItemsChanged(_ notification: Notification) {
        guard let root, notification.userInfo?["root"] as? String == root.path else { return }
        let previous = manualHidden
        readHiddenItems()
        if previous != manualHidden { reloadTree() }
    }

    private func isHidden(_ item: Item) -> Bool { item.isSystemHidden || manualHidden.contains(item.path) }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let item = item as? Item { return item.visibleChildren.count }
        return (root?.visibleChildren.count ?? 0) + (outside == nil ? 0 : 1)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? Item { return item.visibleChildren[index] }
        let entries = root?.visibleChildren ?? []
        if let outside, index == entries.count { return outside }
        return entries[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.isDirectory == true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
        expanded.insert(item.path)
        load(item, force: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
        expanded.remove(item.path)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView.makeView(withIdentifier: WorktreeRow.reuseIdentifier, owner: nil) as? WorktreeRow
            ?? WorktreeRow()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item object: Any) -> NSView? {
        guard let item = object as? Item else { return nil }
        let cell = outlineView.makeView(withIdentifier: WorktreeCell.identifier, owner: self) as? WorktreeCell
            ?? WorktreeCell()
        let muted = item.isIgnored || isHidden(item)
        let icon = item.isDirectory
            ? nil
            : FileIcons.image(for: item.url, appearance: outlineView.effectiveAppearance,
                              language: app.syntaxOverrides.language(for: item.url)?.iconIdentifier)
        cell.configure(name: item.name, path: item.path, icon: icon, muted: muted)
        return cell
    }

    private var selectedItems: [Item] { tree.selectedRowIndexes.compactMap { tree.item(atRow: $0) as? Item } }

    func openFile(at row: Int) {
        guard let item = tree.item(atRow: row) as? Item, !item.isDirectory else { return }
        pendingOpen = item.url
        guard openingFile == nil else { return }
        openingFile = Task { [weak self, app, document] in
            defer { self?.openingFile = nil }
            while let self, let url = self.pendingOpen {
                self.pendingOpen = nil
                await app.openFiles([url], in: document, focusEditor: false)
            }
        }
    }

    @objc private func activateClickedDirectory(_ sender: NSOutlineView) {
        guard tree.isPlainPrimaryClick, sender.clickedRow >= 0,
              let item = tree.item(atRow: sender.clickedRow) as? Item, item.isDirectory else { return }
        if tree.isItemExpanded(item) { tree.collapseItem(item) }
        else { tree.expandItem(item) }
    }

    func renameSelection() {
        guard let root, tree.selectedRowIndexes.count == 1, let item = selectedItems.first else { return }
        actions.rename(item.url, within: root.url)
    }

    func focusEditor() {
        guard let openingFile else {
            document.window.makeFirstResponder(document.editor)
            return
        }
        Task { [weak self] in
            await openingFile.value
            guard let self, document.window.firstResponder === tree else { return }
            document.window.makeFirstResponder(document.editor)
        }
    }

    func addRootCreationItems(to menu: NSMenu) {
        guard let folder = document.folderURL else { return }
        actions.addCreationItems(to: menu, in: folder, root: folder)
    }

    func menu(at row: Int) -> NSMenu? {
        guard let root else { return nil }
        let item = (row >= 0 ? tree.item(atRow: row) as? Item : nil) ?? root
        if row >= 0, !tree.selectedRowIndexes.contains(row) {
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return actions.menu(for: item.url, isDirectory: item.isDirectory, root: root.url)
    }

    func copySelection() {
        let urls = selectedItems.filter { !$0.isDirectory || !$0.outside }.map(\.url)
        if !urls.isEmpty { actions.copy(urls) }
    }

    func pasteIntoSelection() {
        guard let root, let directory = destination(for: selectedItems.first) else { return }
        _ = actions.paste(into: directory, within: root.url)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        tree.didStartDrag = true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem object: Any) -> (any NSPasteboardWriting)? {
        guard let item = object as? Item, !item.outside || !item.isDirectory else { return nil }
        return item.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let target = item as? Item
        let operation = dropOperation(info, onto: target)
        guard !operation.isEmpty else { return [] }
        let directory = target.flatMap { $0.isDirectory ? $0 : itemAtParent(of: $0) }
        outlineView.setDropItem(directory === root ? nil : directory, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex: Int) -> Bool {
        let target = item as? Item
        let operation = dropOperation(info, onto: target)
        guard operation != [], let root, let directory = destination(for: target) else { return false }
        return actions.transfer(WorktreeActions.fileURLs(on: info.draggingPasteboard), into: directory,
                                move: operation == .move, within: root.url)
    }

    private func dropOperation(_ info: any NSDraggingInfo, onto target: Item?) -> NSDragOperation {
        guard let directory = destination(for: target) else { return [] }
        let urls = WorktreeActions.fileURLs(on: info.draggingPasteboard)
        let wantsCopy = NSEvent.modifierFlags.contains(.option)
        let operation: NSDragOperation = info.draggingSource is WorktreeOutline && !wantsCopy ? .move : .copy
        guard info.draggingSourceOperationMask.contains(operation), !urls.isEmpty,
              urls.allSatisfy({ !WorktreeFileOperations.contains(directory, in: $0) && $0.deletingLastPathComponent().path != directory.path })
        else { return [] }
        return operation
    }

    private func destination(for item: Item?) -> URL? {
        guard let item else { return root?.url }
        guard !item.outside else { return nil }
        return item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    private func itemAtParent(of item: Item) -> Item? { self.item(at: item.url.deletingLastPathComponent().path) }
}

@MainActor
private final class WorktreeOutline: NSOutlineView {
    weak var owner: WorktreeSidebar?
    private(set) var isPlainPrimaryClick = false
    var didStartDrag = false

    override func mouseDown(with event: NSEvent) {
        isPlainPrimaryClick = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        didStartDrag = false
        defer { isPlainPrimaryClick = false }
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)

        // A table's action can skip already selected rows. Use the release from its native tracking.
        guard isPlainPrimaryClick, !didStartDrag, clicked >= 0, event.clickCount == 1,
              let release = NSApp.currentEvent, release.type == .leftMouseUp,
              release.window === window, release.timestamp >= event.timestamp,
              row(at: convert(release.locationInWindow, from: nil)) == clicked else { return }
        owner?.openFile(at: clicked)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        return NSRect(x: frame.maxX - WorktreeCell.iconSize, y: frame.minY,
                      width: WorktreeCell.iconSize, height: frame.height)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard let outlineTableColumn, column == self.column(withIdentifier: outlineTableColumn.identifier),
              row >= 0, let item = item(atRow: row), !isExpandable(item) else { return frame }
        // Files put their icon in the same gutter AppKit reserves for folder disclosure.
        return NSRect(x: frame.minX - WorktreeCell.iconSize, y: frame.minY,
                      width: frame.width + WorktreeCell.iconSize, height: frame.height)
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard identifier == NSOutlineView.disclosureButtonIdentifier ||
              identifier == NSOutlineView.showHideButtonIdentifier else {
            return super.makeView(withIdentifier: identifier, owner: owner)
        }
        if let reused = super.makeView(withIdentifier: identifier, owner: owner) { return reused }
        let configuration = NSImage.SymbolConfiguration(pointSize: WorktreeCell.iconSize, weight: .medium)
        let button = NSButton()
        button.identifier = identifier
        button.setButtonType(.onOff)
        button.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = #selector(toggleDirectory(_:))
        return button
    }

    @objc private func toggleDirectory(_ sender: NSButton) {
        let row = row(for: sender)
        guard row >= 0, let item = item(atRow: row) else { return }
        if isItemExpanded(item) { collapseItem(item) }
        else { expandItem(item) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76:
            if !event.isARepeat { owner?.renameSelection() }
        case 49:
            owner?.focusEditor()
        case 125, 126:
            let before = selectedRowIndexes
            super.keyDown(with: event)
            if selectedRowIndexes != before && selectedRowIndexes.count == 1 {
                owner?.openFile(at: selectedRow)
            }
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { owner?.copySelection() }
    @objc func paste(_ sender: Any?) { owner?.pasteIntoSelection() }
}

@MainActor
private final class WorktreeRow: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WorktreeRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) { fatalError("Worktree rows are programmatically constructed") }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        let highlight = bounds.insetBy(dx: 6, dy: 0)
        NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // AppKit can attach its disclosure button after adding the row to the outline.
        guard let button = subview as? NSButton,
              button.identifier == NSOutlineView.disclosureButtonIdentifier ||
              button.identifier == NSOutlineView.showHideButtonIdentifier else { return }
        button.contentTintColor = .secondaryLabelColor
    }
}

@MainActor
private final class WorktreeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WorktreeEntry")
    static let iconSize: CGFloat = 15
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private lazy var labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            labelLeading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Worktree cells are programmatically constructed") }

    func configure(name: String, path: String, icon image: NSImage?, muted: Bool) {
        label.stringValue = name
        labelLeading.constant = image == nil ? 6 : Self.iconSize + 6
        icon.isHidden = image == nil
        label.textColor = muted ? .secondaryLabelColor : .labelColor
        if muted, let image, !image.isTemplate, let template = image.copy() as? NSImage {
            template.isTemplate = true
            icon.image = template
        } else {
            icon.image = image
        }
        icon.contentTintColor = muted ? .secondaryLabelColor : .labelColor
        toolTip = path
    }
}

@MainActor
private final class WorktreeMonitor {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor (Set<String>, Bool) -> Void

    init(directory: URL, changed: @escaping @MainActor (Set<String>, Bool) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorktreeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemInodeMetaMod)
            let overflow = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            var changedPaths = Set<String>()
            var reload = false
            for index in 0..<min(count, paths.count) {
                let path = paths[index]
                if flags[index] & overflow != 0 || (path as NSString).lastPathComponent == ".gitignore" {
                    reload = true
                    break
                }
                if flags[index] & structural != 0 {
                    let parent = (path as NSString).deletingLastPathComponent
                    changedPaths.insert(URL(filePath: parent, directoryHint: .isDirectory).standardizedFileURL.path)
                }
            }
            guard reload || !changedPaths.isEmpty else { return }
            MainActor.assumeIsolated { monitor.changed(changedPaths, reload) }
        }, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
        FSEventStreamCreateFlags(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
