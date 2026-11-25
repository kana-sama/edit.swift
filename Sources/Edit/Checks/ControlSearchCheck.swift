import AppKit

@MainActor
enum ControlSearchCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "Control search: \(message)" }
    }

    static func run(in app: Edit, capture: ((NSView) throws -> Void)? = nil) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "Control search \(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = FileBuffer.canonicalURL(temporary)
        func file(_ path: String) throws -> URL {
            let url = root.appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
            return url
        }

        let readme = try file("Project/README.md")
        let nested = try file("Project/Vendor/README.md")
        let deep = try file("Project/Vendor/Deep/README.md")
        let fuzzy = try file("Project/Read_me.md")
        let foreign = try file("Project Other/README.md")
        let global = try file("README.md")
        let external = try file("Project notes.txt")
        let project = readme.deletingLastPathComponent()
        let otherProject = foreign.deletingLastPathComponent()
        let other = app.makeDocument()
        let document = app.makeDocument()
        defer { document.window.close(); other.window.close() }

        _ = try await app.openFile(foreign, in: other)
        _ = try await app.openFile(otherProject, in: other)
        _ = try await app.openFile(foreign, in: other)
        _ = try await app.openFile(project, in: document)
        _ = try await app.openFile(nested, in: document)
        _ = try await app.openFile(deep, in: document)
        _ = try await app.openFile(external, in: document)
        _ = try await app.openFile(foreign, in: document)
        let folderless = app.makeDocument()
        defer { folderless.window.close() }
        _ = try await app.openFile(global, in: folderless)

        let panel = ControlPanel(app: app)
        try await panel.checkFileOrder(in: document, within: root, query: "", expected: [global, external, deep, nested])
        try await panel.checkFileOrder(in: document, within: root, query: "Vendor/readme.md", expected: [nested, deep])
        try await panel.checkFileOrder(in: other, within: root, query: "readme.md", expected: [foreign, global])
        try await panel.checkFileOrder(in: folderless, within: root, query: "", expected: [global])
        try await panel.checkFileOrder(in: folderless, within: root, query: "readme.md", expected: [global])
        try await panel.checkFileOrder(in: document, within: root, query: "readme.md",
                                       expected: [readme, nested, deep, global, fuzzy], openFirst: true, capture: capture)

        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let recentMenu = fileMenu.item(withTitle: "Open Recent")?.submenu else { throw Failure("missing Open Recent menu") }
        let candidates: Set = [readme.path, nested.path, deep.path, foreign.path, global.path, external.path]
        func menuFiles() -> [String] {
            app.menuWillOpen(fileMenu)
            return recentMenu.items.compactMap { ($0.representedObject as? URL).map(FileBuffer.canonicalURL)?.path }
                .filter(candidates.contains)
        }
        let sharedMenuFiles = menuFiles()
        guard sharedMenuFiles == [global.path] else {
            throw Failure("folderless Open Recent should list just the shared README, got \(recentMenu.items.map(\.title))")
        }
        _ = try await app.openFile(project, in: folderless)
        let projectMenuFiles = menuFiles()
        guard projectMenuFiles == [readme, global, external, deep, nested].map(\.path) else {
            throw Failure("project Open Recent should list this project and shared files, got \(projectMenuFiles)")
        }

        try await checkHistory(at: root.appending(path: "History.json"), project: project, other: otherProject,
                               local: nested, foreign: foreign, global: global, external: external)
        try checkSymbols(in: project, rootFile: readme, nested: nested, foreign: foreign)
        try FileManager.default.removeItem(at: temporary)
        await app.recentFiles.prune()
    }

    private static func checkHistory(at archive: URL, project: URL, other: URL,
                                     local: URL, foreign: URL, global: URL, external: URL) async throws {
        let history = RecentFiles(url: archive)
        await history.recordFolder(project)
        await history.recordFolder(other)
        await history.record(local, in: project)
        await history.record(foreign, in: other)
        await history.record(global)
        await history.record(external, in: project)
        await history.finishWrites()

        let restored = RecentFiles(url: archive)
        await restored.load()
        guard restored.entries(in: project).map(\.canonicalURL.path) == [external, global, local].map(\.path),
              restored.entries(in: other).map(\.canonicalURL.path) == [global, foreign].map(\.path),
              restored.entries(in: nil).map(\.canonicalURL.path) == [global.path] else {
            throw Failure("saved project ownership survives restart")
        }

        // Simulate an archive written before project ownership was stored.
        guard var old = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any],
              let files = old["files"] as? [[String: Any]] else { throw Failure("read history fixture") }
        old["files"] = files.dropFirst().map { $0.filter { $0.key != "project" } }
        try JSONSerialization.data(withJSONObject: old).write(to: archive, options: .atomic)
        let migrated = RecentFiles(url: archive)
        await migrated.load()
        guard migrated.entries(in: project).map(\.canonicalURL.path) == [global, local].map(\.path),
              migrated.entries(in: other).map(\.canonicalURL.path) == [global, foreign].map(\.path),
              migrated.entries(in: nil).map(\.canonicalURL.path) == [global.path],
              let recent = migrated.entries(in: project).last else { throw Failure("isolate known roots in the old archive") }
        migrated.dismiss(recent)
        guard migrated.entries(in: other).map(\.canonicalURL.path) == [global, foreign].map(\.path) else {
            throw Failure("removing a search history item does not change other projects")
        }
        await migrated.finishWrites()
    }

    private static func checkSymbols(in project: URL, rootFile: URL, nested: URL, foreign: URL) throws {
        let start = LSPPosition(line: 0, character: 0)
        func symbol(_ name: String, _ url: URL) -> LSPSymbol {
            LSPSymbol(name: name, detail: nil, kind: 12,
                      location: LSPLocation(url: url, range: LSPRange(start: start, end: start)))
        }
        let symbols = [symbol("ServerOnly", foreign), symbol("findEntry", foreign), symbol("findEntry", nested),
                       symbol("findEntry", rootFile), symbol("findExact", nested), symbol("find_Exact", rootFile)]
        let results = ControlNavigation.symbolResults(symbols, query: "findEntry", workspace: true, folder: project,
                                                      alternateCharacters: [:])
        let expected = ["README.md", "Vendor/README.md", foreign.path]
        guard results.prefix(3).compactMap(\.entry.detail) == expected,
              results.dropFirst(3).map(\.entry.title) == ["ServerOnly", "findExact", "find_Exact"] else {
            throw Failure("workspace symbol location breaks ties without changing server-only order")
        }
        let exact = ControlNavigation.symbolResults(symbols, query: "findExact", workspace: true, folder: project,
                                                    alternateCharacters: [:])
        guard exact.first?.entry.title == "findExact" else { throw Failure("exact symbol match beats proximity") }
    }
}
