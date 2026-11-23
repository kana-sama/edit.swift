import AppKit
import CoreServices

@MainActor
struct SidebarTreeTransfer {
    let operation: NSDragOperation
    let accept: () -> Bool
}

@MainActor
final class SidebarWorktreeSource: NSObject {
    private static let hiddenItemsKey = "WorktreeHiddenItems"
    private static let hiddenItemsChanged = Notification.Name("Edit.WorktreeHiddenItemsChanged")

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private let refresh: () -> Void
    private let visibilityChanged: () -> Void
    private let directoriesChanged: @MainActor (Set<String>, Bool) -> Void
    private let editName: (WorktreeActions.NameRequest, URL) -> Void
    private var folder: URL?
    private var active = false
    private var monitor: FileSystemEvents?
    private var requests: [String: Task<Void, Never>] = [:]
    private var hiddenPaths: Set<String> = []
    private(set) var showsHidden = false

    private(set) lazy var actions = WorktreeActions(
        document: document, app: app, refresh: refresh,
        isHidden: { [weak self] in self?.isHidden(WorktreeFileOperations.path($0)) == true },
        toggleHidden: { [weak self] in self?.toggleHidden($0) }, editName: editName
    )

    init(document: DocumentWindow, app: Edit, refresh: @escaping () -> Void,
         visibilityChanged: @escaping () -> Void, directoriesChanged: @escaping @MainActor (Set<String>, Bool) -> Void,
         editName: @escaping (WorktreeActions.NameRequest, URL) -> Void) {
        self.document = document
        self.app = app
        self.refresh = refresh
        self.visibilityChanged = visibilityChanged
        self.directoriesChanged = directoriesChanged
        self.editName = editName
        super.init()
        if !app.isAgentCheck {
            NotificationCenter.default.addObserver(self, selector: #selector(hiddenItemsChanged(_:)),
                                                   name: Self.hiddenItemsChanged, object: nil)
        }
    }

    isolated deinit {
        for task in requests.values { task.cancel() }
    }

    func setFolder(_ folder: URL) {
        guard self.folder != folder else { return }
        for task in requests.values { task.cancel() }
        requests.removeAll()
        self.folder = folder
        readHiddenPaths()
        updateMonitor()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        updateMonitor()
    }

    func load(_ directory: URL, alreadyLoaded: Bool, force: Bool,
              apply: @escaping ([WorktreeDirectory.Entry]) -> Void) {
        guard let folder else { return }
        let path = WorktreeFileOperations.path(directory)
        if force { requests[path]?.cancel() }
        else if alreadyLoaded || requests[path] != nil { return }
        requests[path] = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                // A previously loaded directory can disappear before its parent's event arrives.
                (try? WorktreeDirectory.read(directory, within: folder)) ?? []
            }
            let entries = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            requests.removeValue(forKey: path)
            apply(entries)
        }
    }

    func setShowsHidden(_ visible: Bool) {
        guard showsHidden != visible else { return }
        showsHidden = visible
        visibilityChanged()
    }

    func isHidden(_ path: String) -> Bool { hiddenPaths.contains(path) }

    func drop(_ info: any NSDraggingInfo, into directory: URL, fromWorktree: Bool) -> SidebarTreeTransfer? {
        guard let folder else { return nil }
        let urls = SidebarFileCommands.fileURLs(on: info.draggingPasteboard)
        let copy = !fromWorktree || NSEvent.modifierFlags.contains(.option)
        let operation: NSDragOperation = copy ? .copy : .move
        guard info.draggingSourceOperationMask.contains(operation), !urls.isEmpty,
              urls.allSatisfy({ !WorktreeFileOperations.contains(directory, in: $0) && $0.deletingLastPathComponent().path != directory.path })
        else { return nil }
        return SidebarTreeTransfer(operation: operation) { [actions] in
            actions.transfer(urls, into: directory, move: !copy, within: folder)
        }
    }

    private func updateMonitor() {
        monitor = nil
        guard active, let folder else { return }
        monitor = FileSystemEvents(directory: folder) { [weak self] events in
            self?.monitorChanged(events)
        }
    }

    private func monitorChanged(_ events: [FileSystemEvents.Event]) {
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemFinderInfoMod
            | kFSEventStreamEventFlagItemInodeMetaMod)
        var changedPaths = Set<String>()
        for event in events {
            let path = event.path as NSString
            if event.requiresRescan || path.lastPathComponent == ".gitignore" {
                directoriesChanged([], true)
                return
            }
            if event.flags & structural != 0 {
                changedPaths.insert(URL(filePath: path.deletingLastPathComponent, directoryHint: .isDirectory).standardizedFileURL.path)
            }
        }
        if !changedPaths.isEmpty { directoriesChanged(changedPaths, false) }
    }

    private func readHiddenPaths() {
        guard !app.isAgentCheck, let folder else {
            hiddenPaths = []
            return
        }
        let path = WorktreeFileOperations.path(folder)
        hiddenPaths = Set(UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey)?[path] as? [String] ?? [])
    }

    private func toggleHidden(_ url: URL) {
        guard let folder else { return }
        if !app.isAgentCheck { readHiddenPaths() }
        let path = WorktreeFileOperations.path(url)
        if hiddenPaths.remove(path) == nil { hiddenPaths.insert(path) }
        if !app.isAgentCheck {
            let rootPath = WorktreeFileOperations.path(folder)
            var folders = UserDefaults.standard.dictionary(forKey: Self.hiddenItemsKey) ?? [:]
            folders[rootPath] = hiddenPaths.isEmpty ? nil : hiddenPaths.sorted()
            UserDefaults.standard.set(folders, forKey: Self.hiddenItemsKey)
            NotificationCenter.default.post(name: Self.hiddenItemsChanged, object: nil, userInfo: ["root": rootPath])
        }
        visibilityChanged()
    }

    @objc private func hiddenItemsChanged(_ notification: Notification) {
        guard let folder, notification.userInfo?["root"] as? String == WorktreeFileOperations.path(folder) else { return }
        let previous = hiddenPaths
        readHiddenPaths()
        if previous != hiddenPaths { visibilityChanged() }
    }
}

@MainActor
final class SidebarScratchSource {
    struct Category {
        let folder: String?
        let title: String
        let files: [ScratchFile]
    }

    let actions: ScratchWorktreeActions
    private let store: ScratchStore
    private(set) var files: [ScratchFile] = []
    private(set) var project: String?

    init(document: DocumentWindow, app: Edit) {
        store = app.scratchStore
        actions = ScratchWorktreeActions(document: document, app: app)
    }

    func replaceContents(_ files: [ScratchFile], project: String?) -> [Category] {
        self.files = files
        self.project = project
        var groups = Dictionary(grouping: files, by: \.folderPath)
        if let project, groups[project] == nil { groups[project] = [] }
        let folders = groups.keys.compactMap { $0 }.sorted {
            let comparison = Self.folderName($0).localizedStandardCompare(Self.folderName($1))
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        let paths: [String?] = [nil] + folders.map(Optional.some)
        let names = Dictionary(grouping: paths) { Self.folderName($0).lowercased() }
        return paths.map { folder in
            let name = Self.folderName(folder)
            let title: String
            if let folder, (names[name.lowercased()]?.count ?? 0) > 1 {
                let parent = (folder as NSString).deletingLastPathComponent as NSString
                title = "\(name) — \(parent.abbreviatingWithTildeInPath)"
            } else {
                title = name
            }
            let members = (groups[folder] ?? []).sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
            }
            return Category(folder: folder, title: title, files: members)
        }
    }

    func file(_ id: UUID) -> ScratchFile? { files.first { $0.id == id } }
    func backingURL(for file: ScratchFile) -> URL { store.url(for: file) }

    func drop(_ info: any NSDraggingInfo, into category: String?, from source: SidebarScratchSource?) -> SidebarTreeTransfer? {
        guard actions.canWork else { return nil }
        let urls = SidebarFileCommands.fileURLs(on: info.draggingPasteboard)
        guard !urls.isEmpty, !urls.contains(where: \.hasDirectoryPath) else { return nil }
        if let source {
            let records = Dictionary(uniqueKeysWithValues: source.files.map {
                (WorktreeFileOperations.path(source.backingURL(for: $0)), $0)
            })
            let files = urls.compactMap { records[WorktreeFileOperations.path($0)] }
            let copy = NSEvent.modifierFlags.contains(.option)
            let operation: NSDragOperation = copy ? .copy : .move
            guard files.count == urls.count, info.draggingSourceOperationMask.contains(operation),
                  copy || files.contains(where: { $0.folderPath != category }) else { return nil }
            return SidebarTreeTransfer(operation: operation) { [actions] in
                actions.move(files, to: category, copying: copy)
            }
        }
        guard info.draggingSourceOperationMask.contains(.copy) else { return nil }
        return SidebarTreeTransfer(operation: .copy) { [actions] in actions.transfer(urls, to: category) }
    }

    private static func folderName(_ folder: String?) -> String {
        guard let folder else { return "Global" }
        let name = URL(filePath: folder, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? folder : name
    }
}
