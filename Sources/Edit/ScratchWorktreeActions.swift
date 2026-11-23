import AppKit

extension ScratchFile {
    var filenameURL: URL { URL(filePath: "/").appending(path: name, directoryHint: .notDirectory) }
}

@MainActor
final class ScratchWorktreeActions {
    private enum Change {
        case metadata([ScratchFile], name: String)
        case trash([ScratchFile])
        case restore([TrashedScratch])

        var name: String {
            switch self {
            case .metadata(_, let name): name
            case .trash, .restore: "Move to Trash"
            }
        }
    }

    private weak var document: DocumentWindow?
    private unowned let app: Edit
    private let commands: SidebarFileCommands
    private var undoChanges: [Change] = []
    private var redoChanges: [Change] = []

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        commands = SidebarFileCommands(document: document, app: app)
    }

    var canWork: Bool {
        guard let document else { return false }
        return !app.isPerformingScratchOperation && !app.isQuitting && document.canReplaceBuffer &&
            app.documents.contains { $0 === document }
    }

    func menu(
        file: ScratchFile?, folderPath: String?, selection: [ScratchFile], categories: [String?],
        rename: @escaping () -> Void, create: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let file {
            let files = selection.isEmpty ? [file] : selection
            commands.addFileItems(to: menu, for: app.scratchStore.url(for: file), isDirectory: false,
                                  copySelection: files.map(app.scratchStore.url(for:)))
            menu.addItem(.separator())
            menu.addItem(commands.action("Rename…", enabled: canWork, body: rename))
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            moveItem.submenu = moveMenu(for: files, categories: categories)
            moveItem.isEnabled = canWork
            menu.addItem(moveItem)
            commands.addTrashItem(to: menu, enabled: canWork, perform: remove)
        } else {
            if let folderPath {
                let directory = URL(filePath: folderPath, directoryHint: .isDirectory)
                commands.addFileItems(to: menu, for: directory, isDirectory: true, copySelection: [directory])
                menu.addItem(.separator())
            }
            let canPaste = !app.isAgentCheck && !SidebarFileCommands.fileURLs(on: .general).isEmpty
            menu.addItem(commands.action("Paste", enabled: canWork && canPaste) { [weak self] in
                _ = self?.transfer(SidebarFileCommands.fileURLs(on: .general), to: folderPath)
            })
            menu.addItem(.separator())
            addCreationItems(to: menu, create: create)
        }
        return menu
    }

    func addCreationItems(to menu: NSMenu, create: @escaping () -> Void) {
        menu.addItem(commands.action("New File…", enabled: canWork, body: create))
    }

    private func moveMenu(for files: [ScratchFile], categories: [String?]) -> NSMenu {
        let menu = NSMenu(title: "Move to")
        menu.autoenablesItems = false
        for path in categories {
            let title = path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Global"
            menu.addItem(commands.action(title, enabled: canWork && files.contains { $0.folderPath != path }) { [weak self] in
                _ = self?.move(files, to: path, copying: false)
            })
        }
        menu.addItem(.separator())
        menu.addItem(commands.action("Choose Folder…", enabled: canWork) { [weak self] in
            Task { [weak self] in
                guard let self, let path = await document?.chooseScratchFolder() else { return }
                _ = move(files, to: path, copying: false)
            }
        })
        return menu
    }

    func commitName(_ name: String, file: ScratchFile?, folderPath: String?) async throws -> ScratchFile {
        guard canWork, app.beginScratchOperation() else { throw CocoaError(.fileWriteUnknown) }
        defer { app.endScratchOperation() }
        if let file {
            let before = try await app.scratchStore.file(at: app.scratchStore.url(for: file)) ?? file
            let renamed = try await app.scratchStore.rename(file.id, to: name)
            if before != renamed {
                record(.metadata([before], name: "Rename"))
                app.scratchesDidChange(updated: [renamed])
            }
            return renamed
        }
        let folder = folderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        let (created, _) = try await app.scratchStore.create(name: name, text: "", format: FileFormat(), in: folder)
        app.scratchesDidChange()
        return created
    }

    @discardableResult
    func move(_ files: [ScratchFile], to folderPath: String?, copying: Bool) -> Bool {
        guard !files.isEmpty else { return false }
        if copying { return transfer(files.map(app.scratchStore.url(for:)), to: folderPath) }
        let ids = Set(files.map(\.id))
        return run("Could Not Move Scratches") { [self] in
            let before = try await app.scratchStore.files().filter { ids.contains($0.id) }
            let moved = try await app.scratchStore.move(files.map(\.id), to: folderPath)
            guard !moved.isEmpty else { return }
            let movedIDs = Set(moved.map(\.id))
            record(.metadata(before.filter { movedIDs.contains($0.id) }, name: "Move"))
            app.scratchesDidChange(updated: moved)
        }
    }

    @discardableResult
    func transfer(_ urls: [URL], to folderPath: String?) -> Bool {
        guard !urls.isEmpty else { return false }
        return run("Could Not Copy Files to Scratches") { [self] in
            _ = try await app.scratchStore.importFiles(urls, into: folderPath)
            app.scratchesDidChange()
        }
    }

    func copy(_ files: [ScratchFile]) {
        SidebarFileCommands.copy(files.map(app.scratchStore.url(for:)))
    }

    func trash(_ files: [ScratchFile], didRemove: @escaping () -> Void) {
        guard !files.isEmpty else { return }
        run("Could Not Move Scratches to Trash") { [self] in
            let trashed = try await trash(files)
            if !trashed.isEmpty {
                record(.restore(trashed))
                didRemove()
            }
        }
    }

    private func trash(_ files: [ScratchFile]) async throws -> [TrashedScratch] {
        let urls = files.map(app.scratchStore.url(for:))
        let trashed = try await app.performWorktreeMutation(affecting: urls) {
            let records = try await self.app.scratchStore.trash(files.map(\.id))
            for record in records {
                let url = self.app.scratchStore.url(for: record.file)
                for document in self.app.documents { document.detachTrashedFile(at: url) }
            }
            return records
        }
        app.scratchesDidChange()
        return trashed
    }

    func undoActionName(redo: Bool) -> String? {
        guard canWork else { return nil }
        return (redo ? redoChanges.last : undoChanges.last)?.name
    }

    func undo(redo: Bool, reveal: @escaping ([ScratchFile]) -> Void) {
        guard let change = redo ? redoChanges.last : undoChanges.last else { return }
        run("Could Not \(redo ? "Redo" : "Undo") \(change.name)") { [self] in
            let inverse: Change
            switch change {
            case .metadata(let records, let name):
                let ids = Set(records.map(\.id))
                let before = try await app.scratchStore.files().filter { ids.contains($0.id) }
                let updated = try await app.scratchStore.restoreMetadata(records)
                app.scratchesDidChange(updated: updated)
                reveal(updated)
                inverse = .metadata(before, name: name)
            case .restore(let records):
                let restored = try await app.scratchStore.restore(records)
                app.scratchesDidChange()
                reveal(restored)
                inverse = .trash(restored)
            case .trash(let files):
                inverse = .restore(try await trash(files))
            }
            if redo {
                redoChanges.removeLast()
                undoChanges.append(inverse)
            } else {
                undoChanges.removeLast()
                redoChanges.append(inverse)
            }
        }
    }

    private func record(_ change: Change) {
        undoChanges.append(change)
        redoChanges.removeAll()
    }

    @discardableResult
    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) -> Bool {
        guard canWork, app.beginScratchOperation() else { return false }
        Task {
            defer { app.endScratchOperation() }
            do { try await operation() }
            catch { await document?.showError(title, detail: error.localizedDescription) }
        }
        return true
    }
}
