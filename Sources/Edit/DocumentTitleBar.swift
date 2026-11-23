import AppKit

@MainActor
final class DocumentTitleBar: NSObject, NSToolbarDelegate {
    static let folderItemIdentifier = NSToolbarItem.Identifier("Edit.FolderTitle")
    static let fileItemIdentifier = NSToolbarItem.Identifier("Edit.FileTitle")
    static let terminalItemIdentifier = NSToolbarItem.Identifier("Edit.Terminal.Title")
    static let sidebarItemIdentifier = NSToolbarItem.Identifier("Edit.SidebarTitle")
    static let terminalItemIdentifiers: [NSToolbarItem.Identifier] = [.inspectorTrackingSeparator, terminalItemIdentifier]
    private static let sidebarItemIdentifiers: [NSToolbarItem.Identifier] = [sidebarItemIdentifier, .sidebarTrackingSeparator]
    private static let itemIdentifiers = [folderItemIdentifier, fileItemIdentifier]
    private static let leadingInset: CGFloat = 8

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private weak var folderLabel: TitleBarLabel?
    private weak var fileLabel: TitleBarLabel?
    private weak var fileTitle: NSStackView?
    private weak var languageIcon: TitleBarIcon?
    private weak var folderItem: NSToolbarItem?
    private weak var fileItem: NSToolbarItem?
    private weak var folderWidth: NSLayoutConstraint?
    private weak var fileWidth: NSLayoutConstraint?
    private weak var sidebar: DocumentSidebar?
    private var sidebarHeaderVisible = false
    private var terminalHeaderVisible = false
    private var terminalDocked = false
    private let fullScreenDividers = TitleBarDividers(frame: .zero)
    private var isFullScreen = false
    private var siblingRequest: Task<Void, Never>?
    private(set) var agentContextMenu: NSMenu?
    private(set) lazy var toolbar = makeToolbar()

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
    }

    deinit { siblingRequest?.cancel() }

    private func makeToolbar() -> NSToolbar {
        // A right-docked terminal changes this window's items independently of other windows.
        let toolbar = NSToolbar(identifier: .init("Edit.Document.\(UUID().uuidString)"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    func installSidebar(_ sidebar: DocumentSidebar) {
        self.sidebar = sidebar
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) else { return }
        toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: 0)
    }

    func setSidebarHeaderVisible(_ visible: Bool) {
        guard sidebarHeaderVisible != visible else { return }
        sidebarHeaderVisible = visible
        updateItems {
            changeItem(Self.sidebarItemIdentifier, in: toolbar, visible: visible, at: 0)
        }
    }

    func setTerminalDocked(_ docked: Bool) {
        guard terminalDocked != docked else { return }
        terminalDocked = docked
        updateItems {
            if docked {
                changeItem(.inspectorTrackingSeparator, in: toolbar, visible: true, at: toolbar.items.count)
                updateTerminalHeader(visible: true)
            } else {
                updateTerminalHeader(visible: false)
                changeItem(.inspectorTrackingSeparator, in: toolbar, visible: false, at: 0)
            }
        }
    }

    func setTerminalHeaderVisible(_ visible: Bool) {
        updateItems { updateTerminalHeader(visible: visible) }
    }

    private func updateTerminalHeader(visible: Bool) {
        terminalHeaderVisible = visible
        changeItem(Self.terminalItemIdentifier, in: toolbar, visible: visible, at: toolbar.items.count)
    }

    private func changeItem(_ identifier: NSToolbarItem.Identifier, in toolbar: NSToolbar, visible: Bool, at index: Int) {
        let item = toolbar.items.first { $0.itemIdentifier == identifier }
        if visible, item == nil {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        } else if !visible, let item {
            item.view?.isHidden = true
            toolbar.removeItem(identifier: identifier)
        }
    }

    // The title row can live in an AppKit companion window in full screen.
    var toolbarWindow: NSWindow? { fileTitle?.window }

    private func updateItems(_ update: () -> Void) {
        PanelLayout.withoutAnimation {
            update()
            let window = document.window
            window.layoutIfNeeded()
            if let host = toolbarWindow, host !== window { host.layoutIfNeeded() }
        }
    }

    private func finishSidebarHeaderLayout() {
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == Self.sidebarItemIdentifier }),
              !item.isHidden else { return }
        PanelLayout.finishHeaderLayout(item, in: document.window)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let leading: [NSToolbarItem.Identifier] = sidebar == nil ? [] :
            sidebarHeaderVisible ? Self.sidebarItemIdentifiers : [.sidebarTrackingSeparator]
        let trailing: [NSToolbarItem.Identifier] = terminalDocked
            ? (terminalHeaderVisible ? Self.terminalItemIdentifiers : [.inspectorTrackingSeparator]) : []
        return leading + Self.itemIdentifiers + trailing
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.sidebarItemIdentifiers + Self.itemIdentifiers + Self.terminalItemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.sidebarItemIdentifier { return sidebar?.makeSidebarHeader() }
        if identifier == Self.terminalItemIdentifier { return document.makeTerminalTitleItem() }
        guard Self.itemIdentifiers.contains(identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = false
        item.autovalidates = false

        if identifier == Self.folderItemIdentifier {
            item.label = "Folder"
            let label = makeLabel()
            folderWidth = constrainWidth(of: label)
            folderLabel = label
            folderItem = item
            let title = NSStackView(views: [label])
            title.alignment = .centerY
            // AppKit measures the item even when the folder label is empty and hidden.
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
            title.edgeInsets.left = Self.leadingInset
            item.view = title
        } else {
            item.label = "File"
            item.visibilityPriority = .high
            let label = makeLabel()
            fileWidth = constrainWidth(of: label)
            let icon = TitleBarIcon()
            icon.imageScaling = .scaleProportionallyDown
            icon.setAccessibilityLabel("Change Language Mode")
            icon.toolTip = "Change Language Mode"
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
            fileLabel = label
            fileItem = item
            languageIcon = icon

            let title = FileTitleView()
            title.addArrangedSubview(icon)
            title.addArrangedSubview(label)
            title.alignment = .centerY
            title.spacing = 2
            title.setVisibilityPriority(.detachOnlyIfNecessary, for: label)
            title.onLayout = { [weak self] in
                guard let self, isFullScreen else { return }
                updateFullScreenDividers()
            }
            fileTitle = title
            item.view = title
        }

        update()
        return item
    }

    private func makeLabel() -> TitleBarLabel {
        let label = TitleBarLabel(labelWithString: "")
        label.font = .titleBarFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func constrainWidth(of label: NSTextField) -> NSLayoutConstraint {
        let width = label.widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        return width
    }

    func resize() {
        fitLabels()
        if isFullScreen { updateFullScreenDividers() }
    }

    func setFullScreen(_ enabled: Bool) {
        isFullScreen = enabled
        if enabled { updateFullScreenDividers() }
        else { fullScreenDividers.removeFromSuperview() }
        finishSidebarHeaderLayout()
    }

    private func updateFullScreenDividers() {
        let window = document.window
        guard let fileTitle, let toolbarWindow = fileTitle.window,
              let split = window.contentViewController as? NSSplitViewController else {
            fullScreenDividers.removeFromSuperview()
            return
        }

        // AppKit can move the toolbar away from the window that owns the split.
        // Attach the continuation to the common host of the document and sidebar headers.
        let host = toolbar.items.reduce(fileTitle as NSView) { commonAncestor, item in
            guard item.itemIdentifier == Self.sidebarItemIdentifier || item.itemIdentifier == Self.terminalItemIdentifier,
                  let view = item.view, view.window === toolbarWindow, !item.isHidden else { return commonAncestor }
            return commonAncestor.ancestorShared(with: view) ?? commonAncestor
        }
        guard host !== fileTitle else {
            fullScreenDividers.removeFromSuperview()
            return
        }
        let strokes: [NSRect] = split.splitViewItems.compactMap { item in
            let pane = item.viewController.view
            guard !item.isCollapsed, pane.window === window, pane.bounds.width > 0 else { return nil }
            let bounds = pane.convert(pane.bounds, to: nil)
            let edge: CGFloat
            let pixelOffset: CGFloat
            // Continue the visible glass edge on the sidebar's side of the gutter.
            switch item.behavior {
            case .sidebar: (edge, pixelOffset) = (bounds.maxX, -1)
            case .inspector: (edge, pixelOffset) = (bounds.minX, 0)
            default: return nil
            }
            let screen = window.convertToScreen(NSRect(x: edge, y: 0, width: 0, height: 0))
            let backingEdge = toolbarWindow.convertToBacking(toolbarWindow.convertFromScreen(screen)).minX.rounded()
            let pixel = NSRect(x: backingEdge + pixelOffset, y: 0, width: 1, height: 1)
            let toolbarFrame = host.convert(toolbarWindow.convertFromBacking(pixel), from: nil)
            return NSRect(x: toolbarFrame.minX - host.bounds.minX, y: 0,
                          width: toolbarFrame.width, height: host.bounds.height)
        }
        guard !strokes.isEmpty else {
            fullScreenDividers.removeFromSuperview()
            return
        }
        if fullScreenDividers.superview !== host {
            fullScreenDividers.removeFromSuperview()
            host.addSubview(fullScreenDividers, positioned: .above, relativeTo: nil)
        }
        if fullScreenDividers.frame != host.bounds { fullScreenDividers.frame = host.bounds }
        fullScreenDividers.update(strokes, color: split.splitView.dividerColor)
    }

    private func fitLabels() {
        let window = document.window
        let editor = document.editorContentView
        let exposed = editor.window === window ? editor.convert(editor.safeAreaRect, to: nil) : window.contentLayoutRect
        let zoom = window.standardWindowButton(.zoomButton)
        let controls = zoom.map { $0.convert($0.bounds, to: nil).maxX + 8 } ?? 84
        // Keep the icon and a compact file name inside the editor pane as the divider moves.
        let width = max(0, floor(exposed.maxX - max(exposed.minX, controls) - 40))
        // Explicit widths let the toolbar grow the labels again after compressing them.
        let folder = document.folderURL == nil ? 0 : min(folderLabel?.intrinsicContentSize.width ?? 0, 160, width * 0.4)
        let file = min(fileLabel?.intrinsicContentSize.width ?? 0, width - folder)
        if folderWidth?.constant != folder { folderWidth?.constant = folder }
        if fileWidth?.constant != file { fileWidth?.constant = file }
    }

    func update() {
        if let folder = document.folderURL {
            let name = folder.lastPathComponent
            folderLabel?.stringValue = name.isEmpty ? folder.path : name
            folderLabel?.toolTip = folder.path
            folderItem?.isHidden = false
        } else {
            folderItem?.isHidden = true
        }
        fileTitle?.edgeInsets.left = document.folderURL == nil ? Self.leadingInset : 7
        fileItem?.isHidden = document.showsEmptyFolder
        fileLabel?.stringValue = document.displayName
        fileLabel?.toolTip = document.displayedFileURL?.path ?? document.displayName
        fitLabels()
        if document.displayedFileURL == nil && document.manualSyntaxLanguage == nil {
            languageIcon?.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        } else {
            languageIcon?.image = FileIcons.image(for: document.fileIconURL, appearance: document.window.effectiveAppearance,
                                                  language: document.manualSyntaxLanguage?.iconIdentifier)
        }
    }

    func recentFoldersMenu() -> NSMenu {
        let menu = NSMenu(title: "Recent Folders")
        let current = document.folderURL?.path
        let icon = NSImage(named: NSImage.folderName)?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        for folder in app.recentFiles.folders.prefix(10) {
            let item = openItem(folder.displayPath, at: folder.url, selected: folder.canonicalURL.path == current)
            item.image = icon
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
        item.preferredImageVisibility = .visible
        return item
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { [app, document] in await app.openFiles([url], in: document) }
    }

    func handleSecondaryClick(at location: NSPoint, in window: NSWindow) -> Bool {
        guard document.window.attachedSheet == nil else { return false }

        func hits(_ view: NSView) -> Bool {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let point = view.convert(location, from: nil)
            return view.bounds.contains(point) && view.visibleRect.contains(point)
        }

        let show: () -> Void
        if let folderLabel, document.folderURL != nil, hits(folderLabel) {
            show = { self.showFolderMenu(from: folderLabel) }
        } else if let languageIcon, document.hasTextDocument, hits(languageIcon) {
            show = { self.showLanguagePicker() }
        } else if let fileLabel, document.displayedFileURL != nil, hits(fileLabel) {
            show = { self.showSiblingMenu(from: fileLabel) }
        } else {
            return false
        }
        app.dismissControlForTitleClick()
        show()
        return true
    }

    private func showFolderMenu(from label: TitleBarLabel) {
        siblingRequest?.cancel()
        guard document.canReplaceBuffer else { return }
        popUp(recentFoldersMenu(), from: label)
    }

    private func showSiblingMenu(from label: TitleBarLabel) {
        siblingRequest?.cancel()
        guard document.canReplaceBuffer, let file = document.displayedFileURL else { return }
        let wasKeyWindow = document.window.isKeyWindow
        siblingRequest = Task { [weak self, weak label] in
            let files = await Self.loadSiblingFiles(of: file)
            guard !Task.isCancelled, let self, let label, document.displayedFileURL == file,
                  document.canReplaceBuffer, !wasKeyWindow || document.window.isKeyWindow else { return }
            popUp(siblingFilesMenu(files, current: file), from: label)
        }
    }

    private func showLanguagePicker() {
        siblingRequest?.cancel()
        app.showLanguageModes(in: document)
    }

    private func popUp(_ menu: NSMenu, from label: TitleBarLabel) {
        guard let first = menu.items.first, label.window != nil, !label.isHiddenOrHasHiddenAncestor else { return }
        if app.isAgentCheck {
            agentContextMenu = menu
            return
        }
        let top = label.isFlipped ? label.bounds.minY : label.bounds.maxY
        menu.popUp(positioning: first, at: NSPoint(x: label.bounds.minX, y: top), in: label)
    }
}

@MainActor
private final class FileTitleView: NSStackView {
    var onLayout: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in self?.onLayout?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class TitleBarDividers: NSView {
    private(set) var strokes: [NSRect] = []
    private var color = NSColor.separatorColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("Edit.TitleBar.Dividers")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ strokes: [NSRect], color: NSColor) {
        guard self.strokes != strokes || self.color != color else { return }
        self.strokes = strokes
        self.color = color
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for stroke in strokes where stroke.intersects(dirtyRect) {
            stroke.fill()
        }
    }
}

@MainActor
private final class TitleBarLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class TitleBarIcon: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}
