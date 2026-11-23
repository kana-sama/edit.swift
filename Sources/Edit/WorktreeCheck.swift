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
        try await checkInitialSelection(in: app, under: temporary)
        try await checkFolderAnimation(in: app, under: temporary)
        try await checkKeyboardFolders(in: app, under: temporary)
        try await checkTrash(in: app, under: temporary)

        let document = app.makeDocument()
        defer { document.window.close() }
        document.toggleSidebarFocus(.worktree)
        try expect(document.worktreeSidebar == nil, "Worktree is unavailable before opening a folder")
        _ = try await app.openFile(project, in: document)
        _ = try await app.openFile(readme, in: document)
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
        let clip = try require(tree.enclosingScrollView?.contentView, "Worktree clip view")
        let firstRow = tree.convert(tree.rect(ofRow: sources), to: clip)
        try expect(abs(firstRow.minY - clip.bounds.minY) < 0.5,
                   "the first Worktree row starts at the top of its scroll area")
        var cursorImages: [NSCursor] = []
        let cursorTracking = EditApplication.ClickCursorTracking(currentCursor: { cursorImages.last ?? .arrow },
                                                                setCursor: { cursorImages.append($0) })
        defer { cursorTracking.end() }
        try expect(document.window.areCursorRectsEnabled, "start with native cursor tracking enabled")
        for row in [sources, log] {
            let frame = tree.rect(ofRow: row)
            // The split view owns the resize grip at the inside edge of the sidebar.
            for x in [frame.minX + 2, frame.midX, frame.maxX - 12] {
                let point = tree.convert(NSPoint(x: x, y: frame.midY), to: nil)
                let cursor = EditApplication.clickCursor(in: document.window, at: point)
                try expect(cursor === NSCursor.pointingHand && cursorTracking.update(cursor, in: document.window) &&
                           document.window.areCursorRectsEnabled, "keep native pointer updates across Worktree rows")
            }
        }
        let disclose = try disclosure(at: sources, in: tree)
        let disclosurePoint = disclose.convert(NSPoint(x: disclose.bounds.midX, y: disclose.bounds.midY), to: nil)
        var nativeTrackingAvailable = false
        cursorTracking.dispatch(.leftMouseDown, in: document.window, resolve: {
            EditApplication.clickCursor(in: document.window, at: disclosurePoint)
        }) { nativeTrackingAvailable = document.window.areCursorRectsEnabled }
        try expect(nativeTrackingAvailable && cursorImages == [.pointingHand],
                   "native tracking stays available during a disclosure press with one pointing-hand image")
        let lastRow = tree.rect(ofRow: tree.numberOfRows - 1)
        let belowRows = tree.convert(NSPoint(x: lastRow.midX, y: lastRow.maxY + 5), to: nil)
        cursorTracking.dispatch(.cursorUpdate, in: document.window, resolve: {
            EditApplication.clickCursor(in: document.window, at: belowRows)
        }) {
            if cursorImages.last !== NSCursor.arrow { cursorImages.append(.arrow) }
        }
        try expect(document.window.areCursorRectsEnabled && cursorImages == [.pointingHand, .arrow],
                   "show the default cursor over the empty Worktree area")
        try checkDisclosureStyle(disclose)
        try checkDisclosureContrast(disclose, in: document.window)
        try checkSelectionShape(in: tree, window: document.window)
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
        document.window.layoutIfNeeded()
        let nameArea = rename.visibleRect
        let namePoint = rename.convert(NSPoint(x: nameArea.midX, y: nameArea.midY), to: nil)
        try expect(!nameArea.isEmpty && EditApplication.clickCursor(in: document.window, at: namePoint) == nil,
                   "keep the text cursor while editing a name in a Worktree row")
        try pressNameKey(53, characters: "\u{1B}", in: document.window)
        try expect(document.window.firstResponder === tree && tree.selectedRow == log &&
                   document.fileURL?.lastPathComponent == "Build.log",
                   "Escape cancels rename and keeps the original file selected in the focused tree")

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
        try checkDisclosureStyle(refreshedSourceButton)
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

    private static func checkInitialSelection(in app: Edit, under temporary: URL) async throws {
        let folder = temporary.appending(path: "Unopened Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [folder.appending(path: "A.txt"), folder.appending(path: "B.txt")]
        for file in files { try Data("Sample\n".utf8).write(to: file) }

        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(folder, in: document)
        document.toggleSidebarFocus(.worktree)
        let sidebar = try require(document.worktreeSidebar, "open the Worktree for a project without an open file")
        let tree = sidebar.outline
        try await waitFor("select the first file when the focused Worktree finishes loading") {
            tree.numberOfRows == 2 && tree.selectedRow == 0
        }
        try expect(row(named: "A.txt", in: tree) == tree.selectedRow && document.window.firstResponder === tree &&
                   document.showsEmptyFolder, "highlight the first row and keep the project open without opening the file")

        document.focusContent()
        tree.deselectAll(nil)
        document.toggleSidebarFocus(.worktree)
        try expect(tree.selectedRow == 0, "select the first row immediately when refocusing an already loaded tree")
        tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        document.focusContent()
        document.toggleSidebarFocus(.worktree)
        try expect(tree.selectedRow == 1 && document.window.firstResponder === tree,
                   "keep an existing selection when refocusing the Worktree without an open file")
        for file in files { try FileManager.default.removeItem(at: file) }
        sidebar.refresh()
        try await waitFor("keep the focus and clear the selection as the last rows disappear") {
            tree.numberOfRows == 0 && tree.selectedRow == -1 && document.window.firstResponder === tree
        }
    }

    private static func checkInlineNames(in document: DocumentWindow, tree: NSOutlineView, directory: URL) async throws {
        let window = document.window
        let toolbarItem = try require(window.toolbar?.items.compactMap { $0 as? SidebarMenuItem }.first?.options,
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

        document.editor.insertText("unsaved", replacementRange: NSRange(location: 0, length: 0))
        try performHistoryAction(in: tree, redo: false, title: "Undo Rename")
        try await waitFor("undo rename selects the original name in the focused tree") {
            let original = row(named: "File.swift", in: tree)
            return document.fileURL?.lastPathComponent == "File.swift" && original == tree.selectedRow &&
                window.firstResponder === tree
        }
        try expect(document.editor.string == "unsaved" && FileManager.default.fileExists(atPath: file.path),
                   "undo rename preserves text and restores the original name")
        try performHistoryAction(in: tree, redo: true, title: "Redo Rename")
        try await waitFor("redo rename selects the new name in the focused tree") {
            let renamed = row(named: "Renamed.swift", in: tree)
            return document.fileURL?.lastPathComponent == "Renamed.swift" && renamed == tree.selectedRow &&
                window.firstResponder === tree
        }
        try expect(document.editor.string == "unsaved" && !FileManager.default.fileExists(atPath: file.path),
                   "redo rename preserves text and reapplies the new name")

        let sourceRow = try require(row(named: "Sources", in: tree), "expanded parent of the open file")
        tree.selectRowIndexes(IndexSet(integer: sourceRow), byExtendingSelection: false)
        try press("\r", code: 36, in: tree)
        try replaceName(with: "Discarded", in: window)
        try pressNameKey(53, characters: "\u{1B}", in: window)
        try expect(window.firstResponder === tree && row(named: "Sources", in: tree) == tree.selectedRow,
                   "Escape keeps the renamed folder selected even with a child open in the editor")

        try press("\r", code: 36, in: tree)
        try replaceName(with: "MovedSources", in: window)
        try pressNameKey(36, characters: "\r", in: window)
        try await waitFor("rename selects the expanded folder and keeps its child visible") {
            row(named: "MovedSources", in: tree) == tree.selectedRow && row(named: "Renamed.swift", in: tree) != nil &&
                window.firstResponder === tree
        }
        try performHistoryAction(in: tree, redo: false, title: "Undo Rename")
        try await waitFor("undo selects the renamed folder instead of its open descendant") {
            row(named: "Sources", in: tree) == tree.selectedRow && row(named: "Renamed.swift", in: tree) != nil &&
                window.firstResponder === tree
        }

        let retained = try require(row(named: "Taken.swift", in: tree), "another file in the expanded folder")
        tree.selectRowIndexes(IndexSet(integer: retained), byExtendingSelection: false)
        try performHistoryAction(in: tree, redo: true, title: "Redo Rename")
        window.makeFirstResponder(document.editor)
        try await waitFor("redo renames the folder while leaving newer editor focus alone") {
            row(named: "MovedSources", in: tree) != nil && window.firstResponder === document.editor
        }
    }

    private static func checkTrash(in app: Edit, under temporary: URL) async throws {
        let root = temporary.appending(path: "Trash project", directoryHint: .isDirectory)
        let trash = temporary.appending(path: "Test Trash", directoryHint: .isDirectory)
        let files = FileManager.default
        for folder in [root, trash] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let readme = root.appending(path: "README.md")
        let first = root.appending(path: "One.txt")
        let second = root.appending(path: "Two.txt")
        for file in [readme, first, second] { try Data(file.lastPathComponent.utf8).write(to: file) }

        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(root, in: document)
        _ = try await app.openFile(readme, in: document)
        document.toggleSidebarFocus(.worktree)
        let worktree = try require(document.worktreeSidebar, "Trash Worktree")
        let tree = worktree.outline
        worktree.setRecycleForCheck { targets in
            let moved = try targets.map { source in
                // Finder can use a different name in the Trash when the basename is occupied.
                let destination = trash.appending(path: UUID().uuidString)
                try files.moveItem(at: source, to: destination)
                return WorktreeFileOperations.Transfer(source: source, destination: destination)
            }
            return .init(completed: moved, failure: nil)
        }
        try await waitFor("show both disposable files") { tree.numberOfRows == 3 }

        func selectionIs(_ names: [String]) -> Bool {
            let rows = IndexSet(names.compactMap { row(named: $0, in: tree) })
            return rows.count == names.count && tree.selectedRowIndexes == rows &&
                document.window.firstResponder === tree
        }

        func selectFiles() throws -> Int {
            let firstRow = try require(row(named: "One.txt", in: tree), "first Trash file")
            let secondRow = try require(row(named: "Two.txt", in: tree), "second Trash file")
            tree.selectRowIndexes(IndexSet([firstRow, secondRow]), byExtendingSelection: false)
            return firstRow
        }

        document.window.makeFirstResponder(document.editor)
        let clicked = try selectFiles()
        let menu = try require(worktree.menu(at: clicked), "the selected files' menu")
        let item = try require(menu.item(withTitle: "Move to Trash"), "the contextual Trash command")
        try expect(item.isEnabled && item.keyEquivalent == "\u{7f}" && item.keyEquivalentModifierMask == .command,
                   "the context menu shows the active Command-Delete command")
        menu.performActionForItem(at: menu.index(of: item))
        try await waitFor("contextual Trash selects the surviving row and keeps focus") {
            tree.numberOfRows == 1 && selectionIs(["README.md"])
        }
        try expect(!files.fileExists(atPath: first.path) && !files.fileExists(atPath: second.path) &&
                   document.window.firstResponder === tree, "the entire selection moves and retains Worktree focus")

        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("one undo restores and selects both contextual Trash entries") {
            tree.numberOfRows == 3 && selectionIs(["One.txt", "Two.txt"])
        }
        let restored = try [first, second].map { try String(contentsOf: $0, encoding: .utf8) }
        try expect(restored == ["One.txt", "Two.txt"], "undo restores each exact file to its original path")
        try performHistoryAction(in: tree, redo: true, title: "Redo Move to Trash")
        try await waitFor("one redo recycles both entries and selects the neighbor") {
            tree.numberOfRows == 1 && selectionIs(["README.md"])
        }
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("files are back before checking the keyboard shortcut") { tree.numberOfRows == 3 }

        _ = try selectFiles()
        try press("\u{7f}", code: 51, in: tree, modifiers: .command)
        try await waitFor("Command-Delete recycles the selection and selects its neighbor") {
            tree.numberOfRows == 1 && selectionIs(["README.md"])
        }

        try Data("new occupant".utf8).write(to: first)
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("undo restores the other file when one name now conflicts") {
            files.fileExists(atPath: second.path) && tree.numberOfRows == 3 && selectionIs(["Two.txt"])
        }
        let occupant = try String(contentsOf: first, encoding: .utf8)
        try expect(occupant == "new occupant", "undo never replaces a file at the original path")
        try files.removeItem(at: first)
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("undo can retry and select the conflicted entry") {
            files.fileExists(atPath: first.path) && selectionIs(["One.txt"])
        }
        let retried = try String(contentsOf: first, encoding: .utf8)
        try expect(retried == "One.txt", "the conflicted item remains available to restore")

        let last = try require(row(named: "Two.txt", in: tree), "last file")
        tree.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        try press("\u{7f}", code: 51, in: tree, modifiers: .command)
        try await waitFor("deleting the last file selects its predecessor") {
            tree.numberOfRows == 2 && selectionIs(["README.md"])
        }
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("undo selects the restored last file") { selectionIs(["Two.txt"]) }

        tree.selectRowIndexes(IndexSet(integersIn: 0..<tree.numberOfRows), byExtendingSelection: false)
        try press("\u{7f}", code: 51, in: tree, modifiers: .command)
        try await waitFor("empty Worktree keeps keyboard focus after Trash") {
            tree.numberOfRows == 0 && selectionIs([])
        }
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("undo reselects the original group from an empty tree") {
            selectionIs(["One.txt", "README.md", "Two.txt"])
        }

        let directory = root.appending(path: "Folder")
        let sibling = root.appending(path: "Other Folder")
        for folder in [directory, sibling] { try files.createDirectory(at: folder, withIntermediateDirectories: false) }
        try Data().write(to: directory.appending(path: "Child.txt"))
        try Data().write(to: sibling.appending(path: "Other Child.txt"))
        worktree.refresh()
        try await waitFor("load the folders before checking selection across levels") {
            row(named: "Folder", in: tree) != nil && row(named: "Other Folder", in: tree) != nil
        }
        let folderRow = try require(row(named: "Folder", in: tree), "folder row")
        tree.expandItem(tree.item(atRow: folderRow))
        try await waitFor("show a child row") { row(named: "Child.txt", in: tree) != nil }
        let child = try require(row(named: "Child.txt", in: tree), "child row")
        tree.selectRowIndexes(IndexSet([folderRow, child]), byExtendingSelection: false)
        try press("\u{7f}", code: 51, in: tree, modifiers: .command)
        try await waitFor("trashing a selected subtree selects the following folder") {
            tree.numberOfRows == 4 && selectionIs(["Other Folder"])
        }
        try press(" ", code: 49, in: tree)
        try await waitFor("Space acts on the next selected folder without leaving the tree") {
            row(named: "Other Child.txt", in: tree) != nil && selectionIs(["Other Folder"])
        }
        try performHistoryAction(in: tree, redo: false, title: "Undo Move to Trash")
        try await waitFor("undo restores selection of both the folder and its selected child") {
            selectionIs(["Folder", "Child.txt"])
        }
    }

    private static func performHistoryAction(in tree: NSOutlineView, redo: Bool, title: String) throws {
        try expect(tree.window?.firstResponder === tree, "file undo is routed through the focused outline")
        let action = redo ? Selector(("redo:")) : Selector(("undo:"))
        let item = NSMenuItem(title: redo ? "Redo" : "Undo", action: action, keyEquivalent: "z")
        let validator = try require(tree as? NSMenuItemValidation, "Worktree participates in Edit menu validation")
        try expect(validator.validateMenuItem(item) && item.title == title, "the Edit menu exposes \(title)")
        try expect(tree.tryToPerform(action, with: item), "dispatch the Edit menu's undo or redo selector")
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

    private static func checkKeyboardFolders(in app: Edit, under directory: URL) async throws {
        let root = directory.appending(path: "Keyboard")
        for name in ["Alpha/Nested", "Bravo", "Charlie", "Delta"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        for name in ["Alpha/Nested/Leaf.txt", "Bravo/Bravo.txt", "Charlie/Charlie.txt", "Delta/Delta.txt", "README.md"] {
            try Data().write(to: root.appending(path: name))
        }
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        _ = try await app.openFile(root, in: document)
        document.toggleSidebarFocus(.worktree)
        let tree = try require(document.worktreeSidebar?.outline, "keyboard outline")
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        try await waitFor("keyboard fixture shows four collapsed folders") { tree.numberOfRows == 5 }
        window.layoutIfNeeded()
        window.makeFirstResponder(tree)

        func item(named name: String) throws -> Any {
            let row = try require(row(named: name, in: tree), "visible folder \(name)")
            return try require(tree.item(atRow: row), "folder \(name)")
        }
        func arrow(expanding: Bool) throws {
            try press(expanding ? "\u{F703}" : "\u{F702}", code: expanding ? 124 : 123, in: tree, enqueue: true)
        }
        func select(_ names: [String]) throws {
            let rows = try names.map { try require(row(named: $0, in: tree), "selected row \($0)") }
            tree.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }
        func retainsSelection(_ names: [String]) -> Bool {
            let rows = IndexSet(names.compactMap { row(named: $0, in: tree) })
            return rows.count == names.count && tree.selectedRowIndexes == rows && window.firstResponder === tree
        }
        func waitForRows(_ names: [String], movement: String) async throws {
            let pitch = tree.rect(ofRow: 1).minY - tree.rect(ofRow: 0).minY
            let offset = tree.rect(ofRow: 0).minY
            var animated = false
            func observeRows() {
                let last = tree.numberOfRows - 1
                if let row = tree.rowView(atRow: last, makeIfNecessary: false), let layer = row.layer {
                    let y = layer.presentation()?.frame.minY ?? row.frame.minY
                    let units = (y - offset) / pitch
                    animated = animated || abs(units - units.rounded()) * pitch > 0.5 ||
                        layer.animation(forKey: "position") != nil || layer.animation(forKey: "bounds") != nil
                }
            }
            try await waitFor(movement) {
                observeRows()
                return names.allSatisfy { row(named: $0, in: tree) != nil }
            }
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(16))
                observeRows()
            }
            try expect(!animated, movement + " without animating the neighboring rows")
        }

        let alpha = try item(named: "Alpha")
        try select(["Alpha"])
        try arrow(expanding: true)
        try expect(tree.isItemExpanded(alpha) && retainsSelection(["Alpha"]), "Right opens a cold folder immediately")
        try await waitForRows(["Nested"], movement: "first keyboard expansion shows children")

        let nested = try item(named: "Nested")
        let bravo = try item(named: "Bravo")
        let charlie = try item(named: "Charlie")
        let group = ["Alpha", "Nested", "Bravo", "Charlie"]
        try select(group)
        try arrow(expanding: true)
        try expect(tree.isItemExpanded(alpha) && tree.isItemExpanded(nested) && tree.isItemExpanded(bravo) &&
                   tree.isItemExpanded(charlie) && retainsSelection(group), "Right expands every selected folder and keeps the group selected")
        try await waitForRows(["Leaf.txt", "Bravo.txt", "Charlie.txt"], movement: "group keyboard expansion shows all children")

        try select(group + ["README.md"])
        try arrow(expanding: false)
        try expect(!tree.isItemExpanded(alpha) && !tree.isItemExpanded(bravo) && !tree.isItemExpanded(charlie) &&
                   retainsSelection(["Alpha", "Bravo", "Charlie", "README.md"]), "Left collapses the selected branches and keeps visible selection")
        try await waitForRows(["Alpha", "Bravo", "Charlie"], movement: "group keyboard collapse settles")
        try select(["Alpha"])
        try arrow(expanding: true)
        try expect(tree.isItemExpanded(nested) && row(named: "Leaf.txt", in: tree) != nil && retainsSelection(["Alpha"]),
                   "reopening the parent preserves its descendant's expanded state")

        let delta = try item(named: "Delta")
        try select(["Delta"])
        try press(" ", code: 49, in: tree, enqueue: true)
        try expect(tree.isItemExpanded(delta) && retainsSelection(["Delta"]), "Space opens a cold folder immediately")
        try await waitForRows(["Delta.txt"], movement: "first Space expansion shows children")
    }

    private static func checkFolderAnimation(in app: Edit, under directory: URL) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let root = directory.appending(path: "Animation", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let childCount = 6
        for index in 1...childCount {
            try Data().write(to: folder.appending(path: "Child \(index).txt"))
        }
        try Data().write(to: root.appending(path: "README.md"))
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        _ = try await app.openFile(root, in: document)
        document.toggleSidebarFocus(.worktree)
        let tree = try require(document.worktreeSidebar?.outline, "animation outline")
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        try expect(window.isVisible && !NSApp.isActive, "quiet live animation instance")
        try await waitFor("animation fixture loads") { tree.numberOfRows == 2 }
        window.layoutIfNeeded()
        let item = try require(tree.item(atRow: 0), "animation folder")
        let clip = try require(tree.enclosingScrollView?.contentView, "Worktree clip view")
        tree.updateTrackingAreas()
        try expect(tree.trackingAreas.contains {
            $0.owner === tree && $0.options.contains([.cursorUpdate, .activeInKeyWindow, .inVisibleRect])
        }, "native cursor refreshes reach the outline while it tracks the disclosure click")
        let hoveredDisclosure = try disclosure(at: 0, in: tree)
        let hover = hoveredDisclosure.convert(NSPoint(x: hoveredDisclosure.bounds.midX, y: hoveredDisclosure.bounds.midY), to: nil)
        var cursorImages: [NSCursor] = []
        let cursorTracking = EditApplication.ClickCursorTracking(currentCursor: { cursorImages.last ?? .arrow },
                                                                setCursor: { cursorImages.append($0) })
        defer { cursorTracking.end() }
        var cursorUsesNativeFallback = false
        func sampleDisclosureCursor() {
            cursorTracking.dispatch(.cursorUpdate, in: window, resolve: {
                EditApplication.clickCursor(in: window, at: hover)
            }) { cursorUsesNativeFallback = true }
        }
        func checkViewportWidth() throws {
            let viewport = clip.bounds
            let proposed = clip.constrainBoundsRect(viewport.offsetBy(dx: viewport.width, dy: 0))
            try expect(abs(tree.frame.width - viewport.width) < 0.5 && abs(proposed.minX - viewport.minX) < 0.5,
                       "expanding folders keeps the outline fixed horizontally (tree \(tree.frame.width), viewport \(viewport.width), reachable x \(proposed.minX))")
        }
        let collapsedY = tree.rect(ofRow: 1).minY
        let rowHeight = tree.rect(ofRow: 1).height
        let expandedY = collapsedY + CGFloat(childCount) * rowHeight
        func siblingRow() -> NSTableRowView? {
            tree.rowView(atRow: tree.numberOfRows - 1, makeIfNecessary: false)
        }
        func displayedY() -> CGFloat? {
            guard let sibling = siblingRow() else { return nil }
            return sibling.layer?.presentation()?.frame.minY ?? sibling.frame.minY
        }
        func childrenMoveWithSibling(_ lastChild: NSTableRowView?) -> Bool {
            guard let y = displayedY(), y > collapsedY + rowHeight && y < expandedY - rowHeight,
                  let outlineLayer = tree.layer?.presentation(),
                  let childLayer = lastChild?.layer?.presentation() else { return false }
            let childBounds = outlineLayer.convert(childLayer.bounds, from: childLayer)
            return abs(childBounds.maxY - y) < 0.5
        }
        func clickChevron() throws {
            let button = try disclosure(at: 0, in: tree)
            let action = try require(button.action, "disclosure action")
            try expect(NSApp.sendAction(action, to: button.target, from: button), "dispatch the chevron action")
        }
        func expectKeyboardStep(_ characters: String, code: UInt16, expanded: Bool) throws {
            try press(characters, code: code, in: tree)
            let settledY = expanded ? expandedY : collapsedY
            let row = try require(siblingRow(), "sibling row after keyboard expansion")
            try expect(tree.isItemExpanded(item) == expanded && abs(row.frame.minY - settledY) < 0.5 &&
                       row.layer?.animationKeys()?.isEmpty != false && document.window.firstResponder === tree,
                       "keyboard expansion or collapse updates row geometry immediately")
        }

        try await waitFor("render the collapsed rows") { abs((displayedY() ?? -1) - collapsedY) < 0.5 }
        sampleDisclosureCursor()
        try clickChevron()
        try await waitFor("the first mouse expansion slides the children and sibling together") {
            sampleDisclosureCursor()
            return tree.isItemExpanded(item) && childrenMoveWithSibling(tree.rowView(atRow: childCount, makeIfNecessary: false))
        }
        try checkViewportWidth()
        try await waitFor("the expanded rows settle") {
            sampleDisclosureCursor()
            return abs((displayedY() ?? -1) - expandedY) < 0.5 && siblingRow()?.layer?.animationKeys()?.isEmpty != false
        }

        try checkViewportWidth()
        let split = try require(window.contentViewController as? NSSplitViewController, "Worktree split view")
        let sidebarWidth = split.splitViewItems[0].viewController.view.frame.width
        split.splitView.setPosition(sidebarWidth - 32, ofDividerAt: 0)
        window.layoutIfNeeded()
        try expect(clip.bounds.width < sidebarWidth, "resizing the sidebar narrows the visible Worktree")
        try checkViewportWidth()
        split.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        window.layoutIfNeeded()
        try checkViewportWidth()

        let lastChild = try require(tree.rowView(atRow: childCount, makeIfNecessary: false), "last expanded child")
        try clickChevron()
        try await waitFor("mouse collapse slides the children and sibling together") {
            sampleDisclosureCursor()
            return !tree.isItemExpanded(item) && childrenMoveWithSibling(lastChild)
        }
        try await waitFor("the collapsed rows settle") {
            sampleDisclosureCursor()
            return abs((displayedY() ?? -1) - collapsedY) < 0.5 && siblingRow()?.layer?.animationKeys()?.isEmpty != false
        }
        try expect(cursorImages == [.pointingHand] && !cursorUsesNativeFallback,
                   "stationary disclosure hover keeps one cursor through two native click animations")

        tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.makeFirstResponder(tree)
        try expectKeyboardStep("\u{F703}", code: 124, expanded: true)
        try expectKeyboardStep("\u{F702}", code: 123, expanded: false)
        try expectKeyboardStep(" ", code: 49, expanded: true)
        try expectKeyboardStep(" ", code: 49, expanded: false)
    }

    private static func checkSelectionShape(in tree: NSOutlineView, window: NSWindow) throws {
        let original = tree.selectedRowIndexes
        let appearance = window.appearance
        defer {
            tree.selectRowIndexes(original, byExtendingSelection: false)
            window.appearance = appearance
        }
        window.appearance = NSAppearance(named: .darkAqua)

        func check(_ selection: IndexSet, _ edges: [(row: Int, top: Bool, bottom: Bool)], name: String) throws {
            tree.selectRowIndexes(selection, byExtendingSelection: false)
            window.layoutIfNeeded()
            for edge in edges {
                let row = try require(tree.rowView(atRow: edge.row, makeIfNecessary: true), "selected Worktree row")
                let bounds = row.bounds
                let image = try require(row.bitmapImageRepForCachingDisplay(in: bounds), "Worktree selection bitmap")
                row.cacheDisplay(in: bounds, to: image)
                let x = Int(7 * CGFloat(image.pixelsWide) / bounds.width)
                let y = Int(CGFloat(image.pixelsHigh) / bounds.height)
                let fill = try require(image.colorAt(x: x, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB), "selection fill")
                try expect(fill.alphaComponent > 0.5, "the center of the selected row is painted")
                func edgeIsFilled(y: Int) throws -> Bool {
                    let pixel = try require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), "selection corner pixel")
                    return abs(pixel.alphaComponent - fill.alphaComponent) < 0.08 &&
                        abs(pixel.redComponent - fill.redComponent) < 0.08
                }
                let top = try edgeIsFilled(y: y)
                let bottom = try edgeIsFilled(y: image.pixelsHigh - y - 1)
                try expect(top == edge.top && bottom == edge.bottom,
                           "\(name) selection rounds only exposed ends (row \(edge.row), top \(top), bottom \(bottom))")
            }
        }

        try check(IndexSet([0, 2]), [(0, false, false), (2, false, false)], name: "disjoint")
        try check(IndexSet(integersIn: 0...2), [(0, false, true), (1, true, true), (2, true, false)], name: "joined")
        try check(IndexSet([0, 2]), [(0, false, false), (2, false, false)], name: "split-again")
    }

    private static func checkDisclosureStyle(_ button: NSButton) throws {
        try expect(button.image?.isTemplate == false && button.alternateImage?.isTemplate == false,
                   "both disclosure states keep their assigned color through contextual menus")
    }

    private static func checkDisclosureContrast(_ button: NSButton, in window: NSWindow) throws {
        let frameView = try require(window.contentView?.superview, "Worktree render frame")
        let row = try require(button.superview as? NSTableRowView, "Worktree disclosure row")
        let originalAppearance = window.appearance
        let emphasized = row.isEmphasized
        defer {
            row.isEmphasized = emphasized
            window.appearance = originalAppearance
        }

        func glyphBrightness(dark: Bool) throws -> CGFloat {
            window.layoutIfNeeded()
            let bounds = frameView.convert(button.bounds, from: button)
            let bitmap = try require(frameView.bitmapImageRepForCachingDisplay(in: bounds), "Worktree disclosure render")
            frameView.cacheDisplay(in: bounds, to: bitmap)
            var extreme: CGFloat = dark ? 0 : 1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    extreme = dark ? max(extreme, pixel.redComponent) : min(extreme, pixel.redComponent)
                }
            }
            return extreme
        }

        try expect(!row.isSelected, "measure the color of an unselected disclosure")
        window.appearance = NSAppearance(named: .darkAqua)
        let before = try glyphBrightness(dark: true)
        row.isEmphasized = !emphasized
        let during = try glyphBrightness(dark: true)
        row.isEmphasized = emphasized
        let after = try glyphBrightness(dark: true)
        try expect(before > 0.48 && abs(during - before) < 0.02 && abs(after - before) < 0.02,
                   "the chevron draws at secondary-label contrast through emphasis changes (\(before), \(during), \(after))")

        window.appearance = NSAppearance(named: .aqua)
        let light = try glyphBrightness(dark: false)
        try expect(light < 0.65, "the same chevron adapts to a light background (\(light))")
    }

    private static func disclosure(at row: Int, in outline: NSOutlineView) throws -> NSButton {
        let button = outline.rowView(atRow: row, makeIfNecessary: true)?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.identifier == NSOutlineView.disclosureButtonIdentifier ||
                $0.identifier == NSOutlineView.showHideButtonIdentifier }
        return try require(button, "native disclosure button")
    }

    private static func press(_ characters: String, code: UInt16, in outline: NSOutlineView,
                              modifiers: NSEvent.ModifierFlags = [], enqueue: Bool = false) throws {
        let window = try require(outline.window, "keyboard navigation window")
        let event = try require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ), "outline key event")
        if enqueue {
            NSApp.postEvent(event, atStart: true)
            let queued = try require(NSApp.nextEvent(matching: .keyDown, until: .distantPast,
                                                     inMode: .default, dequeue: true), "queued Worktree key")
            outline.keyDown(with: queued)
        } else {
            outline.keyDown(with: event)
        }
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
