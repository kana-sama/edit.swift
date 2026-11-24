import AppKit

@MainActor
enum LanguageServerRenameCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "ZLS rename check: \(message)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSView, String) throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "ZLS rename \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = FileBuffer.canonicalURL(temporary)
        let source = root.appending(path: "source.zig")
        let caller = root.appending(path: "caller.zig")
        let closed = root.appending(path: "other caller.zig")
        let sourceText = """
            const emoji = "👋"; pub fn calculate() usize { return 1; }
            pub fn localCall() usize { return calculate(); }
            const Other = struct { fn calculate() usize { return 3; } };
            pub fn otherCall() usize { return Other.calculate(); }

            """
        let callerText = """
            const source = @import("source.zig");
            pub fn use() usize { return source.calculate(); }

            """
        let secondary = app.makeDocument()
        secondary.window.alphaValue = 0
        secondary.window.ignoresMouseEvents = true
        defer {
            secondary.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        for (url, text) in [(source, sourceText), (caller, callerText), (closed, callerText)] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        document.setFolder(root)
        secondary.setFolder(root)
        guard try await app.openFile(source, in: document) != nil,
              try await app.openFile(caller, in: secondary) != nil else { throw Failure("open rename fixtures") }
        try await wait("start ZLS for Rename Symbol") { document.languageFeatures.session.supportsRename }
        let editor = document.editor
        if document.isSidebarVisible { document.performFind(.toggleSidebar) }
        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        document.window.makeFirstResponder(editor)

        let name = (sourceText as NSString).range(of: "calculate")
        let anotherName = (sourceText as NSString).range(of: "calculate", options: .backwards)
        let originalCaret = NSRange(location: name.location + 2, length: 0)
        editor.setCaretSelections([originalCaret], record: false)
        let revision = document.languageFeatures.session.revision
        let hadUndo = editor.editorUndoManager.canUndo
        let baseline = try contrast(in: editor, around: [name, anotherName])
        let f2 = try keyEvent(120, characters: "\u{F705}", in: document.window)
        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name)
        guard editor.string == sourceText else { throw Failure("leave the visible source intact when starting rename") }
        if let view = document.window.contentView { try capture(view, "rename-symbol") }
        editor.setSelectedRange(originalCaret)
        let shaded = try contrast(in: editor, around: [name, anotherName])
        guard baseline[0] > 0.12, baseline[1] > 0.12,
              shaded[0] >= baseline[0] * 0.9, shaded[1] < baseline[1] * 0.78 else {
            throw Failure("preserve the symbol's contrast and dim the surrounding text (\(baseline), \(shaded))")
        }
        editor.setSelectedRange(name)
        let abandoned = "abandonedDraft"
        editor.insertText(abandoned, replacementRange: editor.selectedRange())
        let draft = (sourceText as NSString).replacingCharacters(in: name, with: abandoned)
        let draftRange = NSRange(location: name.location, length: abandoned.utf16.count)
        guard editor.string == draft, editor.renameRange == draftRange,
              editor.selectedRange() == NSRange(location: draftRange.upperBound, length: 0),
              document.textForSaving == sourceText, document.languageFeatures.session.revision == revision,
              editor.editorUndoManager.canUndo == hadUndo, !document.window.isDocumentEdited else {
            throw Failure("display and resize the editable name while retaining the saved and LSP source")
        }
        editor.insertText("protected", replacementRange: NSRange(location: 0, length: 0))
        guard editor.string == draft else { throw Failure("protect source text outside the rename span") }
        let newTail = NSRange(location: name.upperBound, length: draftRange.upperBound - name.upperBound)
        guard try contrast(in: editor, around: [newTail])[0] >= baseline[0] * 0.8 else {
            throw Failure("keep newly typed letters inside the undimmed name")
        }
        if let view = document.window.contentView { try capture(view, "rename-symbol-edited") }
        editor.cancelOperation(nil)
        try await wait("Escape exits rename and restores editor focus and the original caret") {
            editor.renameRange == nil && document.window.firstResponder === editor && editor.selectedRange() == originalCaret
        }
        guard editor.string == sourceText, document.textForSaving == sourceText,
              try String(contentsOf: source, encoding: .utf8) == sourceText else {
            throw Failure("leave source unchanged after Escape")
        }

        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name)
        editor.deleteBackward(nil)
        let insertionPoint = NSRange(location: name.location, length: 0)
        guard editor.renameRange == insertionPoint, editor.selectedRange() == insertionPoint,
              document.textForSaving == sourceText else { throw Failure("keep an empty name editable after Backspace") }
        let composed = "仮名"
        editor.setMarkedText(composed, selectedRange: NSRange(location: composed.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let composedRange = NSRange(location: name.location, length: composed.utf16.count)
        guard editor.hasMarkedText(), editor.markedRange() == composedRange, editor.renameRange == composedRange,
              editor.string == (sourceText as NSString).replacingCharacters(in: name, with: composed),
              document.textForSaving == sourceText else { throw Failure("keep marked IME input inside the draft") }
        editor.insertText(composed, replacementRange: editor.markedRange())
        editor.cancelOperation(nil)
        guard !editor.hasMarkedText(), editor.renameRange == nil, editor.selectedRange() == originalCaret,
              editor.string == sourceText, document.textForSaving == sourceText else {
            throw Failure("restore the saved source and original caret when cancelling an IME rename")
        }

        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name)
        let newName = "compute \"value\""
        let newSpelling = "@\"compute \\\"value\\\"\""
        editor.insertText(newName, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        let expected = sourceText.replacingOccurrences(of: "pub fn calculate", with: "pub fn \(newSpelling)")
            .replacingOccurrences(of: "return calculate()", with: "return \(newSpelling)()")
        let expectedCaller = callerText.replacingOccurrences(of: "source.calculate", with: "source.\(newSpelling)")
        try await wait("Return applies semantic edits in the editor, another buffer, and a closed file") {
            editor.string == expected && secondary.editor.string == expectedCaller &&
                (try? String(contentsOf: closed, encoding: .utf8)) == expectedCaller && editor.renameRange == nil
        }
        guard document.window.firstResponder === editor, editor.undoManager?.undoActionName == "Rename Symbol" else {
            throw Failure("restore focus and give the editor a named Undo")
        }
        let renamed = (editor.string as NSString).range(of: newSpelling)
        editor.setCaretSelections([NSRange(location: renamed.location + 4, length: 0)], record: false)
        try await wait("finish project discovery after applying the rename") {
            document.languageFeatures.session.supportsRename && document.canReplaceBuffer && editor.isEditable
        }
        editor.keyDown(with: f2)
        let quotedName = NSRange(location: renamed.location + 2, length: renamed.length - 3)
        try await waitForRename(in: document, range: quotedName)
        guard editor.string == expected, (editor.string as NSString).substring(with: quotedName) == "compute \\\"value\\\"" else {
            throw Failure("focus the exact source spelling inside an escaped Zig identifier")
        }
        editor.cancelOperation(nil)
        await document.flushAutosave()
        await secondary.flushAutosave()
    }

    private static func waitForRename(in document: DocumentWindow, range: NSRange) async throws {
        let editor = document.editor
        try await wait("focus the symbol's range in the existing editor after F2") {
            document.window.firstResponder === editor && editor.renameRange == range && editor.selectedRange() == range
        }
    }

    private static func contrast(in editor: EditorTextView, around ranges: [NSRange]) throws -> [CGFloat] {
        let bounds = editor.visibleRect
        guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw Failure("capture the native editor viewport")
        }
        editor.cacheDisplay(in: bounds, to: bitmap)
        let xScale = CGFloat(bitmap.pixelsWide) / bounds.width
        let yScale = CGFloat(bitmap.pixelsHigh) / bounds.height
        return try ranges.map { range in
            guard let segment = editor.highlightRects(for: [range]).first else {
                throw Failure("lay out both symbols for the shading check")
            }
            let rect = segment.intersection(bounds).insetBy(dx: 2, dy: 2)
            guard !rect.isEmpty else { throw Failure("sample visible glyphs in the editor viewport") }
            let left = Int((rect.minX - bounds.minX) * xScale)
            let right = Int((rect.maxX - bounds.minX) * xScale)
            let top = Int((editor.isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY) * yScale)
            let bottom = Int((editor.isFlipped ? rect.maxY - bounds.minY : bounds.maxY - rect.minY) * yScale)
            var darkest: CGFloat = 1
            var brightest: CGFloat = 0
            for y in top..<bottom {
                for x in left..<right {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let brightness = 0.2126 * pixel.redComponent + 0.7152 * pixel.greenComponent + 0.0722 * pixel.blueComponent
                    darkest = min(darkest, brightness)
                    brightest = max(brightest, brightness)
                }
            }
            return brightest - darkest
        }
    }

    private static func keyEvent(_ code: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { throw Failure("create an F2 event") }
        return event
    }

    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .seconds(10)
        while !condition(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw Failure(message) }
    }
}
