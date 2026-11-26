import AppKit

@MainActor
enum OdinLSPCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "OLS check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Odin # ? café \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileBuffer.canonicalURL(folder)
        let sources = root.appending(path: "src", directoryHint: .isDirectory)
        let main = sources.appending(path: "main.odin")
        let helper = sources.appending(path: "helper.odin")
        let config = root.appending(path: "ols.json")
        let text = """
            package fixture
            main :: proc() {
                label := "🦜"; result := double_value(2)
                _ = label
                _ = result
            }

            """
        let declaration = """
            package fixture
            // Doubles a value.
            double_value :: proc(value: int) -> int { return value * 2 }

            """
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        try text.write(to: main, atomically: true, encoding: .utf8)
        try declaration.write(to: helper, atomically: true, encoding: .utf8)
        try #"{"enable_checker":false}"#.write(to: config, atomically: true, encoding: .utf8)

        let looseRoot = LanguageServer.odin.projectRoot(in: sources, activeFile: main, previousRoot: nil, searchesParents: true)
        try require(looseRoot?.path == root.path,
                    "resolve the enclosing ols.json when opening a loose document (got \(looseRoot?.path ?? "nil"), expected \(root.path))")
        document.setFolder(root)
        try require(try await app.openFile(main, in: document) === document, "open Odin source in the test window")
        let lsp = document.languageFeatures
        let session = lsp.session
        try require(session.server == .odin && document.resolvedSyntaxLanguage == .odin, "route Odin to OLS")
        try await wait("start OLS from PATH", session: session) { session.state == .ready }
        try require(session.workspaceRoot?.path == root.path && lsp.statusIndicatorForCheck == .ready,
                    "use the ols.json project and show OLS as ready")
        let generation = session.generation
        let editor = document.editor

        let use = (text as NSString).range(of: "double_value")
        let declarationName = (declaration as NSString).range(of: "double_value")
        let offset = use.location + 2
        let locations = try await session.definition(at: offset)
        try require(locations.count == 1 && locations.first?.url.path == helper.path
                    && locations.first?.range.nsRange(in: declaration) == declarationName,
                    "resolve the cross-file definition through a path with reserved characters")
        let hover = await lsp.hover(at: offset, word: use)
        try require(hover?.text.contains("Doubles a value.") == true && hover?.range == use,
                    "show the OLS hover and interpret its UTF-16 range after an emoji")
        let references = try await session.references(at: offset, includeDeclaration: true)
        let referencePaths = Set(references.map { $0.url.path })
        try require(referencePaths == [main.path, helper.path],
                    "find the reference and declaration with decoded paths (got \(referencePaths.sorted()))")
        try require(await lsp.documentHighlights(at: offset) == [use], "highlight occurrences at the correct UTF-16 offsets")
        try require(try await session.documentSymbols().contains { $0.name == "main" }, "list document symbols")
        try require(try await lsp.workspaceSymbols(query: "double_value").contains {
            $0.name == "double_value" && $0.location.url.path == helper.path
        }, "include OLS results in workspace symbol search")

        let unsaved = "\nunsaved_only :: 4\n"
        editor.insertText(unsaved, replacementRange: NSRange(location: text.utf16.count, length: 0))
        try require(try await session.documentSymbols().contains { $0.name == "unsaved_only" }
                    && String(contentsOf: main, encoding: .utf8) == text,
                    "query an unsaved declaration before it reaches disk")
        editor.undoManager?.undo()
        try require(editor.string == text, "restore the caller before testing navigation")

        document.toggleHighlighting(.treeSitter)
        document.window.layoutIfNeeded()
        try await wait("receive OLS semantic colors", session: session) {
            editor.syntaxHighlighting?.semanticSpansForCheck.contains {
                $0.range == use && $0.color == .function
            } == true
        }
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try SyntaxCheck.requireGlyphColors(in: use, document: document, expected: .function)
        document.toggleHighlighting(.treeSitter)

        let title = document.window.title
        let (pending, release) = AsyncStream<Void>.makeStream()
        var staged = false
        document.beforeInstallFileForCheck = { file in
            guard file.url.path == helper.path else { return }
            staged = true
            for await _ in pending { break }
        }
        defer {
            release.finish()
            document.beforeInstallFileForCheck = nil
        }
        lsp.followLink(at: offset, word: use)
        try await wait("hold the OLS definition destination before installation") { staged }
        try require(document.window.title == title && editor.string == text, "keep the source text and title together")
        release.finish()
        try await wait("open the OLS definition") { document.fileURL?.path == helper.path }
        try require(document.window.title.hasSuffix("helper.odin") && editor.string == declaration
                    && editor.selectedRange().location == declarationName.location,
                    "install the destination title and text together and select its definition")
        document.beforeInstallFileForCheck = nil
        try require(try await app.openFile(main, in: document) === document, "return to the caller")
        try require(session.generation == generation, "reuse OLS when switching files in the same project")

        editor.setCaretSelections([NSRange(location: offset, length: 0)], record: false)
        document.window.makeFirstResponder(editor)
        try require(editor.onRenameSymbol?() == true, "start OLS Rename Symbol")
        try await wait("select the name returned by prepareRename") { editor.renameRange == use }
        editor.insertText("twice", replacementRange: editor.selectedRange())
        editor.onSubmitSymbolRename?()
        try await wait("apply OLS edits to the open buffer and the closed file") {
            editor.renameRange == nil && editor.string == text.replacingOccurrences(of: "double_value", with: "twice")
                && (try? String(contentsOf: helper, encoding: .utf8)) == declaration.replacingOccurrences(of: "double_value", with: "twice")
        }
        let renamedUse = (editor.string as NSString).range(of: "twice")
        try await wait("resolve the renamed symbol after the index update") {
            await lsp.hover(at: renamedUse.location + 1, word: renamedUse)?.text.contains("twice") == true
        }
        let updatedHelper = declaration.replacingOccurrences(of: "double_value", with: "twice")
            .replacingOccurrences(of: "Doubles a value.", with: "Updated on disk.")
        try updatedHelper.write(to: helper, atomically: true, encoding: .utf8)
        try await wait("refresh OLS after modifying a closed Odin file") {
            await lsp.hover(at: renamedUse.location + 1, word: renamedUse)?.text.contains("Updated on disk.") == true
        }

        lsp.perform(.stop)
        try await wait("stop OLS") { session.state == .stopped }
        try require(app.workspaceLanguageServers.isStopped(.odin, in: root)
                    && !app.workspaceLanguageServers.isStopped(.zig, in: root)
                    && !app.workspaceLanguageServers.isStopped(.sourceKit, in: root),
                    "save the stop preference for OLS only")
        try #"{"enable_checker":false,"enable_semantic_tokens":false}"#.write(to: config, atomically: true, encoding: .utf8)
        lsp.perform(.restart)
        try await wait("restart OLS with the updated config", session: session) { session.state == .ready }
        try require(session.supportsHover && !session.supportsSemanticTokens
                    && !app.workspaceLanguageServers.isStopped(.odin, in: root),
                    "respect the project's semantic token setting and clear the stopped preference")
        try require(!document.window.isVisible && document.window.alphaValue == 0 && !NSApp.isActive,
                    "keep the isolated OLS check hidden")
    }

    private static func wait(_ detail: String, session: LanguageServerSession? = nil,
                             until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            if let session, let failure = session.failureReason {
                throw Failure(detail: "\(detail) (\(failure))")
            }
            if session?.state == .notOnPATH { throw Failure(detail: "ols is not on PATH") }
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw Failure(detail: detail) }
    }
}
