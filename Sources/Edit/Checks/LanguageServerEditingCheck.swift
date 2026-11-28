import AppKit

@MainActor
enum LanguageServerEditingCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "LSP editing check: \(detail)" }
    }

    private struct Fixture {
        let filename: String
        let language: SyntaxLanguage
        let text: String
        let completionName: String
        let partialName: String
        let signaturePrefix: String
        let signatureParameter: String
        let formattedInvocation: String
    }

    static func run(in app: Edit, document: DocumentWindow) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: "LSP editing \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let base = FileBuffer.canonicalURL(temporary)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: base)
        }
        try checkFormatOnSavePreferences(in: base)
        for fixture in fixtures {
            try await check(fixture, in: base, app: app, document: document)
        }
        try require(!document.window.isVisible && document.window.alphaValue == 0 && !NSApp.isActive,
                    "keep native LSP editing checks hidden")
    }

    private static func check(_ fixture: Fixture, in base: URL, app: Edit, document: DocumentWindow) async throws {
        let label = fixture.language.displayName
        let root = base.appending(path: label, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: fixture.filename)
        switch fixture.language {
        case .odin:
            try #"{"enable_checker":false}"#.write(to: root.appending(path: "ols.json"), atomically: true, encoding: .utf8)
        case .c:
            let commands: [[String: Any]] = [
                ["file": file.path, "directory": root.path, "arguments": ["/usr/bin/clang", "-c", file.path]]
            ]
            try JSONSerialization.data(withJSONObject: commands).write(to: root.appending(path: "compile_commands.json"))
        default:
            break
        }
        try fixture.text.write(to: file, atomically: true, encoding: .utf8)
        document.setFolder(root)
        try require(try await app.openFile(file, in: document) === document, "open the \(label) fixture")
        let session = document.languageFeatures.session
        try await wait("start \(label) LSP at \(root.path)", session: session) {
            session.state == .ready && session.workspaceRoot.map { FileBuffer.canonicalURL($0).path } == root.path
        }
        try require(document.resolvedSyntaxLanguage == fixture.language,
                    "route the active \(label) source (got \(document.resolvedSyntaxLanguage.displayName))")
        try require(session.supportsCompletion && session.supportsSignatureHelp && session.supportsFormatting,
                    "expose the three editing capabilities for \(label)")
        if fixture.language == .c {
            let declaration = try range(fixture.completionName, in: fixture.text)
            try await wait("prepare clangd for the C fixture", session: session) {
                let response = try? await session.hover(at: declaration.location + 1)
                return response?.content.contains(fixture.completionName) == true
            }
        }

        let editor = document.editor
        document.window.makeFirstResponder(editor)
        let usage = try range(fixture.completionName, in: editor.string, options: .backwards)
        editor.insertText(fixture.partialName, replacementRange: usage)
        select(usage.location + fixture.partialName.utf16.count, in: editor)
        editor.complete(nil)
        try await wait("show the \(label) completion for \(fixture.partialName)", session: session) {
            editor.completionLabelsForCheck.first?.trimmingCharacters(in: .whitespaces) == fixture.completionName
                && editor.completionFrameForCheck != nil
        }
        do {
            try await wait("show documentation for the selected \(label) item", session: session) {
                editor.completionDocumentationForCheck?.contains("Combines two fixture values.") == true
                    && editor.completionDocumentationFrameForCheck != nil
            }
        } catch {
            try Task.checkCancellation()
            let raw = try? await session.completion(at: editor.selectedRange().location)
            let matching = raw?.items.filter { $0.label.trimmingCharacters(in: .whitespaces) == fixture.completionName } ?? []
            let entry = matching.map { "\($0.label.debugDescription) docs=\($0.documentation?.value.debugDescription ?? "nil")" }
            throw Failure(detail: "show \(label) completion documentation; pane=\(editor.completionDocumentationForCheck?.debugDescription ?? "nil"), "
                          + "frame=\(String(describing: editor.completionDocumentationFrameForCheck)), server=\(entry)")
        }
        try key(36, "\r", in: document)
        try await wait("accept the \(label) completion") { editor.string == fixture.text }
        try require(document.window.firstResponder === editor, "retain editor focus after choosing the \(label) item")

        let call = try range(fixture.signaturePrefix, in: editor.string)
        select(call.upperBound, in: editor)
        editor.showSignatureHelp(nil)
        try await wait("highlight the second \(label) parameter (\(fixture.signatureParameter))", session: session) {
            guard let label = editor.signatureLabelForCheck, let active = editor.signatureParameterForCheck,
                  active.upperBound <= label.utf16.count else { return false }
            return (label as NSString).substring(with: active) == fixture.signatureParameter
                && editor.signatureFrameForCheck != nil
        }
        try key(53, "\u{1B}", in: document)

        let position = editor.selectedRange()
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        editor.formatDocument(nil)
        try await wait("format the unsaved \(label) buffer", session: session) {
            editor.string.contains(fixture.formattedInvocation)
        }
        try require(try String(contentsOf: file, encoding: .utf8) == fixture.text,
                    "keep the formatted \(label) edits in the buffer")
        editor.undoManager?.undo()
        try require(editor.string == fixture.text && editor.selectedRange() == position,
                    "undo the \(label) formatter's edits and restore the selection in one action")
        if fixture.language == .zig {
            try await checkCompletionScrolling(in: document, session: session)
            try await checkFormatOnSave(in: document, file: file, fixture: fixture)
        }
        print("LSP editing passed for \(label) with \(session.server.name).")
    }

    private static func checkFormatOnSavePreferences(in root: URL) throws {
        let suite = "dev.edit-swift.format-on-save.check.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(detail: "create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = root.appending(path: "Other")
        let saved = WorkspaceFormatOnSave(defaults: defaults)
        saved.setEnabled(true, in: root)
        saved.setEnabled(true, in: nil)
        let reopened = WorkspaceFormatOnSave(defaults: defaults)
        try require(reopened.isEnabled(in: root) && !reopened.isEnabled(in: other) && reopened.isEnabled(in: nil),
                    "restore independent Format on Save settings for folders and standalone windows")
        reopened.setEnabled(false, in: nil)
        let updated = WorkspaceFormatOnSave(defaults: defaults)
        try require(!updated.isEnabled(in: nil) && updated.isEnabled(in: root), "persist switching off a single scope")
    }

    private static func checkFormatOnSave(in document: DocumentWindow, file: URL, fixture: Fixture) async throws {
        let editor = document.editor
        let commands = NSApp.mainMenu.map(ControlCommand.fromMenu) ?? []
        guard let toggle = commands.first(where: { $0.title == "Toggle Format on Save" }),
              let bypass = commands.first(where: { $0.title == "File: Save Without Format" }) else {
            throw Failure(detail: "find Format on Save and Save Without Format in Command Mode")
        }
        try require(toggle.isAvailable(in: document, focus: editor) && toggle.toggleState(in: document) == false,
                    "offer Format on Save switched off in a new workspace")
        func disk(_ url: URL? = nil) throws -> String { try String(contentsOf: url ?? file, encoding: .utf8) }

        let start = NSRange(location: 0, length: 0)
        let prefix = "// Save fixture\n"
        editor.insertText(prefix, replacementRange: start)
        let raw = prefix + fixture.text
        let savedOff = await document.save()
        try require(try savedOff && editor.string == raw && disk() == raw, "save the exact text with formatting off")

        toggle.run(in: document)
        try require(toggle.toggleState(in: document) == true && document.isFormatOnSaveEnabled,
                    "enable formatting for the active workspace from Command Mode")
        editor.insertText("const number=42;\n", replacementRange: start)
        let unformatted = editor.string
        let position = editor.selectedRange()
        try require(bypass.isAvailable(in: document, focus: editor), "offer Save Without Format for an editable document")
        bypass.run(in: document)
        try await wait("save the unformatted text from Command Mode") {
            !document.window.isDocumentEdited && (try? disk()) == unformatted
        }
        try require(editor.string == unformatted && editor.selectedRange() == position && document.isFormatOnSaveEnabled,
                    "preserve the text, selection, and Format on Save setting after Save Without Format")

        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        let savedOn = await document.save()
        let formatted = editor.string
        try require(try savedOn && formatted.contains(fixture.formattedInvocation) && formatted.contains("const number = 42;")
                    && disk() == formatted && !document.window.isDocumentEdited,
                    "write the ZLS-formatted text to disk and mark it saved")
        editor.undoManager?.undo()
        try require(editor.string == unformatted && editor.selectedRange() == position && document.window.isDocumentEdited,
                    "undo every format-on-save edit and restore the caret in one action")

        document.requestAutosave()
        try await wait("autosave the exact text restored by Undo") {
            !document.window.isDocumentEdited && (try? disk()) == unformatted
        }
        let savedClean = await document.save()
        try require(try savedClean && editor.string == formatted && disk() == formatted,
                    "an explicit Save formats an already autosaved buffer")

        editor.undoManager?.undo()
        try require(editor.string == unformatted, "restore the unformatted source for the pending save")
        try await checkPendingSave(in: document, file: file, typeWhileSaving: true)
        editor.insertText("// Slow formatter\n", replacementRange: start)
        try await checkPendingSave(in: document, file: file, typeWhileSaving: false)

        let copy = file.deletingLastPathComponent().appending(path: "SavedAs.zig")
        let beforeCopy = editor.string
        let savedCopy = await document.save(asNew: true, to: copy)
        try require(try savedCopy && document.fileURL == copy && editor.string.contains(fixture.formattedInvocation)
                    && disk(copy) == editor.string && disk() == beforeCopy,
                    "format a named Zig buffer on Save As and preserve the source file")

        let features = document.languageFeatures
        try await wait("prepare ZLS for the saved copy") { features.session.supportsFormatting }
        features.perform(.stop)
        try await wait("stop ZLS before saving without a formatter") { features.session.state == .stopped }
        editor.insertText("const offline=1;\n", replacementRange: start)
        let offline = editor.string
        let savedOffline = await document.save()
        try require(try savedOffline && editor.string == offline && disk(copy) == offline,
                    "save the exact text when the configured formatter is unavailable")
    }

    private static func checkPendingSave(in document: DocumentWindow, file: URL, typeWhileSaving: Bool) async throws {
        let editor = document.editor
        let title = document.window.title
        var expected = editor.string
        let diskBefore = try String(contentsOf: file, encoding: .utf8)
        // Keep the response held even when the deadline cancels its task.
        var gate: CheckedContinuation<Void, Never>?
        var returned = false
        editor.beforeApplyLanguageFormattingForCheck = {
            await withCheckedContinuation { gate = $0 }
            returned = true
        }
        defer {
            gate?.resume()
            editor.beforeApplyLanguageFormattingForCheck = nil
        }
        var saved: Bool?
        let saving = Task { saved = await document.save() }
        defer { saving.cancel() }
        try await wait("hold the live formatting result before Save writes") { gate != nil }
        try require(try editor.string == expected && document.window.title == title
                    && String(contentsOf: file, encoding: .utf8) == diskBefore,
                    "retain text, title, and file contents while format on save is pending")
        if typeWhileSaving {
            let prefix = "// Typed while saving\n"
            editor.insertText(prefix, replacementRange: NSRange(location: 0, length: 0))
            expected = prefix + expected
            gate?.resume()
            gate = nil
        }
        try await wait("save the current buffer when formatting is stale or times out") { saved != nil }
        gate?.resume()
        gate = nil
        try await wait("let the obsolete formatting result finish") { returned }
        try require(try saved == true && editor.string == expected && document.window.title == title
                    && String(contentsOf: file, encoding: .utf8) == expected,
                    "preserve the latest visible and saved text after obsolete formatting returns")
    }

    private static func checkCompletionScrolling(in document: DocumentWindow, session: LanguageServerSession) async throws {
        let editor = document.editor
        let member = try range("elf.ready", in: editor.string)
        let name = NSRange(location: member.location + "elf.".utf16.count, length: "ready".utf16.count)
        editor.insertText("", replacementRange: name)
        select(name.location, in: editor)
        editor.complete(nil)
        try await wait("show a long Zig member completion list", session: session) {
            (editor.completionListForCheck?.numberOfRows ?? 0) > 8
        }
        guard let table = editor.completionListForCheck, let scroll = table.enclosingScrollView else {
            throw Failure(detail: "find the native completion list")
        }
        let last = table.numberOfRows - 1
        func isVisible(_ row: Int) -> Bool {
            scroll.documentVisibleRect.contains(table.rect(ofRow: row))
        }
        try require(table.selectedRow == 0 && isVisible(0) && !isVisible(last),
                    "show the first selection in a list longer than its viewport")
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -1000, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)) else {
            throw Failure(detail: "create an isolated completion scroll event")
        }
        table.scrollWheel(with: event)
        try await wait("reach the last completion row with the scroll wheel") { isVisible(last) }
        try require(table.selectedRow == 0 && document.window.firstResponder === editor,
                    "preserve the selection and editor focus while scrolling the list")

        for row in 1...last {
            try key(125, "\u{F701}", in: document)
            try require(table.selectedRow == row && isVisible(row), "reveal completion row \(row) on Down")
        }
        try key(125, "\u{F701}", in: document)
        try require(table.selectedRow == last && isVisible(last), "stop at the last completion row")
        for row in (0..<last).reversed() {
            try key(126, "\u{F700}", in: document)
            try require(table.selectedRow == row && isVisible(row), "reveal completion row \(row) on Up")
        }
        try key(126, "\u{F700}", in: document)
        try require(table.selectedRow == 0 && isVisible(0), "stop at the first completion row")
        try key(53, "\u{1B}", in: document)
        editor.insertText("ready", replacementRange: NSRange(location: name.location, length: 0))
    }

    private static let fixtures: [Fixture] = [
        Fixture(filename: "Fixture.zig", language: .zig, text: """
            /// Combines two fixture values.
            const combined_amount: u32 = 3;
            fn addAmounts(left: u32, right: u32) u32 {
                return left + right;
            }
            export fn total() u32 {
                return addAmounts(1,2) + combined_amount;
            }
            const Flags = struct {
                ready: bool,
                first: bool,
                second: bool,
                third: bool,
                fourth: bool,
                fifth: bool,
                sixth: bool,
                seventh: bool,
                eighth: bool,
                ninth: bool,
                tenth: bool,
            };
            fn isReady(elf: Flags) bool {
                return elf.ready;
            }

            """, completionName: "combined_amount", partialName: "combined_am",
                signaturePrefix: "addAmounts(1,", signatureParameter: "right: u32", formattedInvocation: "addAmounts(1, 2)"),
        Fixture(filename: "Fixture.odin", language: .odin, text: """
            package fixture
            // Combines two fixture values.
            combined_amount :: 3
            add_amounts :: proc(left, right: int) -> int {
                return left + right
            }
            total :: proc() -> int {
                return add_amounts(1,2) + combined_amount
            }

            """, completionName: "combined_amount", partialName: "combined_am",
                signaturePrefix: "add_amounts(1,", signatureParameter: "right: int", formattedInvocation: "add_amounts(1, 2)"),
        Fixture(filename: "Fixture.swift", language: .swift, text: """
            struct Accumulator {
                /// Combines two fixture values.
                var combinedAmount: Int { 3 }
                func addAmounts(_ left: Int, _ right: Int) -> Int { left + right }
            }
            func total() -> Int {
                Accumulator().addAmounts(1,2) + Accumulator().combinedAmount
            }

            """, completionName: "combinedAmount", partialName: "combinedAm",
                signaturePrefix: "addAmounts(1,", signatureParameter: "_ right: Int", formattedInvocation: "addAmounts(1, 2)"),
        Fixture(filename: "Fixture.c", language: .c, text: """
            /// Combines two fixture values.
            static const int combined_amount = 3;
            static int addAmounts(int left, int right) {
                return left + right;
            }
            int total(void) {
                return addAmounts(1,2) + combined_amount;
            }

            """, completionName: "combined_amount", partialName: "combined_am",
                signaturePrefix: "addAmounts(1,", signatureParameter: "int right", formattedInvocation: "addAmounts(1, 2)")
    ]

    private static func range(_ token: String, in text: String, options: NSString.CompareOptions = []) throws -> NSRange {
        let range = (text as NSString).range(of: token, options: options)
        guard range.location != NSNotFound else { throw Failure(detail: "find \(token) in fixture") }
        return range
    }

    private static func select(_ offset: Int, in editor: EditorTextView) {
        let selection = NSRange(location: offset, length: 0)
        editor.setCaretSelections([selection], record: false)
        editor.window?.layoutIfNeeded()
        editor.revealNavigationSelection(selection)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    private static func key(_ code: UInt16, _ character: String, in document: DocumentWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: document.window.windowNumber, context: nil, characters: character,
                                          charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else {
            throw Failure(detail: "create an isolated editor key event")
        }
        document.editor.keyDown(with: event)
    }

    private static func wait(_ detail: String, session: LanguageServerSession? = nil,
                             until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()) {
            if let failure = session?.failureReason { throw Failure(detail: "\(detail) (\(failure))") }
            if let session, session.state == .notOnPATH { throw Failure(detail: "\(session.server.name) is not on PATH") }
            guard ContinuousClock.now < deadline else {
                let context = session.map { " (\($0.server.name), \($0.state), root \($0.workspaceRoot?.path ?? "nil"))" } ?? ""
                throw Failure(detail: detail + context)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw Failure(detail: detail) }
    }
}
