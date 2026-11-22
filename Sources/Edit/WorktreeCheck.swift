import AppKit

@MainActor
enum WorktreeCheck {
    static func run(in app: Edit) async throws {
        try WorktreeDirectoryCheck.run()
        let temporary = FileManager.default.temporaryDirectory.appending(path: "Worktree check \(UUID())")
        let project = temporary.appending(path: "Project", directoryHint: .isDirectory)
        let parent = project.appending(path: "Sources", directoryHint: .isDirectory)
        let hidden = parent.appending(path: ".Details", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let readme = project.appending(path: "README.md")
        let ignored = project.appending(path: "Build.log")
        let nested = hidden.appending(path: "Active.swift")
        let external = temporary.appending(path: "External.txt")
        for file in [readme, ignored, nested, external] { try Data("Sample\n".utf8).write(to: file) }
        try Data("*.log\n".utf8).write(to: project.appending(path: ".gitignore"))

        let document = app.makeDocument()
        defer { document.window.close() }
        document.toggleSidebarFocus(.worktree)
        try expect(document.worktreeSidebar == nil, "Worktree is unavailable before opening a folder")
        _ = try await app.openFile(project, in: document)
        document.toggleSidebarFocus(.worktree)
        guard let sidebar = document.worktreeSidebar else { throw Failure("open a native outline") }
        let tree = sidebar.outline
        try await waitFor("read the folder and reveal the README") {
            row(named: "README.md", in: tree) != nil && row(named: "Build.log", in: tree) != nil
        }
        let log = try require(row(named: "Build.log", in: tree), "display an ignored file")
        try expect(cell(at: log, in: tree)?.textField?.textColor == .secondaryLabelColor, "Git-ignored files are gray")
        let sources = try require(row(named: "Sources", in: tree), "show the first level")
        try expect(row(named: "Active.swift", in: tree) == nil, "do not expand unrelated directories")
        document.window.layoutIfNeeded()
        try expect(sources == 0 && tree.level(forRow: sources) == 0 && row(named: "Project", in: tree) == nil,
                   "the folder's contents start the tree at level zero")
        try checkRootContextMenu(in: tree)
        let disclose = try disclosure(at: sources, in: tree)
        try expect(disclose.contentTintColor == .secondaryLabelColor,
                   "a folder disclosure uses the system secondary label tint")
        let fileCell = try require(cell(at: log, in: tree), "file row")
        let fileIcon = try require(fileCell.imageView, "file icon")
        try expect(cell(at: sources, in: tree)?.imageView?.image == nil, "folders show only the disclosure symbol")
        fileCell.layoutSubtreeIfNeeded()
        let folderGlyphFrame = disclose.convert(disclose.bounds, to: tree)
        let fileGlyphFrame = fileIcon.convert(fileIcon.bounds, to: tree)
        try expect(abs(folderGlyphFrame.minX - fileGlyphFrame.minX) < 0.5 &&
                   abs(folderGlyphFrame.width - fileGlyphFrame.width) < 0.5,
                   "sibling folders and files use the same icon gutter (\(folderGlyphFrame) and \(fileGlyphFrame))")
        let folder = try require(tree.item(atRow: sources), "Sources folder item")
        tree.collapseItem(folder)
        tree.selectRowIndexes(IndexSet(integer: sources), byExtendingSelection: false)
        document.window.makeFirstResponder(tree)
        try expect(tree.selectedRow == sources && document.window.firstResponder === tree,
                   "start with the collapsed folder selected in the tree")
        try press(" ", code: 49, in: tree)
        try expect(tree.isItemExpanded(folder) && document.window.firstResponder === tree,
                   "Space expands a selected folder and keeps tree focus")
        try press(" ", code: 49, in: tree)
        try expect(!tree.isItemExpanded(folder) && document.window.firstResponder === tree &&
                   document.fileURL?.lastPathComponent == "README.md",
                   "Space collapses the folder and preserves the open file")

        try click(log, in: tree, modifiers: [.command])
        try expect(tree.selectedRowIndexes.contains(log), "Command-click selects the file")
        try await Task.sleep(for: .milliseconds(40))
        try expect(document.fileURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(readme),
                   "Command-click selects without opening a file")
        try click(log, in: tree)
        try await waitFor("open a file from a single click on an already selected row") {
            document.fileURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(ignored)
        }
        try expect(document.window.firstResponder === tree && tree.selectedRow == log,
                   "opening a file keeps the selected row focused")
        try click(log, in: tree)
        try expect(document.window.firstResponder === tree, "clicking the active file keeps focus on the tree")

        try press("\u{F701}", code: 125, in: tree)
        try await waitFor("Down opens the next file and preserves tree focus") {
            document.fileURL?.lastPathComponent == "README.md" &&
                tree.selectedRow == row(named: "README.md", in: tree) && document.window.firstResponder === tree
        }
        try press("\u{F700}", code: 126, in: tree)
        try await waitFor("Up opens the previous file and preserves tree focus") {
            document.fileURL?.lastPathComponent == "Build.log" && tree.selectedRow == log &&
                document.window.firstResponder === tree
        }
        try press("\r", code: 36, in: tree)
        let rename = try fieldEditor(in: document.window)
        try expect(rename.string == "Build.log" && rename.selectedRange() == NSRange(location: 0, length: 5),
                   "Return edits the selected name in place and selects its stem")
        try pressNameKey(53, characters: "\u{1B}", in: document.window)
        try expect(document.window.firstResponder === tree && document.fileURL?.lastPathComponent == "Build.log",
                   "Escape cancels rename and restores tree focus")

        try press("\u{F701}", code: 125, in: tree)
        try press(" ", code: 49, in: tree)
        try await waitFor("Space waits for the selected file and moves focus there without typing") {
            document.fileURL?.lastPathComponent == "README.md" && document.window.firstResponder === document.editor &&
                document.editor.string == "Sample\n"
        }

        guard let sourceMenu = sidebar.menu(at: sources) else { throw Failure("a folder has a contextual menu") }
        for title in ["New File…", "New Folder…", "Copy Path", "Hide"] {
            try expect(sourceMenu.item(withTitle: title) != nil, "folder menu contains \(title)")
        }
        sourceMenu.performActionForItem(at: sourceMenu.indexOfItem(withTitle: "Hide"))
        try expect(row(named: "Sources", in: tree) == nil, "manually hidden folders are filtered")

        _ = try await app.openFile(nested, in: document)
        try await waitFor("expand the hidden ancestor chain of the current file") {
            row(named: "Sources", in: tree) != nil && row(named: ".Details", in: tree) != nil &&
                row(named: "Active.swift", in: tree) != nil
        }
        let active = try require(row(named: "Active.swift", in: tree), "find active row")
        try expect(tree.selectedRow == active, "scroll and select the newly opened file")
        try expect(cell(at: active, in: tree)?.textField?.font == NSFont.systemFont(ofSize: NSFont.systemFontSize),
                   "the selected file uses the same font as the other files")
        let activeItem = try require(tree.item(atRow: active), "retrieve active outline item")
        guard let writer = sidebar.outlineView(tree, pasteboardWriterForItem: activeItem) else {
            throw Failure("the active file can be dragged out")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.writeObjects([writer])
        let exported = WorktreeActions.fileURLs(on: pasteboard).map { $0.standardizedFileURL.path }
        try expect(exported == [nested.standardizedFileURL.path],
                   "dragging exports a native file URL, received \(exported)")

        let sourceRow = try require(row(named: "Sources", in: tree), "retrieve the expanded folder")
        let sourceItem = try require(tree.item(atRow: sourceRow), "retrieve Sources")
        let sourceButton = try disclosure(at: sourceRow, in: tree)
        sourceButton.performClick(nil)
        try expect(!tree.isItemExpanded(sourceItem) && row(named: "Active.swift", in: tree) == nil &&
                   row(named: "README.md", in: tree) != nil, "collapsing a folder leaves its sibling rows visible")
        sidebar.setShowsHidden(true)
        sidebar.refresh()
        try expect(!tree.isItemExpanded(sourceItem) && row(named: "Active.swift", in: tree) == nil,
                   "refreshing the tree keeps the folder collapsed")
        let refreshedSourceButton = try disclosure(at: sourceRow, in: tree)
        try expect(refreshedSourceButton.contentTintColor == .secondaryLabelColor,
                   "a refreshed folder disclosure keeps its tint")
        sidebar.setShowsHidden(false)
        _ = try await app.openFile(readme, in: document)
        try await waitFor("select a file at the top level") {
            row(named: "README.md", in: tree) == tree.selectedRow
        }

        _ = try await app.openFile(external, in: document)
        try await waitFor("show an open file outside the worktree") { row(named: "External.txt", in: tree) != nil }
        try expect(row(named: "Sources", in: tree) == nil, "hidden ancestors disappear when they no longer contain the active file")
        sidebar.setShowsHidden(true)
        try expect(row(named: "Sources", in: tree) != nil && row(named: ".gitignore", in: tree) != nil,
                   "Show Hidden Files reveals manual and system-hidden items")

        try Data("External filesystem change".utf8).write(to: project.appending(path: "New from Finder.txt"))
        try await waitFor("refresh after an external change") { row(named: "New from Finder.txt", in: tree) != nil }

        document.performFind(.find)
        try expect(sidebar.view.isHiddenOrHasHiddenAncestor, "switch from Worktree to Search in the same sidebar")
        document.toggleSidebarFocus(.worktree)
        try expect(!sidebar.view.isHiddenOrHasHiddenAncestor, "return from Search to Worktree")

        guard let root = document.folderURL else { throw Failure("the move has a worktree") }
        let target = try WorktreeFileOperations.create("Nested/Target", in: root, root: root, isDirectory: true)
        let created = try WorktreeFileOperations.create("Created/Notes.txt", in: target, root: root, isDirectory: false)
        try expect(FileManager.default.fileExists(atPath: created.path), "create a file and its parent folders from a relative name")
        _ = try await app.openFile(ignored, in: document)
        let editor = document.editor
        editor.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
        let actions = WorktreeActions(document: document, app: app, refresh: { sidebar.refresh() },
                                      isHidden: { _ in false }, toggleHidden: { _ in }, editName: { _, _ in })
        let source = FileBuffer.canonicalURL(ignored)
        let moved = target.appending(path: ignored.lastPathComponent)
        try expect(actions.transfer([source], into: target, move: true, within: root),
                   "accept a move into another folder")
        try await waitFor("retarget the open buffer after moving the file") {
            document.fileURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(moved) &&
                document.canReplaceBuffer
        }
        try expect(editor.string.hasPrefix("edited") && !FileManager.default.fileExists(atPath: source.path),
                   "keep unsaved text and move the original path")
        let save = await document.save()
        let saved = try String(contentsOf: moved, encoding: .utf8)
        try expect(save && saved == editor.string, "save subsequent edits to the new path")

        let restored = app.makeDocument()
        defer { restored.window.close() }
        restored.setFolder(root)
        restored.restoreSidebar(document.sessionDocument())
        try expect(restored.worktreeSidebar?.showsHidden == true && restored.findSettings.visible,
                   "restore Worktree and its Show Hidden Files setting in that window's session")

        let empty = temporary.appending(path: "Empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        _ = try await app.openFile(empty, in: restored)
        let emptyTree = try require(restored.worktreeSidebar?.outline, "the outline still exists for an empty folder")
        restored.window.layoutIfNeeded()
        try expect(emptyTree.numberOfRows == 0, "an empty folder leaves the tree blank")
        try checkRootContextMenu(in: emptyTree)
        try await checkInlineNames(in: restored, tree: emptyTree, directory: empty)

    }

    private static func checkInlineNames(in document: DocumentWindow, tree: NSOutlineView, directory: URL) async throws {
        let window = document.window
        let toolbarItem = try require(window.toolbar?.items.compactMap { $0 as? SidebarMenuItem }.first,
                                      "find the Worktree toolbar menu")
        toolbarItem.menu.update()
        toolbarItem.menu.performActionForItem(at: toolbarItem.menu.indexOfItem(withTitle: "New Folder…"))
        _ = try fieldEditor(in: window)
        try expect(tree.numberOfRows == 1, "the empty tree displays a provisional folder row")
        try pressNameKey(53, characters: "\u{1B}", in: window)
        try expect(tree.numberOfRows == 0 && FileManager.default.fileExists(atPath: directory.appending(path: "untitled folder").path) == false,
                   "Escape removes the provisional row without creating a folder")

        toolbarItem.menu.update()
        toolbarItem.menu.performActionForItem(at: toolbarItem.menu.indexOfItem(withTitle: "New Folder…"))
        try replaceName(with: "Sources", in: window)
        try pressNameKey(36, characters: "\r", in: window)
        try await waitFor("create and select the folder named in the Worktree row") {
            tree.selectedRow >= 0 && row(named: "Sources", in: tree) == tree.selectedRow
        }
        let folder = directory.appending(path: "Sources")
        try expect(FileManager.default.fileExists(atPath: folder.path), "the inline folder is created in the root")
        let folderRow = try require(row(named: "Sources", in: tree), "created folder row")
        let worktree = try require(document.worktreeSidebar, "folder Worktree")
        let menu = try require(worktree.menu(at: folderRow), "folder creation menu")
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "New File…"))
        _ = try fieldEditor(in: window)

        try replaceName(with: "Nested/File.swift", in: window)
        try pressNameKey(36, characters: "\r", in: window)
        try await waitFor("open a file created from a relative path in its folder row") {
            document.fileURL?.lastPathComponent == "File.swift" && row(named: "File.swift", in: tree) == tree.selectedRow
        }
        let file = folder.appending(path: "Nested/File.swift")
        let occupied = folder.appending(path: "Nested/Taken.swift")
        let fileRow = try require(row(named: "File.swift", in: tree), "selected file created inline")
        let fileMenu = try require(worktree.menu(at: fileRow), "file rename menu")
        fileMenu.performActionForItem(at: fileMenu.indexOfItem(withTitle: "Rename…"))
        try replaceName(with: "Taken.swift", in: window)
        let field = try fieldEditor(in: window)
        try Data("existing".utf8).write(to: occupied)
        worktree.refresh()
        try await Task.sleep(for: .milliseconds(300))
        try expect(window.firstResponder === field && field.string == "Taken.swift",
                   "a directory refresh preserves both the draft name and its focused field")
        try pressNameKey(36, characters: "\r", in: window)
        try await waitFor("a conflicting name keeps the native field available for correction") {
            (window.firstResponder as? NSTextView)?.isFieldEditor == true &&
                (window.firstResponder as? NSTextView)?.isEditable == true
        }
        try expect(FileManager.default.fileExists(atPath: file.path), "the conflicted rename keeps the original file")
        let occupiedContents = try String(contentsOf: occupied, encoding: .utf8)
        try expect(occupiedContents == "existing", "the conflicted rename keeps the destination")

        worktree.refresh()
        try replaceName(with: "Renamed.swift", in: window)
        try pressNameKey(36, characters: "\r", in: window)
        try await waitFor("commit the corrected name and retarget the existing editor") {
            document.fileURL?.lastPathComponent == "Renamed.swift" && row(named: "Renamed.swift", in: tree) == tree.selectedRow
        }
        try expect(window.attachedSheet == nil && !NSApp.isActive, "inline edits stay in the quiet Worktree window")
    }

    private static func fieldEditor(in window: NSWindow) throws -> NSTextView {
        let editor = try require(window.firstResponder as? NSTextView, "the Worktree name editor")
        try expect(editor.isFieldEditor && window.attachedSheet == nil, "Worktree names use an inline AppKit field editor")
        return editor
    }

    private static func replaceName(with value: String, in window: NSWindow) throws {
        let editor = try fieldEditor(in: window)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private static func pressNameKey(_ code: UInt16, characters: String, in window: NSWindow) throws {
        let editor = try fieldEditor(in: window)
        let event = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ), "name editor key event")
        editor.keyDown(with: event)
    }

    private static func checkRootContextMenu(in tree: NSOutlineView) throws {
        let window = try require(tree.window, "Worktree context menu window")
        let rect = tree.visibleRect
        let blank = NSPoint(x: rect.midX, y: rect.maxY - 6)
        try expect(tree.row(at: blank) == -1, "the context click is in a blank area")
        let content = try require(window.contentView, "Worktree window content")
        let hit = content.hitTest(tree.convert(blank, to: content.superview))
        try expect(hit?.isDescendant(of: tree) == true, "the blank area belongs to the outline")
        let click = try require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: tree.convert(blank, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ), "Worktree context click")
        let menu = try require(tree.menu(for: click), "a blank area offers the root context menu")
        try expect(menu.item(withTitle: "New File…")?.isEnabled == true &&
                   menu.item(withTitle: "New Folder…")?.isEnabled == true && menu.item(withTitle: "Rename…") == nil,
                   "the root menu offers creation without a root row")
    }

    private static func disclosure(at row: Int, in outline: NSOutlineView) throws -> NSButton {
        let button = outline.rowView(atRow: row, makeIfNecessary: true)?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.identifier == NSOutlineView.disclosureButtonIdentifier ||
                $0.identifier == NSOutlineView.showHideButtonIdentifier }
        return try require(button, "native disclosure button")
    }

    private static func press(_ characters: String, code: UInt16, in outline: NSOutlineView) throws {
        let window = try require(outline.window, "keyboard navigation window")
        let event = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ), "outline key event")
        outline.keyDown(with: event)
    }

    private static func click(
        _ row: Int, in outline: NSOutlineView, modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let rect = outline.frameOfCell(atColumn: 0, row: row)
        let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let window = try require(outline.window, "outline window")
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 1, clickCount: 1, pressure: 1), "outline click")
        }
        window.makeFirstResponder(outline)
        let press = try event(.leftMouseDown)
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        NSApp.postEvent(press, atStart: true)
        // Give native outline tracking the mouse-down as the current application event.
        let down = try require(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                                              inMode: .default, dequeue: true), "queued outline click")
        outline.mouseDown(with: down)
    }

    private static func row(named name: String, in outline: NSOutlineView) -> Int? {
        (0..<outline.numberOfRows).first { cell(at: $0, in: outline)?.textField?.stringValue == name }
    }

    private static func cell(at row: Int, in outline: NSOutlineView) -> NSTableCellView? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private static func waitFor(_ detail: String, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(detail)
    }

    private static func require<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw Failure(detail) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Worktree: \(detail)" }
    }
}
