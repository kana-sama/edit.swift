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
        print("LSP editing passed for \(label) with \(session.server.name).")
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
