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
        try await checkRecentFiles(in: app, directory: directory)
        try await checkEncodings(in: app, directory: directory)
        try await checkAutosaveAndNewBuffer(in: app, directory: directory)
        try await checkRememberedPosition(in: app, directory: directory)

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

    private static func checkAutosaveAndNewBuffer(in app: Edit, directory: URL) async throws {
        let file = directory.appendingPathComponent("Autosave.txt")
        let original = "\u{feff}Existing\r\n"
        try Data(original.utf8).write(to: file)
        await app.openFiles([file])
        let document = try resolve(app.documents.last)
        let editor = document.editor
        let window = document.window

        editor.insertText("Idle\r\n", replacementRange: editor.selectedRange())
        try expect(try Data(contentsOf: file) == Data(original.utf8), "typing waits for the idle timer")
        try await waitFor("the idle timer saves without a focus change", timeout: .seconds(3)) { !window.isDocumentEdited }
        try expect(try Data(contentsOf: file) == Data("\u{feff}Idle\r\nExisting\r\n".utf8),
                   "idle autosave preserves BOM and CRLF")

        editor.insertText("Blur\r\n", replacementRange: editor.selectedRange())
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

        editor.insertText("Menu\r\n", replacementRange: editor.selectedRange())
        app.menuWillOpen(fileMenu)
        try await waitFor("opening the menu autosaves") { !window.isDocumentEdited }

        // A manual save must drain an earlier request and write the current text.
        editor.insertText("Earlier\r\n", replacementRange: editor.selectedRange())
        document.requestAutosave()
        await Task.yield()
        editor.insertText("Latest\r\n", replacementRange: editor.selectedRange())
        let didSave = await document.save()
        try expect(didSave && !window.isDocumentEdited, "manual Save completes with the latest revision")
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + editor.string).utf8),
                   "an earlier autosave cannot overwrite a manual save")

        let undo = try resolve(editor.undoManager)
        let groupsByEvent = undo.groupsByEvent
        editor.breakUndoCoalescing()
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        // This quiet check has no key event to delimit the edit's undo group.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let beforeUndo = editor.string
        editor.insertText("Undo this\r\n", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        let savedBeforeUndo = await document.save()
        undo.undo()
        undo.groupsByEvent = groupsByEvent
        try expect(savedBeforeUndo && editor.string == beforeUndo && window.isDocumentEdited,
                   "native Undo marks the buffer edited")
        document.requestAutosave()
        try await waitFor("an Undo is autosaved") { !window.isDocumentEdited }
        try expect(try Data(contentsOf: file) == Data(("\u{feff}" + beforeUndo).utf8),
                   "autosave writes the exact text after Undo")

        editor.insertText("Queued snapshot\r\n", replacementRange: editor.selectedRange())
        let requested = Data(("\u{feff}" + editor.string).utf8)
        document.requestAutosave()
        editor.insertText("Later edit\r\n", replacementRange: editor.selectedRange())
        try await waitFor("autosave writes the requested snapshot") {
            (try? Data(contentsOf: file)) == requested
        }
        try expect(window.isDocumentEdited, "newer edits stay marked after a queued autosave")

        editor.insertText("Before replacing\r\n", replacementRange: editor.selectedRange())
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

        editor.insertText("Keep this draft", replacementRange: editor.selectedRange())
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
        editor.insertText("Local text\r\n", replacementRange: editor.selectedRange())
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
