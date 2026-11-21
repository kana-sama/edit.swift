import AppKit

@MainActor
final class DocumentTitleBar: NSObject, NSToolbarDelegate {
    static let folderItemIdentifier = NSToolbarItem.Identifier("Edit.FolderTitle")
    static let languageItemIdentifier = NSToolbarItem.Identifier("Edit.FileLanguage")
    static let fileItemIdentifier = NSToolbarItem.Identifier("Edit.FileTitle")
    static let itemIdentifiers = [folderItemIdentifier, languageItemIdentifier, fileItemIdentifier]

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private weak var folderButton: TitleBarButton?
    private weak var fileButton: TitleBarButton?
    private weak var languageButton: TitleBarButton?
    private weak var folderItem: NSToolbarItem?
    private var siblingRequest: Task<Void, Never>?

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
    }

    deinit { siblingRequest?.cancel() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        makeItem(identifier)
    }

    func makeItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard Self.itemIdentifiers.contains(identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = false
        item.autovalidates = false
        let button = TitleBarButton()
        button.isBordered = false

        switch identifier {
        case Self.folderItemIdentifier:
            item.label = "Folder"
            folderItem = item
            folderButton = button
            configureName(button, maximumWidth: 160)
            button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            button.imagePosition = .imageTrailing
            button.onPress = { [weak self] button in self?.showFolderMenu(from: button) }
        case Self.fileItemIdentifier:
            item.label = "File"
            fileButton = button
            configureName(button, maximumWidth: 280)
            button.onPress = { [weak self] button in self?.showSiblingMenu(from: button) }
        default:
            item.label = "Change Language Mode"
            item.visibilityPriority = .user
            languageButton = button
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            button.setAccessibilityLabel(item.label)
            button.toolTip = item.label
            button.onPress = { [weak self] _ in self?.showLanguagePicker() }
        }

        item.view = button
        update()
        return item
    }

    private func configureName(_ button: NSButton, maximumWidth: CGFloat) {
        button.font = .titleBarFont(ofSize: 0)
        button.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth).isActive = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func update() {
        if let folder = document.folderURL {
            let name = folder.lastPathComponent
            folderButton?.title = name.isEmpty ? folder.path : name
            folderButton?.toolTip = folder.path
            folderItem?.isHidden = false
        } else {
            folderItem?.isHidden = true
        }
        fileButton?.title = document.displayName
        fileButton?.toolTip = document.fileURL?.path ?? document.displayName
        if document.fileURL == nil && document.manualSyntaxLanguage == nil {
            languageButton?.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        } else {
            languageButton?.image = FileIcons.image(for: document.fileURL, appearance: document.window.effectiveAppearance,
                                                   language: document.manualSyntaxLanguage?.iconIdentifier)
        }
    }

    func recentFoldersMenu() -> NSMenu {
        let menu = NSMenu(title: "Recent Folders")
        let current = document.folderURL?.path
        for folder in app.recentFiles.folders.prefix(10) {
            let item = openItem(folder.displayPath, at: folder.url, selected: folder.canonicalURL.path == current)
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    func siblingFilesMenu(_ files: [URL], current file: URL) -> NSMenu {
        let menu = NSMenu(title: "Files in This Folder")
        for url in files {
            let item = openItem(url.lastPathComponent, at: url, selected: url.path == file.path)
            let language = url.path == file.path ? document.manualSyntaxLanguage : app.syntaxOverrides.language(for: url)
            item.image = FileIcons.image(for: url, appearance: document.window.effectiveAppearance,
                                        language: language?.iconIdentifier)
            menu.addItem(item)
        }
        return menu
    }

    nonisolated static func loadSiblingFiles(of file: URL) async -> [URL] {
        let worker = Task.detached(priority: .userInitiated) { siblingFiles(of: file) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func siblingFiles(of file: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let directory = file.deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return [] }
        var files: [URL] = []
        for url in urls {
            if Task.isCancelled { return [] }
            guard !FolderFileSearch.isExcludedFile(url), let info = try? url.resourceValues(forKeys: keys) else { continue }
            if info.isRegularFile == true || (info.isSymbolicLink == true && FileIdentity.at(url) != nil) {
                files.append(url)
            }
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func openItem(_ title: String, at url: URL, selected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.state = selected ? .on : .off
        return item
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { [app, document] in await app.openFiles([url], in: document) }
    }

    private func showFolderMenu(from button: TitleBarButton) {
        siblingRequest?.cancel()
        guard document.canReplaceBuffer else { return }
        popUp(recentFoldersMenu(), from: button)
    }

    private func showSiblingMenu(from button: TitleBarButton) {
        siblingRequest?.cancel()
        guard document.canReplaceBuffer, let file = document.fileURL else { return }
        siblingRequest = Task { [weak self, weak button] in
            let files = await Self.loadSiblingFiles(of: file)
            guard !Task.isCancelled, let self, let button, document.fileURL == file,
                  document.canReplaceBuffer, document.window.isKeyWindow else { return }
            popUp(siblingFilesMenu(files, current: file), from: button)
        }
    }

    private func showLanguagePicker() {
        siblingRequest?.cancel()
        app.showLanguageModes(in: document)
    }

    private func popUp(_ menu: NSMenu, from button: TitleBarButton) {
        guard !menu.items.isEmpty, button.window === document.window else { return }
        let y = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: y), in: button)
    }
}

@MainActor
private final class TitleBarButton: NSButton {
    var onPress: ((TitleBarButton) -> Void)?

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(press(_:))
    }

    required init?(coder: NSCoder) { fatalError("Title buttons are programmatically constructed") }

    @objc private func press(_ sender: Any?) {
        onPress?(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        onPress?(self)
    }
}
