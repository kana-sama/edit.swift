import AppKit
import UniformTypeIdentifiers

@MainActor
final class WorktreeActions: NSObject, NSMenuDelegate {
    enum NameRequest {
        case rename(URL)
        case create(in: URL, directory: Bool)
    }

    private weak var document: DocumentWindow?
    private unowned let app: Edit
    private let refresh: () -> Void
    private let editName: (NameRequest, URL) -> Void
    private let isHidden: (URL) -> Bool
    private let toggleHidden: (URL) -> Void
    private var working = false
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

    func menu(for item: URL, isDirectory: Bool, root: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inside = WorktreeFileOperations.contains(item, in: root)
        let editable = inside && WorktreeFileOperations.path(item) != WorktreeFileOperations.path(root)
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
        menu.addItem(action("Copy") { [weak self] in self?.copy([item]) })
        menu.addItem(action("Copy Path") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.path, forType: .string)
        })
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
            menu.addItem(action("Move to Trash", enabled: canWork) { [weak self] in self?.trash(item, within: root) })
        }
        return menu
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
            let destination = item.deletingLastPathComponent().appending(path: name)
            return try await app.performWorktreeMutation(affecting: [item, destination]) {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorktreeFileOperations.rename(item, to: name, within: root)
                }.value
                if let move { retarget(move) }
                return move?.destination ?? item
            }
        }
    }

    private func trash(_ item: URL, within root: URL) {
        guard !app.isAgentCheck else { return }
        run("Could Not Move “\(item.lastPathComponent)” to Trash", within: root) { _ in
            try await self.app.performWorktreeMutation(affecting: [item]) {
                let target = try await Task.detached(priority: .userInitiated) {
                    try WorktreeFileOperations.trashTarget(item, within: root)
                }.value
                let relocated = try await NSWorkspace.shared.recycle([target])
                guard !relocated.isEmpty else { throw CocoaError(.fileWriteUnknown) }
                for document in self.app.documents { document.detachTrashedFile(at: target) }
            }
        }
    }

    private func retarget(_ move: WorktreeFileOperations.Transfer) {
        for document in app.documents {
            document.retargetMovedFile(from: move.source, to: move.destination)
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

    private func action(_ title: String, enabled: Bool = true, body: @escaping () -> Void) -> NSMenuItem {
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
