import AppKit

@MainActor
enum HeaderCheck {
    static func fileIcon(in document: DocumentWindow) -> NSImageView? {
        fileTitle(in: document.window)?.arrangedSubviews.compactMap { $0 as? NSImageView }.first
    }

    private static func fileTitle(in window: NSWindow) -> NSStackView? {
        window.toolbar?.items.first { $0.itemIdentifier == DocumentTitleBar.fileItemIdentifier }?.view as? NSStackView
    }

    private static func folderStack(in window: NSWindow) -> NSStackView? {
        window.toolbar?.items.first { $0.itemIdentifier == DocumentTitleBar.folderItemIdentifier }?.view as? NSStackView
    }

    private static func folderLabel(in window: NSWindow) -> NSTextField? {
        folderStack(in: window)?.arrangedSubviews.compactMap { $0 as? NSTextField }.first
    }

    private static func fileLabel(in window: NSWindow) -> NSTextField? {
        fileTitle(in: window)?.arrangedSubviews.compactMap { $0 as? NSTextField }.first
    }

    static func run(in app: Edit) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Header check \(UUID())")
        let folder = root.appending(path: "Project")
        let another = root.appending(path: "Another folder")
        let sourceDirectory = folder.appending(path: "Sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory.appending(path: "Helpers"), withIntermediateDirectories: true)
        let source = sourceDirectory.appending(path: "Main.swift")
        let sibling = sourceDirectory.appending(path: "Notes.txt")
        try Data("func main() {}\n".utf8).write(to: source)
        try Data("Notes\n".utf8).write(to: sibling)
        try Data("Finder metadata".utf8).write(to: sourceDirectory.appending(path: ".DS_Store"))
        try Data("Different directory".utf8).write(to: folder.appending(path: "README.md"))
        try Data("Nested file".utf8).write(to: sourceDirectory.appending(path: "Helpers/Helper.swift"))

        let document = app.makeDocument()
        defer { document.window.close() }
        document.window.layoutIfNeeded()
        try expect(fileIcon(in: document)?.image != nil, "an untitled buffer has a visible language icon")
        for sidebarVisible in [false, true, false] {
            if document.isSidebarVisible != sidebarVisible { document.performFind(.toggleSidebar) }
            document.window.layoutIfNeeded()
            guard let icon = fileIcon(in: document), let title = fileTitle(in: document.window) else {
                throw Failure("an untitled window has a document title")
            }
            let inset = icon.convert(icon.bounds, to: title).minX - title.bounds.minX
            try expect(abs(inset - 8) < 0.5,
                       "an untitled title has an 8-point inset with the sidebar visible: \(sidebarVisible) (\(inset) pt)")
        }
        _ = try await app.openFile(another, in: document)
        _ = try await app.openFile(folder, in: document)
        _ = try await app.openFile(source, in: document)

        document.window.layoutIfNeeded()
        guard let folderTitle = folderLabel(in: document.window), let fileTitle = fileLabel(in: document.window),
              let icon = fileIcon(in: document) else { throw Failure("title has two text labels and a file icon") }
        try expect(folderTitle.stringValue == "Project" && fileTitle.stringValue == "Main.swift",
                   "the folder appears before the file name")
        try expect(folderStack(in: document.window)?.edgeInsets.left == 8,
                   "the folder title starts with an 8-point inset")
        let folderFrame = folderTitle.convert(folderTitle.bounds, to: nil)
        let iconFrame = icon.convert(icon.bounds, to: nil)
        let nameFrame = fileTitle.convert(fileTitle.bounds, to: nil)
        let iconGap = nameFrame.minX - iconFrame.maxX
        try expect(iconFrame.minX - folderFrame.maxX >= 3 && (-1...4).contains(iconGap),
                   "separate folder and file hit regions with a compact icon gap (\(folderFrame), \(iconFrame), \(nameFrame))")
        try expect(folderTitle.action == nil && fileTitle.action == nil && icon.action == nil
                   && folderTitle.mouseDownCanMoveWindow && fileTitle.mouseDownCanMoveWindow && icon.mouseDownCanMoveWindow,
                   "the title parts leave primary mouse events available for moving the window")
        guard let frameView = document.window.contentView?.superview else { throw Failure("the title is in a window frame") }
        for view in [folderTitle, icon, fileTitle] as [NSView] {
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            let hit = frameView.hitTest(view.convert(center, to: frameView.superview))
            try expect(hit === view || hit?.isDescendant(of: view) == true,
                       "AppKit routes pointer events to the visible part of the title")
        }
        try secondaryClick(folderTitle, in: document.window)
        guard let recentFolders = document.titleBar.agentContextMenu else {
            throw Failure("a secondary click on the folder title opens recent folders")
        }
        let folderPaths = recentFolders.items.compactMap { ($0.representedObject as? URL)?.lastPathComponent }
        try expect(Array(folderPaths.prefix(2)) == ["Project", "Another folder"], "folder menu shows recent folders")
        try expect(recentFolders.items.first?.state == .on, "the folder menu marks the current project")
        try expect(recentFolders.items.allSatisfy { $0.image != nil && $0.preferredImageVisibility == .visible },
                   "all recent folders show icons on macOS 27")
        try secondaryClick(fileTitle, in: document.window)
        try await waitFor("a secondary click on the file title opens sibling files") {
            document.titleBar.agentContextMenu?.title == "Files in This Folder"
        }
        guard let siblings = document.titleBar.agentContextMenu else { throw Failure("the file menu is available") }
        let siblingTitles = siblings.items.map(\.title)
        try expect(siblingTitles == ["Main.swift", "Notes.txt"],
                   "file menu shows files next to the current file (\(siblingTitles))")
        try expect(siblings.items[0].state == .on, "the file menu marks the current file")
        try expect(siblings.items.allSatisfy { $0.image != nil && $0.preferredImageVisibility == .visible },
                   "all sibling files show icons on macOS 27")

        try await checkDetachedToolbar(in: document, app: app)

        let count = app.documents.count
        siblings.performActionForItem(at: 1)
        try await waitFor("a sibling opens in the same window") {
            document.fileURL?.lastPathComponent == "Notes.txt" && app.documents.count == count
        }
        recentFolders.performActionForItem(at: 1)
        try await waitFor("a recent folder opens in the same window") {
            document.folderURL?.lastPathComponent == "Another folder" && app.documents.count == count
        }
        let fileItem = document.window.toolbar?.items.first { $0.itemIdentifier == DocumentTitleBar.fileItemIdentifier }
        try expect(document.showsEmptyFolder && fileItem?.isHidden == true,
                   "an empty project shows only its folder title")
        await document.newBuffer()
        document.window.layoutIfNeeded()

        guard let icon = fileIcon(in: document) else { throw Failure("the file shows a language icon") }
        try secondaryClick(icon, in: document.window)
        try app.checkHeaderLanguagePicker(in: document)

        document.performFind(.toggleSidebar)
        document.window.layoutIfNeeded()
        try expect(folderLabel(in: document.window)?.stringValue == "Another folder"
                   && fileLabel(in: document.window)?.stringValue == "Untitled" && fileIcon(in: document)?.image != nil,
                   "the folder, file and language icon remain in the toolbar alongside the sidebar")

        document.toggleSidebarFocus(.worktree)
        document.window.layoutIfNeeded()
        guard let split = document.window.contentViewController as? NSSplitViewController,
              let sidebar = split.splitViewItems.first?.viewController.view,
              let visibleFolder = folderLabel(in: document.window) else { throw Failure("the folder title sits next to the sidebar") }
        let divider = sidebar.convert(sidebar.bounds, to: nil).maxX
        let gutter = visibleFolder.convert(visibleFolder.bounds, to: nil).minX - divider
        try expect(folderStack(in: document.window)?.edgeInsets.left == 8,
                   "the open sidebar keeps the folder title inset")
        try expect((10...18).contains(gutter), "the folder title clears the sidebar divider (\(gutter) pt)")
        try secondaryClick(visibleFolder, in: document.window, controlClick: true)
        try expect(document.titleBar.agentContextMenu?.title == "Recent Folders",
                   "Control-click opens recent folders beside Worktree")

        document.performFind(.toggleSidebar)
        document.window.layoutIfNeeded()
        try expect(!document.isSidebarVisible && folderStack(in: document.window)?.edgeInsets.left == 8,
                   "closing the sidebar keeps the folder title inset")
        document.performFind(.toggleSidebar)

        let longFolder = root.appending(path: String(repeating: "Long folder name ", count: 7) + "project")
        let longFile = longFolder.appending(path: String(repeating: "File name ", count: 8) + "example.txt")
        try FileManager.default.createDirectory(at: longFolder, withIntermediateDirectories: true)
        try Data("A long filename".utf8).write(to: longFile)
        _ = try await app.openFile(longFolder, in: document)
        _ = try await app.openFile(longFile, in: document)
        var frame = document.window.frame
        frame.size.width = 480
        document.window.setFrame(frame, display: false)
        document.window.layoutIfNeeded()
        guard let compactIcon = fileIcon(in: document) else { throw Failure("the compact toolbar has a language icon") }
        let rect = compactIcon.convert(compactIcon.bounds, to: nil)
        try expect(compactIcon.window === document.window && rect.width > 0 && rect.minX >= 0 &&
                   rect.maxX <= document.window.frame.width,
                   "the file icon stays visible with long names in a narrow window (\(rect), window width \(document.window.frame.width), attached \(compactIcon.window === document.window))")

        try await checkFileTitleWidth(in: app, folder: folder)
    }

    private static func checkFileTitleWidth(in app: Edit, folder: URL) async throws {
        let short = folder.appending(path: "build.txt")
        let longer = folder.appending(path: "windows_tests.txt")
        let wide = folder.appending(path: "project-configuration-for-a-wide-editor.txt.txt")
        for url in [short, longer, wide] { try Data("Sample\n".utf8).write(to: url) }

        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1072, height: 630), display: false)
        _ = try await app.openFile(folder, in: document)
        _ = try await app.openFile(short, in: document)
        document.toggleSidebarFocus(.worktree)
        document.restoreTerminal(DocumentTerminalState(
            panel: TerminalPanelState(dock: .right, spaces: [], selectedSpace: nil, nextSpaceNumber: 1),
            sizes: TerminalDockSizes(belowHeight: 220, rightWidth: 425), isVisible: true, wasFocused: false
        ))
        window.layoutIfNeeded()
        let split = document.documentSplitView
        guard document.worktreeSidebar != nil, document.isTerminalDockedRight,
              let leading = split.arrangedSubviews.first, let terminal = split.arrangedSubviews.last else {
            throw Failure("put the file title between Worktree and the terminal sidebar")
        }
        let divider = split.arrangedSubviews.count - 2
        split.setPosition(219, ofDividerAt: 0)
        split.setPosition(636, ofDividerAt: divider)
        window.layoutIfNeeded()
        let leadingEdge = split.convert(leading.bounds, from: leading).maxX
        let terminalDivider = split.convert(terminal.bounds, from: terminal).minX - split.dividerThickness

        func expectTitle(_ url: URL, fits: Bool) throws {
            window.layoutIfNeeded()
            guard let label = fileLabel(in: window), label.stringValue == url.lastPathComponent,
                  label.window === window, !label.isHiddenOrHasHiddenAncestor else {
                throw Failure("show the current file in the visible title")
            }
            let width = label.bounds.width
            let naturalWidth = label.intrinsicContentSize.width
            try expect((width + 0.5 >= naturalWidth) == fits,
                       "use the available title width for \(url.lastPathComponent) (\(width) of \(naturalWidth) points)")
        }

        for url in [longer, wide] {
            _ = try await app.openFile(url, in: document)
            try expectTitle(url, fits: true)
        }
        split.setPosition(leadingEdge + 270, ofDividerAt: divider)
        try expectTitle(wide, fits: false)
        _ = try await app.openFile(longer, in: document)
        split.setPosition(terminalDivider, ofDividerAt: divider)
        try expectTitle(longer, fits: true)
        _ = try await app.openFile(wide, in: document)
        try expectTitle(wide, fits: true)

        // Resize in both directions with the same file open, without flushing the toolbar between moves.
        _ = try await app.openFile(longer, in: document)
        split.setPosition(leadingEdge + 170, ofDividerAt: divider)
        try expect(split.convert(terminal.bounds, from: terminal).minX < terminalDivider - 100,
                   "widen the terminal enough to compress the editor title")
        split.setPosition(terminalDivider, ofDividerAt: divider)
        try expectTitle(longer, fits: true)
    }

    private static func checkDetachedToolbar(in document: DocumentWindow, app: Edit) async throws {
        let window = document.window
        guard let toolbar = window.toolbar else { throw Failure("the document has a toolbar to reveal in fullscreen") }
        // Host the real toolbar in another window without switching the user's Space.
        let host = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 640, height: 180),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.collectionBehavior = [.fullScreenAuxiliary]
        host.toolbarStyle = window.toolbarStyle
        window.toolbar = nil
        host.toolbar = toolbar
        defer {
            host.toolbar = nil
            window.toolbar = toolbar
            window.layoutIfNeeded()
            host.close()
        }

        host.layoutIfNeeded()
        guard let folder = folderLabel(in: host), let file = fileLabel(in: host),
              let icon = fileTitle(in: host)?.arrangedSubviews.compactMap({ $0 as? NSImageView }).first,
              [folder, file, icon].allSatisfy({ $0.window === host }) else {
            throw Failure("the detached toolbar hosts the real folder, file, and language icon")
        }

        for controlClick in [false, true] {
            let previous = document.titleBar.agentContextMenu
            try secondaryClick(folder, in: host, controlClick: controlClick)
            let recent = document.titleBar.agentContextMenu
            try expect(recent !== previous && recent?.title == "Recent Folders",
                       "opening recent folders from the detached toolbar")
            try secondaryClick(file, in: host, controlClick: controlClick)
            try await waitFor("opening sibling files from the detached toolbar") {
                document.titleBar.agentContextMenu !== recent &&
                    document.titleBar.agentContextMenu?.items.map(\.title) == ["Main.swift", "Notes.txt"]
            }
            try secondaryClick(icon, in: host, controlClick: controlClick)
            try app.checkHeaderLanguagePicker(in: document)
        }
    }

    private static func secondaryClick(_ view: NSView, in window: NSWindow, controlClick: Bool = false) throws {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let click = NSEvent.mouseEvent(with: controlClick ? .leftMouseDown : .rightMouseDown,
                                             location: location, modifierFlags: controlClick ? .control : [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw Failure("create a secondary click in the window")
        }
        NSApp.sendEvent(click)
    }

    private static func waitFor(_ detail: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(detail)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Title bar: \(detail)" }
    }
}
