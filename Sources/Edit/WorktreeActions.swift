import AppKit

@MainActor
final class WorktreeActions {
    enum NameRequest {
        case rename(URL)
        case create(in: URL, directory: Bool)
    }

    enum SelectionChange {
        case removed([URL])
        case restored([URL])
        case renamed(WorktreeFileOperations.Transfer)
    }

    private final class HistoryItem {
        let url: URL
        var identity: FileIdentity

        init(_ url: URL, identity: FileIdentity) {
            self.url = url
            self.identity = identity
        }
    }

    private struct Restoration {
        let original: URL
        let trashed: HistoryItem
    }

    private enum FileChange {
        case rename(from: HistoryItem, to: URL)
        case trash([HistoryItem], selectingOnRestore: [URL])
        case restore([Restoration], selecting: [URL])

        var items: [HistoryItem] {
            switch self {
            case .rename(let item, _): [item]
            case .trash(let items, _): items
            case .restore(let moves, _): moves.map(\.trashed)
            }
        }

        var name: String {
            switch self {
            case .rename: "Rename"
            case .trash, .restore: "Move to Trash"
            }
        }
    }

    private struct History {
        var undo: [FileChange] = []
        var redo: [FileChange] = []
    }

    private struct ChangeResult {
        let inverse: FileChange?
        var remaining: FileChange? = nil
        var failure: String? = nil
        var selection: SelectionChange? = nil
    }

    private weak var document: DocumentWindow?
    private unowned let app: Edit
    private let commands: SidebarFileCommands
    private let refresh: () -> Void
    private let editName: (NameRequest, URL) -> Void
    private let isHidden: (URL) -> Bool
    private let toggleHidden: (URL) -> Void
    private var working = false
    private var historyByFolder: [String: History] = [:]
    var recycleForCheck: (([URL]) async throws -> WorktreeFileOperations.TransferResult)?
    private var canWork: Bool { !working && document?.canReplaceBuffer == true }

    init(document: DocumentWindow, app: Edit, refresh: @escaping () -> Void,
         isHidden: @escaping (URL) -> Bool, toggleHidden: @escaping (URL) -> Void,
         editName: @escaping (NameRequest, URL) -> Void) {
        self.document = document
        self.app = app
        commands = SidebarFileCommands(document: document, app: app)
        self.refresh = refresh
        self.editName = editName
        self.isHidden = isHidden
        self.toggleHidden = toggleHidden
    }

    func menu(for item: URL, isDirectory: Bool, selection: [URL], root: URL, trashSelection: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inside = WorktreeFileOperations.contains(item, in: root)
        let editable = WorktreeFileOperations.canTrash(item, within: root)
        commands.addFileItems(to: menu, for: item, isDirectory: isDirectory, copySelection: [item])
        if inside && isDirectory {
            let canPaste = SidebarFileCommands.canPasteFiles()
            menu.addItem(commands.action("Paste", enabled: canWork && canPaste) { [weak self] in
                _ = self?.paste(into: item, within: root)
            })
            menu.addItem(.separator())
            addCreationItems(to: menu, in: item, root: root)
        }
        if editable {
            menu.addItem(.separator())
            menu.addItem(commands.action("Rename…", enabled: canWork) { [weak self] in self?.editName(.rename(item), root) })
            menu.addItem(commands.action(isHidden(item) ? "Unhide" : "Hide") { [weak self] in self?.toggleHidden(item) })
            commands.addTrashItem(to: menu, enabled: canTrash(selection, in: root), perform: trashSelection)
        }
        return menu
    }

    func addCreationItems(to menu: NSMenu, in directory: URL, root: URL) {
        menu.addItem(commands.action("New File…", enabled: canWork) { [weak self] in
            self?.editName(.create(in: directory, directory: false), root)
        })
        menu.addItem(commands.action("New Folder…", enabled: canWork) { [weak self] in
            self?.editName(.create(in: directory, directory: true), root)
        })
    }

    @discardableResult
    func paste(into directory: URL, within root: URL) -> Bool {
        transfer(SidebarFileCommands.fileURLs(on: .general), into: directory, move: false, within: root)
    }

    @discardableResult
    func transfer(_ sources: [URL], into destination: URL, move: Bool, within root: URL) -> Bool {
        guard !sources.isEmpty, WorktreeFileOperations.contains(destination, in: root) else { return false }
        let destinations = sources.map { destination.appending(path: $0.lastPathComponent) }
        let affected = move ? sources + destinations : destinations
        return run(move ? "Could Not Move Files" : "Could Not Copy Files", within: root) { _ in
            try await self.app.performWorktreeMutation(affecting: affected) {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WorktreeFileOperations.transfer(sources, into: destination, move: move, within: root)
                }.value
                if move {
                    for operation in result.completed { self.retarget(operation) }
                }
                if let failure = result.failure { throw TransferError(detail: failure) }
            }
        }
    }

    func canEditName(in root: URL) -> Bool { operationDocument(in: root) != nil }

    func commitName(_ name: String, for request: NameRequest, in root: URL) async throws -> URL {
        guard operationDocument(in: root) != nil else {
            throw NameError.unavailable
        }
        working = true
        defer {
            working = false
            refresh()
        }

        switch request {
        case .create(let parent, let directory):
            return try await Task.detached(priority: .userInitiated) {
                try WorktreeFileOperations.create(name, in: parent, root: root, isDirectory: directory)
            }.value
        case .rename(let item):
            guard let (move, identity) = try await rename(item, to: name, within: root) else {
                return item
            }
            recordUndo(.rename(from: HistoryItem(move.destination, identity: identity), to: move.source), in: root)
            return move.destination
        }
    }

    func canTrash(_ items: [URL], in root: URL) -> Bool {
        operationDocument(in: root) != nil && !items.isEmpty &&
            items.allSatisfy { WorktreeFileOperations.canTrash($0, within: root) }
    }

    func trash(_ items: [URL], within root: URL, updateSelection: @escaping (SelectionChange) -> Void) {
        guard canTrash(items, in: root) else { return }
        run("Could Not Move Items to Trash", within: root) { _ in
            let result = try await self.moveToTrash(items, selectingOnRestore: items, within: root)
            if let inverse = result.inverse { self.recordUndo(inverse, in: root) }
            if let selection = result.selection { updateSelection(selection) }
            if let failure = result.failure { throw TransferError(detail: failure) }
        }
    }

    func undoActionName(in root: URL, redo: Bool) -> String? {
        guard operationDocument(in: root) != nil, let history = historyByFolder[WorktreeFileOperations.path(root)] else {
            return nil
        }
        return (redo ? history.redo.last : history.undo.last)?.name
    }

    func undo(in root: URL, redo: Bool, updateSelection: @escaping (SelectionChange) -> Void) {
        let key = WorktreeFileOperations.path(root)
        guard var history = historyByFolder[key], let change = redo ? history.redo.last : history.undo.last else {
            return
        }
        let title = redo ? "Could Not Redo \(change.name)" : "Could Not Undo \(change.name)"
        run(title, within: root) { _ in
            let result = try await self.execute(change, within: root)
            if redo {
                history.redo.removeLast()
                if let remaining = result.remaining { history.redo.append(remaining) }
                if let inverse = result.inverse { history.undo.append(inverse) }
            } else {
                history.undo.removeLast()
                if let remaining = result.remaining { history.undo.append(remaining) }
                if let inverse = result.inverse { history.redo.append(inverse) }
            }
            self.historyByFolder[key] = history
            if let selection = result.selection { updateSelection(selection) }
            if let failure = result.failure { throw TransferError(detail: failure) }
        }
    }

    private func recordUndo(_ change: FileChange, in root: URL) {
        let key = WorktreeFileOperations.path(root)
        historyByFolder[key, default: History()].undo.append(change)
        historyByFolder[key]?.redo.removeAll()
    }

    func fileReplaced(_ previous: FileIdentity, with current: FileIdentity) {
        // An atomic save by Edit replaces the inode of the same document.
        for history in historyByFolder.values {
            for change in history.undo + history.redo {
                for item in change.items where item.identity == previous { item.identity = current }
            }
        }
    }

    private func rename(
        _ item: URL, to name: String, within root: URL, expected: HistoryItem? = nil
    ) async throws -> (transfer: WorktreeFileOperations.Transfer, identity: FileIdentity)? {
        let destination = item.deletingLastPathComponent().appending(path: name)
        return try await app.performWorktreeMutation(affecting: [item, destination]) {
            let identity = expected?.identity
            let result = try await Task.detached(priority: .userInitiated) {
                try WorktreeFileOperations.rename(item, to: name, within: root, expected: identity)
            }.value
            if let result { retarget(result.transfer, revealInWorktree: expected == nil) }
            return result
        }
    }

    private func execute(_ change: FileChange, within root: URL) async throws -> ChangeResult {
        switch change {
        case .rename(let item, let destination):
            let completed = try await rename(item.url, to: destination.lastPathComponent, within: root, expected: item)
            return ChangeResult(
                inverse: completed.map {
                    .rename(from: HistoryItem($0.transfer.destination, identity: $0.identity), to: $0.transfer.source)
                },
                selection: completed.map { .renamed($0.transfer) }
            )
        case .trash(let items, let selection):
            return try await moveToTrash(items.map(\.url), selectingOnRestore: selection, within: root, expected: items)
        case .restore(let moves, let selection):
            let result = try await app.performWorktreeMutation(affecting: moves.flatMap { [$0.original, $0.trashed.url] }) {
                let transfers = moves.map {
                    (transfer: WorktreeFileOperations.Transfer(source: $0.original, destination: $0.trashed.url),
                     identity: $0.trashed.identity)
                }
                return await Task.detached(priority: .userInitiated) {
                    WorktreeFileOperations.restoreTrashed(transfers, within: root)
                }.value
            }
            let restored = result.completed.map(\.source)
            let completed = Set(restored)
            let remaining = moves.filter { !completed.contains($0.original) }
            let restoredItems = moves.filter { completed.contains($0.original) }.map {
                HistoryItem($0.original, identity: $0.trashed.identity)
            }
            let (restoredSelection, remainingSelection) = splitSelection(selection, within: restored)
            return ChangeResult(
                inverse: restoredItems.isEmpty ? nil : .trash(restoredItems, selectingOnRestore: restoredSelection),
                remaining: remaining.isEmpty ? nil : .restore(remaining, selecting: remainingSelection),
                failure: result.failure, selection: restoredSelection.isEmpty ? nil : .restored(restoredSelection)
            )
        }
    }

    private func moveToTrash(
        _ items: [URL], selectingOnRestore selection: [URL], within root: URL, expected: [HistoryItem] = []
    ) async throws -> ChangeResult {
        let targets = try await Task.detached(priority: .userInitiated) {
            try WorktreeFileOperations.trashTargets(items, within: root)
        }.value
        return try await app.performWorktreeMutation(affecting: targets) {
            let known = Dictionary(uniqueKeysWithValues: expected.map { (WorktreeFileOperations.path($0.url), $0.identity) })
            let verified = try await Task.detached(priority: .userInitiated) {
                try targets.map { target in
                    let identity = try WorktreeFileOperations.itemIdentity(at: target, expected: known[WorktreeFileOperations.path(target)])
                    return (url: target, identity: identity)
                }
            }.value
            let result = try await recycle(targets)
            app.removeNavigationFiles(under: result.completed.map(\.source))
            for move in result.completed {
                for document in app.documents { document.detachTrashedFile(at: move.source) }
            }
            let identities = Dictionary(uniqueKeysWithValues: verified.map { ($0.url, $0.identity) })
            let recoverable = await Task.detached(priority: .userInitiated) {
                result.completed.compactMap { move -> (WorktreeFileOperations.Transfer, FileIdentity)? in
                    guard let original = identities[move.source],
                          let trashed = try? WorktreeFileOperations.itemIdentity(at: move.destination),
                          trashed == original || trashed.device != original.device else { return nil }
                    return (move, trashed)
                }
            }.value
            let restorations = recoverable.map { move, identity in
                Restoration(original: move.source, trashed: HistoryItem(move.destination, identity: identity))
            }
            let removed = result.completed.map(\.source)
            let completed = Set(removed)
            let remaining = verified.filter { !completed.contains($0.url) }.map { HistoryItem($0.url, identity: $0.identity) }
            let (restoredSelection, remainingSelection) = splitSelection(selection, within: removed)
            let failure = result.failure ?? (restorations.count == removed.count ? nil : "Some items moved to the Trash could not be identified for Undo.")
            return ChangeResult(
                inverse: restorations.isEmpty ? nil : .restore(restorations, selecting: restoredSelection),
                remaining: remaining.isEmpty ? nil : .trash(remaining, selectingOnRestore: remainingSelection),
                failure: failure, selection: removed.isEmpty ? nil : .removed(removed)
            )
        }
    }

    private func splitSelection(_ selection: [URL], within items: [URL]) -> (matched: [URL], remaining: [URL]) {
        let paths = Set(items.map(WorktreeFileOperations.path))
        var matched: [URL] = []
        var remaining: [URL] = []
        for item in selection {
            if WorktreeFileOperations.isUnderSelection(item, paths: paths) {
                matched.append(item)
            } else {
                remaining.append(item)
            }
        }
        return (matched, remaining)
    }

    private func recycle(_ targets: [URL]) async throws -> WorktreeFileOperations.TransferResult {
        if let recycleForCheck { return try await recycleForCheck(targets) }
        guard !app.isAgentCheck else { throw NameError.unavailable }
        // The throwing overload discards successful moves when Finder reports a partial failure.
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(targets) { relocated, error in
                let completed = targets.compactMap { source in
                    relocated[source].map { WorktreeFileOperations.Transfer(source: source, destination: $0) }
                }
                let failure = error?.localizedDescription ??
                    (completed.count == targets.count ? nil : "Some selected items could not be moved to the Trash.")
                continuation.resume(returning: .init(completed: completed, failure: failure))
            }
        }
    }

    private func retarget(_ move: WorktreeFileOperations.Transfer, revealInWorktree: Bool = true) {
        app.retargetNavigation(from: move.source, to: move.destination)
        app.fileWordWrap.move(from: move.source, to: move.destination)
        app.fileIndentation.move(from: move.source, to: move.destination)
        for document in app.documents {
            document.retargetMovedFile(from: move.source, to: move.destination, revealInWorktree: revealInWorktree)
        }
    }

    @discardableResult
    private func run(_ title: String, within root: URL,
                     operation: @MainActor @escaping (DocumentWindow) async throws -> Void) -> Bool {
        guard let document = operationDocument(in: root) else { return false }
        working = true
        Task {
            defer {
                working = false
                refresh()
            }
            do {
                try await operation(document)
            } catch {
                if app.documents.contains(where: { $0 === document }) {
                    await document.showError(title, detail: error.localizedDescription)
                }
            }
        }
        return true
    }

    private func operationDocument(in root: URL) -> DocumentWindow? {
        guard canWork, !app.isQuitting, let document,
              document.folderURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(root),
              app.documents.contains(where: { $0 === document }) else { return nil }
        return document
    }

    private enum NameError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Edit is busy or this folder is no longer open." }
    }

    private struct TransferError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
}
