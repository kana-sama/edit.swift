import AppKit

@MainActor
enum LanguageServerCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "ZLS check: \(message)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSWindow) throws -> Void,
                    captureHover: (NSView) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ZLS fixture \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let root = FileBuffer.canonicalURL(folder)
        try checkPathOrder(in: root)
        let main = root.appending(path: "main.zig")
        let helper = root.appending(path: "helper.zig")
        let third = root.appending(path: "other use.zig")
        let solo = root.appending(path: "solo.zig")
        let mainText = """
            const helper = @import("helper.zig");
            const third = @import("other use.zig");
            pub fn run() usize { const emoji = "👋"; _ = emoji; return helper.identify() + third.useIt(); }

            """
        let helperText = """
            /// Returns a value.
            ///
            /// - See the caller for an example.
            pub fn identify() usize { return 7; }
            fn local() usize { return identify(); }

            """
        let thirdText = """
            const helper = @import("helper.zig");
            pub fn useIt() usize { return helper.identify(); }

            """
        let soloText = """
            fn onlyValue() usize { return 11; }
            pub fn run() usize { return onlyValue(); }

            """
        for (url, text) in [(main, mainText), (helper, helperText), (third, thirdText), (solo, soloText)] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        document.setFolder(root)
        try expect(try await app.openFile(main, in: document) === document, "open the Zig fixture")
        let lsp = document.languageFeatures
        try await wait("initialize ZLS from PATH (\(lsp.session.state.title))") { lsp.session.supportsDefinition }
        try expect(!lsp.statusButton.isHidden && lsp.statusButton.title == "ZLS · Ready", "header shows the ready server")
        try expect(lsp.canPerform(.stop) && lsp.canPerform(.restart) && !lsp.canPerform(.start), "ready server controls")
        try checkPopoverControls(in: lsp, enabled: [.stop, .restart])

        let use = (mainText as NSString).range(of: "identify")
        try expect(await lsp.probe(at: use.location + 2, word: use) == use, "definition link over Unicode source")
        let hover = await lsp.hover(at: use.location + 2, word: use)
        try expect(hover?.isMarkdown == true && hover?.text.contains("Returns a value.") == true && hover?.range == use,
                   "ZLS returns fenced Markdown and the symbol range")
        try await checkEditorHoverAndClick(in: document, word: use, capture: captureHover)
        let declaration = (helperText as NSString).range(of: "identify")
        try await wait("open cross-file definition at its start") {
            document.fileURL == helper && document.editor.selectedRange().location == declaration.location
        }

        try await wait("reuse ZLS in the definition file") { lsp.session.supportsReferences }
        lsp.followLink(at: declaration.location + 2, word: declaration)
        try await wait("open multi-file References") { document.sidebarMode == .references && document.isSidebarVisible }
        document.window.layoutIfNeeded()
        guard let outline = descend(document.window.contentView, matching: { $0.accessibilityLabel() == "Reference Results" }) as? NSOutlineView,
              outline.numberOfChildren(ofItem: nil) >= 2,
              let sourceGroup = outline.child(0, ofItem: nil), let otherGroup = outline.child(1, ofItem: nil)
        else { throw Failure("show the References outline and its groups") }
        try expect(outline.isItemExpanded(sourceGroup) && outline.selectedRow > 0,
                   "References groups files and reveals the origin")
        try capture(document.window)
        outline.expandItem(otherGroup)
        let result = outline.child(0, ofItem: otherGroup)
        let row = outline.row(forItem: result)
        try expect(row >= 0, "expand a second reference file")
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: document.window.windowNumber, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        else { throw Failure("create Return event") }
        outline.keyDown(with: enter)
        try await wait("open a reference with Return and restore editor focus") {
            document.fileURL != helper && document.window.firstResponder === document.editor
        }
        try expect(document.sidebarMode == .references, "retain the reference tree after opening a result")

        try expect(try await app.openFile(solo, in: document) === document, "open the single-use fixture")
        try await wait("synchronize the single-use fixture") { lsp.session.supportsReferences }
        let first = (soloText as NSString).range(of: "onlyValue")
        let last = (soloText as NSString).range(of: "onlyValue", options: .backwards)
        lsp.followLink(at: first.location + 2, word: first)
        try await wait("follow the single use without opening a new References view") {
            document.editor.selectedRange().location == last.location
        }

        lsp.perform(.stop)
        try await wait("stop the server") { lsp.session.state.title == "Stopped" }
        try expect(lsp.canPerform(.start) && !document.editor.languageInteractionEnabled, "stop disables language gestures")
        try checkPopoverControls(in: lsp, enabled: [.start, .restart])
        try expect(try await app.openFile(main, in: document) === document, "navigate after stopping ZLS")
        try await wait("resolve the stopped document's workspace") { lsp.canPerform(.start) }
        try expect(lsp.session.state.title == "Stopped", "stop holds while switching files in the same project")
        guard let start = ControlCommand.languageServerCommands(for: document).first(where: { $0.id == "lsp.start" })
        else { throw Failure("find Start LSP in Command Mode") }
        try expect(start.isAvailable(in: document, focus: document.editor), "Start LSP is available in Command Mode")
        start.run(in: document)
        try await wait("start with the Command Mode action") { lsp.session.supportsHover }
        let unsaved = mainText.replacingOccurrences(of: "return helper.identify()", with: "return   helper.identify()")
        document.editor.string = unsaved
        lsp.documentTextChanged()
        let moved = (unsaved as NSString).range(of: "identify")
        try expect(moved != use, "test moves the unsaved symbol")
        lsp.perform(.restart)
        try await wait("restart ZLS") { lsp.session.supportsHover }
        let updatedHover = await lsp.hover(at: moved.location + 2, word: moved)
        try expect(updatedHover?.range == moved && updatedHover?.text.contains("Returns a value.") == true,
                   "restart synchronizes unsaved text")
    }

    private static func checkPathOrder(in root: URL) throws {
        let first = root.appending(path: "first bin", directoryHint: .isDirectory)
        let second = root.appending(path: "second bin", directoryHint: .isDirectory)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let executable = directory.appending(path: "zls")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let expected = FileIdentity.at(second.appending(path: "zls"))
        let selected = LanguageServerSession.executable(in: "\(second.path):\(first.path)").flatMap { FileIdentity.at($0) }
        try expect(expected != nil && selected == expected, "resolve PATH entries in order")
        try expect(LanguageServerSession.executable(in: root.path) == nil, "skip executables outside PATH")
    }

    private static func checkPopoverControls(in lsp: DocumentLanguageFeatures, enabled: Set<LanguageServerCommand>) throws {
        guard let view = lsp.statusPopoverForCheck else { throw Failure("prepare the native server popover") }
        for command in LanguageServerCommand.allCases {
            let identifier = "Edit.LanguageServer.\(command.rawValue)"
            guard let button = descend(view, matching: { $0.identifier?.rawValue == identifier }) as? NSButton else {
                throw Failure("find \(command.title) in the server popover")
            }
            try expect(button.title == command.title && button.isEnabled == enabled.contains(command),
                       "show the current state of \(command.title) in the popover")
        }
    }

    private static func checkEditorHoverAndClick(in document: DocumentWindow, word: NSRange,
                                                 capture: (NSView) throws -> Void) async throws {
        let editor = document.editor
        document.window.layoutIfNeeded()
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        guard let glyphs = editor.highlightRects(for: [word]).first else { throw Failure("lay out the source symbol") }
        let location = editor.convert(NSPoint(x: glyphs.midX, y: glyphs.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, clicks: Int = 0) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: document.window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: clicks, pressure: 0)
            else { throw Failure("create a local mouse event") }
            return event
        }
        editor.mouseMoved(with: try event(.mouseMoved, .command))
        try await wait("underline the symbol on Cmd-hover") { editor.languageDefinitionLinkRange == word }
        editor.mouseMoved(with: try event(.mouseMoved, []))
        try expect(editor.languageDefinitionLinkRange == nil, "clear the definition link without Command")
        try await wait("show the documentation hover") { editor.languageHoverWindowForCheck != nil }
        guard let view = editor.languageHoverWindowForCheck?.contentView,
              let text = descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHoverText" }) as? NSTextView
        else { throw Failure("find the rich hover text view") }
        try expect(text.isSelectable && !text.isEditable && text.string.contains("Returns a value.") && text.string.contains("fn identify()"),
                   "show selectable documentation and its signature")
        try capture(view)
        editor.cancelOperation(nil)
        try expect(editor.languageHoverWindowForCheck == nil, "Escape dismisses language documentation")
        editor.mouseMoved(with: try event(.mouseMoved, .command))
        try await wait("restore the definition link for Cmd-click") { editor.languageDefinitionLinkRange == word }
        let down = try event(.leftMouseDown, .command, clicks: 1)
        NSApp.postEvent(try event(.leftMouseUp, .command, clicks: 1), atStart: true)
        editor.mouseDown(with: down)
    }

    private static func descend(_ view: NSView?, matching predicate: (NSView) -> Bool) -> NSView? {
        guard let view else { return nil }
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = descend(child, matching: predicate) { return match }
        }
        return nil
    }

    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try expect(condition(), message)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
}
