import AppKit

@MainActor
enum WorkspaceFindCheck {
    static func run(in app: Edit, capture: (NSWindow, String) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workspace-search-\(UUID())", directoryHint: .isDirectory)
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let ignored = root.appending(path: "Ignored", directoryHint: .isDirectory)
        for directory in [sources, ignored, root.appending(path: ".git")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = sources.appending(path: "Alpha.swift")
        let beta = sources.appending(path: "Beta.swift")
        try "value alpha\r\n".write(to: alpha, atomically: true, encoding: .utf8)
        try "value beta\n".write(to: beta, atomically: true, encoding: .utf8)
        try "value excluded\n".write(to: sources.appending(path: "Skip.log"), atomically: true, encoding: .utf8)
        try "value ignored\n".write(to: ignored.appending(path: "Hidden.txt"), atomically: true, encoding: .utf8)
        try "Ignored/\n*.tmp\n!visible.tmp\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "value kept\n".write(to: root.appending(path: "visible.tmp"), atomically: true, encoding: .utf8)
        try Data([0, 118, 97, 108, 117, 101]).write(to: root.appending(path: "asset.dat"))
        try checkGlobs()

        let document = app.makeDocument()
        defer { document.window.close() }
        let window = document.window
        _ = try await app.openFile(alpha, in: document)
        for action in [FindCommand.find, .findWorkspace] {
            try expect(document.folderURL == nil && document.canPerformFind(action), "both Find commands are available for a standalone file")
            document.performFind(action)
            let input = try require(window.firstResponder as? FindFieldTextView, "focus Find for the standalone file")
            set("alpha", in: input)
            let buffer = try require(descendant(in: window.contentView, of: SidebarActionResultTable.self) {
                $0.accessibilityLabel() == "Search Results"
            }, "find standalone buffer results")
            try await waitFor("show the match in the standalone file") {
                document.findScope == .buffer && !buffer.isHiddenOrHasHiddenAncestor && buffer.numberOfRows == 1
            }
            try expect(descendant(in: window.contentView, of: ModeSelector.self) {
                $0.accessibilityLabel() == "Search scope" && !$0.isHiddenOrHasHiddenAncestor
            } == nil, "a standalone file has no scope picker")
            document.performFind(.toggleSidebar)
        }
        _ = try await app.openFile(root, in: document)
        document.performFind(.find)
        let finder = try require(window.firstResponder as? FindFieldTextView, "Command-F focuses Find before a file is selected")
        let scope = try require(descendant(in: window.contentView, of: ModeSelector.self) {
            $0.accessibilityLabel() == "Search scope"
        }, "Search uses the shared mode selector")
        try expect(document.showsEmptyFolder && !scope.isHiddenOrHasHiddenAncestor && scope.selectedSegment == 0,
                   "Command-F selects Current Buffer in a folder with no open file")
        let buffer = try require(descendant(in: window.contentView, of: SidebarActionResultTable.self) {
            $0.accessibilityLabel() == "Search Results"
        }, "find the empty buffer results")
        let header = try require(descendant(in: window.contentView, of: SidebarResultGroupHeader.self) {
            !$0.isHiddenOrHasHiddenAncestor
        }, "find the visible buffer result count")
        let regex = try require(descendant(in: window.contentView, of: NSButton.self) { $0.toolTip == "Regular Expression" },
                                "find the regex option")
        regex.performClick(nil)
        // Wait for this query's publication even when the previous query also had no results.
        header.detailText = ""
        set("^", in: finder)
        try await waitFor("a zero-width regex finds no matches without an open buffer") {
            !buffer.isHiddenOrHasHiddenAncestor && buffer.numberOfRows == 0 && header.detailText == "No results"
        }
        regex.performClick(nil)
        set("beta", in: finder)
        document.performFind(.findWorkspace)
        let table = try require(descendant(in: window.contentView, of: WorkspaceFindTable.self), "a native workspace results table")
        try await waitFor("Shift-Command-F searches files on disk before a file is selected") {
            scope.selectedSegment == 1 && window.firstResponder === finder && finder.string == "beta" &&
                !table.isHiddenOrHasHiddenAncestor && rows(in: table).count == 1
        }
        set("", in: finder)
        try await waitFor("clear workspace results before the first-scan transition") { table.numberOfRows == 0 }
        let include = try require(field("Files to include", in: window), "the Include field is available")
        let exclude = try require(field("Files to exclude", in: window), "the Exclude field is available")
        let ignore = try require(descendant(in: window.contentView, of: NSButton.self) {
            $0.toolTip == "Respect .gitignore"
        }, "the repository has a .gitignore control")

        try await waitFor("prepare the repository field control") { !ignore.isHidden }
        try checkFields(in: document, finder: finder, include: include, exclude: exclude, ignore: ignore, capture: capture)
        _ = try await app.openFile(alpha, in: document)
        try await checkScopeTransition(in: document, scope: scope, finder: finder, workspace: table, capture: capture)
        try await waitFor("show four matches and apply the ignore rules") { rows(in: table).count == 4 && !ignore.isHidden }
        try expect(scope.selectedSegment == 1 && ignore.state == .on, "Workspace scope and .gitignore are selected")
        ignore.performClick(nil)
        try await waitFor("include the ignored file with ignore rules off") { rows(in: table).count == 5 }
        ignore.performClick(nil)
        try await waitFor("restore the ignore rules") { rows(in: table).count == 4 }

        set("[", in: include)
        try await waitFor("report malformed globs and remove stale results") {
            rows(in: table).isEmpty && fieldValue("Invalid Include pattern", in: window)
        }
        set("*.swift, ./visible.tmp", in: include)
        try await waitFor("include multiple glob patterns") { rows(in: table).count == 3 }
        set("*.log", in: exclude)

        _ = try await app.openFile(alpha, in: document)
        document.toggleSidebarFocus(.worktree)
        let worktree = try require(document.sidebar.worktree?.outline, "show Worktree")
        try await waitFor("show Sources in Worktree") {
            (0..<worktree.numberOfRows).contains { row in
                (worktree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Sources"
            }
        }
        let sourcesRow = try require((0..<worktree.numberOfRows).first { row in
            (worktree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Sources"
        }, "find Sources in Worktree")
        let menu = try require(document.sidebar.worktree?.menu(at: sourcesRow), "open the folder context menu")
        let findHere = menu.indexOfItem(withTitle: "Find Here")
        try expect(findHere >= 0, "Find Here appears for a Worktree folder")
        menu.performActionForItem(at: findHere)
        try await waitFor("Find Here searches only Sources and preserves Exclude") {
            rows(in: table).count == 2 && include.string == "./Sources/**" && exclude.string == "*.log"
        }
        try expect(document.findSettings.query == "value" && window.firstResponder === finder, "Find Here preserves the query and focuses Find")
        let split = document.documentSplitView
        let sidebar = try require(window.contentViewController as? NSSplitViewController, "a native split sidebar")
        split.setPosition(sidebar.splitViewItems[0].minimumThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        let inFrame = try require(include.enclosingScrollView?.superview as? FindInput, "Include has a shared field bezel")
        let exFrame = try require(exclude.enclosingScrollView?.superview as? FindInput, "Exclude has a shared field bezel")
        try expect(abs(inFrame.frame.width - scope.frame.width) < 1 &&
                   abs(exFrame.frame.width - scope.frame.width) < 1 && scope.frame.width >= 188,
                   "equal-width fields and scope fill the minimum sidebar width")
        for index in 0..<2 {
            let segment = scope.segmentFrame(at: index)
            let point = scope.convert(NSPoint(x: segment.midX, y: segment.midY), to: nil)
            try expect(EditApplication.clickCursor(in: window, at: point) === NSCursor.pointingHand,
                       "show the pointing hand on each search scope")
        }
        try capture(window, "workspace")

        let toolbar = window.toolbar?.items.compactMap { $0 as? SidebarMenuItem }.first?.options?.menu
        let menuOptions = try require(toolbar, "Search shares the sidebar options menu")
        menuOptions.performActionForItem(at: menuOptions.indexOfItem(withTitle: "Tree Mode"))
        window.layoutIfNeeded()
        let folderHeading = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let folderLabels = folderHeading?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        try expect(table.numberOfRows == 5 && folderLabels == ["Sources", "2"],
                   "Tree Mode adds a shared folder heading and aggregates its matches")
        try capture(window, "tree")

        let (gate, release) = AsyncStream<Void>.makeStream()
        var staged = false
        document.beforeInstallFileForCheck = { file in
            guard file.url.lastPathComponent == "Beta.swift" else { return }
            staged = true
            for await _ in gate { break }
        }
        defer { release.finish() }
        let betaRow = try require(rows(in: table).last, "find the second workspace match")
        table.selectRowIndexes(IndexSet(integer: betaRow), byExtendingSelection: false)
        try await waitFor("hold the incoming search match") { staged }
        try expect(window.title.contains("Alpha.swift") && document.editor.string.contains("value alpha"),
                   "the previous file and its title remain paired while the search result is pending")
        try capture(window, "pending")
        release.finish()
        try await waitFor("present the destination text and title together") {
            window.title.contains("Beta.swift") && document.editor.string == "value beta\n" && !document.isBusy
        }
        try capture(window, "result")
        document.beforeInstallFileForCheck = nil

        document.editor.insertText("value live\n", replacementRange: NSRange(location: document.editor.string.utf16.count, length: 0))
        try await waitFor("search the unsaved current buffer") { rows(in: table).count == 3 }
        document.performFind(.replace)
        let replacement = try require(window.firstResponder as? FindFieldTextView, "focus workspace replacement")
        replacement.insertText("changed", replacementRange: replacement.selectedRange())
        var confirmation: (Int, Int)?
        document.confirmWorkspaceReplaceForCheck = { matches, files in
            confirmation = (matches, files)
            try? "externally changed\r\n".write(to: alpha, atomically: true, encoding: .utf8)
            return true
        }
        document.performFind(.replaceAll)
        try await waitFor("apply the writable part of the workspace replacement") {
            document.editor.string == "changed beta\nchanged live\n" && window.firstResponder === table &&
                fieldValue("Could not update 1 file(s)", in: window)
        }
        try expect(confirmation?.0 == 3 && confirmation?.1 == 2, "the confirmation counts matches and files")
        try expect(try String(contentsOf: alpha, encoding: .utf8) == "externally changed\r\n" &&
                   String(contentsOf: beta, encoding: .utf8) == "changed beta\nchanged live\n",
                   "replacement preserves newer disk changes and saves the live buffer")
        table.undo(nil)
        try await waitFor("one Undo restores the live file and its unsaved snapshot") {
            document.editor.string == "value beta\nvalue live\n" && table.canUndoChanges?(true) == true
        }
        try expect(try String(contentsOf: beta, encoding: .utf8) == "value beta\nvalue live\n",
                   "Undo restores the disk revision as well as the editor")

        let gamma = sources.appending(path: "Gamma.swift")
        try "value gamma\r\n".write(to: gamma, atomically: true, encoding: .utf8)
        document.performFind(.refresh)
        try await waitFor("refresh finds a newly added closed file") {
            rows(in: table).count == 3 && fieldValue("Gamma.swift", in: window) && document.canPerformFind(.replaceAll)
        }
        document.confirmWorkspaceReplaceForCheck = { _, _ in true }
        document.performFind(.replaceAll)
        try await waitFor("replace in both the live buffer and a closed file") {
            document.editor.string == "changed beta\nchanged live\n" &&
                (try? String(contentsOf: gamma, encoding: .utf8)) == "changed gamma\r\n"
        }
        table.undo(nil)
        try await waitFor("one Undo restores both files and their line endings") {
            document.editor.string == "value beta\nvalue live\n" &&
                (try? String(contentsOf: gamma, encoding: .utf8)) == "value gamma\r\n"
        }

        document.performFind(.find)
        try expect(document.findScope == .buffer && scope.selectedSegment == 0 &&
                   include.isHiddenOrHasHiddenAncestor && exclude.isHiddenOrHasHiddenAncestor,
                   "Command-F chooses Current Buffer and hides the filters")
        try expect(scope.hasLocalSlideForCheck(from: 1, to: 0), "slide from Workspace to Current Buffer")
        try await waitFor("let the Current Buffer highlight settle") { !scope.selectionIsAnimatingForCheck }
        finder.insertText("live", replacementRange: NSRange(location: 0, length: finder.string.utf16.count))
        scope.moveRight(nil)
        try expect(scope.selectedSegment == 1 && scope.hasLocalSlideForCheck(from: 0, to: 1),
                   "use the right arrow and slide from Current Buffer to Workspace")
        try await waitFor("a query changed in Current Buffer also refreshes Workspace") {
            rows(in: table).count == 1 && document.canPerformFind(.replaceAll)
        }
        let peer = app.makeDocument()
        defer { peer.window.close() }
        _ = try await app.openFile(root, in: peer)
        peer.performFind(.findWorkspace)
        try expect(field("Files to include", in: peer.window)?.string == "./Sources/**" &&
                   field("Files to exclude", in: peer.window)?.string == "*.log" &&
                   peer.sessionDocument().findSettings?.scope == .workspace,
                   "workspace filters are shared by folder and the active scope belongs to the window session")
        try checkStoredFilters(root: root)

        let metadataFolder = root.appending(path: "Metadata", directoryHint: .isDirectory)
        let nested = metadataFolder.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let query = "workspaceMetadataMatch"
        try "\(query)\n".write(to: metadataFolder.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try "\(query)\n\(query)\n".write(to: nested.appending(path: "Highlight.m"), atomically: true, encoding: .utf8)
        set("", in: include)
        set(query, in: finder)
        try await waitFor("skip metadata without missing matches in a neighboring folder") {
            rows(in: table).count == 2 && fieldValue("Highlight.m", in: window) && document.canPerformFind(.replaceAll)
        }
        try capture(window, "metadata")
    }

    private static func checkFields(in document: DocumentWindow, finder: FindFieldTextView, include: FindFieldTextView,
                                    exclude: FindFieldTextView, ignore: NSButton, capture: (NSWindow, String) throws -> Void) throws {
        let window = document.window
        document.performFind(.replace)
        let replace = try require(field("Replace", in: window), "find the Replace field")
        let regex = try require(descendant(in: window.contentView, of: NSButton.self) {
            $0.toolTip == "Regular Expression"
        }, "find the trailing toggle in Find")
        window.layoutIfNeeded()
        let fields = [finder, replace, include, exclude]
        let bezels = try fields.map { try require($0.enclosingScrollView?.superview as? FindInput, "use a shared Search field") }
        func origin(_ field: FindFieldTextView, in bezel: FindInput) -> CGFloat {
            field.convert(field.textContainerOrigin, to: bezel).y
        }
        let first = bezels[0]
        for (field, bezel) in zip(fields, bezels) {
            let position = origin(field, in: bezel)
            try expect(abs(first.bounds.height - bezel.bounds.height) < 0.5 &&
                       abs(position - origin(finder, in: first)) < 0.5, "use the same text position and height in all four fields")
            try expect(window.makeFirstResponder(field), "focus \(field.placeholder)")
            window.layoutIfNeeded()
            try expect(abs(position - origin(field, in: bezel)) < 0.5, "the text baseline stays fixed on focus")
        }
        let findButton = regex.convert(regex.bounds, to: first)
        let excludeButton = ignore.convert(ignore.bounds, to: bezels[3])
        try expect(findButton.size == excludeButton.size &&
                   abs(findButton.midY - excludeButton.midY) < 0.5 &&
                   abs((first.bounds.maxX - findButton.maxX) - (bezels[3].bounds.maxX - excludeButton.maxX)) < 0.5,
                   "the trailing toggles share size and insets")
        try capture(window, "fields")
        let longGlob = String(repeating: "Long Folder/", count: 12) + "*.swift"
        set(longGlob, in: exclude)
        try expect(exclude.string == longGlob && exclude.frame.width > (exclude.enclosingScrollView?.bounds.width ?? 0) &&
                   abs(bezels[3].bounds.height - first.bounds.height) < 0.5, "long globs scroll horizontally on one line")
        set("", in: exclude)
        document.performFind(.toggleReplace)
    }

    private static func checkScopeTransition(in document: DocumentWindow, scope: ModeSelector, finder: FindFieldTextView,
                                             workspace: WorkspaceFindTable, capture: (NSWindow, String) throws -> Void) async throws {
        let window = document.window
        document.performFind(.find)
        let menu = try require(window.toolbar?.items.compactMap { $0 as? SidebarMenuItem }.first?.options?.menu,
                               "find the Search options menu")
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Tree Mode"))
        defer { menu.performActionForItem(at: menu.indexOfItem(withTitle: "Tree Mode")) }
        let buffer = try require(descendant(in: window.contentView, of: SidebarActionResultTable.self) {
            $0.accessibilityLabel() == "Search Results"
        }, "find the Current Buffer results")
        set("value", in: finder)
        try await waitFor("paint the Current Buffer match before selecting Workspace") {
            buffer.numberOfRows == 1 && !document.resultDecorations.visibleHighlightsForCheck.isEmpty
        }
        let highlights = document.resultDecorations.visibleHighlightsForCheck
        let text = document.editor.string
        let (gate, release) = AsyncStream<Void>.makeStream()
        var scans = 0
        document.beforePublishingWorkspaceFindForCheck = {
            scans += 1
            for await _ in gate { break }
        }
        defer {
            release.finish()
            document.beforePublishingWorkspaceFindForCheck = nil
        }
        scope.buttonForCheck(at: 1).performClick(nil)
        try await waitFor("hold the first workspace response") { scans == 1 }
        try await Task.sleep(for: .milliseconds(200))
        try capture(window, "scope-pending")
        try expect(window.title.contains("Alpha.swift") && document.editor.string == text,
                   "keep the title and buffer text paired during the scope switch")
        try expect(document.resultDecorations.visibleHighlightsForCheck == highlights,
                   "keep the editor highlight while the workspace scan is pending")
        try expect(!buffer.isHiddenOrHasHiddenAncestor && buffer.numberOfRows == 1,
                   "keep the buffer result visible while the first workspace scan is pending")
        release.finish()
        try await waitFor("present the workspace tree and editor highlight together") {
            !workspace.isHiddenOrHasHiddenAncestor && workspace.numberOfRows == 9 && rows(in: workspace).count == 4
        }
        try capture(window, "scope-ready")
        try expect(document.resultDecorations.visibleHighlightsForCheck == highlights,
                   "the first frame of Workspace preserves the editor highlight")
        scope.buttonForCheck(at: 0).performClick(nil)
        scope.buttonForCheck(at: 1).performClick(nil)
        try expect(!workspace.isHiddenOrHasHiddenAncestor && rows(in: workspace).count == 4 &&
                   document.resultDecorations.visibleHighlightsForCheck == highlights,
                   "return to a populated Workspace tree and preserve the highlight immediately")
        try await Task.sleep(for: .milliseconds(200))
        try expect(scans == 1, "switching back to Workspace does not rerun an unchanged search")
    }

    private static func checkGlobs() throws {
        let mixed = try WorkspaceFindGlob("./Sources/**/{[!A-Z]*,Keep?}.swift, docs/**")
        try expect(mixed.matches("Sources/Nested/Keep1.swift") && mixed.matches("Sources/test.swift") &&
                   !mixed.matches("Other/Sources/test.swift") && !mixed.matches("Sources/Upper.swift") &&
                   mixed.matches("Features/docs/readme.md"), "parse anchors, globstar, braces and character classes")
        let literal = try WorkspaceFindGlob(WorkspaceFindGlob.folder("Sources/A[1],{b}?*"))
        try expect(literal.matches("Sources/A[1],{b}?*/Example.swift") &&
                   !literal.matches("Other/Sources/A[1],{b}?*/Example.swift"), "quote literal navigation paths")
        try expect((try? WorkspaceFindGlob("foo/{bar,baz")) == nil, "reject an unfinished brace group")
    }

    private static func checkStoredFilters(root: URL) throws {
        let key = "EditWorkspaceSearchCheck-\(UUID())"
        let defaults = try require(UserDefaults(suiteName: key), "create disposable preferences")
        defer { defaults.removePersistentDomain(forName: key) }
        let store = WorkspaceFindPreferences(defaults: defaults)
        store[root] = WorkspaceFindFilters(include: "**/*.swift", exclude: "", respectsIgnoreFiles: false)
        let restored = WorkspaceFindPreferences(defaults: defaults)
        try expect(restored[root] == store[root] && restored[root.deletingLastPathComponent()] == WorkspaceFindFilters(),
                   "persist an empty Exclude and custom ignore setting under only the selected folder")
    }

    private static func rows(in table: WorkspaceFindTable) -> [Int] {
        (0..<table.numberOfRows).filter { table.view(atColumn: 0, row: $0, makeIfNecessary: true) is SidebarActionResultCell }
    }

    private static func field(_ name: String, in window: NSWindow) -> FindFieldTextView? {
        descendant(in: window.contentView, of: FindFieldTextView.self) { $0.accessibilityLabel() == name }
    }

    private static func fieldValue(_ value: String, in window: NSWindow) -> Bool {
        descendant(in: window.contentView, of: NSTextField.self) { $0.stringValue == value && !$0.isHiddenOrHasHiddenAncestor } != nil
    }

    private static func set(_ value: String, in field: FindFieldTextView) {
        field.insertText(value, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
    }

    private static func descendant<T: NSView>(in view: NSView?, of type: T.Type, where matches: (T) -> Bool = { _ in true }) -> T? {
        guard let view else { return nil }
        if let target = view as? T, matches(target) { return target }
        for child in view.subviews {
            if let target = descendant(in: child, of: type, where: matches) { return target }
        }
        return nil
    }

    private static func waitFor(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<220 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw Failure(message)
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Workspace Search: \(detail)" }
    }
}
