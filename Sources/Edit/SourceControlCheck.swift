import AppKit

@MainActor
enum SourceControlCheck {
    private static let workingSubject = "feat(editor)!: Working change"

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
        let binary = nested.appending(path: "Shader.spv")
        let liveFile = nested.appending(path: "Live.txt")
        let removed = folder.appending(path: "Removed.txt")
        let original = (1...18).map { "Line \($0)\n" }.joined()
        try await command(executable, folder, ["git", "init", "--colocate"])
        try original.write(to: file, atomically: true, encoding: .utf8)
        try "Clean working file\n".write(to: liveFile, atomically: true, encoding: .utf8)
        try "Removed from the working change\n".write(to: removed, atomically: true, encoding: .utf8)
        try await command(executable, folder, ["describe", "-m", "Base"])
        try await command(executable, folder, ["--config", #"debug.commit-timestamp="2020-01-02T03:04:05Z""#,
                                               "new", "-m", "Historical change"])
        let historical = original.replacingOccurrences(of: "Line 8\n", with: "Historical line\n")
        try historical.write(to: file, atomically: true, encoding: .utf8)
        try Data([3, 2, 35, 7, 0, 255, 0, 0]).write(to: binary)
        let description = "\(workingSubject)\n\nA long description starts with [Guide](https://example.com/guide) and https://example.com/plain.\n"
            + "\n- First item\n  continues onto a second source line.\n  * Nested item\n\n"
            + "1. First numbered item\n2. Second numbered item\n10. Tenth numbered item\n\n"
            + "Co-authored-by: Example in the body <example@example.com>\nThis is a quoted example.\n"
            + String(repeating: "A long description stays in the popover.\n", count: 150)
            + "Remaining: one task\n  - The end of the working description.\n"
            + "Co-authored-by: Ada Finch <ada@example.com>\nSigned-off-by: Reviewer <reviewer@example.com>\n"
            + "Reviewed-on: https://example.com/review\n  Review continued.\n"
            + "co-authored-by: Casey Chen <casey@example.com>\n"
        try await command(executable, folder, ["new", "-m", description])
        try await command(executable, folder, ["bookmark", "create", "review/jj-sidebar-layout-with-a-long-bookmark", "-r", "@"])
        try await command(executable, folder, ["bookmark", "create", "zz-review", "-r", "@"])
        try await command(executable, folder, ["new", "--no-edit", "-m", "Side branch", "@--"])
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
        try await checkRevisionHover(panel.graphView.revisions)
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
        let history = panel.graphView.revisions[historyRow]
        let contextMenu = panel.graphView.table.menuForRow?(historyRow)
        try expect(contextMenu?.item(withTitle: "Squash into Parent")?.isEnabled == true && contextMenu?.item(withTitle: "Abandon Change…")?.isEnabled == true,
                   "offer change actions when opening the context menu on an unselected row")
        document.window.layoutIfNeeded()
        let previousTitle = button(in: panel.view, where: { $0.title == workingSubject })
        try expect(previousTitle?.isAccessibilityEnabled() == false &&
                   !panel.fileTree.view.isHidden && row(named: "Removed.txt", in: tree) != nil && !tree.isEnabled,
                   "keep the complete previous Change pane visible while the next detail loads")
        try await waitFor("browse a historical change while keeping the working-copy pointer") {
            panel.selection?.subject == "Historical change" && panel.detail?.files.count == 2
        }
        try expect(panel.graph?.workingCopy.subject == workingSubject, "keep @ distinct from graph selection")
        try open("Tracked.txt", in: panel.fileTree)
        try await waitFor("open historical text with a revision banner and expanded diff") {
            document.sourceControlRevisionBanner != nil && !document.editor.isEditable &&
                document.editor.string == historical && document.editor.jjInlineDiff?.hasExpandedHunks == true
        }
        try render(document.window)
        let viewport = document.scrollView.contentView.bounds
        try expect(viewport.width > 100 && viewport.height > 100 && !document.scrollView.isHiddenOrHasHiddenAncestor,
                   "give historical text a visible editor viewport (\(viewport), \(document.scrollView.frame))")
        try checkRevisionBanner(in: document, above: document.scrollView)
        if let historicalFileRow = row(named: "Tracked.txt", in: tree) {
            try expect(panel.fileTree.menu(at: historicalFileRow) == nil, "keep historical file rows free of working-copy mutations")
        }
        try open("Shader.spv", in: panel.fileTree)
        try await waitFor("show an explanation in the binary revision preview") {
            document.sourceControlRevisionBanner != nil && document.isShowingFilePreview &&
                descendant(of: document.contentResponder) { (label: NSTextField) in
                    label.stringValue == "A text diff is unavailable for this file."
                } != nil
        }
        try checkRevisionBanner(in: document, above: document.contentResponder)
        try open("Tracked.txt", in: panel.fileTree)
        try await waitFor("restore the historical text after a binary preview") {
            !document.isShowingFilePreview && document.editor.string == historical
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

        guard let previousWorking = panel.graph?.workingCopy, let activate = panel.graphView.onEdit else {
            throw Failure("find the working copy before activating the historical file")
        }
        activate(history)
        try await waitFor("activate a mutable change immediately and promote its open file with hunks expanded") {
            document.window.attachedSheet == nil && document.editor.isEditable &&
                document.sourceControlRevisionBanner == nil && document.editor.string == historical &&
                document.fileURL == FileBuffer.canonicalURL(file) && document.editor.jjInlineDiff?.hasExpandedHunks == true
        }
        try await command(executable, folder, ["edit", previousWorking.changeID])
        try await waitFor("demote the open file to its historical revision after a terminal checkout") {
            !document.editor.isEditable && document.sourceControlRevisionBanner != nil &&
                document.editor.string == historical && document.editor.jjInlineDiff?.hasExpandedHunks == true &&
                panel.graph?.workingCopy.changeID == previousWorking.changeID
        }

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
        try await command(executable, folder, ["tag", "set", "read-only-description", "-r", history.changeID])
        try await waitFor("mark the historical change immutable for the description check") {
            panel.graphView.revisions.contains { $0.changeID == history.changeID && $0.isImmutable } &&
                panel.selection?.isWorkingCopy == true && panel.detail != nil && panel.graphView.table.isEnabled
        }
        try await checkDescription(in: document.window, panel: panel)
        try await command(executable, folder, ["tag", "delete", "read-only-description"])
        try await checkDetailTransitions(panel, executable: executable, folder: folder)
        document.setFolder(plain)
        try expect(document.isSidebarVisible && document.sidebarMode == .worktree && sidebarMenu.menu.item(withTitle: "Jujutsu")?.isEnabled == false,
                   "leave Jujutsu and disable its switcher item when leaving the workspace")
        try expect(!app.validateUserInterfaceItem(focus) && focus.keyEquivalent.isEmpty && previous.keyEquivalent == "g",
                   "restore the Find Previous shortcut outside the workspace")
        app.focusJujutsu(nil)
        try expect(document.sidebarMode == .worktree, "ignore a direct focus command outside a workspace")
        try await checkImmutableActivation(executable: executable, workspace: workspace, changeID: history.changeID, file: file)
        try await checkPublishedLinks(executable: executable, folder: fixture.appending(path: "Origin links"))
        try await checkConflicts(in: app, executable: executable, folder: fixture.appending(path: "Conflicts"), render: render)
    }

    private static func checkConflicts(in app: Edit, executable: URL, folder: URL, render: (NSWindow) throws -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await command(executable, folder, ["git", "init", "--colocate"])
        let file = folder.appending(path: "Conflict.swift")
        let finalLine = folder.appending(path: "End.txt")
        let literal = folder.appending(path: "Marker Example.txt")
        func source(_ value: String) -> String {
            "let first = \"\(value)\"\n" + (1...9).map { "// Unchanged \($0)\n" }.joined() +
                "let last = (x: \(value == "Alpha" ? 1 : 0), y: \(value == "Beta" ? 2 : 0), z: \(value == "Gamma" ? 3 : 0))\n"
        }
        try source("Base").write(to: file, atomically: true, encoding: .utf8)
        try "Base".write(to: finalLine, atomically: true, encoding: .utf8)
        let example = "<<<<<<< example\n+++++++ First\na\n------- Base\nb\n+++++++ Second\nc\n>>>>>>> example ends\n"
        try example.write(to: literal, atomically: true, encoding: .utf8)
        try await command(executable, folder, ["bookmark", "create", "base"])
        for side in ["Alpha", "Beta", "Gamma"] {
            try await command(executable, folder, ["new", "base", "-m", side])
            try source(side).write(to: file, atomically: true, encoding: .utf8)
            try (side == "Alpha" ? side + "\n" : side).write(to: finalLine, atomically: true, encoding: .utf8)
            try await command(executable, folder, ["bookmark", "create", side])
        }
        try await command(executable, folder, ["new", "Alpha", "Beta", "Gamma", "-m", "Conflicting merge"])
        guard let workspace = await JJRepository.discover(at: folder) else { throw Failure("discover the conflict fixture") }
        let graph = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        func blocks(_ text: String) -> [JJConflict] {
            JJLineDiff.analyze(base: nil, current: text, isConflicted: true, recordedConflict: text).conflicts
        }
        let noFinalNewline = try String(contentsOf: finalLine, encoding: .utf8)
        guard let end = blocks(noFinalNewline).first, let snapshot = end.rendered(as: .snapshot),
              let back = blocks(snapshot).first?.rendered(as: .diff) else { throw Failure("convert a conflict at EOF") }
        try expect(end.sides.map(\.text) == ["Alpha\n", "Beta", "Gamma"] && blocks(back).first?.sides == end.sides,
                   "preserve all sides and their final newlines when changing format")
        try back.write(to: finalLine, atomically: true, encoding: .utf8)
        try await command(executable, folder, ["util", "snapshot"])
        let snapshotOperation = try await JJRepository.operation(in: workspace)
        let preserved = try await JJRepository.read(workspace, at: snapshotOperation)
        try expect(preserved.commitID == graph.workingCopy.id, "keep the same jj commit after a marker-only rewrite")

        var cachedOperation: String?
        let warmObserver = app.jjChanges.subscribe(to: workspace) { cachedOperation = $0?.repository.operationID }
        defer { app.jjChanges.unsubscribe(warmObserver) }
        try await waitFor("warm the repository observer cache") { cachedOperation == snapshotOperation }
        var validatedOperation: String?
        let validatedObserver = app.jjChanges.subscribe(to: workspace, openingOperation: String(repeating: "0", count: 128)) {
            validatedOperation = $0?.repository.operationID
        }
        defer { app.jjChanges.unsubscribe(validatedObserver) }
        try expect(validatedOperation == nil, "avoid applying a different cached operation to the opening presentation")
        try await waitFor("deliver the current operation after validating the observer cache") { validatedOperation == snapshotOperation }

        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(folder, in: document)
        document.toggleSidebarFocus(.sourceControl)
        _ = try await app.openFile(literal, in: document)
        try expect(document.editor.string == example && document.conflictPanel == nil &&
                   document.scrollView.additionalSafeAreaInsets.top == 0,
                   "open a regular jj file containing literal markers without a conflict strip")
        guard case .text(let buffer) = try await Edit.readForOpening(file) else {
            throw Failure("read the conflicted text fixture")
        }
        try expect(await document.open(.buffer(buffer)) { true }, "open the working-copy conflict through the editor")
        guard let panel = document.conflictPanel,
              let format: NSSegmentedControl = descendant(of: panel, where: { $0.identifier?.rawValue == "JujutsuConflictFormat" }),
              let sidebar = document.sourceControlSidebar else {
            throw Failure("install the conflict strip before presenting the opened buffer")
        }
        try checkEditorPanelLayout([panel], above: document.scrollView, in: document)
        func firstLineY() -> CGFloat? {
            guard let firstLine = document.editor.laidOutLineBounds(at: 0) else { return nil }
            return document.editor.convert(firstLine, to: document.editorContentView).midY
        }
        guard let openingLineY = firstLineY() else { throw Failure("lay out the conflict text in its first frame") }
        try await waitFor("install live editor marks after opening the conflict") {
            document.editor.isEditable && document.editor.jjLineMarks.contains { $0.kind == .conflict }
        }
        try expect(document.conflictPanel === panel && firstLineY().map { abs($0 - openingLineY) < 1 } == true,
                   "keep the original conflict strip and line position when the live analysis arrives")
        try await waitFor("show the conflict cross next to the selected change ID") {
            guard let identity: NSView = descendant(of: sidebar.view, where: { $0.identifier?.rawValue == "JujutsuSelectedChangeID" }),
                  let icon: NSImageView = descendant(of: identity, where: { $0.identifier?.rawValue == "JujutsuConflictIcon" }) else {
                return false
            }
            identity.layoutSubtreeIfNeeded()
            return !icon.isHiddenOrHasHiddenAncestor && icon.frame.width >= 10
        }
        let editor = document.editor
        guard let undo = editor.undoManager else { throw Failure("find the conflict editor's undo manager") }
        let original = editor.string
        let originalBlocks = blocks(original)
        try expect(originalBlocks.count == 2 && originalBlocks.allSatisfy { $0.sides.count == 3 && $0.style == .diff },
                   "read every block and every side from a jj diff conflict")
        guard let navigation: NSSegmentedControl = descendant(of: panel, where: { $0.identifier?.rawValue == "JujutsuConflictNavigation" }) else {
            throw Failure("find the conflict navigation")
        }
        let scroll = document.scrollView
        func button(_ label: String, on anchor: NSRange) -> NSButton? {
            guard let line = editor.laidOutLineBounds(at: anchor.location) else { return nil }
            let midY = scroll.convert(line, from: editor).midY
            return scroll.subviews.lazy.filter { $0 is JJConflictActions && abs($0.frame.midY - midY) <= 1 }.compactMap { view in
                let match: NSButton? = descendant(of: view, where: { $0.title == label })
                return match
            }.first
        }
        func reveal(_ range: NSRange) {
            let caret = NSRange(location: range.location, length: 0)
            editor.setCaretSelections([caret])
            editor.scrollRangeToVisible(caret)
        }
        try expect(format.segmentCount == 2 && format.label(forSegment: 0) == "Diff" && format.label(forSegment: 1) == "Snapshot",
                   "keep two direct format choices in the top panel")
        guard let firstDiff = originalBlocks[0].segments.first(where: { if case .diff = $0.kind { true } else { false } }),
              let firstEnd = originalBlocks[0].highlights.last?.range else { throw Failure("find the first diff and result rows") }
        try await waitFor("show direct buttons on the visible diff and closing markers") {
            button("Apply Diff", on: firstDiff.anchor) != nil &&
                button("Edit Result…", on: firstEnd) != nil
        }
        let parts = Set(originalBlocks[0].highlights.flatMap(\.changes).map { (original as NSString).substring(with: $0) })
        try expect(parts == ["Base", "Beta", "Gamma"], "highlight only the changed words in the conflict diff lines")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            document.window.appearance = NSAppearance(named: appearance)
            document.window.layoutIfNeeded()
            try checkEditorPanelLayout([panel], above: scroll, in: document)
            try expect(panel.convert(format.bounds, from: format).maxX <= panel.bounds.maxX - 11 &&
                       panel.convert(navigation.bounds, from: navigation).minX >= panel.bounds.minX + 11,
                       "inset the top bar controls from both edges")
            try checkConflictColors(originalBlocks[0], in: editor)
        }
        try render(document.window)
        panel.onNavigate?(1)
        try expect(editor.selectedRange().location == originalBlocks[1].range.location, "navigate to the next conflict")
        reveal(originalBlocks[0].range)
        try await waitFor("bring the first diff action back into view") { button("Apply Diff", on: firstDiff.anchor) != nil }
        button("Apply Diff", on: firstDiff.anchor)?.performClick(nil)
        try await waitFor("offer manual editing when a diff overlaps the starting snapshot") {
            document.conflictResultCheckView != nil
        }
        guard let result = document.conflictResultCheckView,
              let resultEditor: EditorTextView = descendant(of: result, where: { $0.identifier?.rawValue == "JujutsuConflictResultText" }),
              let notice: NSTextField = descendant(of: result, where: { $0.identifier?.rawValue == "JujutsuConflictOverlap" }),
              let use: NSButton = descendant(of: result, where: { $0.identifier?.rawValue == "JujutsuConflictUseEditedResult" }) else {
            throw Failure("open a result editor with the overlap message and a direct Use Result button")
        }
        try expect(!notice.isHidden && resultEditor.string == originalBlocks[0].startingResult && editor.string == original,
                   "leave conflicting source text intact while editing the result")
        resultEditor.string = "let first = \"Manual merge\"\n"
        use.performClick(nil)
        try await waitFor("use the edited result to replace just that conflict") {
            editor.string.hasPrefix("let first = \"Manual merge\"\n") && blocks(editor.string).count == 1
        }
        undo.undo()
        try await waitFor("restore the conflict and its controls with Undo") { editor.string == original && format.isEnabled }
        // The second jj block has independent word changes on one line.
        let replayBlock = originalBlocks[1]
        guard let replayEnd = replayBlock.highlights.last?.range else { throw Failure("locate the result actions") }
        let patchAnchors = replayBlock.segments.compactMap { segment -> NSRange? in
            if case .diff = segment.kind { return segment.anchor }
            return nil
        }
        guard patchAnchors.count == 2 else { throw Failure("find both replayable diffs on the second conflict") }
        let (firstPatch, lastPatch) = (patchAnchors[0], patchAnchors[1])
        reveal(lastPatch)
        try await waitFor("show the second direct Apply Diff action") { button("Apply Diff", on: lastPatch) != nil }
        button("Apply Diff", on: lastPatch)?.performClick(nil)
        try await waitFor("stage the second diff without changing the document") {
            editor.string == original && button("Undo Diff", on: lastPatch) != nil
        }
        reveal(firstPatch)
        try await waitFor("show the first direct Apply Diff action") { button("Apply Diff", on: firstPatch) != nil }
        button("Apply Diff", on: firstPatch)?.performClick(nil)
        try await waitFor("stage the first diff after the second") { button("Undo Diff", on: firstPatch) != nil }
        button("Undo Diff", on: firstPatch)?.performClick(nil)
        try await waitFor("undo only the last staged diff") { button("Apply Diff", on: firstPatch) != nil }
        button("Apply Diff", on: firstPatch)?.performClick(nil)
        reveal(replayEnd)
        try await waitFor("offer a direct Use Result for the staged diff result") { button("Use Result", on: replayEnd) != nil }
        try await waitFor("finish applying the requested diff") { button("Undo Diff", on: firstPatch) != nil }
        button("Use Result", on: replayEnd)?.performClick(nil)
        try await waitFor("resolve with both applied diffs and the original snapshot change") {
            editor.string.hasSuffix("let last = (x: 1, y: 2, z: 3)\n") && blocks(editor.string) == [originalBlocks[0]]
        }
        undo.undo()
        try await waitFor("undo the replay result before changing format") { editor.string == original && format.isEnabled }
        reveal(originalBlocks[0].range)
        format.selectedSegment = 1
        if let action = format.action { format.sendAction(action, to: format.target) }
        try await waitFor("switch all open conflict blocks to Snapshot") {
            let current = blocks(editor.string)
            return current.count == 2 && current.allSatisfy { $0.style == .snapshot }
        }
        let snapshotBlocks = blocks(editor.string)
        document.window.layoutIfNeeded()
        try expect(format.isEnabled, "install the new conflict presentation in the same update as the Snapshot text")
        try checkConflictMarkerGlyphs(snapshotBlocks[0], in: editor)
        try expect(zip(snapshotBlocks, originalBlocks).allSatisfy { $0.sides == $1.sides },
                   "retain each side when changing the editable representation")
        editor.setCaretSelections([NSRange(location: snapshotBlocks[0].range.location, length: 0)])
        editor.scrollRangeToVisible(editor.selectedRange())
        let thirdSide = snapshotBlocks[0].segments[2].anchor
        reveal(thirdSide)
        try await waitFor("attach a direct Accept Snapshot button to the third snapshot") {
            button("Accept Snapshot", on: thirdSide) != nil
        }
        button("Accept Snapshot", on: thirdSide)?.performClick(nil)
        try await waitFor("resolve only the selected block with the third side") {
            editor.string.hasPrefix("let first = \"Gamma\"\n") && blocks(editor.string).count == 1
        }
        undo.undo()
        try await waitFor("undo a resolution and recover all three sides") { blocks(editor.string) == snapshotBlocks }
        undo.undo()
        try await waitFor("undo a format switch") { editor.string == original && format.isEnabled }
        reveal(originalBlocks[0].range)
        try checkConflictMarkerGlyphs(originalBlocks[0], in: editor)
        try expect(await document.save(), "save the restored conflict before opening its history")

        try await command(executable, folder, ["new", "-m", "Review child"])
        let history = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        guard let historical = history.revisions.first(where: { $0.subject == "Conflicting merge" }) else {
            throw Failure("find the historical conflict")
        }
        let details = try await JJSourceControlRepository.detail(for: historical, in: workspace, at: history.operationID)
        guard let path = details.files.first(where: { $0.path == "Conflict.swift" }) else { throw Failure("list the conflicted file") }
        try expect(await document.openSourceControlFile(path, in: historical, workspace: workspace, operationID: history.operationID) { true },
                   "open the historical conflict as a read-only file")
        let disk = try Data(contentsOf: file)
        document.conflictPanel?.onChangeStyle?(.snapshot)
        try await waitFor("show Snapshot in a read-only revision") {
            !editor.isEditable && !scroll.subviews.contains { $0 is JJConflictActions } && blocks(editor.string).first?.style == .snapshot
        }
        try expect(try Data(contentsOf: file) == disk, "leave the working file untouched when switching a historical preview")
        guard let banner = document.sourceControlRevisionBanner, let conflictPanel = document.conflictPanel else {
            throw Failure("keep both editor panels in a historical conflict")
        }
        try checkEditorPanelLayout([banner, conflictPanel], above: document.scrollView, in: document)
        try checkPanelsWithDetachedToolbar([banner, conflictPanel], in: document)
    }

    private static func checkConflictColors(_ block: JJConflict, in editor: EditorTextView) throws {
        for role in [JJConflict.Role.marker, .removal, .addition] {
            guard let highlight = block.highlights.first(where: { $0.role == role }),
                  let line = editor.laidOutLineBounds(at: highlight.range.location) else {
                throw Failure("lay out each conflict color band")
            }
            // Sample away from text and from the floating action to verify the full row fill.
            let sample = NSRect(x: editor.visibleRect.maxX - 108, y: line.midY - 1, width: 2, height: 2)
            guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: sample) else {
                throw Failure("capture the conflict row background")
            }
            editor.cacheDisplay(in: sample, to: bitmap)
            guard let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else {
                throw Failure("read the conflict row background")
            }
            let (red, green, blue) = (color.redComponent, color.greenComponent, color.blueComponent)
            let matches = switch role {
            case .marker: abs(blue - green) < 0.025 && abs(red - green) < 0.025
            case .removal: red > green + 0.03 && red > blue + 0.03
            case .addition: green > red + 0.03 && green > blue + 0.03
            }
            try expect(matches, role == .marker ? "leave the marker background neutral" : "paint a full-width \(role) background")
        }
        try checkConflictMarkerGlyphs(block, in: editor)
    }

    private static func checkConflictMarkerGlyphs(_ block: JJConflict, in editor: EditorTextView) throws {
        let markerOffsets = Set(block.highlights.filter { $0.role == .marker }.map(\.range.location))
        let source = editor.string as NSString
        var offset = block.range.location
        while offset < NSMaxRange(block.range) {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            guard let line = editor.laidOutLineBounds(at: offset) else { throw Failure("lay out the conflict text") }
            let glyphs = NSRect(x: editor.textContainerInset.width + 4, y: line.minY, width: 65, height: line.height)
            guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: glyphs) else { throw Failure("capture the conflict text") }
            editor.cacheDisplay(in: glyphs, to: bitmap)
            let purple = (0..<bitmap.pixelsWide).contains { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return pixel.blueComponent > pixel.greenComponent + 0.12 && pixel.redComponent > pixel.greenComponent + 0.08
                }
            }
            try expect(purple == markerOffsets.contains(offset), "use purple only on marker glyphs at \(source.substring(with: range))")
            offset = NSMaxRange(range)
        }
    }

    private static func checkPublishedLinks(executable: URL, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await command(executable, folder, ["git", "init", "--colocate"])
        try await command(executable, folder, ["describe", "-m", "Published ancestor"])
        try await command(executable, folder, ["new", "-m", "Published tip"])
        try await command(executable, folder, ["new", "-m", "Local draft"])
        guard let workspace = await JJRepository.discover(at: folder) else { throw Failure("open the origin fixture") }
        let tip = try await JJSourceControlRepository.read(workspace, arguments: ["log", "--no-graph", "-r", "@-", "-T", "commit_id"])
        let git = URL(filePath: "/usr/bin/git")
        try await command(git, folder, ["remote", "add", "origin", "git@codeberg.org:edit/example.git"], usesJJOptions: false)
        try await command(git, folder, ["update-ref", "refs/remotes/origin/main", tip], usesJJOptions: false)
        try await command(executable, folder, ["git", "import"])
        let graph = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        guard let ancestor = graph.revisions.first(where: { $0.subject == "Published ancestor" }),
              let link = await JJSourceControlCommitLink.lookup(for: ancestor, in: workspace, at: graph.operationID) else {
            throw Failure("link a commit in the known history of origin")
        }
        try expect(link.url.absoluteString == "https://codeberg.org/edit/example/commit/\(ancestor.id)",
                   "open Codeberg by exact commit ID, including published ancestors")
        let draftLink = await JJSourceControlCommitLink.lookup(for: graph.workingCopy, in: workspace, at: graph.operationID)
        try expect(draftLink == nil, "leave local-only commits without a hosting button")
        var opened: [URL] = []
        let card = SourceControlRevisionCard(revision: ancestor) { opened.append($0) }
        card.setCommitLink(link)
        guard let button = button(in: card, where: { $0.identifier?.rawValue == "JujutsuRevisionCardOpenCommit" }) else {
            throw Failure("find the hosting button in the card")
        }
        try expect(!button.isHidden && button.attributedTitle.string == "Open on Codeberg", "name the origin service on the button")
        button.performClick(nil)
        try expect(opened == [link.url], "dispatch the commit URL from the hosting button")
        card.setCommitLink(nil)
        try expect(button.isHidden, "hide the hosting button without a published commit")
    }

    private static func checkImmutableActivation(executable: URL, workspace: JJWorkspace, changeID: String, file: URL) async throws {
        try await command(executable, workspace.root, ["tag", "set", "protected-change", "-r", changeID])
        let graph = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        guard let change = graph.revisions.first(where: { $0.changeID == changeID && $0.isImmutable }) else {
            throw Failure("find a non-root immutable change")
        }
        let buttons = SourceControlSidebar.changeActivationAlert(for: change).buttons
        try expect(buttons.map(\.title) == ["Edit Change", "New Change Here", "Cancel"] && buttons[0].isEnabled &&
                   buttons[1].keyEquivalent == "\r", "allow explicitly overriding protection and default to creating a child")

        try await JJSourceControlRepository.mutate(.edit(change.id, ignoreImmutable: true), in: workspace,
                                                   expectedOperation: graph.operationID)
        try "Saved in the explicitly edited immutable change\n".write(to: file, atomically: true, encoding: .utf8)
        try await JJRepository.snapshot(workspace)
        let saved = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        try expect(saved.workingCopy.changeID == changeID && saved.workingCopy.id != change.id,
                   "snapshot a file edit in the explicitly chosen immutable change")

        try await JJSourceControlRepository.mutate(.new(saved.workingCopy.id), in: workspace,
                                                   expectedOperation: saved.operationID)
        let child = try await JJSourceControlRepository.graph(in: workspace, revset: "all()")
        try expect(child.workingCopy.parents == [saved.workingCopy.id] && child.workingCopy.changeID != changeID,
                   "create a separate working-copy child of the immutable change")
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
        defer { picker.close() }
        func showPicker() async throws {
            try await waitFor("finish closing the revset picker") { !picker.isShownForCheck }
            open.performClick(nil)
            try expectQuietPopover(content, anchoredTo: window)
        }
        func press(_ title: String) throws {
            let scope: NSView
            if let row = picker.entriesForCheck.firstIndex(where: { "Edit \($0.name)" == title }) {
                let list = try table()
                // An unordered window does not automatically draw and instantiate visible table rows.
                guard let cell = list.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                    throw Failure("lay out the revset row for \(title)")
                }
                scope = cell
            } else {
                scope = content
            }
            guard let control = button(in: scope, where: { $0.title == title || $0.accessibilityLabel() == title }),
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
                panel.graphView.revisions.first?.isRoot == true
        }
        guard let rootCell = panel.graphView.table.view(atColumn: 0, row: 0, makeIfNecessary: true),
              let rootSubject: NSTextField = descendant(of: rootCell, where: { $0.identifier?.rawValue == "JujutsuRevisionSubject" })
        else { throw Failure("find the repository root graph cell") }
        try expect(rootSubject.isHidden && rootCell.accessibilityLabel() == "Repository Root" &&
                   descendant(of: rootCell, where: { (_: NSImageView) in true }) == nil,
                   "draw only the graph node for the repository root and name it for accessibility")
        panel.graphView.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await waitFor("display the root details") { panel.selection?.isRoot == true && panel.detail != nil }
        try expect(button(in: panel.view, where: { $0.title == "Repository Root" })?.isEnabled == false,
                   "identify the root in the details without offering a description editor")
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
        defer { panel.closeDescriptionForCheck() }
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
        try expectQuietPopover(content, anchoredTo: window)
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
            panel.selection?.description == edited && panel.detail != nil &&
                content.window == nil && panel.graphView.table.isEnabled
        }

        open.performClick(nil)
        try await waitFor("reopen the saved description at the subject") {
            content.window != nil && editor.selectedRange() == NSRange(location: 0, length: subject.utf16.count)
        }
        try expectQuietPopover(content, anchoredTo: window)
        try checkViewport()
        try expect(scroll.visibleContentOrigin.y < 2, "start the long description at the top of its viewport")

        guard let index = panel.graphView.revisions.firstIndex(where: { $0.isImmutable && !$0.isRoot }) else {
            throw Failure("find an immutable change to read")
        }
        let immutable = panel.graphView.revisions[index]
        panel.graphView.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await waitFor("present the immutable change") { panel.selection?.id == immutable.id && panel.detail != nil }
        guard let view = button(in: panel.view, where: { $0.toolTip == "View change description" }) else {
            throw Failure("find the read-only description action")
        }
        view.performClick(nil)
        try expectQuietPopover(content, anchoredTo: window)
        try checkViewport()
        try expect(!editor.isEditable && editor.isSelectable && save.title == "Done" &&
                   editor.string == (immutable.description.isEmpty ? "No description" : immutable.description),
                   "show a full read-only description that can be copied")
        save.performClick(nil)
    }

    private static func checkDetailTransitions(_ panel: SourceControlSidebar, executable: URL, folder: URL) async throws {
        let first = "First empty change"
        let second = "Second empty change"
        let historical = "Historical change"
        for subject in [first, second] { try await command(executable, folder, ["new", "-m", subject]) }
        try await waitFor("load both empty changes") {
            panel.graph?.workingCopy.subject == second && panel.graphView.table.isEnabled
        }

        func select(_ subject: String) throws {
            guard let row = panel.graphView.revisions.firstIndex(where: { $0.subject == subject }) else {
                throw Failure("find \(subject) in the graph")
            }
            panel.graphView.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func shows(_ subject: String, _ message: String) -> Bool {
            button(in: panel.view, where: { $0.title == subject }) != nil &&
                descendant(of: panel.view, where: { (label: NSTextField) in
                    label.stringValue == message && !label.isHiddenOrHasHiddenAncestor
                }) != nil
        }
        try select(first)
        try await waitFor("present the first empty change") { shows(first, "No changed files") && panel.detail != nil }
        try select(second)
        try expect(panel.selection?.subject == second && shows(first, "No changed files") && panel.detail == nil,
                   "keep the empty presentation complete as the graph selection moves")
        try await waitFor("present the second empty change without a loading frame") {
            shows(second, "No changed files") && panel.detail != nil
        }

        panel.detailReadDelayForCheck = .seconds(2)
        defer { panel.detailReadDelayForCheck = nil }
        try select(first)
        try await Task.sleep(for: .milliseconds(500))
        try select(historical)
        let switchedAgain = ContinuousClock.now
        try await waitFor("show stable loading for the final selection after the grace period") {
            shows(historical, "Loading changed files…") && panel.detail == nil
        }
        try expect(switchedAgain.duration(to: .now) < .milliseconds(650), "expire the previous pane on its original deadline")
        try await waitFor("publish only the final selection when the slow read finishes") {
            panel.selection?.subject == historical && panel.detail?.files.count == 2 &&
                button(in: panel.view, where: { $0.title == historical }) != nil &&
                !panel.fileTree.view.isHidden && row(named: "Tracked.txt", in: panel.fileTree.outline) != nil
        }
    }

    private static func checkOperationDirection(in window: NSWindow, panel: SourceControlSidebar) async throws {
        let operations = panel.operationsViewForCheck
        guard let open = button(in: panel.view, where: { $0.toolTip == "Repository Operations" }),
              let apply = button(in: operations, where: { $0.title == "Undo Operation" }),
              let directions = descendant(of: operations, where: { (_: NSSegmentedControl) in true }) else {
            throw Failure("find the operation popover controls")
        }
        defer { panel.closeOperationsForCheck() }
        open.performClick(nil)
        try expectQuietPopover(operations, anchoredTo: window)
        try await waitFor("preview Undo in the popover") { apply.isEnabled && directions.selectedSegment == 0 }
        apply.performClick(nil)
        try await waitFor("show the applied Undo") {
            directions.isEnabled && panel.graph?.workingCopy.subject == workingSubject
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

    private static func expectQuietPopover(_ content: NSView, anchoredTo anchor: NSWindow) throws {
        guard let window = content.window else { throw Failure("open the popover content in a check window") }
        try expect(window !== anchor && !window.isVisible && window.alphaValue == 0 && window.ignoresMouseEvents &&
                   !anchor.isVisible && !NSApp.isActive, "keep the popover and its anchor offscreen without activation")
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
              let identity = descendant(of: panel.view, where: { $0.identifier?.rawValue == "JujutsuSelectedChangeID" }),
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
        guard let title = button(in: panel.view, where: { $0.title == workingSubject }) else {
            throw Failure("find the compact description action")
        }
        try expect(title.cell?.usesSingleLineMode == true && title.bounds.height <= 24 && title.image == nil,
                   "make the compact change title a one-line description action")
        try expect(!identity.isHiddenOrHasHiddenAncestor && identity.superview === detail.superview &&
                   identity.frame.minX > detail.frame.maxX && abs(identity.frame.midY - detail.frame.midY) < 1,
                   "keep the change ID in the Change header beside its disclosure")
        try checkGraphRows(in: panel)
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
                   changeChevron == detailCell.imageRect(forBounds: detail.bounds) && !actions.isHiddenOrHasHiddenAncestor &&
                   !identity.isHiddenOrHasHiddenAncestor,
                   "keep the Change title, chevron slot, ID and actions in place when the details collapse")
        detail.performClick(nil)
        document.window.layoutIfNeeded()
    }

    private static func checkGraphRows(in panel: SourceControlSidebar) throws {
        func row(_ matches: (JJSourceControlRevision) -> Bool) throws -> NSView {
            guard let index = panel.graphView.revisions.firstIndex(where: matches),
                  let view = panel.graphView.table.view(atColumn: 0, row: index, makeIfNecessary: true) else {
                throw Failure("find a graph row in the fixture")
            }
            view.layoutSubtreeIfNeeded()
            return view
        }
        func subject(in row: NSView) throws -> NSTextField {
            guard let label = descendant(of: row, where: { (label: NSTextField) in
                label.identifier?.rawValue == "JujutsuRevisionSubject"
            }) else { throw Failure("find the graph subject label") }
            return label
        }

        let working = try row(\.isWorkingCopy)
        let historical = try row { $0.subject == "Historical change" }
        let branch = try row { $0.subject == "Side branch" }
        let workingSubject = try subject(in: working)
        let branchSubject = try subject(in: branch)
        try expect(workingSubject.frame.minX != branchSubject.frame.minX,
                   "reclaim graph width when a row has fewer occupied lanes")
        guard let active = panel.graphView.revisions.first(where: \.isWorkingCopy),
              let bookmarks: NSTextField = descendant(of: working, where: { $0.identifier?.rawValue == "JujutsuRevisionBookmarks" }),
              let count: NSTextField = descendant(of: working, where: { $0.identifier?.rawValue == "JujutsuRevisionBookmarkCount" })
        else { throw Failure("show the graph bookmark and overflow count") }
        let subjectFrame = working.convert(workingSubject.bounds, from: workingSubject)
        let bookmarkFrame = working.convert(bookmarks.bounds, from: bookmarks)
        let countFrame = working.convert(count.bounds, from: count)
        let countAlignment = working.convert(count.alignmentRect(forFrame: count.frame), from: count.superview)
        let name = "review/jj-sidebar-layout-with-a-long-bookmark"
        let authorStart = (active.subject as NSString).length + 1
        try expect(workingSubject.stringValue == "\(active.subject)\u{2002}\(active.author)" &&
                   workingSubject.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor !=
                   workingSubject.attributedStringValue.attribute(.foregroundColor, at: authorStart, effectiveRange: nil) as? NSColor,
                   "combine the subject and muted author into one truncating line without the change ID")
        try expect(panel.graphView.table.rowHeight == 24 && bookmarks.stringValue == name &&
                   count.stringValue == "+1" && !count.isHiddenOrHasHiddenAncestor &&
                   bookmarkFrame.width > subjectFrame.width && subjectFrame.maxX <= bookmarkFrame.minX &&
                   bookmarkFrame.maxX <= countFrame.minX && abs(bookmarkFrame.midY - subjectFrame.midY) < 2 &&
                   abs(working.bounds.maxX - countAlignment.maxX - 12) < 1,
                   "give the bookmark and overflow count priority at the right of the compact row (row \(working.bounds), "
                   + "subject \(subjectFrame), bookmark \(bookmarks.stringValue) \(bookmarkFrame), "
                   + "count \(count.stringValue) \(countFrame), hidden \(count.isHiddenOrHasHiddenAncestor))")
        try expect(working.toolTip == nil && working.accessibilityLabel()?.contains(name) == true &&
                   working.accessibilityLabel()?.contains("zz-review") == true &&
                   branch.accessibilityHelp()?.contains("Created ·") == true &&
                   historical.accessibilityHelp()?.contains("Modified ·") == true,
                   "expose full bookmarks and dates to accessibility without the plain-text tooltip")
    }

    private static func checkRevisionHover(_ revisions: [JJSourceControlRevision]) async throws {
        guard let working = revisions.firstIndex(where: \.isWorkingCopy),
              let historical = revisions.firstIndex(where: { $0.subject == "Historical change" }),
              let branch = revisions.first(where: { $0.subject == "Side branch" }) else {
            throw Failure("find the hover card fixture changes")
        }
        let graph = SourceControlGraphView()
        let bounds = NSRect(x: -10000, y: -10000, width: 260, height: 140)
        let window = EditorFocusCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = graph.view
        window.orderBack(nil)
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeFirstResponder(graph.table)
        graph.install(revisions, selected: revisions[historical].id)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(220))

        func pointer(at row: Int) throws -> NSEvent {
            let rect = graph.table.rect(ofRow: row)
            let point = graph.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) else { throw Failure("create a hover event") }
            return event
        }
        func card() -> NSWindow? {
            window.childWindows?.first { $0.contentView?.identifier?.rawValue == "JujutsuRevisionHoverCard" }
        }
        func text(_ name: String, in root: NSView) -> NSTextView? {
            descendant(of: root) { $0.identifier?.rawValue == "JujutsuRevisionCard\(name)" }
        }

        graph.table.mouseMoved(with: try pointer(at: historical))
        graph.table.mouseMoved(with: try pointer(at: working))
        try expect(card() == nil, "wait for the pointer to settle on a graph row")
        try await waitFor("show the hovered revision card") { card()?.isVisible == true }
        guard let preview = card(), let content = preview.contentView else { throw Failure("find the native hover surface") }
        try expect(preview.canBecomeKey && !preview.isKeyWindow && preview.ignoresMouseEvents && window.firstResponder === graph.table &&
                   graph.table.selectedRow == historical,
                   "preview a different row without moving selection or keyboard focus")
        guard let subject = text("Subject", in: content), let description = text("Description", in: content),
              let authorValue = text("Author", in: content) else { throw Failure("find the selectable revision text") }
        let bookmarks: NSTextField? = descendant(of: content) { $0.identifier?.rawValue == "JujutsuRevisionCardBookmarks" }
        let author = revisions[working]
        try expect(subject.string == workingSubject &&
                   authorValue.string == "\(author.author) \(author.authorEmail)" &&
                   bookmarks?.stringValue.contains("review/jj-sidebar-layout-with-a-long-bookmark") == true &&
                   description.string.hasPrefix("A long description"),
                   "show the subject, author, full bookmark name, and body as distinct parts of the card")
        var subjectStyle = NSRange()
        let subjectFont = subject.textStorage?.attribute(.font, at: 0, effectiveRange: &subjectStyle) as? NSFont
        try expect(subjectFont == .systemFont(ofSize: 14, weight: .semibold) &&
                   subjectStyle.length == subject.string.utf16.count &&
                   subject.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor,
                   "use one ordinary title style for a conventional commit subject")
        guard let grid = descendant(of: content, where: { (_: NSGridView) in true }) else {
            throw Failure("show a grid for revision metadata")
        }
        let labels = (0..<grid.numberOfRows).compactMap { (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue }
        let values = (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 1, rowIndex: $0).contentView as? NSTextView }
        try expect(Array(labels.prefix(4)) == ["Author", "Co-author", "Co-author", "Created"] &&
                   Array(labels.suffix(2)) == ["Signed-off-by", "Reviewed-on"] &&
                   values.map(\.string).dropFirst().prefix(2).elementsEqual(["Ada Finch ada@example.com", "Casey Chen casey@example.com"]) &&
                   values.last?.string == "https://example.com/review\nReview continued." &&
                   Set(values.map { grid.convert($0.bounds, from: $0).maxX }).count == 1 &&
                   values.allSatisfy { ($0.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right },
                   "preserve trailer order and continuation lines and right-align all metadata values")
        try expect(!description.string.contains("Ada Finch") && !description.string.contains("Casey Chen") &&
                   description.string.contains("Co-authored-by: Example in the body example@example.com") &&
                   description.string.contains("Remaining: one task") && !description.string.contains("Signed-off-by: Reviewer"),
                   "move all trailing metadata and preserve header-like lines in the body")
        let body = description.string as NSString
        let list = "•\tFirst item continues onto a second source line.\n◦\tNested item"
        let nested = body.range(of: "Nested item")
        let bullet = body.range(of: "First item")
        guard let layout = description.layoutManager, let container = description.textContainer else {
            throw Failure("lay out the card’s lists and links")
        }
        try expect(description.string.contains(list) && nested.location != NSNotFound && bullet.location != NSNotFound &&
                   (description.textStorage?.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent == 6 &&
                   (description.textStorage?.attribute(.paragraphStyle, at: bullet.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 17 < 12,
                   "keep bullets close to the text and wrap source continuations with their item")
        let numbers = ["1.", "2.", "10."].compactMap { number -> NSRect? in
            let range = body.range(of: "\t\(number)\t")
            guard range.location != NSNotFound else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + 1, length: number.utf16.count),
                                           actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        try expect(numbers.count == 3 && numbers[2].minX < numbers[0].minX &&
                   numbers.allSatisfy { abs($0.maxX - numbers[0].maxX) < 0.75 },
                   "right-align different-width list numbers to the same column")
        try expect(description.isSelectable && !description.isEditable && description.needsPanelToBecomeKey,
                   "allow text selection and keyboard copy without editing the description")
        let guide = (description.string as NSString).range(of: "Guide")
        guard guide.location != NSNotFound,
              let guideURL = description.textStorage?.attribute(.link, at: guide.location, effectiveRange: nil) as? URL else {
            throw Failure("give the rendered Markdown link its destination")
        }
        let plain = (description.string as NSString).range(of: "https://example.com/plain")
        try expect(guideURL.absoluteString == "https://example.com/guide" && plain.location != NSNotFound &&
                   (description.textStorage?.attribute(.link, at: plain.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/plain",
                   "detect both Markdown and plain web links")
        func link(for address: String, in view: NSTextView) -> URL? {
            let range = (view.string as NSString).range(of: address)
            guard range.location != NSNotFound else { return nil }
            return view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        try expect(link(for: author.authorEmail, in: authorValue)?.scheme == "mailto" &&
                   link(for: "ada@example.com", in: values[1])?.absoluteString == "mailto:ada@example.com" &&
                   link(for: "example@example.com", in: description)?.absoluteString == "mailto:example@example.com",
                   "make author, co-author, and description email addresses clickable")

        func cursor(over range: NSRange) -> NSCursor? {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let frame = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let origin = description.textContainerOrigin
            let point = description.convert(NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y), to: nil)
            return EditApplication.clickCursor(in: preview, at: point)
        }
        let ordinary = (description.string as NSString).range(of: "starts")
        try expect(cursor(over: guide) === NSCursor.pointingHand && cursor(over: ordinary) === NSCursor.iBeam,
                   "show a pointing hand exactly on the link and a text cursor beside it")
        let exampleRow = NSRect(x: 0, y: 100, width: 240, height: 38)
        let exampleCard = NSRect(x: 248, y: 9, width: 332, height: 220)
        let crossing = SourceControlRevisionCorridor(anchor: exampleRow, card: exampleCard)
        let start = NSPoint(x: 120, y: 119)
        try expect(crossing.contains(NSPoint(x: 242, y: 20)) && crossing.contains(NSPoint(x: 242, y: 220)) &&
                   crossing.isApproach(NSPoint(x: 180, y: 68), from: start) &&
                   crossing.isApproach(NSPoint(x: 180, y: 170), from: start) &&
                   !crossing.isApproach(NSPoint(x: 120, y: 170), from: start) &&
                   !crossing.contains(NSPoint(x: 242, y: 270)),
                   "allow diagonal approaches to both ends while distinguishing vertical browsing and leaving the card")

        let anchor = window.convertToScreen(graph.table.convert(graph.table.rect(ofRow: working), to: nil))
        let gap = NSPoint(x: (anchor.maxX + preview.frame.minX) / 2, y: (anchor.midY + preview.frame.midY) / 2)
        try expect(SourceControlRevisionCorridor(anchor: anchor, card: preview.frame).contains(gap),
                   "connect the row and the card across their gap")
        let row = graph.table.rect(ofRow: working)
        let adjacent = NSPoint(x: row.midX + 15, y: working + 1 < revisions.count ? row.maxY + 2 : row.minY - 2)
        let adjacentRow = graph.table.row(at: adjacent)
        try expect(revisions.indices.contains(adjacentRow), "find the neighboring graph row")
        graph.table.hoverRowChanged?(adjacentRow, window.convertPoint(toScreen: graph.table.convert(adjacent, to: nil)))
        try expect(card() === preview, "keep the card when the diagonal approach crosses a neighboring row")
        graph.table.hoverPointerLeft?(gap)
        try expect(card() === preview, "keep the card during pointer travel across the gap")
        let inside = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        guard let arrival = NSEvent.mouseEvent(with: .mouseMoved, location: content.convert(inside, to: nil),
                                                modifierFlags: [], timestamp: 0, windowNumber: preview.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw Failure("create a card entry event")
        }
        content.mouseEntered(with: arrival)
        description.setSelectedRange(guide)
        try await Task.sleep(for: .milliseconds(250))
        try expect(card() === preview && description.selectedRange() == guide && graph.table.selectedRow == historical,
                   "keep the card and text selection after crossing into the card")
        try expect(SourceControlRevisionCard.creationDates(for: revisions[historical]).count == 2 &&
                   SourceControlRevisionCard.creationDates(for: branch).count == 1,
                   "show both creation times only when they differ")

        let clip = graph.view.contentView
        guard let scroll = descendant(of: content, where: { (_: NSScrollView) in true }),
              let cardDocument = scroll.documentView, let screen = preview.screen ?? NSScreen.main else {
            throw Failure("scroll long descriptions within the hover card")
        }
        try expect(screen.visibleFrame.contains(preview.frame) &&
                   abs(scroll.documentVisibleRect.maxY - cardDocument.bounds.maxY) < 1,
                   "keep the tall card on screen and start at its top")
        scroll.contentView.scroll(to: .zero)
        let end = (description.string as NSString).range(of: "The end of the working description.")
        try expect(end.location != NSNotFound, "keep the full long description")
        let endGlyphs = layout.glyphRange(forCharacterRange: end, actualCharacterRange: nil)
        let endFrame = layout.boundingRect(forGlyphRange: endGlyphs, in: container)
        try expect(!endFrame.isEmpty && scroll.documentVisibleRect.contains(description.convert(endFrame, to: cardDocument)),
                   "scroll all the way to the final rendered line")
        clip.scroll(to: NSPoint(x: 0, y: graph.table.rowHeight))
        try expect(card() == nil, "dismiss the card when its graph scrolls")
        clip.scroll(to: .zero)
        graph.table.scrollRowToVisible(historical)
        graph.view.reflectScrolledClipView(clip)
        window.layoutIfNeeded()
        await Task.yield()
        do {
            try await waitFor("show both creation dates in the historical card") {
                if let content = card()?.contentView, let created = text("Created", in: content)?.string,
                   let modified = text("Modified", in: content)?.string, created != modified { return true }
                // Keep sending pointer movement while AppKit settles the post-scroll viewport.
                if let event = try? pointer(at: historical) { graph.table.mouseMoved(with: event) }
                return false
            }
        } catch {
            let subject = card()?.contentView.flatMap { text("Subject", in: $0)?.string } ?? "none"
            let row = graph.table.rect(ofRow: historical)
            throw Failure("show both historical creation dates (card \(subject), row \(row), viewport \(graph.table.visibleRect), key \(window.isKeyWindow))")
        }
        graph.table.mouseExited(with: try pointer(at: working))
        try await waitFor("dismiss the card after leaving the row and its corridor") { card() == nil }
        graph.table.mouseMoved(with: try pointer(at: working))
        window.simulatedKeyStatus = false
        try await Task.sleep(for: .milliseconds(500))
        try expect(card() == nil && !NSApp.isActive, "cancel a pending card when the editor window loses key status")
    }

    private static func checkRevisionBanner(in document: DocumentWindow, above body: NSView) throws {
        let content = document.editorContentView
        guard let banner = document.sourceControlRevisionBanner else { throw Failure("find the revision banner") }
        try checkEditorPanelLayout([banner], above: body, in: document)
        let bounds = content.bounds
        func capture() throws -> NSBitmapImageRep {
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw Failure("capture the revision preview")
            }
            content.cacheDisplay(in: bounds, to: bitmap)
            return bitmap
        }
        let visible = try capture()
        banner.isHidden = true
        defer { banner.isHidden = false }
        let uncovered = try capture()
        let bannerFrame = content.convert(banner.bounds, from: banner)
        let exposedBody = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bannerFrame.minY - bounds.minY)
        let area = content.convert(body.bounds, from: body).intersection(exposedBody).insetBy(dx: 8, dy: 8)
        try expect(!area.isEmpty, "give the selected revision a visible body below the strip")
        let xScale = CGFloat(visible.pixelsWide) / bounds.width
        let yScale = CGFloat(visible.pixelsHigh) / bounds.height
        let top = content.isFlipped ? area.minY : bounds.maxY - area.maxY
        for x in stride(from: Int(area.minX * xScale), to: Int(area.maxX * xScale), by: 4) {
            for y in stride(from: Int(top * yScale), to: Int((top + area.height) * yScale), by: 4) {
                try expect(visible.colorAt(x: x, y: y) == uncovered.colorAt(x: x, y: y),
                           "keep all banner drawing above the revision body")
            }
        }
    }

    private static func checkEditorPanelLayout(_ panels: [NSView], above body: NSView, in document: DocumentWindow) throws {
        document.window.layoutIfNeeded()
        let content = document.editorContentView
        guard let scroll = body as? NSScrollView ?? descendant(of: body, where: { (_: NSScrollView) in true }) else {
            throw Failure("find the revision scroll surface")
        }
        let scrollFrame = content.convert(scroll.bounds, from: scroll)
        var edge = content.safeAreaRect.maxY
        var height: CGFloat = 0
        for panel in panels {
            let frame = content.convert(panel.bounds, from: panel)
            try expect(abs(frame.maxY - edge) < 1, "stack editor panels below the native toolbar")
            edge = frame.minY
            height += frame.height
        }
        try expect(scroll.automaticallyAdjustsContentInsets && abs(scrollFrame.maxY - content.bounds.maxY) < 1,
                   "keep the scroll surface extending behind the native toolbar")
        try expect(abs(body.additionalSafeAreaInsets.top - height) < 1 &&
                   abs(scrollFrame.maxY - scroll.contentInsets.top - edge) < 1,
                   "reserve the editor panels in the automatic scroll inset")
    }

    private static func checkPanelsWithDetachedToolbar(_ panels: [NSView], in document: DocumentWindow) throws {
        let window = document.window
        guard let toolbar = window.toolbar else { throw Failure("find the native editor toolbar") }
        let frame = NSRect(x: -10_000, y: -10_000, width: window.frame.width, height: 180)
        let companion = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        companion.isReleasedWhenClosed = false
        companion.alphaValue = 0
        companion.ignoresMouseEvents = true
        companion.collectionBehavior = [.fullScreenAuxiliary]
        companion.toolbarStyle = window.toolbarStyle
        defer {
            companion.toolbar = nil
            window.toolbar = toolbar
            window.layoutIfNeeded()
            document.titleBar.fullScreenTransitionDidFinish()
            companion.close()
        }
        window.toolbar = nil
        companion.toolbar = toolbar
        companion.orderBack(nil)
        companion.setFrame(frame, display: false)
        companion.layoutIfNeeded()
        document.titleBar.fullScreenTransitionDidFinish()
        try expect(document.titleBar.toolbarWindow === companion && !NSApp.isActive,
                   "test the panels with the toolbar in an inactive full-screen companion")
        try checkEditorPanelLayout(panels, above: document.scrollView, in: document)
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
    private static func command(_ executable: URL, _ folder: URL, _ arguments: [String], usesJJOptions: Bool = true) async throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = folder
        process.arguments = usesJJOptions ? ["--no-pager", "--color=never"] + arguments : arguments
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
