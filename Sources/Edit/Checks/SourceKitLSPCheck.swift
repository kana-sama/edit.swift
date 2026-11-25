import AppKit

@MainActor
enum SourceKitLSPCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "SourceKit-LSP check: \(detail)" }
    }

    static func checkCFamily(in app: Edit, document: DocumentWindow, capture: (NSWindow, String?) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "C family \(UUID().uuidString)", directoryHint: .isDirectory)
        let root = FileBuffer.canonicalURL(folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let samples: [(String, SyntaxLanguage, String)] = [
            ("Sample.c", .c, "int entry(void) { int fixtureValue = 7; return fixtureValue; }\n"),
            ("Sample.cpp", .cpp, "namespace demo { constexpr int fixtureValue = 7; }\nint entry() { return demo::fixtureValue; }\n"),
            ("Sample.m", .objectiveC, """
                __attribute__((objc_root_class))
                @interface Widget
                + (int)fixtureValue;
                @end
                int entry(void) { return [Widget fixtureValue]; }
                """),
            ("Sample.mm", .objectiveCPP, """
                __attribute__((objc_root_class))
                @interface Widget
                + (int)value;
                @end
                namespace demo {
                    template <typename T> T fixtureValue(T value) { return value; }
                }
                int entry() { return demo::fixtureValue([Widget value]); }
                """),
        ]
        var commands: [[String: Any]] = []
        for (name, _, text) in samples {
            let file = root.appending(path: name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            commands.append(["file": file.path, "directory": root.path, "arguments": ["/usr/bin/clang", "-c", file.path]])
        }
        let looseRoot = LanguageServer.sourceKit.projectRoot(in: root, activeFile: nil, previousRoot: nil, searchesParents: false)
        try require(looseRoot?.path == root.path,
                    "discover loose C-family sources without a Swift file or build manifest")
        try JSONSerialization.data(withJSONObject: commands).write(to: root.appending(path: "compile_commands.json"))
        document.setFolder(root)

        let lsp = document.languageFeatures
        var generation: Int?
        for (name, mode, text) in samples {
            let file = root.appending(path: name)
            if mode == .objectiveCPP {
                let window = document.window
                let outgoingTitle = window.title
                let outgoingText = document.editor.string
                let (pending, release) = AsyncStream<Void>.makeStream()
                var staged = false
                document.beforeInstallFileForCheck = { incoming in
                    guard incoming.url == file else { return }
                    staged = true
                    for await _ in pending { break }
                }
                let opening = Task { try await app.openFile(file, in: document) }
                defer {
                    document.beforeInstallFileForCheck = nil
                    release.finish()
                    opening.cancel()
                }
                try await wait("hold the Objective-C++ source before installation") { staged }
                try require(window.title == outgoingTitle && document.editor.string == outgoingText,
                            "keep the previous Objective-C file and title while Objective-C++ is pending")
                try capture(window, "pending")
                release.finish()
                try require(try await opening.value === document, "open \(name)")
                try require(window.title.hasSuffix(name) && document.editor.string == text,
                            "show the Objective-C++ text and title together in the first frame")
                try capture(window, nil)
            } else {
                try require(try await app.openFile(file, in: document) === document, "open \(name)")
            }
            let session = lsp.session
            try require(document.resolvedSyntaxLanguage == mode && session.server == .sourceKit, "route \(name) to SourceKit-LSP")
            try await wait("initialize SourceKit-LSP for \(name)") { session.supportsDefinition }
            try require(session.workspaceRoot?.path == root.path, "use the compilation database for \(name)")
            try require(generation == nil || generation == session.generation, "reuse SourceKit-LSP across C-family modes")
            generation = session.generation

            let use = (text as NSString).range(of: "fixtureValue", options: .backwards)
            let declaration = (text as NSString).range(of: "fixtureValue")
            let offset = use.location + 2
            let index = LSPTextIndex(text)
            try await wait("find the \(name) definition") {
                let results = try? await session.definition(at: offset)
                return results?.contains { $0.url == file && index.nsRange($0.range)?.location == declaration.location } == true
            }
            let hover = await lsp.hover(at: offset, word: use)
            try require(hover?.text.contains("fixtureValue") == true, "show the \(name) hover")
            let symbols = try await session.documentSymbols()
            try require(symbols.contains(where: { $0.name == "entry" }), "show the \(name) document symbols")
            if mode == .c {
                let editor = document.editor
                document.window.makeFirstResponder(editor)
                editor.setCaretSelections([NSRange(location: offset, length: 0)], record: false)
                try require(editor.onRenameSymbol?() == true, "start inline C rename")
                try await wait("select the C identifier") { editor.renameRange == use }
                editor.insertText("newValue", replacementRange: editor.selectedRange())
                editor.onSubmitSymbolRename?()
                try await wait("rename both C occurrences") {
                    editor.renameRange == nil && editor.string == text.replacingOccurrences(of: "fixtureValue", with: "newValue")
                }
                let revision = session.revision
                document.setSyntaxLanguage(.cpp)
                try require(session.revision != revision && session.generation == generation,
                            "resynchronize the same file when its language mode changes")
                let renamed = (editor.string as NSString).range(of: "newValue", options: .backwards)
                let updatedHover = await lsp.hover(at: renamed.location + 2, word: renamed)
                try require(updatedHover?.text.contains("newValue") == true, "synchronize unsaved text after changing mode")
            }
        }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSView, String) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Swift fixture \(UUID().uuidString)", directoryHint: .isDirectory)
        let root = FileBuffer.canonicalURL(folder)
        let sources = root.appending(path: "Sources/Fixture", directoryHint: .isDirectory)
        let config = root.appending(path: ".sourcekit-lsp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
            """
        let mainText = """
            struct Caller {
                func run() -> Int { let emoji = "👋"; return identify(label: emoji.count) + identify(label: 1) }
            }
            """
        let helperText = """
            /// Returns the supplied value.
            func identify(label: Int) -> Int { label }
            struct SwiftFixtureType {}
            """
        let otherText = "func other() -> Int { identify(label: 2) }\n"
        let main = sources.appending(path: "Caller.swift")
        let helper = sources.appending(path: "Helper.swift")
        let other = sources.appending(path: "Other.swift")
        let notes = root.appending(path: "Notes.txt")
        for (url, text) in [
            (main, mainText), (helper, helperText), (other, otherText), (notes, "Notes"),
            (root.appending(path: "Package.swift"), manifest),
            (root.appending(path: "sample.zig"), "pub fn zigFixture() void {}\n"),
            (config.appending(path: "config.json"), #"{"backgroundIndexing":true,"workDoneProgressDebounceDuration":0}"#),
        ] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        let lsp = document.languageFeatures
        document.setFolder(root)
        try require(try await app.openFile(main, in: document) === document, "open the Swift source")
        let swift = lsp.session
        try require(swift.server == .sourceKit, "route Swift buffers to SourceKit-LSP")
        var sawProgress = false
        let updateProgress = swift.onProgressChange
        swift.onProgressChange = {
            updateProgress?()
            if !swift.progress.isEmpty, lsp.statusIndicatorForCheck == .busy { sawProgress = true }
        }
        defer { swift.onProgressChange = updateProgress }
        try await wait("initialize SourceKit-LSP") { swift.supportsDefinition }
        try require(swift.workspaceRoot?.path == root.path, "use the package root (\(swift.workspaceRoot?.path ?? "none"))")
        try require(swift.supportsHover && swift.supportsReferences &&
                    swift.supportsDocumentSymbols && swift.supportsWorkspaceSymbols &&
                    swift.supportsDocumentHighlight && swift.supportsRename, "expose the supported commands")

        let use = (mainText as NSString).range(of: "identify")
        let offset = use.location + 2
        try await wait("index package symbols") {
            let symbols = try? await swift.workspaceSymbols(query: "SwiftFixtureType")
            return symbols?.contains(where: { $0.name == "SwiftFixtureType" }) == true
        }
        try require(sawProgress, "show SourceKit-LSP indexing progress in the header")
        let tokens = try await swift.semanticTokens()
        try require(tokens?.contains { $0.start == use.location && $0.end == use.upperBound && $0.color == .function } == true,
                    "decode a Swift function reference from semantic tokens")
        try require(await lsp.probe(at: offset, word: use) == use, "underline a Swift definition link across a UTF-16 offset")
        let hover = await lsp.hover(at: offset, word: use)
        try require(hover?.text.contains("Returns the supplied value.") == true, "show Swift hover documentation")
        let highlights = await lsp.documentHighlights(at: offset)
        try require(highlights.contains(use) && highlights.count >= 2, "highlight matching Swift symbols")
        lsp.followLink(at: offset, word: use)
        try await wait("follow the definition into another file") { document.fileURL == helper }
        try require(document.editor.selectedRange().location == (helperText as NSString).range(of: "identify").location,
                    "place the caret at the Swift definition")
        await app.navigate(.back)
        try await wait("return to the caller") { document.fileURL == main && swift.supportsDefinition }

        let hit = EditorLanguageInteraction.Hit(offset: offset, word: use)
        try performMenu("Go to Definition", at: hit, in: document)
        try await wait("follow Swift Go to Definition") { document.fileURL == helper }
        await app.navigate(.back)
        try await wait("return to the caller after context-menu navigation") { document.fileURL == main && swift.supportsDefinition }
        try performMenu("Find References", at: hit, in: document)
        try await wait("show grouped cross-file references") { document.isSidebarVisible && document.sidebarMode == .references }
        if let view = document.window.contentView {
            document.window.layoutIfNeeded()
            try capture(view, "references")
        }
        try require(try await app.openFile(main, in: document) === document, "return to Swift source to browse symbols")
        try await wait("synchronize the Swift source") { swift.supportsDocumentSymbols }
        try await ControlPanel(app: app).checkSymbols(in: document, documentSymbol: "Caller", workspaceSymbol: "SwiftFixtureType",
                                                       workspaceFile: helper, workspaceSource: notes, capture: capture)
        try await wait("synchronize the source before rename") { swift.supportsRename }
        let editor = document.editor
        document.window.makeFirstResponder(editor)
        editor.setCaretSelections([NSRange(location: offset, length: 0)], record: false)
        try require(editor.onRenameSymbol?() == true, "start inline Swift rename")
        try await wait("select the Swift function base name") { editor.renameRange == use }
        editor.insertText("renamed", replacementRange: editor.selectedRange())
        editor.onSubmitSymbolRename?()
        try await wait("apply Swift rename across the package") {
            editor.renameRange == nil && editor.string.contains("renamed(label:")
        }
        try require(editor.string == mainText.replacingOccurrences(of: "identify", with: "renamed") &&
                    String(contentsOf: helper, encoding: .utf8) == helperText.replacingOccurrences(of: "identify", with: "renamed") &&
                    String(contentsOf: other, encoding: .utf8) == otherText.replacingOccurrences(of: "identify", with: "renamed"),
                    "rename the symbol in the open buffer and both closed files, with labels intact")
        let added = sources.appending(path: "Added.swift")
        try "struct NewlyIndexedSwiftType {}\n".write(to: added, atomically: true, encoding: .utf8)
        try await wait("index a Swift source created after the server started") {
            let symbols = try? await swift.workspaceSymbols(query: "NewlyIndexedSwiftType")
            return symbols?.contains(where: { $0.name == "NewlyIndexedSwiftType" }) == true
        }

        guard let stack = lsp.statusPopoverForCheck as? NSStackView else { throw Failure(detail: "get the native server popover") }
        let rows = stack.arrangedSubviews
        try require(rows.map { $0.accessibilityLabel() } == ["ZLS", "SourceKit-LSP"], "show both servers in the mixed folder")
        let zigState = rows[0].subviews.compactMap { $0 as? NSStackView }.first?.views.last as? NSTextField
        let zigStatus = zigState?.stringValue
        let window = NSWindow(contentRect: stack.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = stack
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        try capture(stack, "servers")
        let logos = rows.compactMap { row in
            row.subviews.first(where: { $0.identifier?.rawValue == "Edit.LanguageServer.logo" }) as? NSImageView
        }
        let identities = rows.compactMap { $0.subviews.compactMap { $0 as? NSStackView }.first }
        guard logos.count == 2, identities.count == 2, let zigLogo = logos[0].image, let sourceKitLogo = logos[1].image else {
            throw Failure(detail: "load the ZLS wordmark and the paired SourceKit-LSP artwork")
        }
        let slot = logos[0].frame
        let logoHeight = identities[0].frame.height / 2
        let scaledLogoWidth = logoHeight * zigLogo.size.width / zigLogo.size.height
        try require(slot.size == logos[1].frame.size && slot.width > 3 * slot.height &&
                    abs(slot.height - logoHeight) < 1 && abs(slot.width - scaledLogoWidth) < 1 &&
                    abs(slot.midY - identities[0].frame.midY) < 0.5 &&
                    identities[0].frame.minX == identities[1].frame.minX &&
                    logos.allSatisfy { $0.imageAlignment == .alignCenter && $0.imageScaling == .scaleProportionallyUpOrDown } &&
                    sourceKitLogo.size.width > 2 * sourceKitLogo.size.height,
                    "size both logo slots to half the two-line label (logos \(logos.map(\.frame)), labels \(identities.map(\.frame)))")
        guard let toggle = rows[1].subviews.first(where: { $0.identifier?.rawValue == "Edit.LanguageServer.toggle" }) as? NSButton,
              let restart = rows[1].subviews.first(where: { $0.identifier?.rawValue == "Edit.LanguageServer.restart" }) as? NSButton
        else { throw Failure(detail: "find the Swift controls") }
        toggle.performClick(nil)
        try await wait("stop SourceKit-LSP independently") { swift.state == .stopped }
        try require(zigState?.stringValue == zigStatus && !swift.supportsHover, "leave ZLS running independently")
        toggle.performClick(nil)
        try await wait("start SourceKit-LSP again") { swift.supportsHover }
        let generation = swift.generation
        restart.performClick(nil)
        try await wait("restart SourceKit-LSP with the unsaved buffer") { swift.generation != generation && swift.supportsHover }
        let renamed = (editor.string as NSString).range(of: "renamed")
        try require((await lsp.hover(at: renamed.location + 1, word: renamed)) != nil, "use unsaved Swift text after restart")
    }

    private static func performMenu(_ title: String, at hit: EditorLanguageInteraction.Hit, in document: DocumentWindow) throws {
        guard let item = document.editor.languageContextItems?(hit).first(where: { $0.title == title }),
              let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
            throw Failure(detail: "invoke \(title) from the Swift symbol menu")
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail: detail) }
    }

    private static func wait(_ detail: String, until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
