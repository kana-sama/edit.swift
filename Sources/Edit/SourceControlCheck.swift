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
        try await checkRevsets(in: document, panel: panel, workspace: workspace, app: app)

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
        try await checkDescription(in: document.window, panel: panel)
        document.setFolder(plain)
        try expect(document.isSidebarVisible && document.sidebarMode == .worktree && sidebarMenu.menu.item(withTitle: "Jujutsu")?.isEnabled == false,
                   "leave Jujutsu and disable its switcher item when leaving the workspace")
        try expect(!app.validateUserInterfaceItem(focus) && focus.keyEquivalent.isEmpty && previous.keyEquivalent == "g",
                   "restore the Find Previous shortcut outside the workspace")
        app.focusJujutsu(nil)
        try expect(document.sidebarMode == .worktree, "ignore a direct focus command outside a workspace")
    }

    private static func checkRevsets(in document: DocumentWindow, panel: SourceControlSidebar, workspace: JJWorkspace, app: Edit) async throws {
        let picker = panel.revsetPickerForCheck
        let content = picker.checkView
        guard let open = button(in: panel.view, where: { $0.identifier?.rawValue == "JujutsuRevsets" }),
              let workingCopy = button(in: panel.view, where: { $0.toolTip == "Go to Working Copy" }),
              let sidebar = document.documentSplitView.arrangedSubviews.first else {
            throw Failure("find the revset and working-copy controls")
        }
        let window = document.window
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer {
            picker.close()
            window.orderOut(nil)
            window.setFrame(frame, display: false)
        }
        try expect(window.alphaValue == 0 && window.ignoresMouseEvents && !NSApp.isActive, "keep the revset check in the background")
        func showPicker() async throws {
            try await waitFor("finish closing the revset picker") { !picker.isShownForCheck }
            open.performClick(nil)
            try await waitFor("open the native revset picker") { content.window?.isVisible == true }
        }
        func press(_ title: String) throws {
            guard let control = button(in: content, where: { $0.title == title || $0.accessibilityLabel() == title }),
                  !control.isHiddenOrHasHiddenAncestor, control.isEnabled else { throw Failure("find \(title) in the revset picker") }
            control.performClick(nil)
        }
        func table() throws -> NSTableView {
            content.layoutSubtreeIfNeeded()
            guard let table = descendant(of: content, where: { (view: NSTableView) in view.accessibilityLabel() == "Revsets" }) else {
                throw Failure("find the revset table")
            }
            return table
        }
        func key(_ characters: String, code: UInt16, in list: NSTableView) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: list.window?.windowNumber ?? 0, context: nil,
                                              characters: characters, charactersIgnoringModifiers: characters,
                                              isARepeat: false, keyCode: code) else {
                throw Failure("dispatch a revset picker key")
            }
            list.keyDown(with: event)
        }
        func row(_ id: String) throws -> Int {
            guard let row = picker.entriesForCheck.firstIndex(where: { $0.id == id }) else {
                throw Failure("find revset \(id)")
            }
            return row
        }
        func choose(_ id: String) throws {
            let list = try table()
            list.selectRowIndexes(IndexSet(integer: try row(id)), byExtendingSelection: false)
            try key("\r", code: 36, in: list)
        }
        func hover(_ id: String) throws {
            let list = try table()
            let rect = list.rect(ofRow: try row(id))
            let point = list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: list.window?.windowNumber ?? 0, context: nil,
                                                eventNumber: 0, clickCount: 0, pressure: 0) else {
                throw Failure("dispatch a pointer move over a revset row")
            }
            list.mouseMoved(with: event)
        }
        try await showPicker()
        guard let field = descendant(of: content, where: { (_: EditorTextView) in true }),
              let codeScroll = field.enclosingScrollView else { throw Failure("find the shared revset code area") }
        try expect(picker.currentIDForCheck == SourceControlRevset.defaultLog.id, "start with the configured log")
        try await waitFor("show the configured default expression on opening") {
            !field.isEditable && !field.string.isEmpty
        }
        let defaultExpression = field.string
        let normalSize = content.bounds.size
        try expect(normalSize.width <= 318 && codeScroll.frame.height > 55, "make room for several lines in a compact popover")
        try hover(SourceControlRevset.allChanges.id)
        try await waitFor("preview a row on hover") { field.string == "all()" }
        try expect(!field.isEditable && content.bounds.size == normalSize &&
                   picker.currentIDForCheck == SourceControlRevset.defaultLog.id,
                   "preview all() without changing the active graph or resizing the popover")
        let initialTable = try table()
        let defaultCell = initialTable.view(atColumn: 0, row: try row(SourceControlRevset.defaultLog.id), makeIfNecessary: true)
        let hoveredCell = initialTable.view(atColumn: 0, row: try row(SourceControlRevset.allChanges.id), makeIfNecessary: true)
        try expect(defaultCell?.accessibilityLabel() == "Default Log, current revset" &&
                   hoveredCell?.accessibilityLabel() == "All Changes",
                   "mark the applied revset independently of the hover highlight")
        try key("\u{f700}", code: 126, in: initialTable)
        try expect(field.string == defaultExpression && picker.currentIDForCheck == SourceControlRevset.defaultLog.id,
                   "preview the previous row on Up")
        try key("\u{f701}", code: 125, in: initialTable)
        try expect(field.string == "all()" && picker.currentIDForCheck == SourceControlRevset.defaultLog.id,
                   "preview the next row on Down")
        try press("Edit All Changes")
        guard let builtInName = descendant(of: content, where: { (field: NSTextField) in field.placeholderString == "Revset name" }) else {
            throw Failure("find the built-in revset editor")
        }
        let removeBuiltIn = button(in: content, where: { $0.title == "Delete" })
        try expect(builtInName.isDescendant(of: initialTable) && !field.isEditable &&
                   removeBuiltIn?.isHiddenOrHasHiddenAncestor != false,
                   "rename a built-in in its row while protecting the expression")
        builtInName.stringValue = "Everything"
        try press("Save")
        try await waitFor("rename a built-in without changing its expression or selecting it") {
            picker.entriesForCheck.contains { $0.name == "Everything" && $0.expression == "all()" } &&
                picker.currentIDForCheck == SourceControlRevset.defaultLog.id
        }
        try choose(SourceControlRevset.allChanges.id)
        try await waitFor("show all() in the graph") {
            picker.currentIDForCheck == SourceControlRevset.allChanges.id &&
                panel.graphView.table.isEnabled && panel.graphView.revisions.contains(where: \.isWorkingCopy)
        }

        try await showPicker()
        try press("New Revset…")
        guard let name = descendant(of: content, where: { (field: NSTextField) in field.placeholderString == "Revset name" }),
              let save = button(in: content, where: { $0.title == "Save" }) else { throw Failure("find the revset form") }
        try expect(!save.isEnabled && field.isEditable && field.enclosingScrollView === codeScroll,
                   "edit in the preview area and require both a name and an expression")
        let newName = "Repository root with a deliberately long display name"
        name.stringValue = newName
        field.insertText("all(", replacementRange: NSRange(location: 0, length: 0))
        save.performClick(nil)
        try await waitFor("keep an invalid revset in the editor with an error") {
            save.isEnabled && descendant(of: content, where: { (field: NSTextField) in
                !field.isHidden && field.stringValue.contains("Error:")
            }) != nil
        }
        try expect(!picker.entriesForCheck.contains { $0.name == newName }, "keep invalid revsets out of the list")
        let multiline = "root() &\n  all()"
        field.insertText(multiline, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        save.performClick(nil)
        try await waitFor("apply the new multiline revset to the real graph") {
            panel.graphView.table.isEnabled && panel.graphView.revisions.count == 1 &&
                panel.graphView.revisions.first?.isWorkingCopy == false
        }
        guard let custom = picker.entriesForCheck.first(where: { $0.name == newName }) else {
            throw Failure("find the saved multiline revset")
        }

        _ = try table()
        let editPositions = try ["Default Log", "Everything", newName].map { title in
            guard let edit = button(in: content, where: { $0.accessibilityLabel() == "Edit \(title)" }) else {
                throw Failure("find each row’s edit action")
            }
            return content.convert(edit.bounds, from: edit).maxX
        }
        try expect(editPositions.allSatisfy { abs($0 - editPositions[0]) < 1 && $0 > content.bounds.maxX - 65 },
                   "align the edit buttons in a fixed trailing column")
        try hover(SourceControlRevset.allChanges.id)
        try await waitFor("browse another revset after creating one") { field.string == "all()" }
        try hover(custom.id)
        try await waitFor("show the new multiline expression on hover") { field.string == multiline }
        guard let layout = field.textLayoutManager else { throw Failure("use TextKit for the revset preview") }
        layout.ensureLayout(for: layout.documentRange)
        let firstLine = layout.textLayoutFragment(for: layout.documentRange.location)?.textElement as? NSTextParagraph
        let functionColor = firstLine?.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        try expect(field.string == multiline && !field.isEditable && functionColor == SyntaxColor.function.nativeColor,
                   "show the complete highlighted and selectable expression")

        let list = try table()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard let from = picker.entriesForCheck.firstIndex(where: { $0.id == custom.id }),
              let item = picker.tableView(list, pasteboardWriterForRow: from),
              pasteboard.writeObjects([item]) else { throw Failure("drag the custom revset") }
        let drag = ControlPinDragCheck(table: list, location: .zero, pasteboard: pasteboard)
        try expect(picker.tableView(list, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move &&
                   picker.tableView(list, acceptDrop: drag, row: 0, dropOperation: .above) &&
                   picker.entriesForCheck.first?.id == custom.id && picker.currentIDForCheck == custom.id,
                   "reorder the rows without changing the graph selection")

        let width = sidebar.frame.width
        PanelLayout.withoutAnimation {
            document.documentSplitView.setPosition(211, ofDividerAt: 0)
            window.layoutIfNeeded()
        }
        let pickerFrame = panel.view.convert(open.bounds, from: open)
        let jumpFrame = panel.view.convert(workingCopy.bounds, from: workingCopy)
        let fits = !open.isHiddenOrHasHiddenAncestor && pickerFrame.maxX <= jumpFrame.minX && pickerFrame.width > 20
        PanelLayout.withoutAnimation {
            document.documentSplitView.setPosition(width, ofDividerAt: 0)
            window.layoutIfNeeded()
        }
        try expect(fits && open.toolTip?.contains(newName) == true, "fit a long revset name alongside the graph actions")

        try choose(SourceControlRevset.allChanges.id)
        try await showPicker()
        try press("Edit \(newName)")
        try expect(name.isDescendant(of: list) && name.stringValue == newName && field.string == multiline && field.isEditable,
                   "edit the name in its row and the expression in its preview")
        try hover(SourceControlRevset.allChanges.id)
        try expect(field.string == multiline && picker.currentIDForCheck == SourceControlRevset.allChanges.id,
                   "leave the inline draft alone while hovering another row")
        name.stringValue = "Discard this draft"
        try press("Cancel")
        try expect(!field.isEditable && picker.entriesForCheck.first?.name == newName, "cancel editing without saving the name")
        try press("Edit \(newName)")
        name.stringValue = "Repository Root"
        save.performClick(nil)
        try await waitFor("keep the other revset selected after editing") {
            picker.entriesForCheck.first?.name == "Repository Root" && picker.currentIDForCheck == SourceControlRevset.allChanges.id
        }
        try choose(custom.id)
        try await waitFor("apply the reordered revset") {
            picker.currentIDForCheck == custom.id && panel.graphView.table.isEnabled && panel.graphView.revisions.count == 1
        }
        let otherProject = JJWorkspace(root: workspace.root.deletingLastPathComponent(), repository: workspace.repository)
        let otherSettings = try SourceControlRevsetStore(url: app.sourceControlRevsets.url).read(for: otherProject)
        try expect(otherSettings.selected == .defaultLog && otherSettings.custom.isEmpty, "scope saved revsets to the workspace root")
        let reopened = app.makeDocument()
        defer { reopened.window.close() }
        _ = try await app.openFile(workspace.root, in: reopened)
        reopened.toggleSidebarFocus(.sourceControl)
        guard let restored = reopened.sourceControlSidebar else { throw Failure("reopen Jujutsu from the workspace root") }
        try await waitFor("restore the selected revset and the reordered list") {
            restored.revsetPickerForCheck.entriesForCheck.first?.id == custom.id &&
                restored.revsetPickerForCheck.currentIDForCheck == custom.id &&
                restored.graphView.revisions.count == 1 && restored.graphView.revisions.first?.isWorkingCopy == false
        }

        workingCopy.performClick(nil)
        try await waitFor("reveal the working copy without changing the revset") {
            picker.currentIDForCheck == custom.id && panel.selection?.isWorkingCopy == true && panel.graphView.table.isEnabled
        }
        try await showPicker()
        try press("Edit Repository Root")
        try press("Delete")
        try await waitFor("return to the configured log after deleting the active revset") {
            !picker.entriesForCheck.contains { $0.id == custom.id } && picker.currentIDForCheck == SourceControlRevset.defaultLog.id &&
                panel.graphView.table.isEnabled && panel.detail?.files.count == 2
        }
    }

    private static func checkDescription(in window: NSWindow, panel: SourceControlSidebar) async throws {
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.setFrameOrigin(origin)
        }
        try expect(window.alphaValue == 0 && window.ignoresMouseEvents && !NSApp.isActive, "keep the description check in the background")
        let content = panel.descriptionViewForCheck
        guard let revision = panel.selection,
              let open = button(in: panel.view, where: { $0.toolTip == "Edit change description" }),
              let save = button(in: content, where: { $0.title == "Save" }),
              let scroll = descendant(of: content, where: { (_: NSScrollView) in true }),
              let editor = scroll.documentView as? EditorTextView,
              let layout = editor.textLayoutManager else { throw Failure("find the change description and its editor") }
        func checkViewport() throws {
            content.layoutSubtreeIfNeeded()
            let size = scroll.contentSize
            let cellWidth = ("0" as NSString).size(withAttributes: [.font: EditorTextView.defaultFont]).width
            let padding = editor.textContainerInset.width + (editor.textContainer?.lineFragmentPadding ?? 0)
            try expect(abs(size.width - 2 * padding - 72 * cellWidth) < 1.1 && size.height >= 220,
                       "open the description with a 72-column viewport (\(size.width) × \(size.height))")
        }
        func paragraph(at offset: Int) throws -> NSAttributedString {
            guard let location = layout.location(layout.documentRange.location, offsetBy: offset),
                  let paragraph = layout.textLayoutFragment(for: location)?.textElement as? NSTextParagraph else {
                throw Failure("lay out the description paragraph at \(offset)")
            }
            return paragraph.attributedString
        }

        open.performClick(nil)
        try await waitFor("show the description in the popover") { content.window?.isVisible == true }
        try checkViewport()
        try expect(editor.string == revision.description && editor.isEditable && content.window?.firstResponder === editor &&
                   editor.selectedRange() == NSRange(location: 0, length: revision.subject.utf16.count),
                   "open the complete description and select the editable subject")

        let prefix = "Keep the full change description visible in Edit e\u{301}"
        let subject = prefix + " with more detail"
        let body = "Show the complete description and keep the subject easy to edit."
        let edited = subject + "\n\n" + String(repeating: body + "\n", count: 16)
        editor.insertText(edited, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        layout.ensureLayout(for: layout.documentRange)
        let rendered = try paragraph(at: 0)
        let bold = rendered.attribute(.font, at: prefix.utf16.count - 1, effectiveRange: nil) as? NSFont
        let excess = rendered.attribute(.font, at: prefix.utf16.count, effectiveRange: nil) as? NSFont
        let red = rendered.attribute(.foregroundColor, at: prefix.utf16.count, effectiveRange: nil) as? NSColor
        let second = try paragraph(at: subject.utf16.count + 2)
        try expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true &&
                   excess.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false &&
                   red == .systemRed && second.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != .systemRed,
                   "emphasize 50 complete characters and color only the subject overflow")
        try expect(editor.bounds.height > scroll.contentSize.height, "scroll a long body inside the popover")
        editor.undoManager?.undo()
        try expect(editor.string == revision.description, "undo edits in the description editor")
        editor.undoManager?.redo()
        try expect(editor.string == edited, "redo the complete description edit")
        save.performClick(nil)
        try await waitFor("save only the description text through Jujutsu") {
            panel.selection?.description == edited && content.window?.isVisible != true && panel.graphView.table.isEnabled
        }

        open.performClick(nil)
        try await waitFor("reopen the saved description at the subject") {
            content.window?.isVisible == true && editor.selectedRange() == NSRange(location: 0, length: subject.utf16.count)
        }
        try checkViewport()
        try expect(scroll.visibleContentOrigin.y < 2, "start the long description at the top of its viewport")

        guard let index = panel.graphView.revisions.firstIndex(where: \.isImmutable) else {
            throw Failure("find an immutable change to read")
        }
        let immutable = panel.graphView.revisions[index]
        panel.graphView.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await waitFor("select the immutable change") { panel.selection?.id == immutable.id }
        guard let view = button(in: panel.view, where: { $0.toolTip == "View change description" }) else {
            throw Failure("find the read-only description action")
        }
        view.performClick(nil)
        try await waitFor("reopen the description for a read-only change") { content.window?.isVisible == true }
        try checkViewport()
        try expect(!editor.isEditable && editor.isSelectable && save.title == "Done" &&
                   editor.string == (immutable.description.isEmpty ? "No description" : immutable.description),
                   "show a full read-only description that can be copied")
        save.performClick(nil)
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
              let revsets = button(in: panel.view, where: { $0.identifier?.rawValue == "JujutsuRevsets" }),
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
        for (toggle, firstAction) in [(graph, revsets), (detail, actions)] {
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
