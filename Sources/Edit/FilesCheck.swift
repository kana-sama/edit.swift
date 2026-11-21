import AppKit

@MainActor
enum FilesCheck {
    static func run(in app: Edit) async throws -> DocumentWindow {
        let temporaryRoot = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = temporaryRoot.appendingPathComponent("files-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Notes.txt")
        let other = directory.appendingPathComponent("Reference.txt")
        let initialText = "first line\r\nsecond line\r\n"
        try Data(("\u{feff}" + initialText).utf8).write(to: file)
        try Data("On disk before quitting\n".utf8).write(to: other)
        let initial = try resolve(app.documents.first)
        initial.editor.string = ""
        initial.editor.didChangeText()

        await app.openFiles([file, file])
        try expect(app.documents.count == 1, "reuse empty window and focus matching file")
        let document = try resolve(app.documents.first)
        try expect(document.fileURL == FileBuffer.canonicalURL(file), "opened file URL")
        try expect(document.window.title == "Notes.txt" && document.editor.string == initialText, "file title and CRLF content")

        let inserted = "Swift café 👋\r\n"
        document.editor.insertText(inserted, replacementRange: NSRange(location: 0, length: 0))
        try expect(document.window.isDocumentEdited, "native dirty marker on editing")
        let saved = await document.save()
        try expect(saved && !document.window.isDocumentEdited, "save clears dirty state")
        let savedBytes = try Data(contentsOf: file)
        try expect(savedBytes == Data(("\u{feff}" + inserted + initialText).utf8), "save preserves UTF-8 BOM and line endings")

        await app.openFiles([other])
        try expect(app.documents.count == 2, "a second file gets a native window")
        let draft = try resolve(app.documents.last)
        let draftText = "An unsaved note\n"
        draft.editor.insertText(draftText, replacementRange: NSRange(location: 0, length: 0))
        let userFrame = NSRect(x: 48, y: 72, width: 640, height: 440)
        document.window.setFrame(userFrame, display: false)
        let unsaved = app.makeDocument()
        unsaved.editor.insertText("An untitled draft", replacementRange: NSRange(location: 0, length: 0))

        let store = SessionStore(url: directory.appendingPathComponent("profiles/session.json"))
        try expect(try store.read() == nil, "missing session is an empty startup")
        try store.write(app.sessionSnapshot())
        let session = try resolve(store.read())
        try Data("Externally changed clean file\n".utf8).write(to: file)
        try Data("Externally changed draft file\n".utf8).write(to: other)

        for window in app.documents {
            window.window.close()
        }
        try expect(app.documents.isEmpty, "closed documents are removed")
        await app.restore(session, reusing: app.makeDocument())
        try expect(app.documents.count == 3, "session restores clean and draft windows")
        let reopened = try resolve(app.documents.first)
        try expect(reopened.editor.string == "Externally changed clean file\n", "clean files reload from disk")
        try expect(reopened.window.frame == userFrame, "native window frame restores")
        let recovered = app.documents[1]
        try expect(recovered.editor.string == draftText + "On disk before quitting\n", "named draft is preserved")
        try expect(recovered.window.isDocumentEdited, "restored draft stays marked edited")
        let untitled = app.documents[2]
        try expect(untitled.editor.string == "An untitled draft", "untitled draft is recovered")
        try expect(!reopened.window.isVisible && !NSApplication.shared.isActive, "quiet restoration")

        // A restored draft still expects its original disk revision.
        let record = recovered.sessionDocument()
        do {
            _ = try FileBuffer.save(recovered.editor.string, to: other, format: record.format ?? FileFormat(), expected: record.revision)
            throw Failure("expected an external edit conflict")
        } catch FileBufferError.changedOnDisk {
            let bytes = try Data(contentsOf: other)
            try expect(bytes == Data("Externally changed draft file\n".utf8), "external version remains intact")
        }

        let newPath = directory.appendingPathComponent("New empty file.txt")
        await app.openFiles([newPath], allowMissing: true)
        let newDocument = try resolve(app.documents.last)
        try expect(!FileManager.default.fileExists(atPath: newPath.path), "new path stays absent until Save")
        let created = await newDocument.save()
        try expect(created && FileManager.default.fileExists(atPath: newPath.path), "Save creates an empty named file")
        try expect(newDocument.windowShouldClose(newDocument.window), "clean file closes without a prompt")
        try expect(!recovered.windowShouldClose(recovered.window), "dirty file cannot close without a decision")
        await recovered.finishClose(.cancel)
        try expect(app.documents.contains { $0 === recovered }, "Cancel keeps a dirty document open")
        await recovered.finishClose(.save(to: nil))
        try expect(app.documents.contains { $0 === recovered }, "a failed save keeps a dirty document open")
        await recovered.finishClose(.discard)
        try expect(!app.documents.contains { $0 === recovered }, "Don’t Save closes a dirty window")
        try expect(try Data(contentsOf: other) == Data("Externally changed draft file\n".utf8),
                   "Don’t Save preserves bytes on disk")

        newDocument.editor.insertText("Saved when closing", replacementRange: newDocument.editor.selectedRange())
        await newDocument.finishClose(.save(to: nil))
        try expect(!app.documents.contains { $0 === newDocument }, "Save closes the successfully saved window")
        try expect(try Data(contentsOf: newPath) == Data("Saved when closing".utf8), "Save on close writes the edits")

        await untitled.finishClose(.cancel)
        try expect(app.documents.contains { $0 === untitled } && untitled.editor.string == "An untitled draft",
                   "Cancel keeps the untitled draft open with its text")
        await untitled.finishClose(.discard)
        try expect(!app.documents.contains { $0 === untitled }, "Delete closes the untitled draft")

        let draftToSave = app.makeDocument()
        draftToSave.editor.insertText("Save the draft", replacementRange: draftToSave.editor.selectedRange())
        let draftPath = directory.appendingPathComponent("Saved draft.txt")
        await draftToSave.finishClose(.save(to: draftPath))
        try expect(!app.documents.contains { $0 === draftToSave }, "saving an untitled draft closes its window")
        try expect(try Data(contentsOf: draftPath) == Data("Save the draft".utf8),
                   "Save writes an untitled draft to the chosen path")

        let preview = directory.appendingPathComponent("Meeting Notes.txt")
        let sampleText = "Meeting notes\n\nTuesday\n    Review the new editor\n    Bring a sample project\n"
        try Data(sampleText.utf8).write(to: preview)
        await app.openFiles([preview])
        let sample = try resolve(app.documents.last)
        try expect(sample.window.title == "Meeting Notes.txt", "opened document uses its native file title")
        let offscreen = WindowPlacement(
            frame: NSRect(x: 60000, y: 60000, width: 720, height: 480),
            isFullScreen: false
        )
        offscreen.restoreFrame(on: sample.window)
        try expect(NSScreen.screens.contains { $0.visibleFrame.intersects(sample.window.frame) },
                   "lost display falls back to an available screen")
        sample.window.layoutIfNeeded()
        sample.editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        sample.editor.refreshCurrentLine()
        return sample
    }

    private static func resolve<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure("missing verification value") }
        return value
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { throw Failure(description) }
    }

    private struct Failure: LocalizedError {
        let description: String

        init(_ description: String) { self.description = description }

        var errorDescription: String? { "Failed file-session check for \(description)." }
    }
}
