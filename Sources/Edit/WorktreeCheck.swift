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
        document.toggleWorktreeSidebar()
        try expect(document.worktreeSidebar == nil, "Worktree is unavailable before opening a folder")
        _ = try await app.openFile(project, in: document)
        document.toggleWorktreeSidebar()
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
        let disclose = try disclosure(at: sources, in: tree)
        let fileCell = try require(cell(at: log, in: tree), "file row")
        let fileIcon = try require(fileCell.imageView, "file icon")
        try expect(cell(at: sources, in: tree)?.imageView?.image == nil, "folders show only the disclosure symbol")
        fileCell.layoutSubtreeIfNeeded()
        let folderGlyphFrame = disclose.convert(disclose.bounds, to: tree)
        let fileGlyphFrame = fileIcon.convert(fileIcon.bounds, to: tree)
        try expect(abs(folderGlyphFrame.minX - fileGlyphFrame.minX) < 0.5 &&
                   abs(folderGlyphFrame.width - fileGlyphFrame.width) < 0.5,
                   "sibling folders and files use the same icon gutter (\(folderGlyphFrame) and \(fileGlyphFrame))")
        try click(log, in: tree, modifiers: [.command])
        try expect(tree.selectedRowIndexes.contains(log), "Command-click selects the file")
        try await Task.sleep(for: .milliseconds(40))
        try expect(document.fileURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(readme),
                   "Command-click selects without opening a file")
        try click(log, in: tree)
        try await waitFor("open a file from a single click on an already selected row") {
            document.fileURL.map(WorktreeFileOperations.path) == WorktreeFileOperations.path(ignored)
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

        let rootItem = try require(tree.item(atRow: 0), "retrieve Worktree root")
        let rootButton = try disclosure(at: 0, in: tree)
        rootButton.performClick(nil)
        try expect(tree.numberOfRows == 1 && !tree.isItemExpanded(rootItem),
                   "manually collapse the tree containing the current file")
        sidebar.setShowsHidden(true)
        sidebar.refresh()
        try expect(tree.numberOfRows == 1 && !tree.isItemExpanded(rootItem),
                   "refreshing the tree keeps the root collapsed")
        sidebar.setShowsHidden(false)
        _ = try await app.openFile(readme, in: document)
        try await waitFor("reveal a new file after manually collapsing the root") {
            tree.isItemExpanded(rootItem) && row(named: "README.md", in: tree) == tree.selectedRow
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
        document.toggleWorktreeSidebar()
        try expect(!sidebar.view.isHiddenOrHasHiddenAncestor, "return from Search to Worktree")

        guard let root = document.folderURL else { throw Failure("the move has a worktree") }
        let target = try WorktreeFileOperations.create("Nested/Target", in: root, root: root, isDirectory: true)
        let created = try WorktreeFileOperations.create("Created/Notes.txt", in: target, root: root, isDirectory: false)
        try expect(FileManager.default.fileExists(atPath: created.path), "create a file and its parent folders from a relative name")
        _ = try await app.openFile(ignored, in: document)
        let editor = document.editor
        editor.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
        let actions = WorktreeActions(document: document, app: app, refresh: { sidebar.refresh() },
                                      isHidden: { _ in false }, toggleHidden: { _ in })
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
    }

    private static func disclosure(at row: Int, in outline: NSOutlineView) throws -> NSButton {
        let button = outline.rowView(atRow: row, makeIfNecessary: true)?.subviews
            .compactMap { $0 as? NSButton }
            .first { $0.identifier == NSOutlineView.disclosureButtonIdentifier ||
                $0.identifier == NSOutlineView.showHideButtonIdentifier }
        return try require(button, "native disclosure button")
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
