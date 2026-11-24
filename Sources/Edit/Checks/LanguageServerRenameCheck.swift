import AppKit

@MainActor
enum LanguageServerRenameCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "ZLS rename check: \(message)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSView, String) throws -> Void) async throws {
        try checkRenameCaret(capture: capture)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "ZLS rename \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = FileBuffer.canonicalURL(temporary)
        let source = root.appending(path: "source.zig")
        let caller = root.appending(path: "caller.zig")
        let closed = root.appending(path: "other caller.zig")
        let sourceText = """
            const emoji = "👋"; pub fn calculate() usize { return 1;
            }
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
        try checkVerticalRoundTrip(in: editor, window: document.window, phase: "before rename")
        let revision = document.languageFeatures.session.revision
        let hadUndo = editor.editorUndoManager.canUndo
        let baseline = try contrast(in: editor, around: [name, anotherName])
        let f2 = try keyEvent(120, characters: "\u{F705}", in: document.window)
        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name, phase: "first F2")
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
        try checkVerticalRoundTrip(in: editor, window: document.window, phase: "after Escape")

        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name, phase: "F2 after Escape")
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
        try await waitForRename(in: document, range: name, phase: "F2 after cancelling IME")
        let unchangedCaret = NSRange(location: name.location + 4, length: 0)
        editor.setSelectedRange(unchangedCaret)
        editor.keyDown(with: try keyEvent(36, characters: "\r", modifiers: [], in: document.window))
        guard !editor.isRenamingSymbol, editor.renameRange == nil, editor.selectedRange() == unchangedCaret,
              editor.string == sourceText, document.textForSaving == sourceText else {
            throw Failure("close rename without edits and keep the caret used to submit")
        }
        try checkVerticalRoundTrip(in: editor, window: document.window, phase: "after unmodified Return")

        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: name, phase: "F2 after unmodified Return")
        let newName = "compute \"value\""
        let newSpelling = "@\"compute \\\"value\\\"\""
        editor.insertText(newName, replacementRange: editor.selectedRange())
        let typedPrefix = "compute \""
        let draftCaret = NSRange(location: name.location + typedPrefix.utf16.count, length: 0)
        editor.setSelectedRange(draftCaret)
        let submittedDraft = editor.string
        editor.insertNewline(nil)
        guard editor.string == submittedDraft, editor.selectedRange() == draftCaret, document.textForSaving == sourceText else {
            throw Failure("keep the draft and caret visible while waiting for Rename")
        }
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
        let escapedPrefix = "@\"compute \\\""
        let committedCaret = NSRange(location: name.location + escapedPrefix.utf16.count, length: 0)
        guard editor.selectedRange() == committedCaret else {
            throw Failure("keep the position at Return inside the renamed symbol (\(editor.selectedRange()), expected \(committedCaret))")
        }
        try checkVerticalRoundTrip(in: editor, window: document.window, phase: "after submitting rename")
        let renamed = (editor.string as NSString).range(of: newSpelling)
        editor.setCaretSelections([NSRange(location: renamed.location + 4, length: 0)], record: false)
        try await wait("finish project discovery after applying the rename") {
            document.languageFeatures.session.supportsRename && document.canReplaceBuffer && editor.isEditable
        }
        editor.keyDown(with: f2)
        let quotedName = NSRange(location: renamed.location + 2, length: renamed.length - 3)
        try await waitForRename(in: document, range: quotedName, phase: "F2 on the quoted identifier")
        guard editor.string == expected, (editor.string as NSString).substring(with: quotedName) == "compute \\\"value\\\"" else {
            throw Failure("focus the exact source spelling inside an escaped Zig identifier")
        }
        editor.cancelOperation(nil)

        let local = (expected as NSString).range(of: "localCall")
        editor.setCaretSelections([NSRange(location: local.location + 2, length: 0)], record: false)
        try await wait("resolve the document after the quoted rename") {
            document.languageFeatures.session.supportsRename && document.canReplaceBuffer && editor.isEditable
        }
        editor.keyDown(with: f2)
        try await waitForRename(in: document, range: local, phase: "F2 on a local symbol")
        let localName = "local_call_longer"
        editor.insertText(localName, replacementRange: editor.selectedRange())
        let localCaret = editor.selectedRange()
        guard localCaret == NSRange(location: local.location + localName.utf16.count, length: 0) else {
            throw Failure("type to the end of the new name")
        }
        let localResult = (expected as NSString).replacingCharacters(in: local, with: localName)
        editor.insertNewline(nil)
        guard editor.string == localResult, editor.selectedRange() == localCaret else {
            throw Failure("keep the new name and end caret visible immediately after Return")
        }
        try await wait("commit a longer name and leave the caret at its end") {
            editor.string == localResult && editor.selectedRange() == localCaret && !editor.isRenamingSymbol
        }
        await document.flushAutosave()
        await secondary.flushAutosave()
    }

    private static func waitForRename(in document: DocumentWindow, range: NSRange, phase: String) async throws {
        let editor = document.editor
        do {
            try await wait("focus the symbol's range in the existing editor after \(phase)") {
                document.window.firstResponder === editor && editor.renameRange == range && editor.selectedRange() == range
            }
        } catch is Failure {
            let state = document.languageFeatures.session.state.title
            throw Failure("focus \(range) after \(phase) (rename range \(String(describing: editor.renameRange)), selection \(editor.selectedRange()), editing \(editor.isRenamingSymbol), focus \(document.window.firstResponder === editor), ZLS \(state))")
        }
    }

    private static func checkRenameCaret(capture: (NSView, String) throws -> Void) throws {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 130)
        let window = EditorFocusCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let (scroll, editor) = EditorTextView.scrollingEditor(in: bounds)
        window.contentView = scroll
        defer { window.close() }
        let source = "fn calculate() void {\n    _ = 1;\n}\n"
        editor.string = source
        guard window.makeFirstResponder(editor), !window.isVisible, !NSApp.isActive else {
            throw Failure("exercise a key editor without activating the window")
        }
        let name = (source as NSString).range(of: "calculate")
        editor.setSelectedRange(NSRange(location: name.location + 2, length: 0))
        func layoutCaret() {
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            editor.refreshCurrentLine()
        }
        layoutCaret()
        guard editor.beginSymbolRename(in: name, source: source) else { throw Failure("focus a rename symbol in the caret fixture") }
        defer { editor.endSymbolRename() }
        layoutCaret()
        guard editor.selectedRange() == name, editor.multiCaret.indicatorGroup?.caretRects.isEmpty != false else {
            throw Failure("hide the caret while the symbol name is selected")
        }

        editor.keyDown(with: try keyEvent(124, characters: "\u{F703}", modifiers: [.function, .numericPad], in: window))
        layoutCaret()
        let insertionPoint = NSRange(location: name.upperBound, length: 0)
        guard editor.selectedRange() == insertionPoint, let group = editor.multiCaret.indicatorGroup,
              group.caretRects.count == 1, let bar = group.caretRects.first,
              let caret = editor.lineBounds(at: insertionPoint.location) else {
            throw Failure("draw one caret at the name's trailing edge after Right")
        }
        let visibleBar = editor.convert(bar, from: group)
        guard visibleBar.width > 0, visibleBar.width <= 2, visibleBar.height > 0,
              abs(visibleBar.midX - caret.midX) <= 1, abs(visibleBar.minY - caret.minY) <= 1,
              abs(visibleBar.maxY - caret.maxY) <= 1, editor.visibleRect.intersects(visibleBar) else {
            throw Failure("match the visible rename bar to the TextKit insertion rect (\(visibleBar), \(caret))")
        }
        guard let shade = editor.subviews.first(where: { $0 is EditorRenameShade }), !shade.isHidden,
              let groupLayer = group.layer, let shadeLayer = shade.layer,
              let groupIndex = editor.subviews.firstIndex(where: { $0 === group }),
              let shadeIndex = editor.subviews.firstIndex(where: { $0 === shade }),
              groupLayer.zPosition > shadeLayer.zPosition ||
                  (groupLayer.zPosition == shadeLayer.zPosition && groupIndex > shadeIndex) else {
            throw Failure("paint the insertion bar above the rename shade")
        }
        try capture(scroll, "rename-caret")
    }

    private static func checkVerticalRoundTrip(in editor: EditorTextView, window: NSWindow, phase: String) throws {
        let source = editor.string as NSString
        let initial = editor.selectedRange()
        let long = LineEditing.line(at: initial.location, in: source)
        let short = LineEditing.line(at: long.end, in: source)
        guard initial.length == 0, initial.location - long.start > 12,
              source.substring(with: NSRange(location: short.start, length: short.contentEnd - short.start)) == "}" else {
            throw Failure("start with a caret well to the right of the next line's closing brace \(phase) (\(initial))")
        }

        let arrowModifiers: NSEvent.ModifierFlags = [.function, .numericPad]
        editor.keyDown(with: try keyEvent(125, characters: "\u{F701}", modifiers: arrowModifiers, in: window))
        let down = editor.selectedRange()
        let downAnchor = editor.textLayoutManager?.textSelections.map(\.anchorPositionOffset) ?? []
        guard down.length == 0, (short.start...short.contentEnd).contains(down.location) else {
            throw Failure("move Down to the closing brace \(phase) (\(initial) to \(down), anchor \(downAnchor))")
        }
        editor.keyDown(with: try keyEvent(126, characters: "\u{F700}", modifiers: arrowModifiers, in: window))
        let up = editor.selectedRange()
        guard up == initial else {
            let upAnchor = editor.textLayoutManager?.textSelections.map(\.anchorPositionOffset) ?? []
            throw Failure("return Up to the long line's original column \(phase) (\(initial) to \(down) to \(up), anchors \(downAnchor), \(upAnchor))")
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

    private static func keyEvent(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = .function,
                                 in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { throw Failure("create a key event for key code \(code)") }
        return event
    }

    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .seconds(10)
        while !condition(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw Failure(message) }
    }
}
