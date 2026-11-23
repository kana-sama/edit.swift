import AppKit

@MainActor
enum SourceControlCheck {
    static func run(in app: Edit, render: (NSWindow) throws -> Void) async throws {
        guard let executable = JJRepository.executable else { return }
        let fixture = FileManager.default.temporaryDirectory.appending(path: "Edit Jujutsu \(UUID())")
        let folder = fixture.appending(path: "Project")
        let nested = folder.appending(path: "Notes")
        let plain = fixture.appending(path: "Plain")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        let file = nested.appending(path: "Tracked.txt")
        let liveFile = nested.appending(path: "Live.txt")
        let removed = folder.appending(path: "Removed.txt")
        let original = (1...18).map { "Line \($0)\n" }.joined()
        try await command(executable, folder, ["git", "init", "--colocate"])
        try original.write(to: file, atomically: true, encoding: .utf8)
        try "Clean working file\n".write(to: liveFile, atomically: true, encoding: .utf8)
        try "Removed from the working change\n".write(to: removed, atomically: true, encoding: .utf8)
        try await command(executable, folder, ["describe", "-m", "Base"])
        try await command(executable, folder, ["new", "-m", "Historical change"])
        let historical = original.replacingOccurrences(of: "Line 8\n", with: "Historical line\n")
        try historical.write(to: file, atomically: true, encoding: .utf8)
        try await command(executable, folder, ["new", "-m", "Working change\n\n" + String(repeating: "A long description stays in the popover.\n", count: 12)])
        try await command(executable, folder, ["bookmark", "create", "review/jj-sidebar-layout-with-a-long-bookmark", "-r", "@"])
        let working = historical.replacingOccurrences(of: "Line 3\n", with: "Working line 3\n")
            .replacingOccurrences(of: "Line 14\n", with: "Working line 14\n")
        try working.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: removed)
        try await command(executable, folder, ["util", "snapshot"])
        guard let workspace = await JJRepository.discover(at: nested) else { throw Failure("resolve the enclosing workspace") }
        let head = try await JJRepository.operation(in: workspace)

        let document = app.makeDocument()
        defer { document.window.close() }
        guard let menu = NSApplication.shared.mainMenu,
              let viewMenu = menu.item(withTitle: "View")?.submenu,
              let focus = viewMenu.item(withTitle: "Focus Jujutsu"),
              let previous = menu.items.compactMap(\.submenu).lazy.compactMap({ $0.item(withTitle: "Find Previous") }).first,
              let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                             windowNumber: document.window.windowNumber, context: nil, characters: "G",
                                             charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5) else {
            throw Failure("find the Focus Jujutsu command and its shortcut")
        }
        try expect(!app.validateUserInterfaceItem(focus), "disable Focus Jujutsu without an open folder")
        _ = try await app.openFile(nested, in: document)
        try expect(app.validateUserInterfaceItem(focus) && focus.keyEquivalent == "g" &&
                   focus.keyEquivalentModifierMask == [.command, .shift] && previous.keyEquivalent.isEmpty,
                   "assign Shift-Command-G to Focus Jujutsu in a nested workspace folder")
        try expect(app.routeWindowEvent(shortcut) != nil && viewMenu.performKeyEquivalent(with: shortcut), "dispatch Shift-Command-G through the View menu")
        guard let panel = document.sourceControlSidebar else { throw Failure("open Jujutsu from the shortcut, current mode \(document.sidebarMode.title)") }
        document.window.layoutIfNeeded()
        guard let sidebarMenu = document.window.toolbar?.items.compactMap({ $0 as? SidebarMenuItem }).first(where: { $0.modePicker != nil }) else {
            throw Failure("install the Jujutsu sidebar switcher")
        }
        try expect(document.sidebarMode.title == "Jujutsu" && sidebarMenu.modePicker?.selectedItem?.title == "Jujutsu",
                   "show the Jujutsu title in the switcher")
        try await waitFor("show the working change and both changed paths") {
            panel.selection?.isWorkingCopy == true && panel.detail?.files.count == 2
        }
        try expect(document.window.firstResponder === panel.graphView.table, "move keyboard focus to the graph when it loads")
        try expect(viewMenu.performKeyEquivalent(with: shortcut) && document.isSidebarVisible &&
                   document.window.firstResponder === document.contentResponder, "return focus to the document without closing Jujutsu")
        try expect(viewMenu.performKeyEquivalent(with: shortcut) && document.window.firstResponder === panel.graphView.table,
                   "focus the graph again with the same shortcut")
        document.window.layoutIfNeeded()
        try expect(panel.graphView.revisions.contains { $0.subject == "Historical change" }, "show multiple revisions in the graph")
        try expect(panel.graphView.revisions.filter(\.isWorkingCopy).count == 1, "mark exactly one working-copy graph node")
        try checkLayout(in: document, panel: panel)

        let tree = panel.fileTree.outline
        try open("Tracked.txt", in: panel.fileTree)
        do {
            try await waitFor("open and expand both working-file hunks") {
                guard document.editor.isEditable, document.fileURL == FileBuffer.canonicalURL(file),
                      let diff = document.editor.jjInlineDiff, document.editor.jjLineMarks.count == 2 else { return false }
                return document.editor.jjLineMarks.allSatisfy { diff.expandedRegion(for: $0) != nil }
            }
        } catch {
            let expanded = document.editor.jjInlineDiff?.hasExpandedHunks == true
            let marks = document.editor.jjLineMarks
            throw Failure("\(error.localizedDescription) (file \(document.fileURL?.path ?? "none"), editable \(document.editor.isEditable), marks \(marks), expanded \(expanded))")
        }
        try expect(document.sourceControlRevisionBanner == nil, "leave the ordinary editor free of a revision banner")
        try render(document.window)
        try expect(try await JJRepository.operation(in: workspace) == head, "leave repository history unchanged by inspection")
        let fileUndo = try await JJSourceControlOperations.preview(.undo, in: workspace)
        try expect(fileUndo.fileEffects.count == 2, "preview both working-copy file effects for Undo")
        try SourceControlPopoverCheck.run(preview: fileUndo)
        guard let currentFileRow = row(named: "Tracked.txt", in: tree) else { throw Failure("find a working file for the context menu") }
        try expect(panel.fileTree.menu(at: currentFileRow)?.item(withTitle: "Discard File Changes…")?.isEnabled == true,
                   "offer to discard changes to a file in @")
        try open("Removed.txt", in: panel.fileTree)
        try await waitFor("open the deleted working-copy file as read-only") {
            document.sourceControlRevisionBanner != nil && !document.editor.isEditable &&
                document.editor.jjInlineDiff?.hasExpandedHunks == true
        }
        try expect(row(named: "Removed.txt", in: tree) != nil, "keep a deleted row in the shared outline")

        guard let historyRow = panel.graphView.revisions.firstIndex(where: { $0.subject == "Historical change" }) else {
            throw Failure("find the history row")
        }
        let contextMenu = panel.graphView.table.menuForRow?(historyRow)
        try expect(contextMenu?.item(withTitle: "Squash into Parent")?.isEnabled == true && contextMenu?.item(withTitle: "Abandon Change…")?.isEnabled == true,
                   "offer change actions when opening the context menu on an unselected row")
        try await waitFor("browse a historical change while keeping the working-copy pointer") {
            panel.selection?.subject == "Historical change" && panel.detail?.files.count == 1
        }
        try expect(panel.graph?.workingCopy.subject == "Working change", "keep @ distinct from graph selection")
        try open("Tracked.txt", in: panel.fileTree)
        try await waitFor("open historical text with a revision banner and expanded diff") {
            document.sourceControlRevisionBanner != nil && !document.editor.isEditable &&
                document.editor.string == historical && document.editor.jjInlineDiff?.hasExpandedHunks == true
        }
        if let historicalFileRow = row(named: "Tracked.txt", in: tree) {
            try expect(panel.fileTree.menu(at: historicalFileRow) == nil, "keep historical file rows free of working-copy mutations")
        }

        try await command(executable, folder, ["describe", "-m", "Renamed at the terminal"])
        try await waitFor("refresh the external operation without changing the selected revision") {
            panel.graph?.workingCopy.subject == "Renamed at the terminal" && panel.selection?.subject == "Historical change"
        }
        let changedHead = try await JJRepository.operation(in: workspace)
        let undo = try await JJSourceControlOperations.preview(.undo, in: workspace)
        try expect(undo.fileEffects.isEmpty && !undo.revisionEffects.isEmpty, "preview a description-only operation as a graph change")
        try expect(try await JJRepository.operation(in: workspace) == changedHead, "leave the operation head unchanged while previewing Undo")
        try await checkOperationDirection(in: document.window, panel: panel)

        guard let currentRow = panel.graphView.revisions.firstIndex(where: \.isWorkingCopy) else {
            throw Failure("find the working copy after Redo")
        }
        panel.graphView.table.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false)
        try await waitFor("return to the working change’s tree") { panel.selection?.isWorkingCopy == true && panel.detail != nil }
        try open("Tracked.txt", in: panel.fileTree)
        try await waitFor("return from the revision preview to the live editor") {
            document.editor.isEditable && document.sourceControlRevisionBanner == nil && document.editor.string == working
        }
        _ = try await app.openFile(liveFile, in: document)
        let beforeTyping = try await JJRepository.operation(in: workspace)
        let typedAt = ContinuousClock.now
        document.editor.insertText("Unsaved\n", replacementRange: NSRange(location: 0, length: 0))
        try await waitFor("show an unsaved edit in the changed-file outline") { row(named: "Live.txt", in: tree) != nil }
        print("Jujutsu unsaved file row: \(typedAt.duration(to: .now)).")
        try expect(try await JJRepository.operation(in: workspace) == beforeTyping, "leave history untouched while showing a buffer edit")
        document.editor.undoManager?.undo()
        try await waitFor("remove the working file from the outline after undoing its buffer edit") { row(named: "Live.txt", in: tree) == nil }

        let external = folder.appending(path: "External.txt")
        let savedAt = ContinuousClock.now
        try "Saved outside the editor\n".write(to: external, atomically: true, encoding: .utf8)
        try await waitFor("show a disk change without a terminal command") {
            row(named: "External.txt", in: tree) != nil && tree.isEnabled
        }
        print("Jujutsu on-disk file row: \(savedAt.duration(to: .now)).")
        guard let externalRow = row(named: "External.txt", in: tree),
              let discard = panel.fileTree.menu(at: externalRow)?.item(withTitle: "Discard File Changes…")?.representedObject as? SourceControlFileRestore else {
            throw Failure("offer a path-scoped restore for an added file")
        }
        try await discard.discardChanges()
        try await waitFor("remove only the discarded path from the changed-file outline") {
            row(named: "External.txt", in: tree) == nil && row(named: "Tracked.txt", in: tree) != nil && tree.isEnabled
        }
        try expect(!FileManager.default.fileExists(atPath: external.path) && (try? String(contentsOf: file, encoding: .utf8)) == working,
                   "discard the selected added file and preserve unrelated changes")
        document.setFolder(plain)
        try expect(document.isSidebarVisible && document.sidebarMode == .worktree && sidebarMenu.menu.item(withTitle: "Jujutsu")?.isEnabled == false,
                   "leave Jujutsu and disable its switcher item when leaving the workspace")
        try expect(!app.validateUserInterfaceItem(focus) && focus.keyEquivalent.isEmpty && previous.keyEquivalent == "g",
                   "restore the Find Previous shortcut outside the workspace")
        app.focusJujutsu(nil)
        try expect(document.sidebarMode == .worktree, "ignore a direct focus command outside a workspace")
    }

    private static func checkOperationDirection(in window: NSWindow, panel: SourceControlSidebar) async throws {
        let operations = panel.operationsViewForCheck
        guard let open = button(in: panel.view, where: { $0.toolTip == "Repository Operations" }),
              let apply = button(in: operations, where: { $0.title == "Undo Operation" }),
              let directions = descendant(of: operations, where: { (_: NSSegmentedControl) in true }) else {
            throw Failure("find the operation popover controls")
        }
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer {
            if operations.window?.isVisible == true { open.performClick(nil) }
            window.orderOut(nil)
            window.setFrameOrigin(origin)
        }
        try expect(window.alphaValue == 0 && window.ignoresMouseEvents && !NSApp.isActive, "keep the operation check in the background")
        open.performClick(nil)
        try await waitFor("preview Undo in the popover") { apply.isEnabled && directions.selectedSegment == 0 }
        apply.performClick(nil)
        try await waitFor("show the applied Undo") {
            directions.isEnabled && panel.graph?.workingCopy.subject == "Working change"
        }
        try expect(directions.selectedSegment == 0 && apply.title == "Undo Operation", "keep Undo selected after applying it")
        try await waitFor("preview the previous operation in the same Undo tab") { apply.isEnabled }

        directions.selectedSegment = 1
        _ = directions.sendAction(directions.action, to: directions.target)
        try await waitFor("preview Redo in the popover") { apply.isEnabled && apply.title == "Redo Operation" }
        apply.performClick(nil)
        try await waitFor("show the applied Redo") {
            directions.isEnabled && panel.graph?.workingCopy.subject == "Renamed at the terminal"
        }
        try expect(directions.selectedSegment == 1 && apply.title == "Redo Operation", "keep Redo selected after applying it")
        try await waitFor("show the end of Redo history in the same tab") {
            !apply.isEnabled && descendant(of: operations, where: { (field: NSTextField) in
                field.stringValue == "There is no operation to redo."
            }) != nil
        }
    }

    private static func row(named name: String, in outline: NSOutlineView) -> Int? {
        (0..<outline.numberOfRows).first { index in
            (outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == name
        }
    }

    private static func checkLayout(in document: DocumentWindow, panel: SourceControlSidebar) throws {
        let split = document.documentSplitView
        guard let sidebar = split.arrangedSubviews.first,
              let graph = button(in: panel.view, where: { $0.title == "Changes" }),
              let graphCell = graph.cell,
              let detail = button(in: panel.view, where: { $0.title == "Change" }),
              let detailCell = detail.cell,
              let filter = button(in: panel.view, where: { $0.toolTip == "Filter Changes" }),
              let actions = button(in: panel.view, where: { $0.toolTip == "Change Actions" }),
              let create = button(in: panel.view, where: { $0.toolTip == "New Change" }) else {
            throw Failure("find the Source Control section controls")
        }
        let width = sidebar.frame.width
        PanelLayout.withoutAnimation {
            split.setPosition(211, ofDividerAt: 0)
            document.window.layoutIfNeeded()
        }
        defer {
            PanelLayout.withoutAnimation {
                split.setPosition(width, ofDividerAt: 0)
                document.window.layoutIfNeeded()
            }
        }
        try expect(!create.isHiddenOrHasHiddenAncestor && panel.view.convert(create.bounds, from: create).maxX <= panel.view.bounds.maxX,
                   "fit the graph controls at minimum sidebar width")
        for (toggle, firstAction) in [(graph, filter), (detail, actions)] {
            try expect(toggle.imagePosition == .imageTrailing && toggle.isAccessibilityExpanded() &&
                       panel.view.convert(firstAction.bounds, from: firstAction).minX -
                       panel.view.convert(toggle.bounds, from: toggle).maxX >= 10,
                       "place the \(toggle.title) chevron after the title and separate it from the actions")
        }
        guard let title = button(in: panel.view, where: { $0.title == "Working change" }),
              let graphRow = panel.graphView.table.view(atColumn: 0, row: panel.graphView.table.selectedRow, makeIfNecessary: true) else {
            throw Failure("find the collapsed title and the selected graph row")
        }
        try expect(title.cell?.usesSingleLineMode == true && title.bounds.height <= 24 && title.image != nil,
                   "make the compact change title a one-line description action")
        let graphLabels = graphRow.subviews.flatMap { child in
            [child as? NSTextField].compactMap { $0 } + child.subviews.compactMap { $0 as? NSTextField }
        }
        try expect(graphLabels.count == 3 && graphLabels.allSatisfy { $0.cell?.usesSingleLineMode == true && $0.maximumNumberOfLines == 1 },
                   "keep the graph subject, change ID, and long bookmark on two lines")
        let graphTitle = graphCell.titleRect(forBounds: graph.bounds)
        let graphChevron = graphCell.imageRect(forBounds: graph.bounds)
        let changeTitle = detailCell.titleRect(forBounds: detail.bounds)
        let changeChevron = detailCell.imageRect(forBounds: detail.bounds)
        graph.performClick(nil)
        document.window.layoutIfNeeded()
        try expect(panel.graphView.view.isHiddenOrHasHiddenAncestor && !panel.fileTree.view.isHiddenOrHasHiddenAncestor,
                   "keep the file tree visible when the graph collapses")
        try expect(!graph.isAccessibilityExpanded() && graphTitle == graphCell.titleRect(forBounds: graph.bounds) &&
                   graphChevron == graphCell.imageRect(forBounds: graph.bounds) && !create.isHiddenOrHasHiddenAncestor,
                   "keep the Changes title, chevron slot and actions in place when the graph collapses")
        graph.performClick(nil)
        detail.performClick(nil)
        document.window.layoutIfNeeded()
        try expect(!panel.graphView.view.isHiddenOrHasHiddenAncestor && panel.fileTree.view.isHiddenOrHasHiddenAncestor,
                   "keep the graph visible when change details collapse")
        try expect(!detail.isAccessibilityExpanded() && changeTitle == detailCell.titleRect(forBounds: detail.bounds) &&
                   changeChevron == detailCell.imageRect(forBounds: detail.bounds) && !actions.isHiddenOrHasHiddenAncestor,
                   "keep the Change title, chevron slot and actions in place when the details collapse")
        detail.performClick(nil)
        document.window.layoutIfNeeded()
    }

    private static func button(in view: NSView, where test: (NSButton) -> Bool) -> NSButton? {
        descendant(of: view, where: test)
    }

    private static func descendant<T: NSView>(of view: NSView, where test: (T) -> Bool) -> T? {
        if let candidate = view as? T, test(candidate) { return candidate }
        for subview in view.subviews {
            if let match = descendant(of: subview, where: test) { return match }
        }
        return nil
    }

    private static func open(_ name: String, in tree: SidebarFileTree) throws {
        guard let index = row(named: name, in: tree.outline) else { throw Failure("find \(name) in the changed-file outline") }
        tree.outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tree.activateClickedRow(index)
    }

    @concurrent
    private static func command(_ executable: URL, _ folder: URL, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = folder
        process.arguments = ["--no-pager", "--color=never"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw Failure(String(decoding: data, as: UTF8.self)) }
    }

    private static func waitFor(_ message: String, _ test: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            if test() { return }
            try await Task.sleep(for: .milliseconds(35))
        } while ContinuousClock.now < deadline
        throw Failure(message)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "Source Control: \(message)" }
    }
}
