import AppKit
import UniformTypeIdentifiers

@MainActor
final class SidebarFileCommands: NSObject, NSMenuDelegate {
    private weak var document: DocumentWindow?
    private unowned let app: Edit

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
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
        menu.addItem(action("Copy") { Self.copy(copySelection) })
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

    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func canPasteFiles() -> Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: fileURLReadingOptions)
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLReadingOptions) as? [URL] ?? []
    }

    static func copy(_ urls: [URL], onto pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
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
