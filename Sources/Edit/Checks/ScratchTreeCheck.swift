import AppKit

@MainActor
enum ScratchTreeCheck {
    static func run(in app: Edit) async throws {
        guard app.isAgentCheck else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-tree-check-\(UUID())", directoryHint: .isDirectory)
        let source = root.appending(path: "Scratch Tree Source", directoryHint: .isDirectory)
        let destination = root.appending(path: "Scratch Tree Destination", directoryHint: .isDirectory)
        for folder in [source, destination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let store = app.scratchStore
        let members = try await [
            store.create(name: "Alpha.txt", text: "Alpha", format: FileFormat(), in: source).0,
            store.create(name: "Beta.txt", text: "Beta", format: FileFormat(), in: source).0,
            store.create(name: "Gamma.txt", text: "Gamma", format: FileFormat(), in: source).0,
        ]
        let (dotFile, _) = try await store.create(name: ".Dest.txt", text: "Destination", format: FileFormat(), in: destination)
        let (global, _) = try await store.create(name: "Global Tree Test.txt", text: "Global", format: FileFormat(), in: nil)
        let window = app.makeDocument()
        defer { window.window.close() }
        _ = try await app.openFile(source, in: window)
        window.toggleSidebarFocus(.scratches)
        let tree = try require(window.scratchOutline, "the Scratches outline is available")
        try expect(tree.allowsMultipleSelection && tree.accessibilityLabel() == "Scratches",
                   "Scratches uses a multiselect outline")
        try await waitFor("both project categories appear") {
            row(named: source.lastPathComponent, in: tree) != nil && row(named: destination.lastPathComponent, in: tree) != nil
        }
        let options = try require(window.window.toolbar?.items.compactMap { $0 as? SidebarMenuItem }.first?.options,
                                  "the Scratches toolbar menu is available")
        try expect(options.menu.items.map(\.title) == ["New File…"], "Scratches only offers New File in the toolbar menu")
        let group = try require(row(named: destination.lastPathComponent, in: tree), "the destination category is visible")
        let groupItem = try require(tree.item(atRow: group), "the destination category can be expanded")
        tree.expandItem(groupItem)
        try await waitFor("a dot-prefixed scratch appears in the tree") { row(named: dotFile.name, in: tree) != nil }
        tree.collapseItem(groupItem)
        let sourceRow = try require(row(named: source.lastPathComponent, in: tree), "the source category appears")
        let sourceItem = try require(tree.item(atRow: sourceRow), "the source category is a tree item")
        try expect(tree.isExpandable(sourceItem) && tree.level(forRow: sourceRow) == 0,
                   "project categories are expandable root-level rows")
        tree.expandItem(sourceItem)
        try await waitFor("the category expands to its scratch files") {
            members.allSatisfy { row(named: $0.name, in: tree) != nil }
        }
        let alpha = try require(row(named: members[0].name, in: tree), "Alpha is visible")
        try expect(tree.level(forRow: alpha) == 1, "scratch files appear one level under their category")

        try click(alpha, in: tree)
        try await waitFor("plain click opens its scratch and keeps focus in the outline") {
            window.scratchFile?.id == members[0].id && window.window.firstResponder === tree
        }
        try await waitFor("plain click selects Alpha before extending selection") {
            selection(in: tree) == [members[0].name]
        }
        let baselineRow = try require(row(named: members[0].name, in: tree), "Alpha is still visible")
        let beta = try require(row(named: members[1].name, in: tree), "Beta is visible")
        try SidebarFileTreeCheck.checkNameWidths(in: tree, rows: [sourceRow, baselineRow, beta])
        try click(beta, in: tree, modifiers: .command)
        try expect(tree.selectedRowIndexes.contains(beta) && window.scratchFile?.id == members[0].id &&
                   window.window.firstResponder === tree, "Command-click changes selection without opening Beta")
        // Synthetic events leave the system modifier state clear in both native outlines.
        tree.selectRowIndexes(IndexSet([baselineRow, beta]), byExtendingSelection: false)
        try expect(selection(in: tree) == [members[0].name, members[1].name], "the outline retains a multiple selection")
        try click(baselineRow, in: tree)
        let gamma = try require(row(named: members[2].name, in: tree), "Gamma is visible")
        try click(gamma, in: tree, modifiers: .shift)
        try expect(window.scratchFile?.id == members[0].id, "Shift-click keeps the current scratch open")
        tree.selectRowIndexes(IndexSet(integersIn: baselineRow...gamma), byExtendingSelection: false)

        let fileMenu = try require(menu(at: alpha, in: tree), "the file has a context menu")
        for command in ["Show in Finder", "Open With", "Copy", "Copy Path", "Rename…", "Move to", "Move to Trash"] {
            try expect(fileMenu.item(withTitle: command) != nil, "the file menu offers \(command)")
        }
        try expect(fileMenu.item(withTitle: "Hide") == nil && fileMenu.item(withTitle: "Unhide") == nil,
                   "the scratch file menu has no hidden-file commands")
        let destinationRow = try require(row(named: destination.lastPathComponent, in: tree), "the destination category appears")
        let categoryMenu = try require(menu(at: destinationRow, in: tree), "the category has a context menu")
        try expect(categoryMenu.item(withTitle: "New File…") != nil && categoryMenu.item(withTitle: "New Folder…") == nil,
                   "the category permits new scratches and omits folder creation")

        tree.selectRowIndexes(IndexSet(integer: gamma), byExtendingSelection: false)
        let space = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.window.windowNumber, context: nil, characters: " ",
                                                 charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49),
                                "the Scratches Space event is available")
        tree.keyDown(with: space)
        try await waitFor("Space opens the selected scratch and focuses its buffer") {
            window.scratchFile?.id == members[2].id && window.window.firstResponder === window.editor
        }
        try click(beta, in: tree)
        try await waitFor("opening a different scratch changes the active document") { window.scratchFile?.id == members[1].id }
        tree.collapseItem(sourceItem)
        try await ControlPanel(app: app).checkScratches(in: window, scratch: members[0], global: global)
        let activeRow = try require(row(named: members[0].name, in: tree), "the scratch opened from Control is visible")
        try expect(tree.selectedRowIndexes == IndexSet(integer: activeRow) && window.window.firstResponder === window.editor,
                   "Control highlights the opened scratch while the editor keeps focus")

        try click(activeRow, in: tree)
        let lastRow = try require(row(named: members[2].name, in: tree), "the last scratch can be selected for dragging")
        tree.selectRowIndexes(IndexSet(integersIn: activeRow...lastRow), byExtendingSelection: false)
        let dataSource = try require(tree.dataSource, "the outline has a data source")
        let writers = try tree.selectedRowIndexes.map { row in
            let item = try require(tree.item(atRow: row), "a selected scratch has an outline item")
            return try require(dataSource.outlineView?(tree, pasteboardWriterForItem: item), "each selected scratch has a drag writer")
        }
        try expect(writers.count == members.count, "the drag contains the entire scratch selection")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try expect(pasteboard.writeObjects(writers), "write selected scratch URLs to a disposable drag pasteboard")
        let drag = ControlPinDragCheck(table: tree, location: .zero, pasteboard: pasteboard)
        drag.numberOfValidItemsForDrop = writers.count
        let targetRow = try require(row(named: destination.lastPathComponent, in: tree), "the drop target is visible")
        let destinationItem = try require(tree.item(atRow: targetRow), "the drop target is a tree item")
        let operation = dataSource.outlineView?(tree, validateDrop: drag, proposedItem: destinationItem,
                                               proposedChildIndex: NSOutlineViewDropOnItemIndex)
        try expect(operation == .move, "dropping on another project accepts a move")
        try expect(dataSource.outlineView?(tree, acceptDrop: drag, item: destinationItem,
                                          childIndex: NSOutlineViewDropOnItemIndex) == true,
                   "the shared outline drop handler accepts the selected files")
        let destinationPath = ScratchStore.folderPath(for: destination)
        let ids = Set(members.map(\.id))
        try await waitFor("all selected scratches move to the destination and retain identity") {
            let moved = try await store.files().filter { ids.contains($0.id) && $0.folderPath == destinationPath }
            return moved.count == members.count
        }
        try expect(window.scratchFile?.id == members[0].id && window.editor.string == "Alpha",
                   "moving the active scratch keeps its editor open")
        try await waitFor("the moved active scratch is revealed and selected at its destination") {
            guard let row = row(named: members[0].name, in: tree), let item = tree.item(atRow: row),
                  let parent = tree.parent(forItem: item),
                  let target = self.row(named: destination.lastPathComponent, in: tree) else { return false }
            return tree.row(forItem: parent) == target && tree.selectedRowIndexes.contains(row)
        }

        let movedRow = try require(row(named: members[0].name, in: tree), "the moved scratch can be renamed")
        let renameMenu = try require(menu(at: movedRow, in: tree), "the moved scratch has a menu")
        renameMenu.performActionForItem(at: renameMenu.indexOfItem(withTitle: "Rename…"))
        let field = try require(window.window.firstResponder as? NSTextView, "rename uses the Worktree field editor")
        try expect(field.isFieldEditor, "rename edits the scratch name in its row")
        field.insertText("Renamed.swift", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        let enter = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.window.windowNumber, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                                "the inline Return event is available")
        field.keyDown(with: enter)
        try await waitFor("renaming updates the active file and its row") {
            window.scratchFile?.name == "Renamed.swift" && row(named: "Renamed.swift", in: tree) != nil
        }
        try expect(window.scratchFile?.id == members[0].id && window.resolvedSyntaxLanguage == .swift,
                   "rename keeps the scratch identity and updates syntax detection")
        try expect(tree.tryToPerform(Selector(("undo:")), with: nil), "undo dispatches through the Worktree outline")
        try await waitFor("undo restores the original name") { window.scratchFile?.name == members[0].name }
    }

    private static func click(_ row: Int, in tree: NSOutlineView, modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try require(tree.window, "the tree belongs to a window")
        window.layoutIfNeeded()
        window.makeFirstResponder(tree)
        let down = try mouseEvent(.leftMouseDown, row: row, in: tree, modifiers: modifiers)
        let up = try mouseEvent(.leftMouseUp, row: row, in: tree, modifiers: modifiers)
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        let queued = try require(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                                                 inMode: .default, dequeue: true), "the native mouse-down is queued")
        tree.mouseDown(with: queued)
    }

    private static func menu(at row: Int, in tree: NSOutlineView) throws -> NSMenu? {
        tree.menu(for: try mouseEvent(.rightMouseDown, row: row, in: tree))
    }

    private static func mouseEvent(_ type: NSEvent.EventType, row: Int, in tree: NSOutlineView,
                                   modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try require(tree.window, "the event has a window")
        let frame = tree.frameOfCell(atColumn: 0, row: row)
        let location = tree.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        return try require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                              clickCount: 1, pressure: 1), "the outline mouse event is available")
    }

    private static func row(named name: String, in tree: NSOutlineView) -> Int? {
        (0..<tree.numberOfRows).first { title(at: $0, in: tree) == name }
    }

    private static func selection(in tree: NSOutlineView) -> [String] {
        tree.selectedRowIndexes.compactMap { title(at: $0, in: tree) }
    }

    private static func title(at row: Int, in tree: NSOutlineView) -> String? {
        (tree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    private static func waitFor(_ detail: String, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw Failure(detail)
    }

    private static func require<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw Failure(detail) }
        return value
    }

    private static func expect(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Scratch tree check: \(detail)" }
    }
}
