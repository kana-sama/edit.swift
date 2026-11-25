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
        try makeDirectory(empty)
        _ = try write("Project README", to: project.appending(path: "README.md"))
        let readme = try write("Only file in this project", to: other.appending(path: "README.md"))
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
        try await waitFor("launcher opens the project without a document in the current window") {
            document.folderURL?.path == canonicalProject && document.showsEmptyFolder
        }
        try expect(document.fileURL == nil && !document.editor.isEditable && app.documents.count == count
                   && document.window.frame == frame && document.window.title == "Project One",
                   "opening an unvisited folder preserves the window and shows only the folder title")
        try expect(document.window.representedURL == nil, "the empty screen represents no file")
        try expect(!document.canPerformFind(.find) && document.canPerformFind(.toggleSidebar),
                   "the empty screen keeps sidebar navigation available")
        if let menu = NSApp.mainMenu,
           let goToBracket = ControlCommand.fromMenu(menu).first(where: {
               $0.item.action == #selector(EditorTextView.goToBracket(_:))
           }) {
            try expect(!goToBracket.isAvailable(in: document, focus: document.window.firstResponder),
                       "document-only Control commands are unavailable on the empty screen")
        } else {
            throw Failure("find Go to Bracket in Control")
        }
        await app.recentFiles.record(outside)
        try await ControlPanel(app: app).checkFolder(in: document, file: FileBuffer.canonicalURL(nested))
        try expect(document.folderURL?.path == canonicalProject && document.fileURL == FileBuffer.canonicalURL(nested)
                   && !document.showsEmptyFolder && document.window.representedURL == document.fileURL,
                   "a file chosen in Control keeps its folder")

        _ = try await app.openFile(outside, in: document)
        try expect(document.folderURL?.path == canonicalProject && document.window.title == "Project One — Notes.txt",
                   "opening an external file keeps the folder")
        let remembered = await app.recentFiles.lastFile(in: project)
        try expect(remembered == FileBuffer.canonicalURL(nested), "external files leave the folder's last file alone")
        let returned = try await app.openFile(project, in: document)
        try expect(returned === document && document.fileURL == remembered, "reopening a folder restores its last file")
        let selection = NSRange(location: 2, length: 3)
        document.editor.setSelectedRange(selection)
        _ = try await app.openFile(project, in: document)
        try expect(document.editor.selectedRange() == selection, "opening the current folder preserves selection")

        let closing = app.makeDocument()
        _ = try await app.openFile(project, in: closing)
        try expect(closing.fileURL == remembered, "opening the project in another window opens its remembered file")
        closing.editor.insertText("// autosaved while closing\n", replacementRange: NSRange(location: 0, length: 0))
        let savedText = closing.editor.string
        try expect(closing.window.isDocumentEdited, "the active document needs an autosave before closing")
        closing.closeDocument()
        try await waitFor("the first document close shows the empty folder") { closing.showsEmptyFolder && !closing.isBusy }
        try expect(app.documents.contains { $0 === closing } && closing.folderURL?.path == canonicalProject,
                   "closing an edited file keeps the project window open")
        let saved = try String(contentsOf: nested, encoding: .utf8)
        try expect(saved == savedText, "the first close writes the edited named document")
        let emptySession = closing.sessionDocument()
        closing.closeDocument()
        try await waitFor("the second document close closes the folder window") { !app.documents.contains { $0 === closing } }

        let scratch = app.makeDocument()
        _ = try await app.openFile(empty, in: scratch)
        try expect(scratch.showsEmptyFolder && scratch.window.title == "Empty Project", "a folder with no files opens empty")
        await scratch.newBuffer()
        try expect(!scratch.showsEmptyFolder && scratch.editor.isEditable && scratch.window.title == "Empty Project — Untitled",
                   "New creates an editable untitled document in the project")
        scratch.editor.insertText("Recover this scratch buffer", replacementRange: scratch.editor.selectedRange())
        scratch.window.performClose(nil)
        try expect(scratch.isBusy, "closing a dirty untitled document runs draft protection")
        try await waitFor("Cancel ends the pending close") { !scratch.isBusy }
        try expect(!scratch.showsEmptyFolder && scratch.editor.string == "Recover this scratch buffer"
                   && app.documents.contains { $0 === scratch }, "Cancel preserves the open untitled draft")
        let cancelled = try await app.openFile(other, in: scratch)
        try expect(cancelled == nil && scratch.window.title == "Empty Project — Untitled"
                   && scratch.editor.string == "Recover this scratch buffer", "Cancel keeps the folder and draft")

        let missing = app.makeDocument()
        _ = try await app.openFile(other, in: missing)
        try expect(missing.fileURL == nil && missing.showsEmptyFolder, "a README by itself does not open automatically")
        _ = try await app.openFile(readme, in: missing)
        try FileManager.default.removeItem(at: readme)

        let cleanUntitled = app.makeDocument()
        _ = try await app.openFile(empty, in: cleanUntitled)
        await cleanUntitled.newBuffer()
        let windows = [document, scratch, missing, cleanUntitled]
        let records = windows.map { $0.sessionDocument() } + [emptySession]
        let store = SessionStore(url: root.appending(path: "session.json"))
        try store.write(EditorSession(documents: records, activeIndex: 0, lastWindow: nil))
        guard let session = try store.read() else { throw Failure("read back folder session") }
        windows.forEach { $0.window.close() }
        let placeholder = app.makeDocument()
        await app.restore(session, reusing: placeholder)
        let recovered = Array(app.documents.suffix(records.count))
        try expect(recovered.first === placeholder && recovered.map { $0.folderURL?.lastPathComponent }
                   == ["Project One", "Empty Project", "Project Two", "Empty Project", "Project One"],
                   "restore independent folder contexts")
        try expect(placeholder.fileURL == FileBuffer.canonicalURL(nested) && placeholder.window.frame == frame,
                   "restore the original file and frame in a folder")
        try expect(recovered[1].editor.string == "Recover this scratch buffer" && recovered[1].window.isDocumentEdited,
                   "restore the unsaved draft within its folder")
        try expect(recovered[2].fileURL == nil && recovered[2].showsEmptyFolder && recovered[2].window.title == "Project Two",
                   "restore the empty folder screen after its named file is deleted")
        try expect(!recovered[3].showsEmptyFolder && recovered[3].editor.isEditable && recovered[3].fileURL == nil,
                   "restore an explicitly opened clean untitled document separately from the empty folder screen")
        try expect(recovered[4].showsEmptyFolder && recovered[4].fileURL == nil,
                   "restore the empty folder screen even when the folder has a remembered file")

        _ = try write("New fallback", to: other.appending(path: "README.txt"))
        _ = try await app.openFile(other, in: recovered[2])
        try expect(recovered[2].showsEmptyFolder && recovered[2].fileURL == nil,
                   "a folder with a missing remembered file opens without selecting a substitute")

        try await checkControlExclusions(in: app, root: root)
        try await checkRecentMenu(in: app, root: root)
        return recovered[4].window
    }

    private static func checkControlExclusions(in app: Edit, root: URL) async throws {
        let repo = root.appending(path: "Ignore Repository")
        let project = repo.appending(path: "Project")
        try makeDirectory(repo.appending(path: ".git"))
        _ = try write("/Project/from-parent/\n", to: repo.appending(path: ".gitignore"))
        try makeDirectory(project)
        _ = try write("a\nprobe-c.txt\nignored*/\n!ignored-keep/\n**/Generated/\n",
                      to: project.appending(path: ".gitignore"))

        func file(_ path: String) throws -> URL {
            let url = project.appending(path: path)
            try makeDirectory(url.deletingLastPathComponent())
            return try write("sample", to: url)
        }

        let b = try file("a/probe-b.txt")
        let g = try file("a/e/probe-g.txt")
        let c = try file("probe-c.txt")
        let d = try file("probe-d.txt")
        let dotFile = try file(".probe-config")
        let findCheck = try file("Sources/Edit/FindCheck.swift")
        let highlight = try file("Sources/EditSyntax/Highlight.m")
        let dsStore = try file("Sources/.DS_Store")
        let hiddenDSStore = try file("a/.DS_Store")
        let outsideDSStore = try write("sample", to: repo.appending(path: ".DS_Store"))
        _ = try file(".DS_Store")
        let dotDirectory = try file("src/.hidden/probe-h.txt")
        let generated = try file("src/Generated/probe-generated.txt")
        let dependency = try file("node_modules/probe-module.txt")
        let keep = try file("ignored-keep/probe-keep.txt")
        let ignored = try file("ignored-other/probe-other.txt")
        let inherited = try file("from-parent/probe-parent.txt")
        let nestedIgnored = try file("src/one/probe-x.txt")
        let nestedIncluded = try file("elsewhere/one/probe-y.txt")
        let rustTarget = try file("Rust/target/probe-build.txt")
        let ordinaryTarget = try file("Other/target/probe-source.txt")
        _ = try file("Rust/Cargo.toml")
        _ = try write("/one/\n", to: project.appending(path: "src/.gitignore"))

        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(project, in: document)
        for recent in [b, g, c, dotDirectory, generated, inherited, nestedIgnored, rustTarget, findCheck, dsStore, hiddenDSStore, outsideDSStore] {
            await app.recentFiles.record(recent, in: document.folderURL)
        }
        try await ControlPanel(app: app).checkFolderQueries(in: document, expectations: [
            ("", [c, findCheck]),
            ("probe", [c, d, dotFile, keep, nestedIncluded, ordinaryTarget]),
            ("FindCheck", [findCheck]),
            ("Sources/", [findCheck, highlight]),
            ("Sources/Highlight", [highlight]),
            ("Sources/Edit/", [findCheck]),
            (".DS_Store", []),
            ("a/", [b]),
            ("a/ probe-g", []),
            ("a/e/", [g]),
            ("a/e/probe-g", [g]),
            ("src/.hidden/", [dotDirectory]),
            ("src/Generated/", [generated]),
            ("node_modules/", [dependency]),
            ("ignored-other/", [ignored]),
            ("from-parent/", [inherited]),
            ("src/one/", [nestedIgnored]),
            ("Rust/target/", [rustTarget]),
            ("../", []),
            ("", [c, findCheck]),
            ("a/e/probe-g", [g]),
        ], relativeDetails: [findCheck: "Sources/Edit", highlight: "Sources/EditSyntax"], opening: g)
    }

    private static func checkRecentMenu(in app: Edit, root: URL) async throws {
        for index in 0..<11 {
            let folder = root.appending(path: "Recent Folder \(index)")
            try makeDirectory(folder)
            _ = try write("Recent file", to: folder.appending(path: "Recent File \(index).txt"))
            await app.recentFiles.recordFolder(folder, opening: folder.appending(path: "Recent File \(index).txt"))
        }
        let document = app.makeDocument()
        guard let fileMenu = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu,
              let menu = fileMenu.item(withTitle: "Open Recent")?.submenu else { throw Failure("File → Open Recent menu") }
        app.menuWillOpen(fileMenu)
        guard let separator = menu.items.firstIndex(where: \.isSeparatorItem) else { throw Failure("recent menu separator") }
        let folderItems = menu.items[..<separator].filter { $0.representedObject is URL }
        let folderRows = folderItems.compactMap { $0.representedObject as? URL }
        let fileRows = menu.items[(separator + 1)...].compactMap { $0.representedObject as? URL }
        try expect(folderRows.count == 10 && folderRows.map(\.path) == app.recentFiles.folders.prefix(10).map(\.url.path)
                   && fileRows.map(\.path) == app.recentFiles.entries(in: nil).prefix(10).map(\.url.path),
                   "Open Recent shows ten folders before up to ten eligible files, each newest first")
        guard let item = folderItems.first, let action = item.action, let folder = folderRows.first else {
            throw Failure("action on the first recent folder")
        }
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
