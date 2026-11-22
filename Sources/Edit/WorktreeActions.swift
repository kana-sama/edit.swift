import AppKit
import UniformTypeIdentifiers

@MainActor
final class WorktreeActions: NSObject, NSMenuDelegate {
    enum NameRequest {
        case rename(URL)
        case create(in: URL, directory: Bool)
    }

    enum SelectionChange {
        case removed([URL])
        case restored([URL])
        case renamed(WorktreeFileOperations.Transfer)
    }

    private enum FileChange {
        case rename(WorktreeFileOperations.Transfer)
        case trash([URL], selectingOnRestore: [URL])
        case restore([WorktreeFileOperations.Transfer], selecting: [URL])

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
        addFileItems(to: menu, for: item, isDirectory: isDirectory, copySelection: [item])
        if inside && isDirectory {
            let canPaste = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: Self.fileURLReadingOptions)
            menu.addItem(action("Paste", enabled: canWork && canPaste) { [weak self] in
                _ = self?.paste(into: item, within: root)
            })
            menu.addItem(.separator())
            addCreationItems(to: menu, in: item, root: root)
        }
        if editable {
            menu.addItem(.separator())
            menu.addItem(action("Rename…", enabled: canWork) { [weak self] in self?.editName(.rename(item), root) })
            menu.addItem(action(isHidden(item) ? "Unhide" : "Hide") { [weak self] in self?.toggleHidden(item) })
            addTrashItem(to: menu, enabled: canTrash(selection, in: root), perform: trashSelection)
        }
        return menu
    }

    func addFileItems(to menu: NSMenu, for item: URL, isDirectory: Bool, copySelection: [URL]) {
        menu.addItem(action("Show in Finder") { [weak self] in
            guard let self, !app.isAgentCheck else { return }
            NSWorkspace.shared.activateFileViewerSelecting([item])
        })
        if !isDirectory {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = OpenWithMenu(file: item)
            submenu.delegate = self
            submenu.addItem(action("Other…") { [weak self] in self?.chooseApplication(for: item) })
            openWith.submenu = submenu
            menu.addItem(openWith)
        }

        menu.addItem(.separator())
        menu.addItem(action("Copy") { [weak self] in self?.copy(copySelection) })
        menu.addItem(action("Copy Path") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.path, forType: .string)
        })
    }

    func addTrashItem(to menu: NSMenu, enabled: Bool, perform: @escaping () -> Void) {
        let trash = action("Move to Trash", enabled: enabled, body: perform)
        trash.keyEquivalent = "\u{7f}"
        trash.keyEquivalentModifierMask = .command
        menu.addItem(trash)
    }

    func addCreationItems(to menu: NSMenu, in directory: URL, root: URL) {
        menu.addItem(action("New File…", enabled: canWork) { [weak self] in
            self?.editName(.create(in: directory, directory: false), root)
        })
        menu.addItem(action("New Folder…", enabled: canWork) { [weak self] in
            self?.editName(.create(in: directory, directory: true), root)
        })
    }

    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLReadingOptions) as? [URL] ?? []
    }

    func copy(_ urls: [URL], onto pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    @discardableResult
    func paste(into directory: URL, within root: URL) -> Bool {
        transfer(Self.fileURLs(on: .general), into: directory, move: false, within: root)
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let openWith = menu as? OpenWithMenu, !openWith.loaded else { return }
        openWith.loaded = true
        let file = openWith.file
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: file)
        let apps = workspace.urlsForApplications(toOpen: file)
        for (index, application) in apps.enumerated() {
            let bundle = Bundle(url: application)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? application.deletingPathExtension().lastPathComponent
            let option = action(application == preferred ? "\(name) (Default)" : name) { [weak self] in
                self?.open(file, with: application)
            }
            let image = workspace.icon(forFile: application.path)
            image.size = NSSize(width: 16, height: 16)
            option.image = image
            menu.insertItem(option, at: index)
        }
        if !apps.isEmpty { menu.insertItem(.separator(), at: apps.count) }
    }

    private func open(_ file: URL, with application: URL) {
        guard let document, !app.isAgentCheck, !app.isQuitting else { return }
        Task { [app] in
            let chosen = Bundle(url: application)
            if let identifier = Bundle.main.bundleIdentifier, identifier == chosen?.bundleIdentifier {
                await app.openFiles([file], in: document)
            } else {
                do {
                    _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init())
                } catch {
                    await document.showError("Could Not Open “\(file.lastPathComponent)”", detail: error.localizedDescription)
                }
            }
        }
    }

    private func chooseApplication(for file: URL) {
        guard let document, document.window.attachedSheet == nil, !app.isAgentCheck, !app.isQuitting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.beginSheetModal(for: document.window) { [weak self] result in
            panel.orderOut(nil)
            if result == .OK, let application = panel.url { self?.open(file, with: application) }
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
            guard let move = try await rename(item, to: name, within: root) else {
                return item
            }
            recordUndo(.rename(.init(source: move.destination, destination: move.source)), in: root)
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
            let result = try await self.execute(.trash(items, selectingOnRestore: items), within: root)
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

    private func rename(
        _ item: URL, to name: String, within root: URL, revealInWorktree: Bool = true
    ) async throws -> WorktreeFileOperations.Transfer? {
        let destination = item.deletingLastPathComponent().appending(path: name)
        return try await app.performWorktreeMutation(affecting: [item, destination]) {
            let result = try await Task.detached(priority: .userInitiated) {
                try WorktreeFileOperations.rename(item, to: name, within: root)
            }.value
            if let result { retarget(result, revealInWorktree: revealInWorktree) }
            return result
        }
    }

    private func execute(_ change: FileChange, within root: URL) async throws -> ChangeResult {
        switch change {
        case .rename(let move):
            let completed = try await rename(
                move.source, to: move.destination.lastPathComponent, within: root, revealInWorktree: false
            )
            return ChangeResult(
                inverse: completed.map { .rename(.init(source: $0.destination, destination: $0.source)) },
                selection: completed.map(SelectionChange.renamed)
            )
        case .trash(let items, let selection):
            let targets = try await Task.detached(priority: .userInitiated) {
                try WorktreeFileOperations.trashTargets(items, within: root)
            }.value
            let result = try await app.performWorktreeMutation(affecting: targets) {
                let result = try await recycle(targets)
                for move in result.completed {
                    for document in app.documents { document.detachTrashedFile(at: move.source) }
                }
                return result
            }
            let removed = result.completed.map(\.source)
            let completed = Set(removed.map(WorktreeFileOperations.path))
            let remaining = targets.filter { !completed.contains(WorktreeFileOperations.path($0)) }
            let (restoredSelection, remainingSelection) = splitSelection(selection, within: removed)
            return ChangeResult(
                inverse: removed.isEmpty ? nil : .restore(result.completed, selecting: restoredSelection),
                remaining: remaining.isEmpty ? nil : .trash(remaining, selectingOnRestore: remainingSelection),
                failure: result.failure, selection: removed.isEmpty ? nil : .removed(removed)
            )
        case .restore(let moves, let selection):
            let result = try await app.performWorktreeMutation(affecting: moves.map(\.source)) {
                await Task.detached(priority: .userInitiated) {
                    WorktreeFileOperations.restoreTrashed(moves, within: root)
                }.value
            }
            let restored = result.completed.map(\.source)
            let completed = Set(restored)
            let remaining = moves.filter { !completed.contains($0.source) }
            let (restoredSelection, remainingSelection) = splitSelection(selection, within: restored)
            return ChangeResult(
                inverse: restored.isEmpty ? nil : .trash(restored, selectingOnRestore: restoredSelection),
                remaining: remaining.isEmpty ? nil : .restore(remaining, selecting: remainingSelection),
                failure: result.failure, selection: restoredSelection.isEmpty ? nil : .restored(restoredSelection)
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

    func action(_ title: String, enabled: Bool = true, body: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = body
        return item
    }

    @objc private func performAction(_ item: NSMenuItem) {
        (item.representedObject as? () -> Void)?()
    }

    private struct TransferError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
}

private final class OpenWithMenu: NSMenu {
    let file: URL
    var loaded = false

    init(file: URL) {
        self.file = file
        super.init(title: "Open With")
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError("Open With menus are programmatically constructed") }
}
