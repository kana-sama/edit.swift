import AppKit

@MainActor
enum LanguageServerRenameCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "ZLS rename check: \(message)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSView) throws -> Void) async throws {
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
        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        document.window.makeFirstResponder(editor)

        let name = (sourceText as NSString).range(of: "calculate")
        editor.setCaretSelections([NSRange(location: name.location + 2, length: 0)], record: false)
        let f2 = try keyEvent(120, characters: "\u{F705}", in: document.window)
        editor.keyDown(with: f2)
        let first = try await fieldEditor(in: document, name: "the original name")
        guard first.string == "calculate", first.selectedRange() == NSRange(location: 0, length: name.length),
              editor.string == sourceText else { throw Failure("focus the prepared symbol and select its whole name") }
        if let view = document.window.contentView { try capture(view) }
        first.insertText("abandoned", replacementRange: first.selectedRange())
        first.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await wait("Escape exits rename and restores editor focus") {
            !editor.isRenamingSymbol && document.window.firstResponder === editor
        }
        guard editor.string == sourceText else { throw Failure("leave source unchanged after Escape") }

        editor.keyDown(with: f2)
        let second = try await fieldEditor(in: document, name: "the original name after cancelling")
        let newName = "compute \"value\""
        let newSpelling = "@\"compute \\\"value\\\"\""
        second.insertText(newName, replacementRange: second.selectedRange())
        second.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let expected = sourceText.replacingOccurrences(of: "pub fn calculate", with: "pub fn \(newSpelling)")
            .replacingOccurrences(of: "return calculate()", with: "return \(newSpelling)()")
        let expectedCaller = callerText.replacingOccurrences(of: "source.calculate", with: "source.\(newSpelling)")
        try await wait("Return applies semantic edits in the editor, another buffer, and a closed file") {
            editor.string == expected && secondary.editor.string == expectedCaller &&
                (try? String(contentsOf: closed, encoding: .utf8)) == expectedCaller && !editor.isRenamingSymbol
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
        let quoted = try await fieldEditor(in: document, name: "the escaped Zig name")
        guard quoted.string == newName else { throw Failure("edit the name of an escaped Zig identifier") }
        quoted.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await document.flushAutosave()
        await secondary.flushAutosave()
    }

    private static func fieldEditor(in document: DocumentWindow, name: String) async throws -> NSTextView {
        func activeFieldEditor() -> NSTextView? {
            let field = document.editor.subviews.first { $0.identifier?.rawValue == "Edit.RenameSymbol.Name" } as? NSTextField
            return field?.currentEditor() as? NSTextView
        }
        try await wait("focus the inline field for \(name) after F2") { activeFieldEditor() != nil }
        guard let editor = activeFieldEditor() else { throw Failure("find the symbol name field editor") }
        return editor
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
