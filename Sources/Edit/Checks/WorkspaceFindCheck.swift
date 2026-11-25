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
        try expect(!document.canPerformFind(.findWorkspace), "workspace search is unavailable without a folder")
        _ = try await app.openFile(root, in: document)
        try expect(document.showsEmptyFolder && document.canPerformFind(.findWorkspace), "search can open before a file is selected")
        document.performFind(.findWorkspace)
        let window = document.window
        let table = try require(descendant(in: window.contentView, of: WorkspaceFindTable.self), "a native workspace results table")
        let finder = try require(window.firstResponder as? FindFieldTextView, "Find in Workspace focuses Find")
        let scope = try require(descendant(in: window.contentView, of: ModeSelector.self) {
            $0.accessibilityLabel() == "Search scope"
        }, "Search uses the shared mode selector")
        let include = try require(field("Include", in: window), "the Include field is available")
        let exclude = try require(field("Exclude", in: window), "the Exclude field is available")
        let ignore = try require(descendant(in: window.contentView, of: NSButton.self) {
            $0.toolTip == "Respect .gitignore"
        }, "the repository has a .gitignore control")

        finder.insertText("value", replacementRange: finder.selectedRange())
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
            rows(in: table).count == 2 && include.stringValue == "./Sources/**" && exclude.stringValue == "*.log"
        }
        try expect(document.findSettings.query == "value" && window.firstResponder === finder, "Find Here preserves the query and focuses Find")
        let split = document.documentSplitView
        let sidebar = try require(window.contentViewController as? NSSplitViewController, "a native split sidebar")
        split.setPosition(sidebar.splitViewItems[0].minimumThickness, ofDividerAt: 0)
        window.layoutIfNeeded()
        let inFrame = try require(include.superview?.superview, "Include has a shared field bezel")
        let exFrame = try require(exclude.superview?.superview, "Exclude has a shared field bezel")
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
        try await Task.sleep(for: .milliseconds(220))
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
        try expect(field("Include", in: peer.window)?.stringValue == "./Sources/**" &&
                   field("Exclude", in: peer.window)?.stringValue == "*.log" &&
                   peer.sessionDocument().findSettings?.scope == .workspace,
                   "workspace filters are shared by folder and the active scope belongs to the window session")
        try checkStoredFilters(root: root)
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

    private static func field(_ name: String, in window: NSWindow) -> NSTextField? {
        descendant(in: window.contentView, of: NSTextField.self) { $0.accessibilityLabel() == name }
    }

    private static func fieldValue(_ value: String, in window: NSWindow) -> Bool {
        descendant(in: window.contentView, of: NSTextField.self) { $0.stringValue == value && !$0.isHiddenOrHasHiddenAncestor } != nil
    }

    private static func set(_ value: String, in field: NSTextField) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
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
