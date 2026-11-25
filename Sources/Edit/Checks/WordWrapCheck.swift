import AppKit

@MainActor
enum WordWrapCheck {
    static func run(in app: Edit, capture: (NSWindow, String) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Word Wrap \(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let first = root.appending(path: "Wrapped.txt")
        let second = root.appending(path: "Plain.txt")
        let prose = String(repeating: "Soft wrapping keeps these words together. ", count: 6)
        let text = prose + "\n" + String(repeating: "x", count: 170) + "\nEnd of file.\n"
        let otherText = "A separate buffer. " + text
        try Data(text.utf8).write(to: first)
        try Data(otherText.utf8).write(to: second)

        let document = app.makeDocument()
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let editor = document.editor
        let window = document.window
        let scroll = document.scrollView
        window.setContentSize(NSSize(width: 690, height: 455))
        let menu = try require(NSApp.mainMenu, "main menu")
        let item = try require(menu.item(withTitle: "View")?.submenu?.item(withTitle: "Toggle Word Wrap"), "View menu command")
        let command = try require(ControlCommand.fromMenu(menu).first { $0.result.title == "View: Toggle Word Wrap" },
                                  "Command Mode action with its menu prefix")
        let action = try require(item.action, "word wrap menu action")

        func layout() {
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        func firstLineRows() throws -> [NSTextLineFragment] {
            let layout = try require(editor.textLayoutManager, "TextKit 2 layout manager")
            let fragment = try require(layout.textLayoutFragment(for: layout.documentRange.location), "first paragraph")
            try expect(fragment.state == .layoutAvailable, "lay out the first paragraph")
            return fragment.textLineFragments
        }

        _ = try await app.openFile(first, in: document)
        layout()
        try expect(!editor.wrapsWords && scroll.hasHorizontalScroller && (try firstLineRows().count) == 1,
                   "a file starts with wrapping off and one display row per source line")
        let selection = NSRange(location: 5, length: 7)
        editor.setSelectedRange(selection)
        let farRight = CGFloat(prose.utf16.count) * 6
        scroll.scrollToVisibleContentOrigin(NSPoint(x: farRight, y: 0))
        try expect(scroll.visibleContentOrigin.x > 0, "the unwrapped file can scroll horizontally")
        try expect(app.validateUserInterfaceItem(item) && item.state == .off &&
                   NSApp.sendAction(action, to: item.target, from: item), "activate the View menu command")
        layout()
        let wideRows = try firstLineRows()
        let firstBreak = try require(wideRows.first?.characterRange.upperBound, "first soft break")
        let tokenStart = try require(editor.laidOutLineBounds(at: prose.utf16.count + 1), "long word start")
        let tokenEnd = try require(editor.laidOutLineBounds(at: prose.utf16.count + 170), "long word end")
        try expect(editor.wrapsWords && wideRows.count > 1 && firstBreak > 0 && firstBreak < prose.utf16.count &&
                   (prose as NSString).substring(with: NSRange(location: firstBreak - 1, length: 1)) == " ",
                   "TextKit reflows the paragraph at a word boundary")
        try expect(tokenEnd.minY > tokenStart.minY, "a token wider than the buffer also wraps")
        try expect(scroll.visibleContentOrigin.x == 0 && !scroll.hasHorizontalScroller && editor.selectedRange() == selection &&
                   editor.string == text && !window.isDocumentEdited && app.validateUserInterfaceItem(item) && item.state == .on,
                   "wrap preserves the selection and contents, clears horizontal scrolling and checks the menu item")
        try capture(window, "word-wrap")

        window.setContentSize(NSSize(width: 500, height: 455))
        layout()
        let narrowRows = try firstLineRows().count
        try expect(narrowRows > wideRows.count, "narrowing the window adds display rows")
        document.performFind(.find)
        layout()
        await Task.yield()
        layout()
        try expect(scroll.contentInsets.left > 0 && (try firstLineRows().count) > narrowRows,
                   "the sidebar reduces the available wrap width")
        try capture(window, "word-wrap-sidebar")
        document.performFind(.toggleSidebar)
        layout()

        let (pending, release) = AsyncStream<Void>.makeStream()
        var staged = false
        document.beforeInstallFileForCheck = { file in
            guard file.url == FileBuffer.canonicalURL(second) else { return }
            staged = true
            for await _ in pending { break }
        }
        let opening = Task { try await app.openFile(second, in: document) }
        defer {
            document.beforeInstallFileForCheck = nil
            release.finish()
            opening.cancel()
        }
        for _ in 0..<200 where !staged { try await Task.sleep(for: .milliseconds(10)) }
        layout()
        try expect(staged && window.title == first.lastPathComponent && editor.string == text && editor.wrapsWords &&
                   (try firstLineRows().count) > 1, "the outgoing title and wrapped editor stay visible while a file is pending")
        release.finish()
        _ = try await opening.value
        document.beforeInstallFileForCheck = nil
        layout()
        try expect(window.title == second.lastPathComponent && editor.string == otherText && !editor.wrapsWords &&
                   (try firstLineRows().count) == 1, "the first destination frame has its own title and wrap mode")

        _ = try await app.openFile(first, in: document)
        layout()
        try expect(editor.wrapsWords && (try firstLineRows().count) > 1, "reopening the file restores its wrap mode")
        let peer = app.makeDocument()
        defer { peer.window.close() }
        _ = try await app.openFile(first, in: peer)
        try expect(peer.editor.wrapsWords, "a separate window opens the file with its saved wrap mode")
        try expect(command.isAvailable(in: document, focus: editor), "word wrap is available in Command Mode")
        command.run(in: document)
        layout()
        try expect(!editor.wrapsWords && !peer.editor.wrapsWords && scroll.hasHorizontalScroller &&
                   (try firstLineRows().count) == 1, "Command Mode turns wrapping off for the file in both windows")

        await document.newBuffer()
        try expect(document.fileURL == nil && !editor.wrapsWords, "a fresh untitled buffer starts unwrapped")
        document.toggleWordWrap()
        let saved = root.appending(path: "Saved draft.txt")
        let didSave = await document.save(to: saved)
        try expect(didSave && editor.wrapsWords, "a draft keeps its mode on first save")
        _ = try await app.openFile(second, in: document)
        try expect(!editor.wrapsWords, "the other file still opens unwrapped")
        _ = try await app.openFile(saved, in: document)
        try expect(editor.wrapsWords, "the saved draft reopens wrapped")
        let didCopy = await document.save(to: root.appending(path: "Copy.txt"))
        try expect(didCopy && !editor.wrapsWords, "Save As uses the new path's setting")
        _ = try await app.openFile(saved, in: document)
        try expect(editor.wrapsWords, "Save As preserves the original file's setting")
        try checkStoredModes(first: first, second: second)
    }

    private static func checkStoredModes(first: URL, second: URL) throws {
        let suite = "dev.edit-swift.word-wrap-check.\(UUID())"
        let defaults = try require(UserDefaults(suiteName: suite), "isolated preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FileWordWrap(defaults: defaults)
        settings.set(true, for: first)
        let reloaded = FileWordWrap(defaults: defaults)
        try expect(reloaded.isEnabled(for: first) && !reloaded.isEnabled(for: second),
                   "a fresh settings store loads only the selected file's wrap mode")
        reloaded.set(false, for: first)
        try expect(!FileWordWrap(defaults: defaults).isEnabled(for: first), "turning off wrap is persistent")
        reloaded.set(true, for: first)
        let directory = first.deletingLastPathComponent()
        let destination = directory.appending(path: "Moved", directoryHint: .isDirectory)
        reloaded.move(from: directory, to: destination)
        let moved = FileWordWrap(defaults: defaults)
        try expect(!moved.isEnabled(for: first) && moved.isEnabled(for: destination.appending(path: first.lastPathComponent)),
                   "an enabled setting moves with a Worktree rename")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(detail: message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(detail: message) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Word Wrap: \(detail)" }
    }
}
