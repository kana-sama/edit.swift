import AppKit

@MainActor
enum ScratchCheck {
    static func run(in app: Edit) async throws {
        try await ScratchSaveSheet.check()
        let root = FileManager.default.temporaryDirectory.appending(path: "scratch-check-\(UUID())", directoryHint: .isDirectory)
        let project = root.appending(path: "Project", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested/Project", directoryHint: .isDirectory)
        for folder in [project, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = project.appending(path: "Notes.txt")
        let original = Data("\u{feff}Project notes\r\n".utf8)
        try original.write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = app.makeDocument()
        let folderless = app.makeDocument()
        defer {
            document.window.close()
            folderless.window.close()
        }
        folderless.editor.insertText("Global notes", replacementRange: NSRange(location: 0, length: 0))
        let global = try await folderless.saveScratch(name: "Notes.txt", folder: nil)
        try expect(folderless.fileURL != nil && global.folderPath == nil && !folderless.window.isDocumentEdited,
                   "saving as a global scratch adopts it in the same window")

        _ = try await app.openFile(project, in: document)
        _ = try await app.openFile(source, in: document)
        document.editor.insertText("Extra\r\n", replacementRange: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 1, length: 3)
        document.editor.setSelectedRange(selection)
        let text = document.editor.string
        let canUndo = document.editor.undoManager?.canUndo
        let scratch = try await document.saveScratch(name: "Notes.txt", folder: project)
        let url = try resolve(document.fileURL)
        try expect(document.editor.string == text && document.editor.selectedRange() == selection &&
                   document.editor.undoManager?.canUndo == canUndo && !document.window.isDocumentEdited,
                   "Save as Scratch keeps content, selection, and undo in the active document")
        try expect(try Data(contentsOf: url) == Data(("\u{feff}" + text).utf8) && Data(contentsOf: source) == original,
                   "scratch retains BOM and CRLF and leaves the source file on disk")
        try expect(!app.recentFiles.entries.contains { $0.canonicalURL == url }, "a scratch never enters Open Recent")
        try expect(await app.recentFiles.lastFile(in: project) == FileBuffer.canonicalURL(source),
                   "saving a scratch keeps the folder's remembered file")

        let newer = project.appending(path: "Newer Recent.txt")
        try Data("Recent file".utf8).write(to: newer)
        await app.recentFiles.record(newer)
        try await ControlPanel(app: app).checkScratchRecency(in: document, scratch: scratch, older: source, newer: newer)
        try await ControlPanel(app: app).checkScratches(in: document, scratch: scratch, global: global)
        document.toggleSidebarFocus(.scratches)
        try expect(document.sidebarMode == .scratches && document.isSidebarVisible, "show Scratches in a folder window")
        folderless.toggleSidebarFocus(.scratches)
        folderless.performFind(.toggleSidebar)
        folderless.performFind(.toggleSidebar)
        try expect(folderless.sidebarMode == .scratches && folderless.isSidebarVisible,
                   "remember Scratches when toggling the sidebar without a folder")

        let nestedPath = try resolve(ScratchStore.folderPath(for: nested))
        let projectPath = try resolve(ScratchStore.folderPath(for: project))
        let originalGlobalURL = folderless.fileURL
        app.scratchesDidChange(updated: try await app.scratchStore.move([global.id], to: projectPath))
        let moved = try resolve(folderless.scratchFile)
        try expect(moved.id == global.id && moved.name == "Notes 2.txt" && moved.folderPath == projectPath &&
                   folderless.fileURL == originalGlobalURL && folderless.window.title == "Notes 2.txt",
                   "a move resolves a collision and updates the open title without replacing the editor")
        app.scratchesDidChange(updated: try await app.scratchStore.move([scratch.id], to: nestedPath))
        try expect(document.scratchFile?.folderPath == nestedPath && ScratchStore.folderPath(for: document.folderURL) == projectPath &&
                   document.editor.selectedRange() == selection, "moving a scratch keeps the window context and selection")

        document.editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        try await waitForAutosave(document, at: url)
        document.editor.insertText("Local draft", replacementRange: NSRange(location: 0, length: 0))
        let external = Data("External edit".utf8)
        try external.write(to: url, options: .atomic)
        await document.flushAutosave()
        try expect(try Data(contentsOf: url) == external && document.window.isDocumentEdited,
                   "a conflicting scratch autosave keeps the external file and dirty draft")

        let record = document.sessionDocument()
        let reopened = app.makeDocument()
        defer { reopened.window.close() }
        await app.restore(EditorSession(documents: [record], activeIndex: 0, lastWindow: nil), reusing: reopened)
        try expect(reopened.scratchFile?.id == scratch.id && reopened.scratchFile?.folderPath == nestedPath &&
                   reopened.editor.string == document.editor.string && reopened.window.isDocumentEdited &&
                   reopened.sidebarMode == .scratches && reopened.isSidebarVisible,
                   "session restoration recovers the scratch draft, moved category, and sidebar")

        let exported = project.appending(path: "Exported.txt")
        try expect(await reopened.save(asNew: true, to: exported) && reopened.scratchFile == nil,
                   "Save As continues in a regular file")
        try expect(try Data(contentsOf: url) == external && app.recentFiles.entries.contains { $0.url == exported },
                   "export leaves the scratch on disk and records the regular file")

        do {
            _ = try await folderless.saveScratch(name: "../invalid", folder: nil)
            throw Failure("invalid scratch name was accepted")
        } catch where !(error is Failure) {
            try expect(folderless.scratchFile?.id == global.id, "a failed save keeps the open scratch")
        }

        folderless.setFolder(project)
        let scratchPath = try resolve(folderless.fileURL)
        let rememberedFile = await app.recentFiles.lastFile(in: project)
        folderless.editor.insertText("Saved on close. ", replacementRange: NSRange(location: 0, length: 0))
        let textAtClose = folderless.editor.string
        folderless.window.performClose(nil)
        let deadline = ContinuousClock.now + .seconds(4)
        while (!folderless.showsEmptyFolder || folderless.isBusy) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(folderless.showsEmptyFolder && !folderless.isBusy && folderless.scratchFile == nil
                   && folderless.window.representedURL == nil && folderless.sidebarMode == .scratches
                   && folderless.isSidebarVisible && app.documents.contains { $0 === folderless },
                   "closing a scratch leaves its folder and Scratches sidebar open")
        try expect(try FileBuffer.read(scratchPath).text == textAtClose, "closing a scratch flushes its edits")
        try expect(await app.recentFiles.lastFile(in: project) == rememberedFile,
                   "closing a scratch preserves the remembered project file")
        _ = try await app.openFile(scratchPath, in: folderless)
        try expect(folderless.scratchFile?.id == global.id && folderless.editor.string == textAtClose
                   && ScratchStore.folderPath(for: folderless.folderURL) == projectPath,
                   "reopening a scratch replaces the empty screen in the same folder")
    }

    private static func waitForAutosave(_ document: DocumentWindow, at url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while document.window.isDocumentEdited && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(try FileBuffer.read(url).text == document.editor.string && !document.window.isDocumentEdited,
                   "idle autosave writes scratch edits")
    }

    private static func resolve<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure("expected a scratch value") }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { "Scratch check: \(message)" }
    }
}
