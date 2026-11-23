import AppKit
import CoreServices

@MainActor
final class SidebarFileTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    enum Mode { case worktree, scratches }

    private enum RowID: Hashable {
        case file(String)
        case scratchRoot
        case scratchCategory(String?)
        case scratch(UUID)
        case draft(UUID)

        static func fileURL(_ url: URL) -> Self { .file(WorktreeFileOperations.path(url)) }

        var filePath: String? {
            if case .file(let path) = self { return path }
            return nil
        }
    }

    private final class Item: NSObject {
        let id: RowID
        let fileURL: URL?
        let isDirectory: Bool
        let outside: Bool
        var scratchFile: ScratchFile?
        var displayName: String?
        var isIgnored = false
        var isSystemHidden = false
        var hasHiddenParent = false
        var children: [Item] = []
        var visibleChildren: [Item] = []
        var isLoaded = false
        var expandWithAnimationWhenLoaded = false

        init(_ id: RowID, directory: Bool, fileURL: URL? = nil, outside: Bool = false) {
            self.id = id
            self.fileURL = fileURL
            self.isDirectory = directory
            self.outside = outside
        }

        convenience init(_ url: URL, directory: Bool, outside: Bool = false) {
            self.init(.fileURL(url), directory: directory, fileURL: url, outside: outside)
        }

        var scratchCategory: String? {
            if case .scratchCategory(let folder) = id { return folder }
            return nil
        }

        var name: String {
            if let scratchFile { return scratchFile.name }
            if let displayName { return displayName }
            guard let fileURL, let path = id.filePath else { return "" }
            if outside && isDirectory { return (path as NSString).abbreviatingWithTildeInPath }
            return fileURL.lastPathComponent.isEmpty ? path : fileURL.lastPathComponent
        }
    }

    private enum NameRequest {
        case worktree(WorktreeActions.NameRequest, root: URL)
        case scratch(file: ScratchFile?, category: String?)
    }

    private enum OpenTarget: Equatable {
        case file(URL)
        case scratch(UUID)
    }

    @MainActor
    private final class NameEdit {
        let request: NameRequest
        let entry: Item
        let draftParent: Item?
        let selection: [RowID]
        let field = NSTextField()
        var submitting = false
        var error: NSPopover?

        init(request: NameRequest, entry: Item, draftParent: Item?, selection: [RowID]) {
            self.request = request
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
    private let mode: Mode
    private var root: Item?
    private var outside: Item?
    private var currentRow: RowID?
    private var currentDirectories: Set<RowID> = []
    private var rowToReveal: RowID?
    private var restoredSelection: [RowID] = []
    private var selectionRevision: UInt64 = 0
    private var restoringSelection = false
    private var manualHidden: Set<String> = []
    private var expanded: Set<RowID> = []
    private var requests: [String: Task<Void, Never>] = [:]
    private var isActive = false
    private var monitor: WorktreeMonitor?
    private var reloading = false
    private var pendingOpen: (target: OpenTarget, focusSelectionRevision: UInt64?)?
    private var openingFile: Task<Void, Never>?
    private var nameEdit: NameEdit?
    private var scratchFiles: [ScratchFile] = []
    private var scratchProject: String?
    private var currentScratchID: UUID?
    private var pendingScratchFiles: [ScratchFile]?
    private var jjDecorations: JJWorktreeDecorations?

    private lazy var actions = WorktreeActions(
        document: document, app: app,
        refresh: { [weak self] in self?.refresh() },
        isHidden: { [weak self] in self?.manualHidden.contains(WorktreeFileOperations.path($0)) ?? false },
        toggleHidden: { [weak self] in self?.toggleHidden($0) },
        editName: { [weak self] in self?.beginNameEdit($0, in: $1) }
    )
    private lazy var scratchActions = ScratchWorktreeActions(document: document, app: app)

    var view: NSView { container }
    var outline: NSOutlineView { tree }
    var isObservingWorktree: Bool { mode == .worktree && isActive }
    private(set) var showsHidden = false

    init(document: DocumentWindow, app: Edit, mode: Mode) {
        self.document = document
        self.app = app
        self.mode = mode
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
        tree.setAccessibilityLabel(mode == .worktree ? "Worktree" : "Scratches")
        tree.dataSource = self
        tree.delegate = self
        tree.owner = self
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
        if mode == .worktree, !app.isAgentCheck {
            NotificationCenter.default.addObserver(self, selector: #selector(hiddenItemsChanged(_:)),
                                                   name: Self.hiddenItemsChanged, object: nil)
        }
        if mode == .scratches { updateScratches([], current: document.scratchFile?.id) }
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
        if mode == .worktree { document.updateJJContext() }
        if active {
            rowToReveal = currentRow
            if mode == .scratches, !currentDirectories.isSubset(of: expanded) {
                expanded.formUnion(currentDirectories)
                reloadTree()
            } else {
                revealPendingItem()
            }
            if root?.isLoaded == true { refresh() }
        }
    }

    func update(folder: URL, currentFile: URL?, revealCurrentFile: Bool = true) {
        let folder = folder.standardizedFileURL
        let rootID = RowID.fileURL(folder)
        let rootChanged = root?.id != rootID
        if rootChanged {
            restoredSelection.removeAll()
            pendingOpen = nil
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
        let fileID = file.map(RowID.fileURL)
        guard rootChanged || currentRow != fileID else { return }
        currentRow = fileID
        currentDirectories = []
        if !rootChanged, let outside { expanded.remove(outside.id) }
        outside = nil
        // Loading a previous selection must not move the highlight back during rapid navigation.
        rowToReveal = revealCurrentFile && openingFile == nil ? fileID : nil
        if let file, WorktreeFileOperations.contains(file, in: folder) {
            currentDirectories = ancestors(of: file, in: folder)
            expanded.formUnion(currentDirectories.subtracting([rootID]))
        } else if let file {
            let parent = Item(file.deletingLastPathComponent(), directory: true, outside: true)
            parent.visibleChildren = [Item(file, directory: false, outside: true)]
            outside = parent
            expanded.insert(parent.id)
        }
        reloadTree()
    }

    func updateScratches(_ files: [ScratchFile], current: UUID?) {
        guard mode == .scratches else { return }
        if nameEdit != nil {
            pendingScratchFiles = files
            return
        }
        let project = document.folderURL.map(WorktreeFileOperations.path)
        guard root == nil || files != scratchFiles || project != scratchProject else {
            updateScratchCurrent(current, reveal: true)
            return
        }
        installScratchFiles(files, current: current, preserving: selectedItems.map(\.id))
    }

    private func installScratchFiles(_ files: [ScratchFile], current: UUID?, preserving selection: [RowID]) {
        if root == nil {
            root = Item(.scratchRoot, directory: true)
            root?.isLoaded = true
        }
        guard let root else { return }
        let selected = Set(selection)
        let previous = Dictionary(uniqueKeysWithValues: root.children.map { ($0.id, $0) })
        let previousFiles = Dictionary(uniqueKeysWithValues: root.children.flatMap(\.children).map { ($0.id, $0) })
        scratchFiles = files
        scratchProject = document.folderURL.map(WorktreeFileOperations.path)
        var groups = Dictionary(grouping: files, by: \.folderPath)
        if let scratchProject, groups[scratchProject] == nil { groups[scratchProject] = [] }
        let folders = groups.keys.compactMap { $0 }.sorted {
            let comparison = Self.scratchFolderName($0).localizedStandardCompare(Self.scratchFolderName($1))
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        let categoryPaths: [String?] = [nil] + folders.map(Optional.some)
        let names = Dictionary(grouping: categoryPaths) { Self.scratchFolderName($0).lowercased() }
        var kept = selection.filter { previous[$0] != nil }
        root.children = categoryPaths.map { folderPath in
            let categoryID = RowID.scratchCategory(folderPath)
            let category = previous[categoryID] ?? Item(categoryID, directory: true)
            let name = Self.scratchFolderName(folderPath)
            if let folderPath, (names[name.lowercased()]?.count ?? 0) > 1 {
                let parent = (folderPath as NSString).deletingLastPathComponent as NSString
                category.displayName = "\(name) — \(parent.abbreviatingWithTildeInPath)"
            } else {
                category.displayName = name
            }
            category.isLoaded = true
            category.children = (groups[folderPath] ?? []).sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
            }.map { file in
                let id = RowID.scratch(file.id)
                let item = previousFiles[id] ?? Item(id, directory: false)
                if selected.contains(id) {
                    kept.append(id)
                    if item.scratchFile?.folderPath != file.folderPath { expanded.insert(categoryID) }
                }
                item.scratchFile = file
                return item
            }
            return category
        }
        setScratchCurrent(current, reveal: true)
        reloadTree(keeping: kept)
    }

    func updateScratchCurrent(_ id: UUID?, reveal: Bool) {
        guard mode == .scratches, currentScratchID != id else { return }
        // Refreshing an unchanged outline resets AppKit's selection anchor during click-to-open.
        setScratchCurrent(id, reveal: reveal)
        if reveal && openingFile == nil {
            revealActiveScratch()
        }
    }

    func revealCurrentScratch() {
        guard mode == .scratches, openingFile == nil, let currentRow else { return }
        rowToReveal = currentRow
        expanded.formUnion(currentDirectories)
        revealActiveScratch()
    }

    private func revealActiveScratch() {
        guard nameEdit == nil, let id = currentDirectories.first, let category = item(at: id) else { return }
        if !tree.isItemExpanded(category) { tree.setFolderExpanded(category, expanded: true, animated: false) }
        revealPendingItem()
    }

    private func setScratchCurrent(_ id: UUID?, reveal: Bool) {
        let file = scratchFiles.first { $0.id == id }
        let next = file.map { RowID.scratch($0.id) }
        let directories = Set(file.map { [RowID.scratchCategory($0.folderPath)] } ?? [])
        let changed = currentScratchID != id || currentRow != next || currentDirectories != directories
        currentScratchID = id
        currentRow = next
        currentDirectories = directories
        if changed && reveal && openingFile == nil {
            rowToReveal = next
            expanded.formUnion(currentDirectories)
        }
    }

    private static func scratchFolderName(_ folderPath: String?) -> String {
        guard let folderPath else { return "Global" }
        let name = URL(filePath: folderPath, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? folderPath : name
    }

    private func ancestors(of url: URL, in folder: URL) -> Set<RowID> {
        let rootID = RowID.fileURL(folder)
        var ids: Set<RowID> = []
        var ancestor = url.deletingLastPathComponent()
        while WorktreeFileOperations.contains(ancestor, in: folder) {
            let id = RowID.fileURL(ancestor)
            ids.insert(id)
            if id == rootID { break }
            ancestor.deleteLastPathComponent()
        }
        return ids
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

    fileprivate func selectFirstRowIfNeeded() {
        guard mode == .worktree, document.displayedFileURL == nil, nameEdit == nil,
              tree.selectedRow == -1, tree.numberOfRows > 0 else { return }
        selectRows(IndexSet(integer: 0))
        tree.scrollRowToVisible(0)
    }

    private func startMonitoring() {
        monitor = nil
        guard isActive, let directory = root?.fileURL else { return }
        monitor = WorktreeMonitor(directory: directory) { [weak self] paths, reload in
            guard let self, let root = self.root else { return }
            if reload {
                refresh()
            } else {
                for item in expandedDirectories(from: root) where item.id.filePath.map(paths.contains) == true {
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
        guard let rootURL = root?.fileURL, let directoryURL = item.fileURL, let path = item.id.filePath,
              !item.outside, item.isDirectory, item !== provisionalEntry else { return }
        if force { requests[path]?.cancel() }
        else if item.isLoaded || requests[path] != nil { return }
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
            RowID.fileURL(entry.url) != child.id || entry.isDirectory != child.isDirectory ||
                entry.isIgnored != child.isIgnored || entry.isHidden != child.isSystemHidden
        }
        item.isLoaded = true
        // Reloading identical rows would interrupt the outline's expansion animation.
        guard changed || shouldAnimateExpansion else { return }
        let previous = Dictionary(uniqueKeysWithValues: item.children.map { ($0.id, $0) })
        item.children = entries.map { entry in
            let child: Item
            if let existing = previous[.fileURL(entry.url)], existing.isDirectory == entry.isDirectory {
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
            let hadRows = tree.numberOfRows > 0
            reloadTree()
            if !hadRows, isActive, document.window.firstResponder === tree { selectFirstRowIfNeeded() }
            return
        }
        updateVisibleChildren(of: item)
        guard tree.row(forItem: item) >= 0 else { return }
        if shouldAnimateExpansion && isActive && !tree.isItemExpanded(item) {
            reloading = true
            tree.setFolderExpanded(item, expanded: true, animated: true)
            reloading = false
            if tree.isItemExpanded(item) { expanded.insert(item.id) }
            return
        }
        let selection = selectedItems.map(\.id)
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
        guard let directoryPath = item.id.filePath else {
            item.visibleChildren = item.children
            return
        }
        let parentHidden = item !== root && (item.hasHiddenParent || isHidden(item))
        item.visibleChildren = item.children.filter { child in
            child.hasHiddenParent = parentHidden
            return showsHidden || (!parentHidden && !isHidden(child))
                || child.id == currentRow || currentDirectories.contains(child.id)
        }
        // The CLI can open a new path before the file exists on disk.
        if let currentPath = currentRow?.filePath, item.isLoaded, currentDirectories.contains(item.id),
           URL(filePath: currentPath).deletingLastPathComponent().path == directoryPath,
           !item.visibleChildren.contains(where: { $0.id == currentRow }) {
            item.visibleChildren.append(Item(URL(filePath: currentPath), directory: false))
        }
    }

    private func reloadTree(keeping ids: [RowID]? = nil) {
        guard nameEdit == nil else { return }
        let selection = ids ?? selectedItems.map(\.id)
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
        guard item.isDirectory, expanded.contains(item.id) else { return }
        tree.expandItem(item)
        load(item)
        for child in item.visibleChildren where child.isDirectory {
            restoreExpansion(from: child)
        }
    }

    private func restoreSelection(_ ids: [RowID]) {
        selectRows(visibleRows(for: ids))
    }

    private func visibleRows(for ids: [RowID]) -> IndexSet {
        IndexSet(ids.compactMap { id in
            guard let item = item(at: id) else { return nil }
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
        guard nameEdit == nil, let rowToReveal, let item = item(at: rowToReveal) else { return }
        let row = tree.row(forItem: item)
        guard row >= 0 else { return }
        self.rowToReveal = nil
        if mode == .worktree || !tree.selectedRowIndexes.contains(row) {
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        tree.scrollRowToVisible(row)
    }

    private func item(at id: RowID) -> Item? {
        switch id {
        case .scratchRoot: return root?.id == id ? root : nil
        case .scratchCategory: return root?.visibleChildren.first { $0.id == id }
        case .scratch: return root?.visibleChildren.lazy.compactMap { $0.visibleChildren.first { $0.id == id } }.first
        case .draft: return provisionalEntry?.id == id ? provisionalEntry : nil
        case .file(let path): return fileItem(at: path)
        }
    }

    private func fileItem(at path: String) -> Item? {
        let id = RowID.file(path)
        if let file = outside?.visibleChildren.first, file.id == id { return file }
        if let outside, outside.id == id { return outside }
        guard var item = root else { return nil }
        while item.id != id {
            guard let parent = item.id.filePath else { return nil }
            let prefix = parent.hasSuffix("/") ? parent : parent + "/"
            guard path.hasPrefix(prefix) else { return nil }
            let next = path.dropFirst(prefix.count).prefix { $0 != "/" }
            guard let child = item.visibleChildren.first(where: { $0.id == .file(prefix + next) }) else { return nil }
            item = child
        }
        return item
    }

    private func readHiddenItems() {
        guard !app.isAgentCheck, let rootPath = root?.id.filePath else {
            manualHidden = []
            return
        }
        manualHidden = Set(UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey)?[rootPath] as? [String] ?? [])
    }

    private func toggleHidden(_ url: URL) {
        guard let rootPath = root?.id.filePath else { return }
        if !app.isAgentCheck { readHiddenItems() }
        let path = WorktreeFileOperations.path(url)
        if manualHidden.remove(path) == nil { manualHidden.insert(path) }
        if !app.isAgentCheck {
            var folders = UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey) ?? [:]
            folders[rootPath] = manualHidden.isEmpty ? nil : manualHidden.sorted()
            UserDefaults.standard.set(folders, forKey: Self.hiddenItemsKey)
            NotificationCenter.default.post(name: Self.hiddenItemsChanged, object: nil, userInfo: ["root": rootPath])
        }
        reloadTree()
    }

    @objc private func hiddenItemsChanged(_ notification: Notification) {
        guard let rootPath = root?.id.filePath, notification.userInfo?["root"] as? String == rootPath else { return }
        let previous = manualHidden
        readHiddenItems()
        if previous != manualHidden { reloadTree() }
    }

    private func isHidden(_ item: Item) -> Bool {
        item.isSystemHidden || item.id.filePath.map(manualHidden.contains) == true
    }

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
        expanded.insert(item.id)
        load(item, force: item.isLoaded)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? Item else { return }
        expanded.remove(item.id)
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
        let backingURL = item.scratchFile.map { app.scratchStore.url(for: $0) } ?? item.fileURL
        let icon: NSImage?
        if item.isDirectory {
            icon = nil
        } else {
            let nameURL = item.scratchFile?.filenameURL ?? item.fileURL ?? URL(filePath: item.name)
            icon = FileIcons.image(for: nameURL, appearance: outlineView.effectiveAppearance,
                                  language: backingURL.flatMap { app.syntaxOverrides.language(for: $0)?.iconIdentifier })
        }
        let path = item.id.filePath ?? backingURL?.path ?? (item.isDirectory ? item.scratchCategory ?? "Global" : item.name)
        cell.configure(name: item.name, path: path, icon: icon, muted: muted)
        cell.setJJStatus(jjStatus(for: item))
        return cell
    }

    func setJJDecorations(_ decorations: JJWorktreeDecorations?) {
        jjDecorations = decorations
        let rows = tree.rows(in: tree.visibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else { return }
        for row in rows.location..<NSMaxRange(rows) {
            guard let item = tree.item(atRow: row) as? Item,
                  let cell = tree.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorktreeCell else { continue }
            cell.setJJStatus(jjStatus(for: item))
        }
    }

    private func jjStatus(for item: Item) -> JJPathStatus? {
        guard let url = item.fileURL, !item.outside, item !== provisionalEntry else { return nil }
        return jjDecorations?.status(at: url, directory: item.isDirectory)
    }

    private var selectedItems: [Item] { tree.selectedRowIndexes.compactMap { tree.item(atRow: $0) as? Item } }

    func openFile(at row: Int, focusContent: Bool = false) {
        guard let item = tree.item(atRow: row) as? Item, !item.isDirectory, item !== provisionalEntry else { return }
        let target: OpenTarget
        if let file = item.scratchFile { target = .scratch(file.id) }
        else if let url = item.fileURL { target = .file(url) }
        else { return }
        if focusContent && openingFile == nil && item.id == currentRow {
            document.focusContent()
            return
        }
        if mode == .scratches && !tree.selectedRowIndexes.contains(row) {
            selectRows(IndexSet(integer: row))
        }
        rowToReveal = nil
        pendingOpen = (target, focusContent ? selectionRevision : nil)
        guard openingFile == nil else { return }
        openingFile = Task { [weak self, app, document] in
            defer { self?.openingFile = nil }
            while let self, let (target, focusSelectionRevision) = self.pendingOpen {
                self.pendingOpen = nil
                let opened: Bool
                switch target {
                case .scratch(let id):
                    guard let scratch = self.scratchFiles.first(where: { $0.id == id }) else { continue }
                    opened = await document.openScratch(scratch, focusEditor: false) {
                        self.isActive && (self.pendingOpen == nil || self.pendingOpen?.target == target)
                    }
                case .file(let url):
                    let folder = document.folderURL
                    opened = await app.openFiles([url], in: document, focusEditor: false) {
                        self.isActive && document.folderURL == folder &&
                            (self.pendingOpen == nil || self.pendingOpen?.target == target)
                    }
                }
                if opened && focusSelectionRevision == self.selectionRevision && self.pendingOpen == nil &&
                    self.isActive && document.window.firstResponder === self.tree {
                    document.focusContent()
                }
            }
        }
    }

    func activateClickedRow(_ row: Int) {
        if (tree.item(atRow: row) as? Item)?.isDirectory == true {
            toggleFolder(at: row, animated: true)
        } else {
            openFile(at: row)
        }
    }

    func activateSelection() {
        let row = tree.selectedRow
        if row < 0 {
            document.focusContent()
        } else if (tree.item(atRow: row) as? Item)?.isDirectory == true {
            toggleFolder(at: row, animated: false)
        } else {
            openFile(at: row, focusContent: true)
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

        let closingPaths = Set(expanding ? [] : changed.compactMap(\.id.filePath))
        for folder in changed {
            // Collapsing a parent leaves the expansion state of its hidden children intact.
            if !expanding, let url = folder.fileURL,
               WorktreeFileOperations.isUnderSelection(url.deletingLastPathComponent(), paths: closingPaths) {
                continue
            }
            tree.setFolderExpanded(folder, expanded: expanding, animated: false)
        }
        if selection.count > 1 { restoreSelection(selection.map(\.id)) }
        return true
    }

    func renameSelection() {
        guard tree.selectedRowIndexes.count == 1, let item = selectedItems.first else { return }
        rename(item)
    }

    private func rename(_ item: Item) {
        if let file = item.scratchFile, scratchActions.canWork {
            beginNameEdit(.scratch(file: file, category: file.folderPath), entry: item)
        } else if let url = item.fileURL, let folder = root?.fileURL {
            beginNameEdit(.rename(url), in: folder)
        }
    }

    private func beginNameEdit(_ request: WorktreeActions.NameRequest, in openedFolder: URL) {
        guard actions.canEditName(in: openedFolder), let root else { return }
        let worktree = NameRequest.worktree(request, root: openedFolder)
        switch request {
        case .rename(let url):
            guard let item = item(at: .fileURL(url)), item !== root, !item.outside else { return }
            beginNameEdit(worktree, entry: item)
        case .create(let directory, let isDirectory):
            guard let parent = item(at: .fileURL(directory)), !parent.outside else { return }
            beginNameEdit(worktree, entry: makeDraft(in: parent, directory: isDirectory), draftParent: parent)
        }
    }

    private func makeDraft(in parent: Item, directory: Bool) -> Item {
        let base = directory ? "untitled folder" : "untitled"
        let occupied = Set(parent.children.map { $0.name.lowercased() })
        var name = base
        var suffix = 2
        while occupied.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let entry = Item(.draft(UUID()), directory: directory)
        entry.displayName = name
        return entry
    }

    private func beginNameEdit(_ request: NameRequest, entry: Item, draftParent: Item? = nil) {
        guard isActive, let root, nameEdit?.submitting != true else { return }
        if let nameEdit { finishNameEdit(nameEdit) }
        if let draftParent, draftParent !== root { tree.expandItem(draftParent) }
        let edit = NameEdit(request: request, entry: entry, draftParent: draftParent, selection: selectedItems.map(\.id))
        nameEdit = edit
        rowToReveal = nil
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
            let selection = self.selectedItems.filter { $0 !== self.provisionalEntry }.map(\.id)
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
                switch edit.request {
                case .scratch(let file, let category):
                    let record = try await scratchActions.commitName(name, file: file, folderPath: category)
                    guard nameEdit === edit else { return }
                    let stillEditing = document.window.firstResponder === editor
                    rowToReveal = .scratch(record.id)
                    expanded.insert(.scratchCategory(record.folderPath))
                    pendingScratchFiles = (pendingScratchFiles ?? scratchFiles).filter { $0.id != record.id } + [record]
                    finishNameEdit(edit)
                    if edit.draftParent != nil, stillEditing { _ = await document.openScratch(record) }
                case .worktree(let request, let folder):
                    let url = try await actions.commitName(name, for: request, in: folder)
                    guard nameEdit === edit else { return }
                    if case .rename(let source) = request { retargetExpansion(from: source, to: url) }
                    expanded.formUnion(ancestors(of: url, in: folder).subtracting([.fileURL(folder)]))
                    rowToReveal = .fileURL(url)
                    let stillEditing = document.window.firstResponder === editor
                    finishNameEdit(edit)
                    if case .create(_, false) = request, stillEditing { await app.openFiles([url], in: document) }
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

    private func finishNameEdit(_ edit: NameEdit, keeping selection: [RowID]? = nil) {
        guard nameEdit === edit else { return }
        nameEdit = nil
        edit.error?.close()
        edit.field.delegate = nil
        if let editor = edit.field.currentEditor(), document.window.firstResponder === editor {
            editor.isEditable = true
            document.window.makeFirstResponder(tree)
        }
        edit.field.removeFromSuperview()
        let kept = selection ?? edit.selection
        if mode == .scratches, let pendingScratchFiles {
            self.pendingScratchFiles = nil
            installScratchFiles(pendingScratchFiles, current: document.scratchFile?.id, preserving: kept)
        } else {
            reloadTree(keeping: kept)
        }
    }

    func addRootCreationItems(to menu: NSMenu) {
        if mode == .scratches {
            let folderPath = document.folderURL.map(WorktreeFileOperations.path)
            scratchActions.addCreationItems(to: menu) { [weak self] in
                self?.beginScratchCreation(in: folderPath)
            }
            return
        }
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
        if mode == .scratches { return scratchMenu(for: item, in: root) }
        guard let url = item.fileURL, let folder = root.fileURL else { return nil }
        let urls = row >= 0 ? selectedItems.filter { $0 !== provisionalEntry }.compactMap(\.fileURL) : []
        return actions.menu(for: url, isDirectory: item.isDirectory, selection: urls, root: folder) { [weak self] in
            guard let self, actions.canTrash(urls, in: folder) else { return }
            document.window.makeFirstResponder(tree)
            actions.trash(urls, within: folder, updateSelection: fileSelectionUpdate(in: folder))
        }
    }

    private func scratchMenu(for item: Item, in root: Item) -> NSMenu {
        let selection = selectedItems.compactMap(\.scratchFile)
        let categories = root.children.map(\.scratchCategory)
        let file = item.scratchFile
        let folderPath = item === root
            ? document.folderURL.map(WorktreeFileOperations.path)
            : file?.folderPath ?? item.scratchCategory
        return scratchActions.menu(
            file: file, folderPath: folderPath, selection: selection, categories: categories,
            rename: { [weak self] in self?.rename(item) },
            create: { [weak self] in self?.beginScratchCreation(in: folderPath) },
            remove: { [weak self] in
                guard let self else { return }
                document.window.makeFirstResponder(tree)
                trashScratches(selection)
            }
        )
    }

    private func beginScratchCreation(in folderPath: String?) {
        guard scratchActions.canWork, let parent = item(at: .scratchCategory(folderPath)) else { return }
        beginNameEdit(.scratch(file: nil, category: folderPath), entry: makeDraft(in: parent, directory: false), draftParent: parent)
    }

    private func trashScratches(_ files: [ScratchFile]) {
        let removed = Set(files.map { RowID.scratch($0.id) })
        let wasRemoved: (Item) -> Bool = { removed.contains($0.id) }
        let update = selectionAfterRemoval(excluding: wasRemoved)
        scratchActions.trash(files) { update(wasRemoved) }
    }

    func trashSelection() {
        guard let root, nameEdit == nil else { return }
        if mode == .scratches {
            trashScratches(selectedItems.compactMap(\.scratchFile))
            return
        }
        let items = selectedItems.compactMap(\.fileURL)
        guard let folder = root.fileURL, actions.canTrash(items, in: folder) else { return }
        actions.trash(items, within: folder, updateSelection: fileSelectionUpdate(in: folder))
    }

    func undoActionName(redo: Bool) -> String? {
        if mode == .scratches { return scratchActions.undoActionName(redo: redo) }
        guard let folder = root?.fileURL else { return nil }
        return actions.undoActionName(in: folder, redo: redo)
    }

    func undoFileChange(redo: Bool) {
        guard let root, nameEdit == nil else { return }
        if mode == .scratches {
            let revision = selectionRevision
            scratchActions.undo(redo: redo) { [weak self] files in
                guard let self, selectionRevision == revision,
                      document.window.firstResponder === tree, nameEdit == nil else { return }
                restoredSelection = files.map { .scratch($0.id) }
                expanded.formUnion(files.map { .scratchCategory($0.folderPath) })
                rowToReveal = nil
                reloadTree()
            }
            return
        }
        guard let folder = root.fileURL else { return }
        actions.undo(in: folder, redo: redo, updateSelection: fileSelectionUpdate(in: folder))
    }

    private func fileSelectionUpdate(in folder: URL) -> (WorktreeActions.SelectionChange) -> Void {
        let revision = selectionRevision
        let folderID = RowID.fileURL(folder)
        let selectedPaths = Set(selectedItems.compactMap(\.id.filePath))
        let selectAfterRemoving = selectionAfterRemoval { item in
            item.fileURL.map { WorktreeFileOperations.isUnderSelection($0, paths: selectedPaths) } == true
        }
        return { [weak self] change in
            guard let self, root?.id == folderID else { return }
            if case .renamed(let move) = change {
                retargetExpansion(from: move.source, to: move.destination)
            }
            guard selectionRevision == revision,
                  document.window.firstResponder === tree, nameEdit == nil else { return }
            rowToReveal = nil
            switch change {
            case .removed(let removed):
                let removedPaths = Set(removed.map(WorktreeFileOperations.path))
                selectAfterRemoving { item in
                    item.fileURL.map { WorktreeFileOperations.isUnderSelection($0, paths: removedPaths) } == true
                }
            case .restored(let items):
                revealSelection(items, in: folder)
            case .renamed(let move):
                revealSelection([move.destination], in: folder)
            }
        }
    }

    private func selectionAfterRemoval(excluding excluded: (Item) -> Bool) -> ((Item) -> Bool) -> Void {
        let revision = selectionRevision
        let selection = selectedItems
        var neighbors: [Item] = []
        if let anchor = tree.selectedRowIndexes.first {
            func nearbyItem(in rows: some Sequence<Int>) -> Item? {
                rows.lazy.compactMap { (self.tree.item(atRow: $0) as? Item) }.first { !excluded($0) }
            }
            if let next = nearbyItem(in: (anchor + 1)..<tree.numberOfRows) { neighbors.append(next) }
            if let previous = nearbyItem(in: (0..<anchor).reversed()) { neighbors.append(previous) }
        }
        return { [weak self] wasRemoved in
            guard let self, selectionRevision == revision, document.window.firstResponder === tree,
                  nameEdit == nil, selection.contains(where: wasRemoved) else { return }
            rowToReveal = nil
            var rows = visibleRows(for: selection.filter { !wasRemoved($0) }.map(\.id))
            if rows.isEmpty {
                for neighbor in neighbors where !wasRemoved(neighbor) {
                    rows = visibleRows(for: [neighbor.id])
                    if !rows.isEmpty { break }
                }
            }
            selectRows(rows)
            if let first = rows.first { tree.scrollRowToVisible(first) }
        }
    }

    private func revealSelection(_ items: [URL], in folder: URL) {
        restoredSelection = items.map(RowID.fileURL)
        let rootID = RowID.fileURL(folder)
        for item in items { expanded.formUnion(ancestors(of: item, in: folder).subtracting([rootID])) }
        reloadTree()
    }

    private func retargetExpansion(from source: URL, to destination: URL) {
        let sourcePath = WorktreeFileOperations.path(source)
        let destinationPath = WorktreeFileOperations.path(destination)
        guard sourcePath != destinationPath else { return }
        let prefix = sourcePath + "/"
        expanded = Set(expanded.map { id in
            guard let path = id.filePath else { return id }
            if path == sourcePath { return .file(destinationPath) }
            if path.hasPrefix(prefix) { return .file(destinationPath + path.dropFirst(sourcePath.count)) }
            return id
        })
    }

    func setRecycleForCheck(_ recycle: @escaping ([URL]) async throws -> WorktreeFileOperations.TransferResult) {
        actions.recycleForCheck = recycle
    }

    func fileReplaced(_ previous: FileIdentity, with current: FileIdentity) {
        actions.fileReplaced(previous, with: current)
    }

    func copySelection() {
        if mode == .scratches {
            scratchActions.copy(selectedItems.compactMap(\.scratchFile))
            return
        }
        let urls = selectedItems.filter { $0 !== provisionalEntry && (!$0.isDirectory || !$0.outside) }.compactMap(\.fileURL)
        if !urls.isEmpty { SidebarFileCommands.copy(urls) }
    }

    func pasteIntoSelection() {
        if mode == .scratches {
            guard let category = scratchDestination(for: selectedItems.first) else { return }
            _ = scratchActions.transfer(SidebarFileCommands.fileURLs(on: .general), to: category.scratchCategory)
            return
        }
        guard let folder = root?.fileURL, let directory = destination(for: selectedItems.first) else { return }
        _ = actions.paste(into: directory, within: folder)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        tree.didStartDrag = true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem object: Any) -> (any NSPasteboardWriting)? {
        guard let item = object as? Item, item !== provisionalEntry, !item.outside || !item.isDirectory else { return nil }
        if mode == .scratches {
            return item.scratchFile.map { app.scratchStore.url(for: $0) as NSURL }
        }
        return item.fileURL.map { $0 as NSURL }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let target = item as? Item
        if mode == .scratches {
            guard let drop = scratchDrop(info, onto: target) else { return [] }
            outlineView.setDropItem(drop.category, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return drop.operation
        }
        let operation = dropOperation(info, onto: target)
        guard !operation.isEmpty else { return [] }
        let directory = target.flatMap { $0.isDirectory ? $0 : itemAtParent(of: $0) }
        outlineView.setDropItem(directory === root ? nil : directory, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex: Int) -> Bool {
        let target = item as? Item
        if mode == .scratches {
            guard let drop = scratchDrop(info, onto: target) else { return false }
            if !drop.files.isEmpty {
                return scratchActions.move(drop.files, to: drop.category.scratchCategory, copying: drop.operation == .copy)
            }
            return scratchActions.transfer(drop.urls, to: drop.category.scratchCategory)
        }
        let operation = dropOperation(info, onto: target)
        guard operation != [], let folder = root?.fileURL, let directory = destination(for: target) else { return false }
        return actions.transfer(SidebarFileCommands.fileURLs(on: info.draggingPasteboard), into: directory,
                                move: operation == .move, within: folder)
    }

    private func dropOperation(_ info: any NSDraggingInfo, onto target: Item?) -> NSDragOperation {
        guard let directory = destination(for: target) else { return [] }
        let urls = SidebarFileCommands.fileURLs(on: info.draggingPasteboard)
        let wantsCopy = NSEvent.modifierFlags.contains(.option)
        let source = (info.draggingSource as? WorktreeOutline)?.owner
        let operation: NSDragOperation = source?.mode == .worktree && !wantsCopy ? .move : .copy
        guard info.draggingSourceOperationMask.contains(operation), !urls.isEmpty,
              urls.allSatisfy({ !WorktreeFileOperations.contains(directory, in: $0) && $0.deletingLastPathComponent().path != directory.path })
        else { return [] }
        return operation
    }

    private func scratchDrop(_ info: any NSDraggingInfo, onto target: Item?)
        -> (category: Item, operation: NSDragOperation, files: [ScratchFile], urls: [URL])? {
        guard scratchActions.canWork, let category = scratchDestination(for: target) else { return nil }
        let urls = SidebarFileCommands.fileURLs(on: info.draggingPasteboard)
        guard !urls.isEmpty, !urls.contains(where: \.hasDirectoryPath) else { return nil }
        if let source = (info.draggingSource as? WorktreeOutline)?.owner, source.mode == .scratches {
            let records = Dictionary(uniqueKeysWithValues: source.scratchFiles.map {
                (WorktreeFileOperations.path(app.scratchStore.url(for: $0)), $0)
            })
            let files = urls.compactMap { records[WorktreeFileOperations.path($0)] }
            guard files.count == urls.count else { return nil }
            let operation: NSDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
            guard info.draggingSourceOperationMask.contains(operation),
                  operation == .copy || files.contains(where: { $0.folderPath != category.scratchCategory }) else { return nil }
            return (category, operation, files, urls)
        }
        guard info.draggingSourceOperationMask.contains(.copy) else { return nil }
        return (category, .copy, [], urls)
    }

    private func scratchDestination(for item: Item?) -> Item? {
        guard let item, item !== root else {
            return self.item(at: .scratchCategory(scratchProject))
        }
        guard item !== provisionalEntry else { return nil }
        if item.isDirectory { return item }
        return item.scratchFile.flatMap { self.item(at: .scratchCategory($0.folderPath)) }
    }

    private func destination(for item: Item?) -> URL? {
        guard let item else { return root?.fileURL }
        guard let url = item.fileURL, !item.outside, item !== provisionalEntry else { return nil }
        return item.isDirectory ? url : url.deletingLastPathComponent()
    }

    private func itemAtParent(of item: Item) -> Item? {
        item.fileURL.flatMap { self.item(at: .fileURL($0.deletingLastPathComponent())) }
    }
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
    private var pointerTrackingArea: NSTrackingArea?
    weak var owner: SidebarFileTree?
    var didStartDrag = false

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        owner?.selectFirstRowIfNeeded()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTrackingArea == nil else { return }
        // AppKit refreshes tracking-area cursors inside native control tracking as well.
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if let window, (NSApp as? EditApplication)?.updatePointerCursor(in: window) == true { return }
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        let disclosure = clicked >= 0 && frameOfOutlineCell(atRow: clicked).contains(point)
        let isFolder = clicked >= 0 && item(atRow: clicked).map { isExpandable($0) } == true
        let plainClick = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        if isFolder, !disclosure, plainClick, event.clickCount > 1,
           let press = NSEvent.mouseEvent(with: .leftMouseDown, location: event.locationInWindow,
                                          modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                          windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                                          clickCount: 1, pressure: event.pressure) {
            // AppKit tracks a single press through release and reserves multi-clicks for doubleAction.
            super.mouseDown(with: press)
        } else {
            super.mouseDown(with: event)
        }

        // A table's action can skip already selected rows. Use the release from its native tracking.
        guard !didStartDrag, clicked >= 0, !disclosure, plainClick, isFolder || event.clickCount == 1,
              let release = NSApp.currentEvent, release.type == .leftMouseUp,
              release.window === window, release.timestamp >= event.timestamp,
              row(at: convert(release.locationInWindow, from: nil)) == clicked else { return }
        owner?.activateClickedRow(clicked)
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
        button.ignoresMultiClick = false
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
        didSet {
            updateDisclosureImages()
            updateJJTextColor()
        }
    }

    override var isEmphasized: Bool {
        didSet {
            updateDisclosureImages()
            updateJJTextColor()
        }
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

    private func updateJJTextColor() {
        for case let cell as WorktreeCell in subviews { cell.updateJJTextColor() }
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
    private var muted = false
    private var jjStatus: JJPathStatus?
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
        self.muted = muted
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

    func setJJStatus(_ status: JJPathStatus?) {
        jjStatus = status
        let name = label.stringValue
        let detail: String?
        switch status {
        case .added: detail = "Added"
        case .modified, .removed: detail = "Changed"
        case .conflict: detail = "Unresolved conflict"
        case nil: detail = nil
        }
        label.setAccessibilityLabel(detail.map { "\(name), \($0)" })
        updateJJTextColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateJJTextColor()
    }

    func updateJJTextColor() {
        let kind: JJLineMark.Kind
        switch jjStatus {
        case .added: kind = .insertion
        case .modified, .removed: kind = .replacement
        case .conflict: kind = .conflict
        case nil:
            label.textColor = muted ? .secondaryLabelColor : .labelColor
            return
        }
        let row = superview as? WorktreeRow
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let emphasized = row?.isSelected == true && row?.isEmphasized == true
            let selected: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            let background: NSColor = row?.isSelected == true ? selected : .windowBackgroundColor
            let foreground: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            label.textColor = Self.readable(kind.color, over: background, toward: foreground)
        }
    }

    private static func readable(_ color: NSColor, over background: NSColor, toward foreground: NSColor) -> NSColor {
        func luminance(_ color: NSColor) -> Double? {
            guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        guard let base = luminance(background) else { return foreground }
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            guard let sample = color.blended(withFraction: fraction, of: foreground),
                  let value = luminance(sample) else { continue }
            if (max(value, base) + 0.05) / (min(value, base) + 0.05) >= 4.5 { return sample }
        }
        return foreground
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
