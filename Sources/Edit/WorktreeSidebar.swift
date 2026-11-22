import AppKit
import CoreServices

@MainActor
final class WorktreeSidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
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
        var expandWithAnimationWhenLoaded = false

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

    @MainActor
    private final class NameEdit {
        let request: WorktreeActions.NameRequest
        let root: URL
        let entry: Item
        let draftParent: Item?
        let selection: [String]
        let field = NSTextField()
        var submitting = false
        var error: NSPopover?

        init(request: WorktreeActions.NameRequest, root: URL, entry: Item, draftParent: Item?, selection: [String]) {
            self.request = request
            self.root = root
            self.entry = entry
            self.draftParent = draftParent
            self.selection = selection
        }
    }

    private static let hiddenItemsKey = "WorktreeHiddenItems"
    private static let hiddenItemsChanged = Notification.Name("Edit.WorktreeHiddenItemsChanged")
    private let container = NSView()
    private let scroll = WorktreeScrollView()
    private let tree = WorktreeOutline()
    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private var root: Item?
    private var outside: Item?
    private var currentPath: String?
    private var currentDirectories: Set<String> = []
    private var pathToReveal: String?
    private var restoredSelection: [String] = []
    private var selectionRevision: UInt64 = 0
    private var restoringSelection = false
    private var manualHidden: Set<String> = []
    private var expanded: Set<String> = []
    private var requests: [String: Task<Void, Never>] = [:]
    private var isActive = false
    private var monitor: WorktreeMonitor?
    private var reloading = false
    private var pendingOpen: URL?
    private var openingFile: Task<Void, Never>?
    private var nameEdit: NameEdit?

    private lazy var actions = WorktreeActions(
        document: document, app: app,
        refresh: { [weak self] in self?.refresh() },
        isHidden: { [weak self] in self?.manualHidden.contains(WorktreeFileOperations.path($0)) ?? false },
        toggleHidden: { [weak self] in self?.toggleHidden($0) },
        editName: { [weak self] in self?.beginNameEdit($0, in: $1) }
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
        // Keep regular-weight selections and start the outline at the top of the clip view.
        tree.style = .fullWidth
        tree.indentationPerLevel = 12
        // Keep the column fitted to the sidebar as new indentation levels appear.
        tree.autoresizesOutlineColumn = false
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
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
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
        if !active {
            restoredSelection.removeAll()
            selectionRevision &+= 1
            pendingOpen = nil
            if let nameEdit { finishNameEdit(nameEdit) }
        }
        startMonitoring()
        if active {
            pathToReveal = currentPath
            revealPendingItem()
            if root?.isLoaded == true { refresh() }
        }
    }

    func update(folder: URL, currentFile: URL?, revealCurrentFile: Bool = true) {
        let folder = folder.standardizedFileURL
        let folderPath = WorktreeFileOperations.path(folder)
        let rootChanged = root?.path != folderPath
        if rootChanged {
            restoredSelection.removeAll()
            selectionRevision &+= 1
            if let nameEdit { finishNameEdit(nameEdit) }
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
        pathToReveal = revealCurrentFile && openingFile == nil ? filePath : nil
        if let file, WorktreeFileOperations.contains(file, in: folder) {
            currentDirectories = ancestors(of: file, in: folder)
            expanded.formUnion(currentDirectories.subtracting([folderPath]))
        } else if let file {
            let parent = Item(file.deletingLastPathComponent(), directory: true, outside: true)
            parent.visibleChildren = [Item(file, directory: false, outside: true)]
            outside = parent
            expanded.insert(parent.path)
        }
        reloadTree()
    }

    private func ancestors(of url: URL, in folder: URL) -> Set<String> {
        let rootPath = WorktreeFileOperations.path(folder)
        var paths: Set<String> = []
        var ancestor = url.deletingLastPathComponent()
        while WorktreeFileOperations.contains(ancestor, in: folder) {
            let path = WorktreeFileOperations.path(ancestor)
            paths.insert(path)
            if path == rootPath { break }
            ancestor.deleteLastPathComponent()
        }
        return paths
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
        guard let root, !item.outside, item.isDirectory, item !== provisionalEntry else { return }
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
        let shouldAnimateExpansion = item.expandWithAnimationWhenLoaded
        let firstLoad = !item.isLoaded && item.visibleChildren.isEmpty
        item.expandWithAnimationWhenLoaded = false
        let changed = !item.isLoaded || entries.count != item.children.count || zip(entries, item.children).contains { entry, child in
            WorktreeFileOperations.path(entry.url) != child.path || entry.isDirectory != child.isDirectory ||
                entry.isIgnored != child.isIgnored || entry.isHidden != child.isSystemHidden
        }
        item.isLoaded = true
        // Reloading identical rows would interrupt the outline's expansion animation.
        guard changed || shouldAnimateExpansion else { return }
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
        // Keep the AppKit field editor attached to its row while filesystem updates arrive.
        guard nameEdit == nil else { return }
        if item === root {
            reloadTree()
            return
        }
        updateVisibleChildren(of: item)
        guard tree.row(forItem: item) >= 0 else { return }
        if shouldAnimateExpansion && isActive && !tree.isItemExpanded(item) {
            reloading = true
            tree.setFolderExpanded(item, expanded: true, animated: true)
            reloading = false
            if tree.isItemExpanded(item) { expanded.insert(item.path) }
            return
        }
        let selection = selectedItems.map(\.path)
        reloading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if firstLoad, tree.isItemExpanded(item) {
                // A keyboard expansion is already open while its first directory read is pending.
                tree.insertItems(at: IndexSet(integersIn: 0..<item.visibleChildren.count),
                                 inParent: item, withAnimation: [])
            } else {
                tree.reloadItem(item, reloadChildren: true)
            }
            restoreExpansion(from: item)
        }
        reloading = false
        restoreSelection(selection)
        revealPendingItem()
        reselectRestoredItems()
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

    private func reloadTree(keeping paths: [String]? = nil) {
        guard nameEdit == nil else { return }
        let selection = paths ?? selectedItems.map(\.path)
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
        revealPendingItem()
        reselectRestoredItems()
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
        selectRows(visibleRows(for: paths))
    }

    private func visibleRows(for paths: [String]) -> IndexSet {
        IndexSet(paths.compactMap { path in
            guard let item = item(at: path) else { return nil }
            let row = tree.row(forItem: item)
            return row >= 0 ? row : nil
        })
    }

    private func selectRows(_ rows: IndexSet) {
        restoringSelection = true
        defer { restoringSelection = false }
        tree.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, !restoringSelection else { return }
        selectionRevision &+= 1
        restoredSelection.removeAll()
    }

    private func reselectRestoredItems() {
        guard !restoredSelection.isEmpty else { return }
        guard document.window.firstResponder === tree, nameEdit == nil else {
            restoredSelection.removeAll()
            return
        }
        let rows = visibleRows(for: restoredSelection)
        guard let first = rows.first else { return }
        let firstChanged = tree.selectedRowIndexes.first != first
        selectRows(rows)
        if firstChanged { tree.scrollRowToVisible(first) }
        if rows.count == restoredSelection.count { restoredSelection.removeAll() }
    }

    private func revealPendingItem() {
        guard nameEdit == nil, let pathToReveal, let item = item(at: pathToReveal) else { return }
        let row = tree.row(forItem: item)
        guard row >= 0 else { return }
        self.pathToReveal = nil
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

    private var provisionalEntry: Item? { nameEdit?.draftParent == nil ? nil : nameEdit?.entry }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let parent = (item as? Item) ?? root
        let draftCount = parent != nil && nameEdit?.draftParent === parent ? 1 : 0
        let outsideCount = item == nil && outside != nil ? 1 : 0
        return (parent?.visibleChildren.count ?? 0) + draftCount + outsideCount
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parent = (item as? Item) ?? root
        let entries = parent?.visibleChildren ?? []
        if index < entries.count { return entries[index] }
        if let nameEdit, let draftParent = nameEdit.draftParent, draftParent === parent, index == entries.count {
            return nameEdit.entry
        }
        if let outside, item == nil { return outside }
        return entries[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        (item as? Item) !== provisionalEntry
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
        expanded.insert(item.path)
        load(item, force: item.isLoaded)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
        expanded.remove(item.path)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView.makeView(withIdentifier: WorktreeRow.reuseIdentifier, owner: nil) as? WorktreeRow
            ?? WorktreeRow(outline: tree)
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
        guard let item = tree.item(atRow: row) as? Item, !item.isDirectory, item !== provisionalEntry else { return }
        pathToReveal = nil
        pendingOpen = item.url
        guard openingFile == nil else { return }
        openingFile = Task { [weak self, app, document] in
            defer { self?.openingFile = nil }
            while let self, let url = self.pendingOpen {
                self.pendingOpen = nil
                await app.openFiles([url], in: document, focusEditor: false) {
                    self.pendingOpen == nil || self.pendingOpen == url
                }
            }
        }
    }

    @objc private func activateClickedDirectory(_ sender: NSOutlineView) {
        guard tree.isPlainPrimaryClick else { return }
        toggleFolder(at: sender.clickedRow, animated: true)
    }

    func activateSelection() {
        if let item = tree.item(atRow: tree.selectedRow) as? Item, item.isDirectory {
            toggleFolder(at: tree.selectedRow, animated: false)
        } else {
            focusEditor()
        }
    }

    func toggleFolder(at row: Int, animated: Bool) {
        guard row >= 0, let item = tree.item(atRow: row) as? Item,
              item.isDirectory, item !== provisionalEntry else { return }
        if item.expandWithAnimationWhenLoaded {
            item.expandWithAnimationWhenLoaded = false
            return
        }
        let expand = !tree.isItemExpanded(item)
        if animated && expand && !item.isLoaded && !item.outside {
            item.expandWithAnimationWhenLoaded = true
            load(item)
            return
        }
        tree.setFolderExpanded(item, expanded: expand, animated: animated)
    }

    func navigateFolders(expanding: Bool) -> Bool {
        let selection = selectedItems
        let folders = selection.filter { $0.isDirectory && $0 !== provisionalEntry }
        guard !folders.isEmpty else { return false }

        let cancelledMouseExpansion = folders.contains(where: \.expandWithAnimationWhenLoaded)
        for folder in folders { folder.expandWithAnimationWhenLoaded = false }
        let changed = folders.filter { tree.isItemExpanded($0) != expanding }
        guard !changed.isEmpty else { return cancelledMouseExpansion || selection.count > 1 }

        let closingPaths = Set(expanding ? [] : changed.map(\.path))
        for folder in changed {
            // Collapsing a parent leaves the expansion state of its hidden children intact.
            if !expanding,
               WorktreeFileOperations.isUnderSelection(folder.url.deletingLastPathComponent(), paths: closingPaths) {
                continue
            }
            tree.setFolderExpanded(folder, expanded: expanding, animated: false)
        }
        if selection.count > 1 { restoreSelection(selection.map(\.path)) }
        return true
    }

    func renameSelection() {
        guard let root, tree.selectedRowIndexes.count == 1, let item = selectedItems.first else { return }
        beginNameEdit(.rename(item.url), in: root.url)
    }

    private func beginNameEdit(_ request: WorktreeActions.NameRequest, in openedFolder: URL) {
        guard isActive, let root, actions.canEditName(in: openedFolder), nameEdit?.submitting != true else { return }
        if let nameEdit { finishNameEdit(nameEdit) }
        let entry: Item
        let draftParent: Item?
        switch request {
        case .rename(let url):
            guard let item = item(at: WorktreeFileOperations.path(url)), item !== root, !item.outside else { return }
            entry = item
            draftParent = nil
        case .create(let directory, let isDirectory):
            guard let parent = item(at: WorktreeFileOperations.path(directory)), !parent.outside else { return }
            if parent !== root { tree.expandItem(parent) }
            let base = isDirectory ? "untitled folder" : "untitled"
            let occupied = Set(parent.children.map { $0.name.lowercased() })
            var initial = base
            var suffix = 2
            while occupied.contains(initial) {
                initial = "\(base) \(suffix)"
                suffix += 1
            }
            entry = Item(parent.url.appending(path: initial), directory: isDirectory)
            draftParent = parent
        }

        let edit = NameEdit(request: request, root: openedFolder, entry: entry, draftParent: draftParent,
                            selection: selectedItems.map(\.path))
        nameEdit = edit
        pathToReveal = nil
        if let draftParent {
            tree.insertItems(at: IndexSet(integer: draftParent.visibleChildren.count),
                             inParent: draftParent === root ? nil : draftParent, withAnimation: [])
        }
        let row = tree.row(forItem: entry)
        guard row >= 0 else { finishNameEdit(edit); return }
        tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tree.scrollRowToVisible(row)
        guard let cell = tree.view(atColumn: 0, row: row, makeIfNecessary: true) as? WorktreeCell else {
            finishNameEdit(edit)
            return
        }
        let field = edit.field
        field.stringValue = entry.name
        field.delegate = self
        field.setAccessibilityLabel(entry.isDirectory ? "Folder Name" : "File Name")
        cell.installNameField(field)
        guard document.window.makeFirstResponder(field), let editor = field.currentEditor() else {
            finishNameEdit(edit)
            return
        }
        let name = entry.name as NSString
        let stem = name.deletingPathExtension as NSString
        let length = draftParent == nil && !entry.isDirectory && stem.length > 0 ? stem.length : name.length
        editor.selectedRange = NSRange(location: 0, length: length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let edit = nameEdit, edit.field === control, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submitName(edit, from: textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !edit.submitting { finishNameEdit(edit) }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let edit = nameEdit, edit.field === notification.object as? NSTextField else { return }
        // Let AppKit finish the focus change before removing the edited row.
        Task { [weak self, weak edit] in
            guard let self, let edit, !edit.submitting, edit.field.currentEditor() == nil else { return }
            let selection = self.selectedItems.filter { $0 !== self.provisionalEntry }.map(\.path)
            self.finishNameEdit(edit, keeping: selection.isEmpty ? edit.selection : selection)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        nameEdit?.error?.close()
        nameEdit?.error = nil
        nameEdit?.field.toolTip = nil
    }

    private func submitName(_ edit: NameEdit, from editor: NSTextView) {
        guard !edit.submitting else { return }
        let name = editor.string
        if edit.draftParent == nil && name == edit.entry.name {
            finishNameEdit(edit)
            return
        }
        edit.submitting = true
        editor.isEditable = false
        Task { [weak self, document] in
            guard let self else { return }
            do {
                let url = try await actions.commitName(name, for: edit.request, in: edit.root)
                guard nameEdit === edit else { return }
                let path = WorktreeFileOperations.path(url)
                if case .rename(let source) = edit.request {
                    retargetExpansion(from: source, to: url)
                }
                expanded.formUnion(ancestors(of: url, in: edit.root).subtracting([WorktreeFileOperations.path(edit.root)]))
                pathToReveal = path
                let stillEditing = document.window.firstResponder === editor
                finishNameEdit(edit)
                if case .create(_, false) = edit.request, stillEditing {
                    await app.openFiles([url], in: document)
                }
            } catch {
                guard nameEdit === edit else { return }
                edit.submitting = false
                guard document.window.firstResponder === editor else { finishNameEdit(edit); return }
                editor.isEditable = true
                showNameError(error, in: edit)
            }
        }
    }

    private func showNameError(_ error: Error, in edit: NameEdit) {
        let message = error.localizedDescription
        edit.field.toolTip = message
        guard document.window.isVisible, !app.isAgentCheck else { return }
        let label = NSTextField(wrappingLabelWithString: message)
        label.preferredMaxLayoutWidth = 240
        let size = label.fittingSize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 20, height: size.height + 16))
        label.frame = NSRect(origin: NSPoint(x: 10, y: 8), size: size)
        view.addSubview(label)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        edit.error?.close()
        edit.error = popover
        popover.show(relativeTo: edit.field.bounds, of: edit.field, preferredEdge: .maxY)
    }

    private func finishNameEdit(_ edit: NameEdit, keeping selection: [String]? = nil) {
        guard nameEdit === edit else { return }
        nameEdit = nil
        edit.error?.close()
        edit.field.delegate = nil
        if let editor = edit.field.currentEditor(), document.window.firstResponder === editor {
            editor.isEditable = true
            document.window.makeFirstResponder(tree)
        }
        edit.field.removeFromSuperview()
        reloadTree(keeping: selection ?? edit.selection)
    }

    private func focusEditor() {
        guard let openingFile else {
            document.focusContent()
            return
        }
        Task { [weak self] in
            await openingFile.value
            guard let self, document.window.firstResponder === tree else { return }
            document.focusContent()
        }
    }

    func addRootCreationItems(to menu: NSMenu) {
        guard let folder = document.folderURL else { return }
        actions.addCreationItems(to: menu, in: folder, root: folder)
    }

    func menu(at row: Int) -> NSMenu? {
        guard let root else { return nil }
        let item = (row >= 0 ? tree.item(atRow: row) as? Item : nil) ?? root
        guard item !== provisionalEntry else { return nil }
        if row >= 0, !tree.selectedRowIndexes.contains(row) {
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let urls = row >= 0 ? selectedItems.filter { $0 !== provisionalEntry }.map(\.url) : []
        let folder = root.url
        return actions.menu(for: item.url, isDirectory: item.isDirectory, selection: urls, root: folder) { [weak self] in
            guard let self, actions.canTrash(urls, in: folder) else { return }
            document.window.makeFirstResponder(tree)
            actions.trash(urls, within: folder, updateSelection: fileSelectionUpdate(in: folder))
        }
    }

    func trashSelection() {
        guard let root, nameEdit == nil else { return }
        let items = selectedItems.map(\.url)
        guard actions.canTrash(items, in: root.url) else { return }
        actions.trash(items, within: root.url, updateSelection: fileSelectionUpdate(in: root.url))
    }

    func undoActionName(redo: Bool) -> String? {
        guard let root else { return nil }
        return actions.undoActionName(in: root.url, redo: redo)
    }

    func undoFileChange(redo: Bool) {
        guard let root, nameEdit == nil else { return }
        actions.undo(in: root.url, redo: redo, updateSelection: fileSelectionUpdate(in: root.url))
    }

    private func fileSelectionUpdate(in folder: URL) -> (WorktreeActions.SelectionChange) -> Void {
        let revision = selectionRevision
        let folderPath = WorktreeFileOperations.path(folder)
        let selection = selectedItems.map(\.url)
        let anchor = tree.selectedRowIndexes.first
        var neighbors: [URL] = []
        if let anchor {
            let paths = Set(selection.map(WorktreeFileOperations.path))
            func nearbyItem(in rows: some Sequence<Int>) -> URL? {
                rows.lazy.compactMap { (self.tree.item(atRow: $0) as? Item)?.url }
                    .first { !WorktreeFileOperations.isUnderSelection($0, paths: paths) }
            }
            if let next = nearbyItem(in: (anchor + 1)..<tree.numberOfRows) { neighbors.append(next) }
            if let previous = nearbyItem(in: (0..<anchor).reversed()) { neighbors.append(previous) }
        }
        return { [weak self] change in
            guard let self, root?.path == folderPath else { return }
            if case .renamed(let move) = change {
                retargetExpansion(from: move.source, to: move.destination)
            }
            guard selectionRevision == revision,
                  document.window.firstResponder === tree, nameEdit == nil else { return }
            pathToReveal = nil
            switch change {
            case .removed(let removed):
                let removedPaths = Set(removed.map(WorktreeFileOperations.path))
                func wasRemoved(_ item: URL) -> Bool {
                    WorktreeFileOperations.isUnderSelection(item, paths: removedPaths)
                }
                guard selection.contains(where: wasRemoved) else { return }
                let surviving = selection.filter { !wasRemoved($0) }
                var rows = visibleRows(for: surviving.map(WorktreeFileOperations.path))
                if rows.isEmpty {
                    let nearby = neighbors.filter { !wasRemoved($0) }.map(WorktreeFileOperations.path)
                    for path in nearby {
                        rows = visibleRows(for: [path])
                        if !rows.isEmpty { break }
                    }
                }
                selectRows(rows)
                if let first = rows.first { tree.scrollRowToVisible(first) }
            case .restored(let items):
                revealSelection(items, in: folder)
            case .renamed(let move):
                revealSelection([move.destination], in: folder)
            }
        }
    }

    private func revealSelection(_ items: [URL], in folder: URL) {
        restoredSelection = items.map(WorktreeFileOperations.path)
        let rootPath = WorktreeFileOperations.path(folder)
        for item in items { expanded.formUnion(ancestors(of: item, in: folder).subtracting([rootPath])) }
        reloadTree()
    }

    private func retargetExpansion(from source: URL, to destination: URL) {
        let sourcePath = WorktreeFileOperations.path(source)
        let destinationPath = WorktreeFileOperations.path(destination)
        guard sourcePath != destinationPath else { return }
        let prefix = sourcePath + "/"
        expanded = Set(expanded.map { path in
            if path == sourcePath { return destinationPath }
            if path.hasPrefix(prefix) { return destinationPath + path.dropFirst(sourcePath.count) }
            return path
        })
    }

    func setRecycleForCheck(_ recycle: @escaping ([URL]) async throws -> WorktreeFileOperations.TransferResult) {
        actions.recycleForCheck = recycle
    }

    func copySelection() {
        let urls = selectedItems.filter { $0 !== provisionalEntry && (!$0.isDirectory || !$0.outside) }.map(\.url)
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
        guard let item = object as? Item, item !== provisionalEntry, !item.outside || !item.isDirectory else { return nil }
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
        guard !item.outside, item !== provisionalEntry else { return nil }
        return item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    private func itemAtParent(of item: Item) -> Item? { self.item(at: item.url.deletingLastPathComponent().path) }
}

private final class WorktreeScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self || hit === contentView, let documentView else { return hit }
        let clipPoint = contentView.convert(point, from: superview)
        guard contentView.bounds.contains(clipPoint), clipPoint.y >= documentView.frame.maxY else { return hit }
        // Treat the bottom inset as blank outline space for the root context menu.
        return documentView
    }
}

@MainActor
private final class WorktreeOutline: NSOutlineView, NSMenuItemValidation {
    private static let contentInset: CGFloat = 10

    private var disclosureActions: [NSUserInterfaceItemIdentifier: Selector] = [:]
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
        return NSRect(x: frame.maxX - WorktreeCell.iconSize + Self.contentInset, y: frame.minY,
                      width: WorktreeCell.iconSize, height: frame.height)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row).insetBy(dx: Self.contentInset, dy: 0)
        guard let outlineTableColumn, column == self.column(withIdentifier: outlineTableColumn.identifier),
              row >= 0, let item = item(atRow: row), !isExpandable(item) else { return frame }
        // Files put their icon in the same gutter AppKit reserves for folder disclosure.
        return NSRect(x: frame.minX - WorktreeCell.iconSize, y: frame.minY,
                      width: frame.width + WorktreeCell.iconSize, height: frame.height)
    }

    func installDisclosureAction(on button: NSButton) {
        let action = #selector(toggleDirectory(_:))
        // Remember AppKit's action even when the button is later reused by another row.
        if button.target === self, let identifier = button.identifier,
           let nativeAction = button.action, nativeAction != action {
            disclosureActions[identifier] = nativeAction
        }
        button.target = self
        button.action = action
    }

    @objc private func toggleDirectory(_ sender: NSButton) {
        let row = row(for: sender)
        guard row >= 0, let item = item(atRow: row) else { return }
        sender.state = isItemExpanded(item) ? .on : .off
        owner?.toggleFolder(at: row, animated: true)
    }

    func setFolderExpanded(_ item: Any, expanded: Bool, animated: Bool) {
        if animated {
            let row = row(forItem: item)
            if row >= 0,
               let view = rowView(atRow: row, makeIfNecessary: false) as? WorktreeRow,
               let button = view.disclosureButton, let identifier = button.identifier,
               let action = disclosureActions[identifier] {
                // The disclosure action slides and clips the child rows with the rest of the outline.
                button.state = expanded ? .on : .off
                if NSApp.sendAction(action, to: self, from: button) { return }
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if expanded { expandItem(item) }
            else { collapseItem(item) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 51 && modifiers == .command {
            if !event.isARepeat { owner?.trashSelection() }
            return
        }
        let unmodified = modifiers.isEmpty
        if event.keyCode == 123 || event.keyCode == 124 {
            let expanding = (event.keyCode == 124) != (userInterfaceLayoutDirection == .rightToLeft)
            if unmodified && owner?.navigateFolders(expanding: expanding) == true { return }
            // Keep the outline's native parent, child and modified-arrow navigation.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                super.keyDown(with: event)
            }
            return
        }
        guard unmodified else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76:
            if !event.isARepeat { owner?.renameSelection() }
        case 49:
            if !event.isARepeat { owner?.activateSelection() }
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

    @objc func undo(_ sender: Any?) { owner?.undoFileChange(redo: false) }
    @objc func redo(_ sender: Any?) { owner?.undoFileChange(redo: true) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return owner?.undoActionName(redo: false) != nil
        case #selector(redo(_:)): return owner?.undoActionName(redo: true) != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = owner?.undoActionName(redo: false).map { "Undo \($0)" } ?? "Undo"
        case #selector(redo(_:)):
            item.title = owner?.undoActionName(redo: true).map { "Redo \($0)" } ?? "Redo"
        default: break
        }
        return validateUserInterfaceItem(item)
    }

    @objc func copy(_ sender: Any?) { owner?.copySelection() }
    @objc func paste(_ sender: Any?) { owner?.pasteIntoSelection() }
}

@MainActor
private final class WorktreeRow: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("WorktreeRow")
    private static let normalChevrons = chevrons(color: .secondaryLabelColor)
    private static let selectedChevrons = chevrons(color: .alternateSelectedControlTextColor)

    private weak var outline: WorktreeOutline?
    private(set) weak var disclosureButton: NSButton?

    override var isSelected: Bool {
        didSet { updateDisclosureImages() }
    }

    override var isEmphasized: Bool {
        didSet { updateDisclosureImages() }
    }

    // AppKit updates these independently of the row's own selection.
    override var isPreviousRowSelected: Bool {
        didSet { if isSelected && isPreviousRowSelected != oldValue { needsDisplay = true } }
    }

    override var isNextRowSelected: Bool {
        didSet { if isSelected && isNextRowSelected != oldValue { needsDisplay = true } }
    }

    init(outline: WorktreeOutline) {
        self.outline = outline
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) { fatalError("Worktree rows are programmatically constructed") }

    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        let highlight = bounds.insetBy(dx: 6, dy: 0)
        let radius: CGFloat = 8
        let joinsMinY = isFlipped ? isPreviousRowSelected : isNextRowSelected
        let joinsMaxY = isFlipped ? isNextRowSelected : isPreviousRowSelected
        var shape = highlight
        if joinsMinY {
            shape.origin.y -= radius
            shape.size.height += radius
        }
        if joinsMaxY { shape.size.height += radius }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: highlight).addClip()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // AppKit can attach its disclosure button after adding the row to the outline.
        guard let button = subview as? NSButton,
              button.identifier == NSOutlineView.disclosureButtonIdentifier ||
              button.identifier == NSOutlineView.showHideButtonIdentifier else { return }
        disclosureButton = button
        outline?.installDisclosureAction(on: button)
        updateDisclosureImages()
    }

    private func updateDisclosureImages() {
        guard let disclosureButton else { return }
        let images = isSelected && isEmphasized ? Self.selectedChevrons : Self.normalChevrons
        disclosureButton.image = images.collapsed
        disclosureButton.alternateImage = images.expanded
    }

    private static func chevrons(color: NSColor) -> (collapsed: NSImage?, expanded: NSImage?) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        func image(_ symbol: String) -> NSImage? {
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return nil }
            // Draw the semantic color into the symbol's mask to avoid AppKit applying a second tint.
            return NSImage(size: glyph.size, flipped: false) { rect in
                glyph.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        return (image("chevron.forward"), image("chevron.down"))
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

    func installNameField(_ field: NSTextField) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.controlSize = .small
        field.font = label.font
        field.usesSingleLineMode = true
        label.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -4),
            field.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    func configure(name: String, path: String, icon image: NSImage?, muted: Bool) {
        label.isHidden = false
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
