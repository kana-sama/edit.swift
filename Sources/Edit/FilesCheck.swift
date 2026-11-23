import AppKit
import Darwin

@MainActor
enum FilesCheck {
    static func run(in app: Edit) async throws -> DocumentWindow {
        let temporaryRoot = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = temporaryRoot.appendingPathComponent("files-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await checkReopeningClosedFiles(in: app, directory: directory)
        let file = directory.appendingPathComponent("Notes.txt")
        let other = directory.appendingPathComponent("Reference.txt")
        let initialText = "first line\r\nsecond line\r\n"
        try Data(("\u{feff}" + initialText).utf8).write(to: file)
        try Data("On disk before quitting\n".utf8).write(to: other)
        let initial = try resolve(app.documents.first)
        initial.editor.string = ""
        initial.editor.didChangeText()

        await app.openFiles([file, file], in: initial)
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

        app.newWindow(nil)
        let draft = try resolve(app.documents.last)
        await app.openFiles([other], in: draft)
        try expect(app.documents.count == 2 && draft.fileURL == FileBuffer.canonicalURL(other),
                   "Open fills the separate window created by New Window")
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

        let cli = URL(string: "dev-edit-swift://open?path=/tmp/Re%CC%81sume%20%23%26.txt")!
        try expect(Edit.launcherFileURL(cli)?.path == "/tmp/Re\u{301}sume #&.txt", "launcher preserves Unicode and reserved characters")
        let relative = URL(string: "dev-edit-swift://open?path=../file")!
        try expect(Edit.launcherFileURL(relative) == nil, "launcher only accepts absolute file paths")

        let newPath = directory.appendingPathComponent("New empty file.txt")
        app.newWindow(nil)
        let newDocument = try resolve(app.documents.last)
        await app.openFiles([newPath], allowMissing: true, in: newDocument)
        try expect(!FileManager.default.fileExists(atPath: newPath.path), "new path stays absent until Save")
        let created = await newDocument.save()
        try expect(created && FileManager.default.fileExists(atPath: newPath.path), "Save creates an empty named file")
        try expect(newDocument.windowShouldClose(newDocument.window), "clean file closes without a prompt")
        try expect(!recovered.windowShouldClose(recovered.window), "dirty file waits for autosave before closing")
        try await waitFor("cancel after a conflicting autosave leaves the document available") { !recovered.isBusy }
        await recovered.finishClose(.cancel)
        try expect(app.documents.contains { $0 === recovered }, "Cancel keeps a dirty document open")
        await recovered.finishClose(.save(to: nil))
        try expect(app.documents.contains { $0 === recovered }, "a failed save keeps a dirty document open")
        await recovered.finishClose(.discard)
        try expect(!app.documents.contains { $0 === recovered }, "Don’t Save closes a dirty window")
        try expect(try Data(contentsOf: other) == Data("Externally changed draft file\n".utf8),
                   "Don’t Save preserves bytes on disk")

        newDocument.editor.insertText("Saved when closing", replacementRange: newDocument.editor.selectedRange())
        newDocument.requestAutosave()
        try expect(!newDocument.windowShouldClose(newDocument.window), "Close waits for a pending write")
        try await waitFor("Close removes the successfully saved window") {
            !app.documents.contains { $0 === newDocument }
        }
        try expect(try Data(contentsOf: newPath) == Data("Saved when closing".utf8), "autosave on close writes the edits")

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

        try await checkOpeningInPlace(in: app, directory: directory)
        try await checkSupersededOpen(in: app, directory: directory)
        try await checkRecentFiles(in: app, directory: directory)
        try await checkEncodings(in: app, directory: directory)
        try checkSaveMetadata(in: directory)
        try await checkCoordinatedSave(in: directory)
        try await checkExternalRefresh(in: app, directory: directory)
        try await checkAutosaveAndNewBuffer(in: app, directory: directory)
        try await checkRememberedPosition(in: app, directory: directory)
        try await checkInterruptedDrafts(in: app, directory: directory)

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

    private static func checkInterruptedDrafts(in app: Edit, directory: URL) async throws {
        let first = app.makeDocument()
        let second = app.makeDocument()
        defer { first.window.close() }
        first.editor.insertText("Old draft", replacementRange: NSRange(location: 0, length: 0))
        second.editor.insertText("Independent draft", replacementRange: NSRange(location: 0, length: 0))
        let saved = EditorSession(documents: [first.sessionDocument(), second.sessionDocument()], activeIndex: 0, lastWindow: nil)
        let firstID = try resolve(saved.documents[0].draftRecovery?.id)
        let secondID = try resolve(saved.documents[1].draftRecovery?.id)
        first.editor.insertText(" updated", replacementRange: NSRange(location: 9, length: 0))

        let deadline = ContinuousClock.now + .seconds(3)
        var entries: [DraftCheckpoint] = []
        repeat {
            entries = try await app.draftRecovery.read().checkpoints.filter { [firstID, secondID].contains($0.revision.id) }
            if entries.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        let recovered = EditorSession.recovering(entries, into: saved)
        try expect(entries.count == 2 && recovered?.documents.map(\.draft) == ["Old draft updated", "Independent draft"],
                   "recover the latest checkpoint next to the other untitled draft without duplicating either")
        try expect(EditorSession.recovering(entries, into: nil)?.documents.count == 2,
                   "recover both untitled drafts even when the regular session is missing")

        let target = directory.appending(path: "Saved recovery draft.txt")
        let savedDraft = await first.save(to: target)
        second.window.close()
        let retired = try await app.draftRecovery.read().checkpoints.filter { [firstID, secondID].contains($0.revision.id) }
        try expect(savedDraft && retired.count == 2 && retired.allSatisfy { $0.text == nil } &&
                   EditorSession.recovering(retired, into: saved)?.documents.isEmpty == true,
                   "saving and discarding retire their copies from both the journal and the previous session")
    }

    private static func checkReopeningClosedFiles(in app: Edit, directory: URL) async throws {
        let originalWindows = app.documents
        defer {
            for document in app.documents where !originalWindows.contains(where: { $0 === document }) {
                document.window.close()
            }
        }
        let folder = directory.appending(path: "Reopen Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appending(path: "First.txt")
        let replacement = folder.appending(path: "Replacement.txt")
        let standaloneFile = directory.appending(path: "Standalone.txt")
        for file in [first, replacement, standaloneFile] { try Data("Test file\n".utf8).write(to: file) }
        let firstPath = FileBuffer.canonicalURL(first)
        let replacementPath = FileBuffer.canonicalURL(replacement)
        let standalonePath = FileBuffer.canonicalURL(standaloneFile)

        let project = app.makeDocument()
        let standalone = app.makeDocument()
        let menu = try resolve(NSApp.mainMenu)
        let fileMenu = try resolve(menu.item(withTitle: "File")?.submenu)
        let command = try resolve(ControlCommand.fromMenu(menu).first { $0.title == "File: Reopen Closed File" })
        try expect(command.result.shortcut == "⇧⌘T" && !command.isAvailable(in: project, focus: nil),
                   "Reopen Closed File appears in Command Mode and starts unavailable")
        let shortcut = try resolve(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                    timestamp: 0, windowNumber: project.window.windowNumber, context: nil,
                                                    characters: "T", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))

        project.setFolder(folder)
        _ = try await app.openFile(first, in: project)
        _ = try await app.openFile(standaloneFile, in: standalone)
        standalone.window.performClose(nil)
        try expect(!app.documents.contains { $0 === standalone }, "closing a standalone file closes its window")
        let selection = NSRange(location: 1, length: 3)
        project.editor.setSelectedRange(selection)
        project.window.performClose(nil)
        try await waitFor("closing a project file leaves the project window empty") { project.showsEmptyFolder && !project.isBusy }
        let windowCount = app.documents.count
        try expect(fileMenu.performKeyEquivalent(with: shortcut), "Shift-Command-T invokes Reopen Closed File through the File menu")
        try await waitFor("the shortcut reopens the last closed file in its project and restores focus and selection") {
            project.fileURL == firstPath && app.documents.count == windowCount &&
                project.window.firstResponder === project.editor && project.editor.selectedRange() == selection &&
                command.isAvailable(in: project, focus: nil)
        }

        project.window.performClose(nil)
        try await waitFor("the restored file can be closed again") { project.showsEmptyFolder && !project.isBusy }
        _ = try await app.openFile(replacement, in: project)
        command.run(in: project)
        try await waitFor("Command Mode reopens a project file in a separate window when its old window is occupied") {
            project.fileURL == replacementPath && app.documents.count == windowCount + 1 &&
                app.documents.last?.fileURL == firstPath && app.documents.last?.folderURL == project.folderURL &&
                command.isAvailable(in: project, focus: nil)
        }
        try expect(fileMenu.performKeyEquivalent(with: shortcut), "Shift-Command-T can step further back through the close history")
        try await waitFor("the older standalone file reopens and consumes the last history entry") {
            app.documents.count == windowCount + 2 && app.documents.last?.fileURL == standalonePath &&
                app.documents.last?.folderURL == nil && !command.isAvailable(in: project, focus: nil)
        }
    }

    static func checkFilePreview(in app: Edit) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "file-preview-\(UUID())",
                                                                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "actions")
        let original = Data([0xff, 0xff, 0x00, 0x42])
        try original.write(to: binary)

        let draft = app.makeDocument()
        draft.editor.insertText("Keep this draft", replacementRange: NSRange(location: 0, length: 0))
        let cancelled = try await app.openFile(binary, in: draft)
        try expect(cancelled == nil && draft.editor.string == "Keep this draft" && !draft.isShowingFilePreview,
                   "an inline preview respects cancellation of the outgoing draft")
        draft.window.close()

        let text = directory.appending(path: "Preview source.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" />".utf8).write(to: text)
        let document = app.makeDocument()
        _ = try await app.openFile(text, in: document)
        let selection = NSRange(location: 3, length: 4)
        document.editor.setSelectedRange(selection)
        let windowCount = app.documents.count
        let opened = try await app.openFile(binary, in: document)
        try expect(opened === document && app.documents.count == windowCount && document.window.attachedSheet == nil,
                   "an unreadable file shows inline in the current window")
        let surface = try resolve(document.contentResponder as? FilePreviewView)
        try expect(document.window.representedURL == FileBuffer.canonicalURL(binary) &&
                   document.scrollView.isHidden && !document.editor.isEditable && !document.window.isDocumentEdited,
                   "the read-only preview replaces the editor and owns the file title")
        try await waitFor("inline explanation and file metadata") {
            let labels = views(in: surface, ofType: NSTextField.self).map(\.stringValue)
            return labels.contains(where: { $0.contains("UTF-8") }) && labels.contains(where: { $0.contains("4 bytes") })
                && labels.contains(FileBuffer.canonicalURL(binary).path)
        }
        let saved = await document.save()
        let savedAs = await document.save(asNew: true, to: text)
        try expect(!saved && !savedAs && (try Data(contentsOf: binary)) == original,
                   "save commands cannot change a previewed file")

        let record = document.sessionDocument()
        let restored = app.makeDocument()
        await app.restore(EditorSession(documents: [record], activeIndex: 0, lastWindow: nil), reusing: restored)
        try expect(restored.isShowingFilePreview && restored.window.title == "actions" &&
                   restored.window.firstResponder === restored.contentResponder, "restoration reopens the read-only preview")
        restored.window.close()

        let image = directory.appending(path: "Preview sample.png")
        let bitmap = try resolve(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let blue = NSColor(deviceRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        for y in 0..<20 {
            for x in 0..<32 { bitmap.setColor(blue, atX: x, y: y) }
        }
        try resolve(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let window = document.window
        window.setContentSize(NSSize(width: 720, height: 300))
        var oldPreviewRemained = true
        var completeOnTitleChange = false
        let titleObservation = window.observe(\.title, options: [.new]) { _, change in
            guard change.newValue == image.lastPathComponent else { return }
            MainActor.assumeIsolated {
                let preview = document.contentResponder
                completeOnTitleChange = views(in: preview, ofType: NSImageView.self).contains {
                    $0.accessibilityLabel() == "Preview of Preview sample.png"
                } && views(in: preview, ofType: NSTextField.self).contains { $0.stringValue == "32 × 20" }
            }
        }
        let switched = try await app.openFile(image, in: document) {
            oldPreviewRemained = oldPreviewRemained && document.contentResponder === surface && window.title == "actions"
            return true
        }
        titleObservation.invalidate()
        try expect(switched === document && oldPreviewRemained && completeOnTitleChange,
                   "the previous preview stays in place until the new image and dimensions can appear with its title")
        let imageSurface = try resolve(document.contentResponder as? FilePreviewView)
        let scroll = try resolve(views(in: imageSurface, ofType: NSScrollView.self).first)
        let previewImage = try resolve(views(in: imageSurface, ofType: NSImageView.self).first)
        try expect(previewImage.imageScaling == .scaleProportionallyDown,
                   "preview images only scale down to fit")
        let path = try resolve(views(in: imageSurface, ofType: NSTextField.self).first {
            $0.stringValue == FileBuffer.canonicalURL(image).path
        })
        try expect(path.alignment == .right, "the path is aligned with the other metadata values")

        for sidebarVisible in [false, true] {
            if sidebarVisible { document.performFind(.toggleSidebar) }
            window.layoutIfNeeded()
            let toolbarBottom = window.contentLayoutRect.maxY
            try expect(scroll.contentInsets.top > 0 && scroll.convert(scroll.bounds, to: nil).maxY > toolbarBottom,
                       "the preview scroll view extends behind the toolbar with its native top inset")
            scroll.scrollToVisibleContentOrigin(.zero)
            let start = previewImage.convert(previewImage.bounds, to: nil)
            try expect(start.maxY <= toolbarBottom, "the preview starts below the toolbar")
            scroll.scrollToVisibleContentOrigin(NSPoint(x: 0, y: 68))
            let scrolled = previewImage.convert(previewImage.visibleRect, to: nil)
            try expect(scrolled.maxY > toolbarBottom && scrolled.minY < toolbarBottom,
                       "the image remains in the visible scroll area beneath the toolbar")
        }

        document.setFolder(directory)
        document.toggleSidebarFocus(.worktree)
        let worktree = try resolve(document.worktreeSidebar)
        let outline = worktree.outline
        func row(of file: URL) -> Int? {
            (0..<outline.numberOfRows).first { row in
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
                return cell?.textField?.stringValue == file.lastPathComponent
            }
        }
        try await waitFor("Worktree lists the files available to preview") { row(of: binary) != nil && row(of: image) != nil }
        let firstRow = try resolve(row(of: image))
        let lastRow = try resolve(row(of: binary))
        outline.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
        worktree.openFile(at: firstRow)
        outline.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
        worktree.openFile(at: lastRow)
        try await waitFor("rapid requests in Worktree keep the last preview and its metadata") {
            document.displayedFileURL == FileBuffer.canonicalURL(binary) &&
                views(in: document.contentResponder, ofType: NSTextField.self).contains { $0.stringValue.contains("4 bytes") }
        }
        try expect(window.firstResponder === outline && outline.selectedRow == lastRow,
                   "switching previews keeps Worktree focus and the final selection")

        _ = try await app.openFile(text, in: document)
        try expect(!document.isShowingFilePreview && document.editor.isEditable && !document.scrollView.isHidden
                   && document.editor.selectedRange() == selection && document.window.firstResponder === document.editor,
                   "returning to text restores editability, selection and focus")
        document.window.close()
    }

    private static func views<T: NSView>(in root: NSView, ofType type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views(in: $0, ofType: type) }
    }

    private static func checkOpeningInPlace(in app: Edit, directory: URL) async throws {
        let source = directory.appendingPathComponent("Open from here.txt")
        let target = directory.appendingPathComponent("Cargo.lock")
        try Data("original".utf8).write(to: source)
        try Data("version = 4".utf8).write(to: target)

        app.newWindow(nil)
        let first = try resolve(app.documents.last)
        _ = try await app.openFile(source, in: first)
        first.editor.insertText("Saved ", replacementRange: NSRange(location: 0, length: 0))

        app.newWindow(nil)
        let second = try resolve(app.documents.last)
        _ = try await app.openFile(target, in: second)
        let count = app.documents.count
        let frame = first.window.frame
        let opened = try await app.openFile(target, in: first)
        try expect(opened === first && app.documents.count == count && first.window.frame == frame,
                   "Open replaces the named buffer in the originating native window")
        try expect(try String(contentsOf: source, encoding: .utf8) == "Saved original",
                   "opening a new file autosaves the outgoing buffer")
        try expect(second.window !== first.window && second.editor.string == "version = 4",
                   "an explicitly created second window keeps its independent buffer")
        let icon = FileIcons.image(for: target, appearance: first.window.effectiveAppearance)
        try expect(icon != nil && HeaderCheck.fileIcon(in: first)?.image === icon,
                   "the title icon uses the same Seti image as the file list")
        first.setSyntaxLanguage(.rust)
        let rustIcon = FileIcons.image(for: target, appearance: first.window.effectiveAppearance,
                                      language: SyntaxLanguage.rust.iconIdentifier)
        try expect(rustIcon !== icon && HeaderCheck.fileIcon(in: first)?.image === rustIcon,
                   "the title icon follows a manual language override")

        first.editor.insertText("# newest\n", replacementRange: NSRange(location: 0, length: 0))
        let saved = await first.save()
        try expect(saved, "an already-associated buffer can save with another view of the same file open")
        second.editor.insertText("# stale\n", replacementRange: NSRange(location: 0, length: 0))
        let otherSaved = await second.save()
        try expect(!otherSaved && second.window.isDocumentEdited, "a stale parallel buffer cannot overwrite a newer save")
        try expect(try String(contentsOf: target, encoding: .utf8) == "# newest\nversion = 4",
                   "the first write survives a stale local save")

        await first.newBuffer()
        first.editor.insertText("Keep the untitled draft", replacementRange: NSRange(location: 0, length: 0))
        let cancelled = try await app.openFile(target, in: first)
        try expect(cancelled == nil && first.fileURL == nil && first.editor.string == "Keep the untitled draft",
                   "cancelling Open preserves an untitled draft")
        let incoming = try FileBuffer.read(target)
        let savedDraft = directory.appendingPathComponent("Saved before opening.txt")
        let continued = await first.finishClose(.save(to: savedDraft), destination: .buffer(incoming))
        try expect(continued && first.fileURL == incoming.url && first.editor.string == incoming.text,
                   "saving the outgoing draft continues Open in the same window")
        try expect(try String(contentsOf: savedDraft, encoding: .utf8) == "Keep the untitled draft",
                   "saving during Open writes only the outgoing draft")
        first.window.close()
        second.window.close()
    }

    private static func checkSupersededOpen(in app: Edit, directory: URL) async throws {
        let incoming = directory.appending(path: "Superseded.md")
        let current = directory.appending(path: "Keep.txt")
        try Data("# Superseded".utf8).write(to: incoming)
        try Data("Keep the current buffer".utf8).write(to: current)
        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(current, in: document)

        let session = document.sessionDocument()
        var reachedReplacement = false
        let opened = try await app.openFile(incoming, in: document) {
            reachedReplacement = document.isBusy
            return !reachedReplacement
        }
        try expect(opened == nil && reachedReplacement && document.displayedFileURL?.lastPathComponent == current.lastPathComponent &&
                   document.editor.string == "Keep the current buffer" && document.editor.isEditable,
                   "a request superseded during replacement leaves the current buffer editable")

        let placeholder = app.makeDocument()
        let undo = placeholder.editor.editorUndoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        placeholder.editor.insertText("Keep startup input", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        let count = app.documents.count
        await app.restore(EditorSession(documents: [session], activeIndex: 0, lastWindow: nil), reusing: placeholder)
        try expect(app.documents.count == count + 1 && placeholder.editor.string == "Keep startup input" &&
                   placeholder.window.isDocumentEdited && app.documents.last?.displayedFileURL == document.displayedFileURL,
                   "restoration keeps text in a used placeholder and restores the previous file separately")
        app.documents.last?.window.close()
        placeholder.window.close()
    }

    private static func checkRememberedPosition(in app: Edit, directory: URL) async throws {
        let source = directory.appending(path: "Remembered Position.txt")
        let alias = directory.appending(path: "Remembered Position Alias.txt")
        let other = directory.appending(path: "Other Buffer.txt")
        let text = (0..<750).map { index in
            "position_\(index) " + String(repeating: "wide text ", count: 22) + "\n"
        }.joined()
        let contents = text as NSString
        try Data(text.utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        try Data("Another buffer\n".utf8).write(to: other)

        func offset(_ line: Int) -> Int { contents.range(of: "position_\(line) ").location }
        func viewport(in document: DocumentWindow) -> NSPoint {
            let scroll = document.scrollView
            return scroll.visibleContentOrigin
        }

        func setPosition(in document: DocumentWindow, row: Int, x: CGFloat, ranges: [NSRange]) -> EditorPosition {
            let window = document.window
            let editor = document.editor
            let scroll = document.scrollView
            editor.setCaretSelections(ranges, record: false)
            let anchor = NSRange(location: offset(row), length: 0)
            editor.scrollRangeToVisible(anchor)
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let line = window.convertFromScreen(editor.firstRect(forCharacterRange: anchor, actualRange: nil))
            let y = editor.convert(line, from: nil).minY + 4
            scroll.scrollToVisibleContentOrigin(NSPoint(x: x, y: y))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            return editor.capturePosition()
        }

        func expectPosition(in document: DocumentWindow, at expected: EditorPosition, ranges: [NSRange]) throws {
            let viewportPoint = viewport(in: document)
            let actual = document.editor.capturePosition()
            let expectedTop = try resolve(expected.topLine)
            let actualTop = try resolve(actual.topLine)
            try expect(abs(viewportPoint.x - expected.horizontalOffset) <= 1 &&
                       actualTop.textOffset == expectedTop.textOffset &&
                       abs(actualTop.offsetIntoLine - expectedTop.offsetIntoLine) <= 1,
                       "restore the visible text and horizontal offset (expected \(expected), got \(actual))")
            try expect(document.editor.caretSelections == ranges && document.editor.selectedRange() == ranges.last,
                       "restore all selections and the primary caret")
        }

        let first = app.makeDocument()
        _ = try await app.openFile(source, in: first)
        let ranges = [
            NSRange(location: offset(495) + 5, length: 3),
            NSRange(location: offset(502) + 19, length: 0),
            NSRange(location: offset(12) + 2, length: 4),
        ]
        let point = setPosition(in: first, row: 500, x: 220, ranges: ranges)
        try expect(point.horizontalOffset > 200 && point.verticalOffset > 7_900,
                   "the position check starts scrolled on both axes")
        _ = try await app.openFile(other, in: first)
        try expect(first.editor.caretSelections == [NSRange(location: 0, length: 0)],
                   "opening a different file uses its own selection")
        _ = try await app.openFile(alias, in: first)
        await Task.yield()
        try expectPosition(in: first, at: point, ranges: ranges)
        first.window.close()

        let reopened = app.makeDocument()
        _ = try await app.openFile(source, in: reopened)
        try expectPosition(in: reopened, at: point, ranges: ranges)

        let second = app.makeDocument()
        _ = try await app.openFile(source, in: second)
        second.performFind(.toggleSidebar)
        await Task.yield()
        let secondRanges = [NSRange(location: offset(250) + 2, length: 7)]
        let secondPoint = setPosition(in: second, row: 245, x: 125, ranges: secondRanges)
        let store = SessionStore(url: directory.appending(path: "position-session.json"))
        try store.write(EditorSession(documents: [reopened, second].map { $0.sessionDocument() },
                                      activeIndex: 0, lastWindow: nil))
        let session = try resolve(store.read())
        [reopened, second].forEach { $0.window.close() }
        let placeholder = app.makeDocument()
        await app.restore(session, reusing: placeholder)
        await Task.yield()
        let restored = Array(app.documents.suffix(2))
        try expect(restored.first === placeholder, "restore session windows for the same file")
        try expectPosition(in: restored[0], at: point, ranges: ranges)
        try expectPosition(in: restored[1], at: secondPoint, ranges: secondRanges)

        await restored[0].newBuffer()
        try Data("👋".utf8).write(to: source)
        _ = try await app.openFile(source, in: restored[0])
        let end = NSRange(location: "👋".utf16.count, length: 0)
        try expect(restored[0].editor.caretSelections == [end], "saved selections clamp to the end of a shortened file")
        try expect(restored[0].scrollView.contentView.bounds.minX <= 1
                   && restored[0].scrollView.contentView.bounds.minY <= 1, "saved scroll clamps to the shortened file")
    }

    private static func checkRecentFiles(in app: Edit, directory: URL) async throws {
        let one = directory.appendingPathComponent("Recent one.txt")
        let two = directory.appendingPathComponent("Recent two.txt")
        let alias = directory.appendingPathComponent("Recent hard link.txt")
        try Data("one".utf8).write(to: one)
        try Data("two".utf8).write(to: two)
        try FileManager.default.linkItem(at: one, to: alias)
        _ = try await app.openFile(two)
        let current = try resolve(try await app.openFile(one))
        let selection = NSRange(location: 1, length: 0)
        current.editor.setSelectedRange(selection)
        let same = try await app.openFile(alias, in: current)
        try expect(current === same && current.editor.selectedRange() == selection,
                   "a hard link already in the current window preserves selection and text")
        try expect(Array(app.recentFiles.entries.prefix(2).map(\.url)) == [alias, two],
                   "history keeps the latest alias once")

        let archive = directory.appendingPathComponent("recent-test.json")
        let list = RecentFiles(url: archive)
        await list.record(two)
        await list.record(alias)
        await list.finishWrites()
        let restored = RecentFiles(url: archive)
        await restored.load()
        try expect(restored.entries.map(\.url) == [alias, two], "recent history survives restart")
        try FileManager.default.removeItem(at: two)
        await restored.prune()
        try expect(restored.entries.map(\.url) == [alias], "confirmed deletions leave recent history")
        await restored.finishWrites()

        let item = NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open Recent")
        let menu = try resolve(item?.submenu)
        app.menuWillOpen(menu)
        let recentURLs = menu.items.compactMap { $0.representedObject as? URL }
        try expect(recentURLs.first == alias, "native Open Recent shows the history")
        try expect(recentURLs.count <= 10, "Open Recent is capped at ten files when no folder has been opened")
        let rust = FileIcons.iconKey(for: URL(fileURLWithPath: "/tmp/MAIN.RS"), dark: true)
        let typescript = FileIcons.iconKey(for: URL(fileURLWithPath: "/tmp/widget.test.ts"), dark: true)
        try expect(rust != nil && typescript != nil && rust != typescript, "bundled file icons match file types")
        try expect(FileIcons.iconKey(for: URL(fileURLWithPath: "/tmp/main.rs"), dark: false) != rust,
                   "light appearance uses the theme variant")

        let entries = [
            ControlEntry(id: "folder", title: "helper.rs", detail: "~/src/main"),
            ControlEntry(id: "split", title: "m_a_i_n.rs", detail: "~/src"),
            ControlEntry(id: "exact", title: "main.rs", detail: "~/src"),
            ControlEntry(id: "space", title: "Meeting Notes.md", detail: "~/docs"),
        ]
        let ranked = ControlMatching.rank(entries, query: "src main").map(\.entry.id)
        try expect(ranked.first == "exact" && ranked.contains("folder"), "prefer a filename match across all terms")
        try expect(ControlMatching.rank(entries, query: "MAIN src").map(\.entry.id) == ranked,
                   "Control terms can appear in any order")
        try expect(ControlMatching.rank(entries, query: "docs Meeting\\ Notes").first?.entry.id == "space",
                   "a backslash escapes a literal space")
        try expect(ControlMatching.rank(entries, query: "src missing").isEmpty, "all terms must match")

        let alternateCharacters: [Character: Character] = ["ы": "s", "ф": "a", "м": "v", "у": "e"]
        let layoutEntries = [
            ControlEntry(id: "alternate", title: "save"),
            ControlEntry(id: "typed-fuzzy", title: "ы_ф_м_у"),
            ControlEntry(id: "typed-exact", title: "Long menu name: ыфму"),
            ControlEntry(id: "both", title: "ыфму save"),
        ]
        let bothLayouts = ControlMatching.rank(layoutEntries, query: "ыфму", alternateCharacters: alternateCharacters)
        try expect(bothLayouts.map(\.entry.id) == ["typed-exact", "alternate", "both", "typed-fuzzy"],
                   "Control ranks an exact typed match first and still prefers a strong alternate to a weak match")
        try expect(bothLayouts[2].titleCharacters == [0, 1, 2, 3],
                   "Control shows one row and highlights the better match when both queries match")
        let comparable = [ControlEntry(id: "alternate", title: "save.md"), ControlEntry(id: "typed", title: "ыфму.md")]
        try expect(ControlMatching.rank(comparable, query: "ыфму", alternateCharacters: alternateCharacters)
            .map(\.entry.id) == ["typed", "alternate"], "Control favors an equally strong match in the typed layout")
        let escaped = [ControlEntry(id: "space", title: "sa ve.txt"), ControlEntry(id: "joined", title: "save.txt")]
        let escapedMatches = ControlMatching.rank(escaped, query: "ыф\\ му", alternateCharacters: alternateCharacters)
        try expect(escapedMatches.map(\.entry.id) == ["space"] && escapedMatches.first?.titleCharacters == [0, 1, 2, 3, 4],
                   "Control preserves escaped spaces and highlights translated terms")
    }

    private static func checkEncodings(in app: Edit, directory: URL) async throws {
        let oldFormat = Data(#"{"hasBOM":true,"lineEnding":"\r\n"}"#.utf8)
        let restored = try JSONDecoder().decode(FileFormat.self, from: oldFormat)
        try expect(restored.encoding == .utf8 && restored.hasBOM && restored.lineEnding == "\r\n",
                   "older sessions still restore UTF-8")

        for encoding in FileTextEncoding.allCases {
            let file = directory.appendingPathComponent(encoding.rawValue + ".txt")
            let text: String
            switch encoding {
            case .utf8, .utf16BE, .utf32LE, .utf32BE: text = "Привет 😀\r\n"
            case .utf16LE: text = "\0Привет 😀\r\n"
            case .windowsCP1251: text = "Привет\r\n"
            case .shiftJIS: text = "日本語\r\n"
            case .macOSRoman, .windowsCP1252, .isoLatin1: text = "Café\r\n"
            }
            let format = FileFormat().using(encoding)
            _ = try FileBuffer.save(text, to: file, format: format, expected: .missing)
            let decoded = try FileBuffer.read(file)
            try expect(decoded.text == text && decoded.format.encoding == encoding
                       && decoded.format.hasBOM == format.hasBOM && decoded.format.lineEnding == "\r\n",
                       "reopening preserves " + encoding.rawValue + " and CRLF")
        }

        let file = directory.appendingPathComponent("windowsCP1251.txt")
        await app.openFiles([file])
        let document = try resolve(app.documents.last)
        document.editor.insertText("Мир ", replacementRange: document.editor.selectedRange())
        document.requestAutosave()
        try await waitFor("named autosave preserves the file's encoding") { !document.window.isDocumentEdited }
        let savedText = "Мир Привет\r\n"
        let expected = try resolve(savedText.data(using: .windowsCP1251))
        try expect(try Data(contentsOf: file) == expected, "autosave writes Windows Cyrillic bytes")
        var detected: UInt = 0
        let reopened = try NSString(contentsOf: file, usedEncoding: &detected)
        try expect(reopened as String == savedText && detected == String.Encoding.windowsCP1251.rawValue,
                   "macOS recognizes the encoding hint")

        do {
            _ = try FileBuffer.save("😀", to: file, format: FileFormat().using(.windowsCP1251), expected: nil)
            throw Failure("expected an incompatible encoding error")
        } catch FileBufferError.unrepresentableText(.windowsCP1251) {
            try expect(try Data(contentsOf: file) == expected, "encoding errors leave existing bytes intact")
        }
    }

    private static func checkSaveMetadata(in directory: URL) throws {
        let url = directory.appending(path: "Save metadata.txt")
        let alias = directory.appending(path: "Save metadata alias.txt")
        let format = FileFormat().using(.windowsCP1251)
        let original = try FileBuffer.save("Привет", to: url, format: format, expected: .missing).file
        let attribute = "dev.edit.check-metadata"
        let value = Data("keep me".utf8)
        let source = try FileHandle(forWritingTo: url)
        try expect(value.withUnsafeBytes {
            fsetxattr(source.fileDescriptor, attribute, $0.baseAddress, $0.count, 0, 0) == 0
        }, "set a disposable file attribute")
        try expect(fchmod(source.fileDescriptor, 0o640) == 0, "set disposable file permissions")
        try source.close()

        let saved = try FileBuffer.save("Привет снова", to: url, format: FileFormat(), expected: original.revision)
        let reopened = try FileBuffer.read(url)
        try expect(saved.replacedIdentity == original.identity && reopened.text == "Привет снова" && reopened.format.encoding == .utf8,
                   "replace the expected revision and remove its old encoding hint")
        let output = try FileHandle(forReadingFrom: url)
        defer { try? output.close() }
        var copied = Data(count: value.count)
        let copiedCount = copied.withUnsafeMutableBytes {
            fgetxattr(output.fileDescriptor, attribute, $0.baseAddress, $0.count, 0, 0)
        }
        var status = stat()
        try expect(copiedCount == value.count && copied == value &&
                   fstat(output.fileDescriptor, &status) == 0 && status.st_mode & 0o777 == 0o640,
                   "safe replacement preserves extended attributes and permissions")

        try FileManager.default.linkItem(at: url, to: alias)
        do {
            _ = try FileBuffer.save("replacement", to: url, format: reopened.format, expected: reopened.revision)
            throw Failure("expected a hard-link conflict")
        } catch FileBufferError.multipleHardLinks {
            let retained = try FileBuffer.read(alias)
            try expect(retained.identity == FileIdentity.at(url) && retained.text == reopened.text,
                       "a rejected save keeps both hard links and their original bytes")
        }
    }

    private static func checkCoordinatedSave(in directory: URL) async throws {
        let url = directory.appending(path: "Coordinated save.txt")
        let format = FileFormat()
        let original = try FileBuffer.save("Original", to: url, format: format, expected: .missing).file
        let acquired = DispatchSemaphore(value: 0)
        let publish = DispatchSemaphore(value: 0)
        let external = Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var accessError: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &accessError) { target in
                acquired.signal()
                guard publish.wait(timeout: .now() + 5) == .success else { return }
                result = Result { try Data("External".utf8).write(to: target, options: .atomic) }
            }
            if let accessError { throw accessError }
            guard let result else { throw Failure("the coordinated external write could not acquire its turn") }
            return try result.get()
        }
        defer { publish.signal() }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: acquired.wait(timeout: .now() + 5) == .success)
            }
        }
        try expect(ready, "a competing writer acquires the coordinated file")
        let edit = Task.detached { try FileBuffer.save("Local", to: url, format: format, expected: original.revision) }
        try await Task.sleep(for: .milliseconds(100))
        publish.signal()
        try await external.value
        do {
            _ = try await edit.value
            throw Failure("a coordinated save must validate the version after the competing writer finishes")
        } catch FileBufferError.changedOnDisk {
            try expect(try FileBuffer.read(url).text == "External", "keep the coordinated writer's newer version")
        }
    }

    private static func checkExternalRefresh(in app: Edit, directory: URL) async throws {
        let file = directory.appendingPathComponent("External refresh.txt")
        let lines = (0..<80).map { "Line \($0)\n" }.joined()
        try Data(("First\n" + lines).utf8).write(to: file)
        let document = app.makeDocument()
        defer { document.window.close() }
        _ = try await app.openFile(file, in: document)
        let editor = document.editor
        let window = document.window
        editor.scrollRangeToVisible(NSRange(location: 310, length: 0))
        editor.setCaretSelections([NSRange(location: 180, length: 3), NSRange(location: 325, length: 0)], record: false)
        document.toggleSidebarFocus(.search)
        let search = try resolve(window.firstResponder)
        try expect(search !== editor, "Search owns focus before the external update")
        let position = editor.capturePosition()
        let initialIdentity = FileIdentity.at(file)

        let inPlace = "Other\n" + lines
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(inPlace.utf8))
        try handle.close()
        try await waitFor("reload an in-place write without switching back to Edit", timeout: .seconds(3)) { editor.string == inPlace }
        try expect(window.firstResponder === search && !window.isDocumentEdited && document.fileIdentity == initialIdentity,
                   "reload keeps focus in Search and the file clean")
        let refreshedPosition = editor.capturePosition()
        try expect(refreshedPosition.selections == position.selections &&
                   abs(refreshedPosition.verticalOffset - position.verticalOffset) < 1,
                   "reload retains the editor selections and scroll position")

        let replaced = "Third\n" + lines
        try Data(replaced.utf8).write(to: file, options: .atomic)
        try await waitFor("reload an atomic external save at the same path", timeout: .seconds(3)) { editor.string == replaced }
        try expect(document.fileIdentity == FileIdentity.at(file) && document.fileIdentity != initialIdentity,
                   "reload adopts the replacement file identity")

        document.focusContent()
        let undo = editor.editorUndoManager
        undo.beginUndoGrouping()
        editor.insertText("Local ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        let newest = "Final\n" + lines
        try Data(newest.utf8).write(to: file, options: .atomic)
        document.toggleSidebarFocus(.search)
        var conflict: String?
        try await waitFor("report the conflict while the dirty buffer stays in place") {
            if conflict == nil { conflict = document.takeAutosaveFailure() }
            return conflict != nil
        }
        try expect(window.isDocumentEdited && editor.string.hasPrefix("Local ") &&
                   (try FileBuffer.read(file)).text == newest, "external reload and autosave both preserve the conflicting edits")
        undo.undo()
        try await waitFor("apply the pending external change once the local edit is undone", timeout: .seconds(3)) { editor.string == newest }
        try expect(window.firstResponder === search && !window.isDocumentEdited, "pending reload keeps Search focused")

        document.focusContent()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Saved ", replacementRange: editor.selectedRange())
        let saved = await document.save()
        try expect(saved && (try FileBuffer.read(file)).text == "Saved " + newest, "Save uses the refreshed disk revision")
    }

    private static func checkAutosaveAndNewBuffer(in app: Edit, directory: URL) async throws {
        let file = directory.appendingPathComponent("Autosave.txt")
        let original = "\u{feff}Existing\r\n"
        try Data(original.utf8).write(to: file)
        await app.openFiles([file])
        let document = try resolve(app.documents.last)
        let editor = document.editor
        let window = document.window
        let undo = editor.editorUndoManager
        let groupsByEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = groupsByEvent }

        func insert(_ text: String) {
            // This quiet check does not deliver key events to AppKit.
            undo.beginUndoGrouping()
            editor.insertText(text, replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
        }

        insert("Idle\r\n")
        try expect(try Data(contentsOf: file) == Data(original.utf8), "typing waits for the idle timer")
        try await waitFor("the idle timer saves without a focus change", timeout: .seconds(3)) { !window.isDocumentEdited }
        try expect(try Data(contentsOf: file) == Data("\u{feff}Idle\r\nExisting\r\n".utf8),
                   "idle autosave preserves BOM and CRLF")

        insert("Blur\r\n")
        try expect(window.makeFirstResponder(nil), "the editor gives up focus")
        try await waitFor("resigning editor focus writes before the idle timer") {
            !window.isDocumentEdited
        }

        let fileMenu = try resolve(NSApplication.shared.mainMenu?.item(withTitle: "File")?.submenu)
        let new = try resolve(fileMenu.item(withTitle: "New"))
        let newWindow = try resolve(fileMenu.item(withTitle: "New Window"))
        try expect(new.keyEquivalent == "n" && new.keyEquivalentModifierMask == .command,
                   "New uses Command-N")
        try expect(newWindow.keyEquivalent == "n" && newWindow.keyEquivalentModifierMask == [.command, .shift],
                   "New Window uses Shift-Command-N")

        insert("Menu\r\n")
        app.menuWillOpen(fileMenu)
        try await waitFor("opening the menu autosaves") { !window.isDocumentEdited }

        // A manual save must drain an earlier request and write the current text.
        insert("Earlier\r\n")
        document.requestAutosave()
        await Task.yield()
        insert("Latest\r\n")
        let didSave = await document.save()
        try expect(didSave && !window.isDocumentEdited, "manual Save completes with the latest revision")
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + editor.string).utf8),
                   "an earlier autosave cannot overwrite a manual save")

        let beforeUndo = editor.string
        insert("Undo this\r\n")
        let savedBeforeUndo = await document.save()
        undo.undo()
        try expect(savedBeforeUndo && editor.string == beforeUndo && window.isDocumentEdited,
                   "native Undo marks the buffer edited")
        document.requestAutosave()
        try await waitFor("an Undo is autosaved") { !window.isDocumentEdited }
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + beforeUndo).utf8),
                   "autosave writes the exact text after Undo")

        insert("Queued snapshot\r\n")
        let requested = Data(("\u{feff}" + editor.string).utf8)
        document.requestAutosave()
        insert("Later edit\r\n")
        try await waitFor("autosave writes the requested snapshot") {
            (try? Data(contentsOf: file)) == requested
        }
        try expect(window.isDocumentEdited, "newer edits stay marked after a queued autosave")

        insert("Before replacing\r\n")
        let lastText = editor.string
        let frame = window.frame
        let count = app.documents.count
        app.newDocument(nil)
        try await waitFor("New clears the current file") { document.fileURL == nil }
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + lastText).utf8),
                   "New saves the outgoing named buffer")
        try expect(app.documents.count == count && app.documents.last === document
                   && document.window === window && window.frame == frame,
                   "New reuses the same window and its geometry")
        try expect(editor.string.isEmpty && window.title == "Untitled" && !window.isDocumentEdited
                   && editor.undoManager?.canUndo != true, "New clears text, identity, and undo")

        insert("Keep this draft")
        await document.newBuffer()
        try expect(editor.string == "Keep this draft" && window.isDocumentEdited,
                   "cancelling the untitled sheet preserves the draft")
        let destination = directory.appendingPathComponent("Draft saved by New.txt")
        await document.finishClose(.save(to: destination), destination: .buffer(nil))
        try expect(try Data(contentsOf: destination) == Data("Keep this draft".utf8),
                   "saving the untitled draft uses the chosen path")
        try expect(document.fileURL == nil && editor.string.isEmpty && app.documents.count == count,
                   "saving from New leaves a blank buffer in the same window")

        await app.openFiles([file])
        try expect(app.documents.last === document, "the blank replacement buffer can open a file")
        insert("Local text\r\n")
        let localText = editor.string
        let external = Data("External version\n".utf8)
        try external.write(to: file)
        await document.newBuffer()
        try expect(try Data(contentsOf: file) == external, "failed autosave leaves the external version intact")
        try expect(document.fileURL != nil && editor.string == localText && window.isDocumentEdited,
                   "a conflict keeps the named buffer and local edits available")
        try expect(document.sessionDocument().draft == localText, "a failed autosave is recoverable from the session")

        app.newWindow(nil)
        let separate = try resolve(app.documents.last)
        try expect(app.documents.count == count + 1 && separate.window !== window
                   && separate.fileURL == nil && separate.editor.string.isEmpty
                   && editor.string == localText, "New Window leaves the current buffer and opens a blank window")
        separate.window.close()

        try Data(("\u{feff}" + lastText).utf8).write(to: file)
        await document.newBuffer()
        try expect(document.fileURL == nil && editor.string.isEmpty, "New retries a failed autosave")
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + localText).utf8),
                   "a retry after restoring the disk baseline writes the preserved edits")
    }

    private static func waitFor(
        _ description: String,
        timeout: Duration = .milliseconds(750),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(condition(), description)
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
