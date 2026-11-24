import AppKit

@MainActor
enum LanguageServerCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "ZLS check: \(message)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSWindow) throws -> Void,
                    captureHover: (NSView, String) throws -> Void,
                    captureServers: (NSView, LanguageServerCommand) throws -> Void) async throws {
        try checkHoverPlacement()
        try checkHoverLayout(in: document.window, capture: captureHover)
        try checkStructuredHover(in: document.window, capture: captureHover)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ZLS fixture \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let root = FileBuffer.canonicalURL(folder)
        try checkPathOrder(in: root)
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let main = root.appending(path: "main.zig")
        let helper = root.appending(path: "helper.zig")
        let third = root.appending(path: "other use.zig")
        let solo = root.appending(path: "solo.zig")
        let notes = root.appending(path: "Notes.txt")
        let font = root.appending(path: "Font Types #é.zig")
        let typed = root.appending(path: "Typed.zig")
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
        for (url, text) in [(main, mainText), (helper, helperText), (third, thirdText), (solo, soloText), (notes, "Notes\n")] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let fontText = "/// Display variant.\r\n\r\npub const FontVariant = struct { bold: bool };\r\n"
        let typedText = """
            const std = @import("std");
            const text_mod = @import("Font Types #é.zig");
            pub fn select() void {
                const variant = text_mod.FontVariant{ .bold = true };
                std.log.debug("Ready", .{});
                _ = variant;
            }
            """
        try fontText.write(to: font, atomically: true, encoding: .utf8)
        try typedText.write(to: typed, atomically: true, encoding: .utf8)

        let lsp = document.languageFeatures
        document.setFolder(empty)
        try await wait("finish discovering an unrelated folder") { lsp.session.state == .stopped }
        try expect(lsp.statusButton.isHidden && lsp.statusIndicatorForCheck == nil, "omit LSP controls in a folder without a project")
        document.setFolder(root)
        try await wait("discover ZLS while an untitled buffer is active") { lsp.statusIndicatorForCheck == .ready }
        try expect(try await app.openFile(notes, in: document) === document, "open a non-Zig file in the project folder")
        try expect(lsp.statusIndicatorForCheck == .ready && lsp.canPerform(.stop), "keep folder controls available over a text file")
        try expect(try await app.openFile(main, in: document) === document, "open the Zig fixture")
        try await wait("initialize ZLS from PATH (\(lsp.session.state.title))") { lsp.session.supportsDefinition }
        document.window.layoutIfNeeded()
        let button = lsp.statusButton
        let headerPoint = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try expect(!button.isHidden && button.title.isEmpty && button.image != nil && lsp.statusIndicatorForCheck == .ready,
                   "show the ready state as an icon without a title")
        try expect(button.window === document.window && headerPoint.x > document.window.frame.width - 55,
                   "anchor the language server icon at the trailing edge of the header")
        try expect(lsp.canPerform(.stop) && lsp.canPerform(.restart) && !lsp.canPerform(.start), "ready server controls")
        let readyControls = try checkPopoverControls(in: lsp, toggle: .stop, capture: captureServers)

        let use = (mainText as NSString).range(of: "identify")
        try expect(await lsp.probe(at: use.location + 2, word: use) == use, "definition link over Unicode source")
        let hover = await lsp.hover(at: use.location + 2, word: use)
        try expect(hover?.isMarkdown == true && hover?.text.contains("Returns a value.") == true && hover?.range == use,
                   "ZLS returns fenced Markdown and the symbol range")
        try await checkEditorHoverAndClick(in: document, word: use)
        let declaration = (helperText as NSString).range(of: "identify")
        try await wait("open cross-file definition at its start") {
            document.fileURL == helper && document.editor.selectedRange().location == declaration.location
        }
        await app.navigate(.back)
        try expect(document.fileURL == main && NSLocationInRange(document.editor.selectedRange().location, use),
                   "Go Back returns to the clicked symbol")
        await app.navigate(.forward)
        try expect(document.fileURL == helper && document.editor.selectedRange().location == declaration.location,
                   "Go Forward restores the original definition target")

        try await wait("reuse ZLS in the definition file") { lsp.session.supportsReferences }
        lsp.followLink(at: declaration.location + 2, word: declaration)
        try await wait("open multi-file References") { document.sidebarMode == .references && document.isSidebarVisible }
        document.window.layoutIfNeeded()
        guard let table = descend(document.window.contentView, matching: { $0.accessibilityLabel() == "Reference Results" }) as? SidebarResultTable,
              let isHeader = table.isFileHeader else { throw Failure("show the shared References table") }
        let headings = (0..<table.numberOfRows).filter(isHeader)
        try expect(headings.count >= 2 && table.numberOfRows > headings.count + 1 && table.selectedRow > 0,
                   "all reference file groups and their rows are visible when the list opens")
        let selected = table.selectedRow
        table.selectRowIndexes(IndexSet(integer: headings[1]), byExtendingSelection: false)
        try expect(table.selectedRow == selected, "file headings cannot receive selection")
        let row = headings[1] + 1
        let previous = headings[1] - 1
        try clickRow(previous, in: table, window: document.window)
        try expect(table.selectedRow == previous && document.window.firstResponder === table,
                   "clicking a result selects it without entering the editor (expected \(previous), selected \(table.selectedRow), focus \(String(describing: document.window.firstResponder)))")
        table.keyDown(with: try key(125, character: "\u{F701}", in: document.window))
        try expect(table.selectedRow == row, "Down skips the next file heading")
        try await wait("preview the next file with focus remaining in References") {
            document.fileURL != helper && document.window.firstResponder === table
        }
        try capture(document.window)
        table.keyDown(with: try key(49, character: " ", in: document.window))
        try await wait("Space transfers focus to the reference in the editor") { document.window.firstResponder === document.editor }
        try expect(document.sidebarMode == .references && table.selectedRow == row, "retain the reference list and selection after activation")
        document.window.makeFirstResponder(table)
        table.keyDown(with: try key(36, character: "\r", in: document.window))
        try await wait("Return also transfers focus to the reference") { document.window.firstResponder === document.editor }
        await app.navigate(.back)
        try expect(document.fileURL == helper && document.editor.selectedRange().location == declaration.location + 2,
                   "Go Back returns to the symbol that produced the references")

        try expect(try await app.openFile(solo, in: document) === document, "open the single-use fixture")
        try await wait("synchronize the single-use fixture") { lsp.session.supportsReferences }
        let first = (soloText as NSString).range(of: "onlyValue")
        let last = (soloText as NSString).range(of: "onlyValue", options: .backwards)
        lsp.followLink(at: first.location + 2, word: first)
        try await wait("follow the single use without opening a new References view") {
            document.editor.selectedRange().location == last.location
        }

        try expect(try await app.openFile(typed, in: document) === document, "open the referenced-type fixture")
        try await wait("synchronize the referenced-type fixture") { lsp.session.supportsHover }
        let debug = (typedText as NSString).range(of: "debug")
        let debugHover = await lsp.hover(at: debug.location + 1, word: debug)
        let debugSections = debugHover.flatMap { ZLSHover(markdown: $0.text) }
        try expect(debugHover?.isMarkdown == true && debugSections?.declaration.hasPrefix("fn debug(") == true &&
                   debugSections?.types.first?.hasPrefix("fn (") == true && debugSections?.documentation?.contains("debug message") == true,
                   "parse the standard library's debug function from live ZLS output")
        let variant = (typedText as NSString).range(of: "variant")
        let typeLine = (fontText as NSString).range(of: "pub const FontVariant").location
        try await checkHoverDefinitionLink(in: document, word: variant, file: font, lineOffset: typeLine) { view in
            try captureHover(view, "hover")
        }
        await app.navigate(.back)
        try expect(document.fileURL == typed && document.editor.selectedRange().location == variant.location,
                   "Go Back returns to the word whose hover was followed")

        lsp.perform(.stop)
        try await wait("stop the server") { lsp.session.state.title == "Stopped" }
        try expect(lsp.canPerform(.start) && !document.editor.languageInteractionEnabled, "stop disables language gestures")
        try expect(lsp.statusIndicatorForCheck == .stopped, "show the stopped workspace in red")
        let stoppedControls = try checkPopoverControls(in: lsp, toggle: .start, capture: captureServers)
        try expect(readyControls == stoppedControls, "switching between Play and Stop keeps both controls in place")
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

    private static func checkPopoverControls(in lsp: DocumentLanguageFeatures, toggle: LanguageServerCommand,
                                             capture: (NSView, LanguageServerCommand) throws -> Void) throws -> [NSRect] {
        guard let view = lsp.statusPopoverForCheck else { throw Failure("prepare the native server popover") }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = lsp.statusButton.effectiveAppearance
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        try expect(window.acceptsMouseMovedEvents, "track the pointer in the server popover before the window becomes key")
        let frames = try [("toggle", toggle), ("restart", LanguageServerCommand.restart)].map { id, command in
            let identifier = "Edit.LanguageServer.\(id)"
            guard let button = descend(view, matching: { $0.identifier?.rawValue == identifier }) as? NSButton else {
                throw Failure("find \(command.title) in the server popover")
            }
            try expect(button.title.isEmpty && button.image != nil && button.isEnabled && button.accessibilityLabel() == command.title,
                       "show the current icon action for \(command.title) in the popover")
            for x in [button.bounds.minX + 1, button.bounds.midX, button.bounds.maxX - 1] {
                let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: nil)
                try expect(EditApplication.clickCursor(in: window, at: point) === NSCursor.pointingHand,
                           "show a pointing hand across the \(command.title) button")
            }
            return button.convert(button.bounds, to: view)
        }
        let toggleFrame = frames[0]
        let restartFrame = frames[1]
        let spacing = restartFrame.minX - toggleFrame.maxX
        let rightInset = view.bounds.maxX - restartFrame.maxX
        try expect(toggleFrame.size == restartFrame.size && toggleFrame.width >= 24 &&
                   abs(toggleFrame.midY - restartFrame.midY) < 1 && abs(restartFrame.midY - view.bounds.midY) < 1 &&
                   (0...4).contains(spacing) && (8...14).contains(rightInset),
                   "align equal-sized controls in a compact group at the right edge (\(frames), \(view.bounds))")
        try capture(view, toggle)
        return frames
    }

    private static func clickRow(_ row: Int, in table: SidebarResultTable, window: NSWindow) throws {
        table.scrollRowToVisible(row)
        let rect = table.frameOfCell(atColumn: 0, row: row)
        let location = NSPoint(x: rect.midX, y: rect.midY)
        try expect(table.row(at: location) == row, "target the expected native table row")
        let point = table.convert(location, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 1)
            else { throw Failure("create a References click") }
            return event
        }
        table.mouseDown(with: try event(.leftMouseDown))
    }

    private static func key(_ code: UInt16, character: String, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: code) else { throw Failure("create a keyboard event") }
        return event
    }

    private static func checkEditorHoverAndClick(in document: DocumentWindow, word: NSRange) async throws {
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
        guard let panel = editor.languageHoverWindowForCheck, let view = panel.contentView,
              let declaration = hoverBody(.declaration, in: view), let docs = hoverBody(.documentation, in: view)
        else { throw Failure("find the declaration and documentation for a live ZLS function") }
        try expect(docs.isSelectable && !docs.isEditable && docs.string.contains("Returns a value.") &&
                   declaration.isSelectable && declaration.string.contains("fn identify()"),
                   "show selectable documentation and its signature")
        try checkFirstHoverSelection(in: panel, text: docs, editor: editor)
        editor.cancelOperation(nil)
        try expect(editor.languageHoverWindowForCheck == nil, "Escape dismisses language documentation")
        editor.mouseMoved(with: try event(.mouseMoved, .command))
        try await wait("restore the definition link for Cmd-click") { editor.languageDefinitionLinkRange == word }
        let down = try event(.leftMouseDown, .command, clicks: 1)
        NSApp.postEvent(try event(.leftMouseUp, .command, clicks: 1), atStart: true)
        editor.mouseDown(with: down)
    }

    private static func checkFirstHoverSelection(in panel: NSWindow, text: NSTextView, editor: EditorTextView) throws {
        let phrase = (text.string as NSString).range(of: "Returns a value")
        try orderQuietHover(panel)
        try expect(phrase.location != NSNotFound && text.selectedRange().length == 0 &&
                   !panel.isKeyWindow && panel.firstResponder !== text && editor.window?.firstResponder === editor,
                   "start selecting while the editor still has focus")
        let first = text.firstRect(forCharacterRange: NSRange(location: phrase.location, length: 1), actualRange: nil)
        let last = text.firstRect(forCharacterRange: NSRange(location: NSMaxRange(phrase) - 1, length: 1), actualRange: nil)
        let start = panel.convertPoint(fromScreen: NSPoint(x: first.minX + 1, y: first.midY))
        let end = panel.convertPoint(fromScreen: NSPoint(x: last.maxX - 1, y: last.midY))
        let press = try hoverMouseEvent(.leftMouseDown, at: start, in: panel)
        try expect(text.acceptsFirstMouse(for: press), "accept the starting press of the first text drag")
        let drag = try hoverMouseEvent(.leftMouseDragged, at: end, in: panel)
        let release = try hoverMouseEvent(.leftMouseUp, at: end, in: panel)
        try sendHoverGesture(press, followedBy: [drag, release], in: panel)
        let range = text.selectedRange()
        try expect(range.length >= 6 && NSIntersectionRange(phrase, range).length == range.length,
                   "select documentation with one drag (\(range))")
    }

    private static func checkHoverLayout(in owner: NSWindow, capture: (NSView, String) throws -> Void) throws {
        guard let screen = owner.screen ?? NSScreen.main else { throw Failure("find a screen for the hover layout") }
        let area = screen.visibleFrame
        let anchor = NSRect(x: area.midX, y: area.midY, width: 20, height: 14)
        let structure = """
            const Binding = struct {
                keys: []const u8,
                action: u64,
                key_context: ?KeyContext = null,
                arg: u64 = 0,
                convention: ?Convention = null,
            }
            """
        var insets: [(top: CGFloat, bottom: CGFloat)] = []
        var hasCodeBackground = false
        var codeLineGap: CGFloat?
        for (id, code) in [("hover-short", "const std_scoped = std.log.scoped(scope)"), ("hover-code", structure)] {
            let markdown = "```zig\n\(code)\n```\n```zig\n(type)\n```"
            let content = EditorHoverContent(text: markdown, isMarkdown: true)
            let attributed = content.attributedText()
            guard let panel = EditorHoverPopover(owner: owner, appearance: owner.effectiveAppearance, anchor: anchor,
                                                  presentation: .markdown(content), onNavigate: { _ in }, onEnter: {}, onExit: {}),
                  let view = panel.window.contentView,
                  let text = descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHoverText" }) as? NSTextView,
                  let scroll = text.enclosingScrollView
            else { throw Failure("lay out a fenced code hover") }
            defer { panel.close(restoreFocus: false) }
            try capture(view, id)
            let type = (text.string as NSString).range(of: "(type)")
            try expect(type.location != NSNotFound, "show the type below the code")
            let first = text.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            let last = text.firstRect(forCharacterRange: type, actualRange: nil)
            let viewport = panel.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            insets.append((viewport.maxY - first.maxY, last.minY - viewport.minY))
            hasCodeBackground = hasCodeBackground || attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil
            let lineBreak = (code as NSString).range(of: "\n")
            if lineBreak.location != NSNotFound {
                let next = text.firstRect(forCharacterRange: NSRange(location: NSMaxRange(lineBreak), length: 1), actualRange: nil)
                codeLineGap = first.minY - next.maxY
            }
        }
        try expect(insets.allSatisfy { abs($0.top - $0.bottom) < 2 }, "fit the hover with balanced vertical padding (\(insets))")
        try expect(!hasCodeBackground, "avoid text background stripes in fenced code")
        try expect(codeLineGap.map { abs($0) < 1 } == true, "keep consecutive code lines at the normal line height")
    }

    private static func checkHoverPlacement() throws {
        let screen = NSRect(x: -1_000, y: 50, width: 1_000, height: 800)
        let content = NSSize(width: 450, height: 245)
        let middle = NSRect(x: screen.midX, y: screen.midY, width: 26, height: 16)
        let top = NSRect(x: screen.maxX - 7, y: screen.maxY - 25, width: 6, height: 16)
        let left = NSRect(x: screen.minX + 1, y: screen.midY, width: 6, height: 16)
        for (anchor, above) in [(middle, true), (top, false), (left, true)] {
            guard let placement = EditorHoverPlacement(anchor: anchor, contentSize: content, screen: screen)
            else { throw Failure("place the hover on the screen") }
            let frame = placement.frame
            let tipX = frame.minX + placement.shape.pointerX
            let gap = above ? frame.minY - anchor.maxY : anchor.minY - frame.maxY
            try expect(screen.contains(frame) && abs(tipX - anchor.midX) < 1 && (3...5).contains(gap),
                       "point to the symbol with clearance above or below, including at screen edges")
            try expect((placement.shape.contentFrame.minY > 0) == above,
                       "put the pointer on the edge that faces the symbol")
        }

        let shortScreen = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: 400)
        let anchor = NSRect(x: shortScreen.midX, y: shortScreen.midY, width: 26, height: 16)
        guard let placement = EditorHoverPlacement(anchor: anchor, contentSize: content, screen: shortScreen)
        else { throw Failure("fit a hover beside its symbol with limited vertical space") }
        try expect(shortScreen.contains(placement.frame) && !placement.frame.intersects(anchor) &&
                   placement.shape.contentFrame.height < content.height,
                   "shorten the viewport before it would cover the symbol")
    }

    private static func checkStructuredHover(in owner: NSWindow, capture: (NSView, String) throws -> Void) throws {
        let declaration = "fn debug(\n            comptime format: []const u8,\n            args: anytype,\n        ) void"
        let wrappedType = "(fn (comptime []const u8, anytype) void)"
        let referenceLine = "Go to [A](file:///tmp/A.zig#L1) | [B](file:///tmp/B.zig#L2) | [C](file:///tmp/C.zig#L3)"
        let raw = """
            ```zig
            \(declaration)
            ```
            ```zig
            \(wrappedType)
            ```

            \(referenceLine)

            Log a debug message. This log level is intended to be used for messages which are only useful for debugging.
            """
        let presentation = EditorHoverPresentation(text: raw, isMarkdown: true)
        guard let screen = owner.screen ?? NSScreen.main else { throw Failure("find a screen for the sections") }
        let area = screen.visibleFrame
        let anchor = NSRect(x: area.midX, y: area.midY, width: 20, height: 14)
        guard let panel = EditorHoverPopover(owner: owner, appearance: owner.effectiveAppearance, anchor: anchor,
                                              presentation: presentation, onNavigate: { _ in }, onEnter: {}, onExit: {}),
              let view = panel.window.contentView else { throw Failure("show the structured hover") }
        defer { panel.close(restoreFocus: false) }
        for kind in [EditorHoverPresentation.Section.Kind.declaration, .documentation] {
            let label = descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHover.\(kind.rawValue).label" })
            try expect(label?.isHidden == true &&
                       hoverBody(kind, in: view)?.accessibilityLabel() == kind.rawValue,
                       "give the \(kind.rawValue) an accessible name without a visible label")
        }
        let kinds: [EditorHoverPresentation.Section.Kind] = [.declaration, .documentation, .type, .references]
        let frames = try kinds.map { kind in
            guard let body = hoverBody(kind, in: view) else { throw Failure("find the \(kind.rawValue) content") }
            return body.convert(body.bounds, to: nil)
        }
        try expect(zip(frames, frames.dropFirst()).allSatisfy { earlier, later in earlier.minY >= later.maxY },
                   "order the signature, description, type and references")
        guard let separator = descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHover.separator" }) as? NSBox
        else { throw Failure("find the divider above hover metadata") }
        let separatorFrame = separator.convert(separator.bounds, to: nil)
        try expect(frames[1].minY > separatorFrame.maxY && separatorFrame.minY > frames[2].maxY,
                   "divide the description from metadata")
        try expect(frames[1].minX == separatorFrame.minX && frames[0].minX == separatorFrame.minX + 6 &&
                   frames[2].minX == frames[3].minX && frames[2].minX > frames[0].minX,
                   "start the description and declaration block at the left inset and keep a column for labeled rows")
        guard let type = hoverBody(.type, in: view),
              let codeBackground = type.superview?.subviews.compactMap({ $0 as? NSBox }).first(where: {
                  $0.boxType == .custom && $0.frame == type.frame.insetBy(dx: -6, dy: -4)
              })
        else { throw Failure("preserve the padded code background behind the type") }
        try expect(codeBackground.cornerRadius == 6 &&
                   type.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == EditorTextView.defaultFont,
                   "preserve the type's background and code font")
        try expect(hoverBody(.declaration, in: view)?.string == "fn debug(\n    comptime format: []const u8,\n    args: anytype,\n) void" &&
                   hoverBody(.type, in: view)?.string == "fn (comptime []const u8, anytype) void",
                   "dedent the signature and remove only the outer type parentheses")
        try expect(hoverBody(.documentation, in: view)?.string.hasPrefix("Log a debug message.") == true,
                   "render the documentation in its own text view")
        guard let links = hoverBody(.references, in: view), links.string == "A, B, C" else { throw Failure("show comma-separated links") }
        for offset in [0, 3, 6] {
            try expect(links.textStorage?.attribute(.link, at: offset, effectiveRange: nil) is URL, "preserve each target URL")
        }
        try capture(view, "hover-sections")
        if let light = NSAppearance(named: .aqua) {
            let upperAnchor = NSRect(x: anchor.minX, y: area.maxY - 32, width: anchor.width, height: anchor.height)
            guard let lightPanel = EditorHoverPopover(owner: owner, appearance: light, anchor: upperAnchor,
                                                       presentation: presentation, onNavigate: { _ in }, onEnter: {}, onExit: {}),
                  let lightView = lightPanel.window.contentView
            else { throw Failure("draw the light hover near the top of the screen") }
            defer { lightPanel.close(restoreFocus: false) }
            try expect(lightPanel.frame.maxY < upperAnchor.minY, "leave the symbol above the light hover's pointer")
            try checkLightCodeBackground(in: lightView)
            try capture(lightView, "hover-sections-light")
        }

        let columns = try [EditorHoverPresentation.Section.Kind.type, .references].map { kind in
            guard let label = descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHover.\(kind.rawValue).label" }) as? NSTextField,
                  let body = hoverBody(kind, in: view)
            else { throw Failure("find both columns in the \(kind.rawValue) row") }
            try expect(label.stringValue == (kind == .references ? "Links" : "Type") &&
                       label.accessibilityRole()?.rawValue == "AXHeading" &&
                       label.alignment == .right && label.textColor == .secondaryLabelColor &&
                       label.font == .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                       "show the aligned native \(kind.rawValue) label")
            let labelEdge = label.convert(label.alignmentRect(forFrame: label.bounds), to: nil).maxX
            let bodyStart = body.convert(body.textContainerOrigin, to: nil).x
            let labelBaseline = label.convert(NSPoint(x: 0, y: label.isFlipped ? label.firstBaselineOffsetFromTop :
                label.bounds.height - label.firstBaselineOffsetFromTop), to: nil).y
            let firstLine = body.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            let textLine = panel.window.convertFromScreen(firstLine)
            try expect((textLine.minY...textLine.maxY).contains(labelBaseline), "align the \(kind.rawValue) label with its first line")
            let naturalWidth = label.alignmentRect(forFrame: NSRect(origin: .zero, size: label.fittingSize)).width
            return (labelEdge: labelEdge, bodyStart: bodyStart, naturalWidth: naturalWidth)
        }
        let firstColumn = columns[0]
        try expect(columns.allSatisfy { abs($0.labelEdge - firstColumn.labelEdge) < 1 &&
                   abs($0.bodyStart - firstColumn.bodyStart) < 1 && $0.labelEdge < $0.bodyStart },
                   "share a label edge and a content column across the hover rows (\(columns))")
        let widestLabel = ceil(max(columns[0].naturalWidth, columns[1].naturalWidth))
        try expect(abs(firstColumn.labelEdge - separatorFrame.minX - widestLabel) < 1,
                   "size the label column for the widest visible label")

        let typeOnly = raw.replacingOccurrences(of: referenceLine + "\n\n", with: "")
        guard let typePanel = EditorHoverPopover(owner: owner, appearance: owner.effectiveAppearance, anchor: anchor,
                                                  presentation: EditorHoverPresentation(text: typeOnly, isMarkdown: true),
                                                  onNavigate: { _ in }, onEnter: {}, onExit: {}),
              let typeView = typePanel.window.contentView,
              let label = descend(typeView, matching: { $0.identifier?.rawValue == "EditorLanguageHover.Type.label" }) as? NSTextField,
              let description = hoverBody(.documentation, in: typeView)
        else { throw Failure("show a type without links") }
        defer { typePanel.close(restoreFocus: false) }
        let labelFrame = label.alignmentRect(forFrame: label.bounds)
        let naturalWidth = label.alignmentRect(forFrame: NSRect(origin: .zero, size: label.fittingSize)).width
        let labelStart = label.convert(labelFrame, to: nil).minX
        let descriptionStart = description.convert(description.bounds, to: nil).minX
        try expect(hoverBody(.references, in: typeView) == nil && abs(labelFrame.width - ceil(naturalWidth)) < 1 &&
                   abs(labelStart - descriptionStart) < 1, "place a lone Type label at the left inset")
        try capture(typeView, "hover-type-only")

        let longDocumentation = raw + String(repeating: "\n\nA documentation paragraph in a long hover.", count: 20)
        let longPresentation = EditorHoverPresentation(text: longDocumentation, isMarkdown: true)
        guard let longPanel = EditorHoverPopover(owner: owner, appearance: owner.effectiveAppearance, anchor: anchor,
                                                  presentation: longPresentation, onNavigate: { _ in }, onEnter: {}, onExit: {}),
              let longView = longPanel.window.contentView, let lastSection = hoverBody(.references, in: longView),
              let scroll = lastSection.enclosingScrollView, let document = scroll.documentView
        else { throw Failure("lay out the long structured hover") }
        defer { longPanel.close(restoreFocus: false) }
        let lastFrame = lastSection.convert(lastSection.bounds, to: document)
        try expect(scroll.hasVerticalScroller && !scroll.documentVisibleRect.intersects(lastFrame),
                   "cap long documentation and start at the declaration")
        lastSection.scrollToVisible(lastSection.bounds)
        try expect(scroll.documentVisibleRect.contains(lastFrame), "scroll to the links after long documentation")

        let alternatives = "```zig\nvalue\n```\n```zig\n(A)\n```\n```zig\n(B)\n```\n```txt\n(...)\n```"
        let parsed = ZLSHover(markdown: alternatives)
        try expect(parsed?.types == ["A", "B"] && parsed?.hasMoreTypes == true, "retain alternative types and the truncation marker")
        let builtin = ZLSHover(markdown: "```zig\n@as(comptime T: type, expression: anytype) T\n```\nSee **coercion**.")
        try expect(builtin?.types.isEmpty == true && builtin?.documentation == "See **coercion**.", "preserve builtin documentation")
        for unfamiliar in ["| Decimal | Hex |\n|---|---|\n| 8 | 0x8 |", alternatives + "\n\n" + alternatives,
                           "```zig\nx\n```\n```zig\nmissing wrapper\n```"] {
            let fallback = EditorHoverPresentation(text: unfamiliar, isMarkdown: true)
            guard case .markdown(let content) = fallback else { throw Failure("keep unsupported ZLS Markdown in the generic hover") }
            try expect(content.attributedText().length > 0, "keep fallback content visible")
        }
    }

    private static func checkLightCodeBackground(in view: NSView) throws {
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure("capture the light hover") }
        view.cacheDisplay(in: bounds, to: bitmap)

        for kind in [EditorHoverPresentation.Section.Kind.declaration, .type] {
            guard let body = hoverBody(kind, in: view) else { throw Failure("find the light hover's \(kind.rawValue)") }
            let frame = body.convert(body.bounds, to: view)
            let top = view.isFlipped ? frame.midY - bounds.minY : bounds.maxY - frame.midY
            let y = Int(top * CGFloat(bitmap.pixelsHigh) / bounds.height)
            let scale = CGFloat(bitmap.pixelsWide) / bounds.width
            let codeX = Int((frame.maxX - bounds.minX + 2) * scale)
            let marginX = Int(6 * scale)
            guard let code = bitmap.colorAt(x: codeX, y: y)?.usingColorSpace(.sRGB),
                  let margin = bitmap.colorAt(x: marginX, y: y)?.usingColorSpace(.sRGB)
            else { throw Failure("sample the light hover's code padding and card margin") }
            try expect(margin.redComponent - code.redComponent > 0.035,
                       "make the \(kind.rawValue) background visibly darker than the card in light appearance")
        }
    }

    private static func checkHoverDefinitionLink(in document: DocumentWindow, word: NSRange, file: URL, lineOffset: Int,
                                                 capture: (NSView) throws -> Void) async throws {
        let editor = document.editor
        document.window.layoutIfNeeded()
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        guard let symbol = editor.highlightRects(for: [word]).first else { throw Failure("layout the inferred-type use") }
        let location = editor.convert(NSPoint(x: symbol.midX, y: symbol.midY), to: nil)
        editor.mouseMoved(with: try hoverMouseEvent(.mouseMoved, at: location, in: document.window))
        try await wait("show the inferred-type hover from ZLS") { editor.languageHoverWindowForCheck != nil }
        guard let panel = editor.languageHoverWindowForCheck, let view = panel.contentView,
              let text = hoverBody(.references, in: view), let declaration = hoverBody(.declaration, in: view)
        else { throw Failure("find the inferred-type hover content") }
        let link = (text.string as NSString).range(of: "FontVariant", options: .backwards)
        guard link.location != NSNotFound,
              let url = text.textStorage?.attribute(.link, at: link.location, effectiveRange: nil) as? URL
        else { throw Failure("make the FontVariant name in the hover's Links row clickable") }
        let linkedFile = FileBuffer.canonicalURL(URL(filePath: url.path))
        try expect(linkedFile.path == file.path && url.fragment == "L3",
                   "retain the local line link from the actual ZLS Markdown (\(url.absoluteString), expected \(file.absoluteString)#L3)")
        try capture(view)
        try orderQuietHover(panel)
        let screen = text.firstRect(forCharacterRange: NSRange(location: link.location + 2, length: 1), actualRange: nil)
        try expect(!screen.isEmpty, "lay out the hover link target")
        let point = panel.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        for character in [link.location, link.location + 2, NSMaxRange(link) - 1] {
            let glyph = text.firstRect(forCharacterRange: NSRange(location: character, length: 1), actualRange: nil)
            for x in [glyph.minX + glyph.width / 4, glyph.midX, glyph.maxX - glyph.width / 4] {
                let target = panel.convertPoint(fromScreen: NSPoint(x: x, y: glyph.midY))
                try expect(EditApplication.clickCursor(in: panel, at: target) === NSCursor.pointingHand,
                           "show a pointing hand across the link glyph at \(character)")
            }
        }
        let prose = declaration.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let prosePoint = panel.convertPoint(fromScreen: NSPoint(x: prose.midX, y: prose.midY))
        try expect(EditApplication.clickCursor(in: panel, at: prosePoint) === NSCursor.iBeam,
                   "keep the text cursor over the declaration")
        let press = try hoverMouseEvent(.leftMouseDown, at: point, in: panel)
        try expect(!panel.isKeyWindow && panel.firstResponder !== text && document.window.firstResponder === editor,
                   "start the click while the editor still has focus")
        try expect(text.acceptsFirstMouse(for: press), "deliver the first click to the link in the non-key hover")
        let release = try hoverMouseEvent(.leftMouseUp, at: point, in: panel)
        try sendHoverGesture(press, followedBy: [release], in: panel)
        try await wait("open the definition at the linked line on the first click") {
            document.fileURL == file && editor.selectedRange().location == lineOffset &&
                document.window.firstResponder === editor && editor.languageHoverWindowForCheck == nil
        }
    }

    private static func hoverMouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                             clickCount: type == .mouseMoved ? 0 : 1,
                                             pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
        else { throw Failure("create a hover mouse event") }
        return event
    }

    private static func orderQuietHover(_ panel: NSWindow) throws {
        try expect(panel.alphaValue == 0 && panel.ignoresMouseEvents && !NSApp.isActive, "keep the hover fixture non-interactive")
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderBack(nil)
        try expect(panel.isVisible && !panel.isKeyWindow, "order the transparent hover without giving it focus")
    }

    private static func sendHoverGesture(_ press: NSEvent, followedBy events: [NSEvent], in panel: NSWindow) throws {
        for event in events.reversed() { NSApp.postEvent(event, atStart: true) }
        NSApp.postEvent(press, atStart: true)
        guard let down = NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        else { throw Failure("queue the first press in the hover") }
        panel.sendEvent(down)
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast,
                                          inMode: .default, dequeue: true) {
            if panel.isVisible { panel.sendEvent(event) }
        }
    }

    private static func hoverBody(_ kind: EditorHoverPresentation.Section.Kind, in view: NSView) -> NSTextView? {
        descend(view, matching: { $0.identifier?.rawValue == "EditorLanguageHover.\(kind.rawValue).body" }) as? NSTextView
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
