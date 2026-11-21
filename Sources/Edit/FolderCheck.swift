import AppKit

@MainActor
enum FolderCheck {
    static func run(in app: Edit) async throws -> NSWindow {
        let root = FileManager.default.temporaryDirectory.appending(path: "Folder check #\(UUID())")
        let project = root.appending(path: "Project One")
        let other = root.appending(path: "Project Two")
        let empty = root.appending(path: "Empty Project")
        try makeDirectory(project.appending(path: "Sources"))
        try makeDirectory(other)
        try makeDirectory(empty.appending(path: "README.md"))
        let readme = try write("Preferred README", to: project.appending(path: "README.MD"))
        _ = try write("Second choice", to: project.appending(path: "readme"))
        _ = try write("Third choice", to: project.appending(path: "readme.txt"))
        let fallback = try write("Other README format", to: other.appending(path: "ReadMe.rst"))
        let nested = try write("func folderCheck() {}\n", to: project.appending(path: "Sources/FolderCheckUnique.swift"))
        let outside = try write("Outside the project", to: root.appending(path: "Notes.txt"))
        let canonicalProject = FileBuffer.canonicalURL(project).path

        let document = app.makeDocument()
        let count = app.documents.count
        let frame = document.window.frame
        var launcher = URLComponents()
        launcher.scheme = "dev-edit-swift"
        launcher.host = "open"
        launcher.queryItems = [URLQueryItem(name: "path", value: project.path)]
        guard let launcherURL = launcher.url else { throw Failure("folder launch URL") }
        app.application(NSApplication.shared, open: [launcherURL])
        try await waitFor("launcher opens the preferred README in the current window") {
            document.folderURL?.path == canonicalProject && document.fileURL == FileBuffer.canonicalURL(readme)
        }
        try expect(document.editor.string == "Preferred README" && app.documents.count == count
                   && document.window.frame == frame && document.window.title == "README.MD — Project One",
                   "opening a folder preserves the window and updates its native title")
        try expect(document.window.representedURL == document.fileURL, "folder title keeps the file's native proxy")
        try await ControlPanel(app: app).checkFolder(in: document, file: FileBuffer.canonicalURL(nested))
        try expect(document.folderURL?.path == canonicalProject && document.fileURL == FileBuffer.canonicalURL(nested),
                   "a file chosen in Control keeps its folder")

        _ = try await app.openFile(outside, in: document)
        try expect(document.folderURL?.path == canonicalProject && document.window.title == "Notes.txt — Project One",
                   "opening an external file keeps the folder")
        let remembered = await app.recentFiles.lastFile(in: project)
        try expect(remembered == FileBuffer.canonicalURL(nested), "external files leave the folder's last file alone")
        let returned = try await app.openFile(project, in: document)
        try expect(returned === document && document.fileURL == remembered, "reopening a folder restores its last file")
        let selection = NSRange(location: 2, length: 3)
        document.editor.setSelectedRange(selection)
        _ = try await app.openFile(project, in: document)
        try expect(document.editor.selectedRange() == selection, "opening the current folder preserves selection")

        let scratch = app.makeDocument()
        _ = try await app.openFile(empty, in: scratch)
        try expect(scratch.fileURL == nil && scratch.editor.string.isEmpty
                   && scratch.window.title == "Untitled — Empty Project", "a folder with no README opens empty")
        scratch.editor.insertText("Recover this scratch buffer", replacementRange: scratch.editor.selectedRange())
        let cancelled = try await app.openFile(other, in: scratch)
        try expect(cancelled == nil && scratch.window.title == "Untitled — Empty Project"
                   && scratch.editor.string == "Recover this scratch buffer", "Cancel keeps the folder and draft")

        let missing = app.makeDocument()
        _ = try await app.openFile(other, in: missing)
        try expect(missing.fileURL == FileBuffer.canonicalURL(fallback), "other README extensions are accepted")
        try FileManager.default.removeItem(at: fallback)
        let store = SessionStore(url: root.appending(path: "session.json"))
        try store.write(EditorSession(documents: [document, scratch, missing].map { $0.sessionDocument() },
                                      activeIndex: 0, lastWindow: nil))
        guard let session = try store.read() else { throw Failure("read back folder session") }
        [document, scratch, missing].forEach { $0.window.close() }
        let placeholder = app.makeDocument()
        await app.restore(session, reusing: placeholder)
        let recovered = Array(app.documents.suffix(3))
        try expect(recovered.first === placeholder && recovered.map { $0.folderURL?.lastPathComponent }
                   == ["Project One", "Empty Project", "Project Two"], "restore independent folder contexts")
        try expect(placeholder.fileURL == FileBuffer.canonicalURL(nested) && placeholder.window.frame == frame,
                   "restore the original file and frame in a folder")
        try expect(recovered[1].editor.string == "Recover this scratch buffer" && recovered[1].window.isDocumentEdited,
                   "restore the unsaved draft within its folder")
        try expect(recovered[2].fileURL == nil && recovered[2].window.title == "Untitled — Project Two",
                   "restore a folder window after its named file is deleted")

        let newReadme = try write("New fallback", to: other.appending(path: "README.txt"))
        _ = try await app.openFile(other, in: recovered[2])
        try expect(recovered[2].fileURL == FileBuffer.canonicalURL(newReadme),
                   "a folder with a missing remembered file falls back to its README")

        try await checkRecentMenu(in: app, root: root)
        return placeholder.window
    }

    private static func checkRecentMenu(in app: Edit, root: URL) async throws {
        for index in 0..<11 {
            let folder = root.appending(path: "Recent Folder \(index)")
            try makeDirectory(folder)
            _ = try write("Recent file", to: folder.appending(path: "Recent File \(index).txt"))
            await app.recentFiles.recordFolder(folder, opening: folder.appending(path: "Recent File \(index).txt"))
        }
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu,
              let menu = fileMenu.item(withTitle: "Open Recent")?.submenu else { throw Failure("File → Open Recent menu") }
        app.menuWillOpen(fileMenu)
        guard let separator = menu.items.firstIndex(where: \.isSeparatorItem) else { throw Failure("recent menu separator") }
        let folderItems = menu.items[..<separator].filter { $0.representedObject is URL }
        let folderRows = folderItems.compactMap { $0.representedObject as? URL }
        let fileRows = menu.items[(separator + 1)...].compactMap { $0.representedObject as? URL }
        try expect(folderRows.count == 10 && folderRows.map(\.path) == app.recentFiles.folders.prefix(10).map(\.url.path)
                   && fileRows.count == 10 && fileRows.map(\.path) == app.recentFiles.entries.prefix(10).map(\.url.path),
                   "Open Recent shows ten folders before ten files, each newest first")
        guard let item = folderItems.first, let action = item.action, let folder = folderRows.first else {
            throw Failure("action on the first recent folder")
        }
        let document = app.makeDocument()
        let windowCount = app.documents.count
        let canonical = FileBuffer.canonicalURL(folder)
        try expect(NSApplication.shared.sendAction(action, to: item.target, from: item), "Open Recent can select a folder")
        try await waitFor("Open Recent opens the remembered file in the same window") {
            document.folderURL?.path == canonical.path && document.fileURL?.lastPathComponent == "Recent File 10.txt"
        }
        try expect(app.documents.count == windowCount, "Open Recent reuses the current window")
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func write(_ text: String, to url: URL) throws -> URL {
        try Data(text.utf8).write(to: url)
        return url
    }

    private static func waitFor(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Folders: \(detail)" }
    }
}
