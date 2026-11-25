import AppKit

@MainActor
enum LSPSemanticHighlightCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "LSP highlighting check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow, captureWindow: (NSWindow, String) throws -> Void,
                    captureControl: (NSView, String) throws -> Void) async throws {
        try checkTokenData()
        let files = FileManager.default
        let root = FileBuffer.canonicalURL(files.temporaryDirectory.appending(path: "LSP highlighting \(UUID())"))
        let otherRoot = root.appending(path: "other")
        try files.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let swiftWindow = app.makeDocument()
        let otherWindow = app.makeDocument()
        let windows = [document, swiftWindow, otherWindow]
        defer {
            for window in windows where app.documents.contains(where: { $0 === window }) { window.window.close() }
            try? files.removeItem(at: root)
        }
        try checkPreferences(root: root, other: otherRoot)
        let zig = root.appending(path: "Main.zig")
        let sources = root.appending(path: "Sources/Fixture")
        try files.createDirectory(at: sources, withIntermediateDirectories: true)
        let swift = sources.appending(path: "Widget.swift")
        let rust = root.appending(path: "Other.rs")
        let swiftText = "struct SwiftWidget {}\nfunc makeWidget() -> SwiftWidget { SwiftWidget() } // fixture\n"
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
            """
        try manifest.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "const label = \"🧩\"; pub const ZigWidget = struct {};\r\n".write(to: zig, atomically: true, encoding: .utf8)
        try swiftText.write(to: swift, atomically: true, encoding: .utf8)
        try "fn marker() -> i32 { 7 }\n".write(to: rust, atomically: true, encoding: .utf8)
        swiftWindow.setFolder(root)
        otherWindow.setFolder(otherRoot)
        try require(try await app.openFile(swift, in: swiftWindow) === swiftWindow, "open Swift")
        try await wait("show SourceKit-LSP tokens (\(swiftWindow.languageFeatures.session.state.title))") {
            hasSemanticColor("struct", in: swiftWindow)
        }
        try require(hasColor("// fixture", in: swiftWindow, color: .comment), "request Swift syntactic tokens from SourceKit-LSP")
        document.setFolder(root)
        try require(try await app.openFile(zig, in: document) === document, "open Zig")
        try await wait("show ZLS tokens after an astral character") { hasSemanticColor("ZigWidget", in: document) }

        document.performFind(.find)
        let control = ControlPanel(app: app)
        try control.checkToggleSwitches(in: document, enabled: true, clickLSP: true) { try captureControl($0, "switches-on") }
        try require(!swiftWindow.isLSPHighlightEnabled && otherWindow.isLSPHighlightEnabled,
                    "share the setting in one workspace only")
        try await wait("return to Tree-sitter in both windows") {
            [document, swiftWindow].allSatisfy {
                $0.editor.syntaxHighlighting?.usesLSPForCheck == false && $0.editor.syntaxHighlighting?.spansForCheck.isEmpty == false
            }
        }
        try require(document.languageFeatures.session.supportsDefinition && swiftWindow.languageFeatures.session.supportsDefinition,
                    "keep language-server navigation enabled with highlighting off")
        try control.checkToggleSwitches(in: document, enabled: false, clickLSP: true) { try captureControl($0, "switches-off") }
        try await wait("restore semantic colors in both windows") {
            hasSemanticColor("ZigWidget", in: document) && hasSemanticColor("struct", in: swiftWindow)
        }

        let editor = document.editor
        guard let highlighting = editor.syntaxHighlighting else { throw Failure(detail: "attach highlighting") }
        let (heldResult, release) = AsyncStream<Void>.makeStream()
        var responsePending = false
        highlighting.beforeInstallSemanticTokensForCheck = {
            responsePending = true
            for await _ in heldResult { break }
        }
        defer {
            highlighting.beforeInstallSemanticTokensForCheck = nil
            release.finish()
        }
        let outgoingTitle = document.window.title
        let start = ContinuousClock.now
        editor.insertText("pub const Added = struct {};\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait("receive an edited token result") { responsePending }
        try require(document.window.title == outgoingTitle && highlighting.spansForCheck.isEmpty == false,
                    "keep existing colors and the title while edited tokens are pending")
        try captureWindow(document.window, "pending")
        highlighting.beforeInstallSemanticTokensForCheck = nil
        release.finish()
        try await wait("paint the new semantic tokens") { hasSemanticColor("Added", in: document) }
        try require(document.window.title == outgoingTitle, "retain the title on the first colored frame")
        try captureWindow(document.window, "ready")
        print("LSP highlighting: edited Zig buffer painted in \(start.duration(to: .now)) including the held response.")

        let (heldOpen, finishOpen) = AsyncStream<Void>.makeStream()
        var openingPending = false
        document.beforeInstallFileForCheck = { incoming in
            guard incoming.url == rust else { return }
            openingPending = true
            for await _ in heldOpen { break }
        }
        let opening = Task { try await app.openFile(rust, in: document) }
        defer {
            document.beforeInstallFileForCheck = nil
            finishOpen.finish()
            opening.cancel()
        }
        try await wait("hold the incoming Rust buffer") { openingPending }
        try require(document.window.title == outgoingTitle && hasSemanticColor("Added", in: document),
                    "keep the outgoing buffer, colors and title while opening")
        finishOpen.finish()
        try require(try await opening.value === document, "open a file without an LSP")
        try require(document.window.title.hasSuffix("Other.rs") && !highlighting.usesLSPForCheck
                    && hasColor("marker", in: document, color: .function),
                    "show the incoming buffer, Tree-sitter colors and title together")
        for window in windows { window.window.close() }
        try await wait("stop fixture language servers before discarding the profile") {
            windows.allSatisfy { $0.languageFeatures.serversStoppedForCheck }
        }
    }

    private static func hasSemanticColor(_ token: String, in document: DocumentWindow) -> Bool {
        document.editor.syntaxHighlighting?.usesLSPForCheck == true && hasColor(token, in: document)
    }

    private static func hasColor(_ token: String, in document: DocumentWindow, color: SyntaxColor? = nil) -> Bool {
        let range = (document.editor.string as NSString).range(of: token)
        return document.editor.syntaxHighlighting?.spansForCheck.contains {
            $0.start == range.location && $0.end == range.upperBound && (color == nil || $0.color == color)
        } == true
    }

    private static func checkPreferences(root: URL, other: URL) throws {
        let suite = "dev.edit-swift.lsp-highlighting.check.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(detail: "create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkspaceLSPHighlighting(defaults: defaults)
        try require(preferences.isEnabled(in: root), "default to enabled")
        preferences.setEnabled(false, in: root)
        let reopened = WorkspaceLSPHighlighting(defaults: defaults)
        try require(!reopened.isEnabled(in: root) && reopened.isEnabled(in: other), "restore the workspace setting")
    }

    private static func checkTokenData() throws {
        let options = try JSONDecoder().decode(LSPSemanticTokenOptions.self, from: Data(
            #"{"legend":{"tokenTypes":[],"tokenModifiers":[]},"full":{"delta":true},"range":false}"#.utf8
        ))
        try require(options.full && options.delta && !options.range, "honor advertised semantic tokens request modes")
        let legend = LSPSemanticTokenOptions.Legend(tokenTypes: ["type", "variable"], tokenModifiers: ["readonly"])
        let tokens = LSPSemanticTokens(resultID: "one", data: [0, 2, 3, 0, 0, 1, 0, 20, 1, 1])
        let delta = LSPSemanticTokens.Response(resultId: "two", data: nil, edits: [
            .init(start: 9, deleteCount: 1, data: [0]), .init(start: 1, deleteCount: 1, data: [3])
        ])
        let index = LSPTextIndex("🧩 Type\r\nother\r\n")
        let spans = try delta.tokens(updating: tokens).spans(in: index, legend: legend)
        try require(spans.count == 1 && spans[0].start == 3 && spans[0].end == 6 && spans[0].color == .type,
                    "apply unordered deltas with UTF-16 and CRLF")
        let invalid = LSPSemanticTokens.Response(resultId: "invalid", data: nil, edits: [
            .init(start: 0, deleteCount: 11, data: nil)
        ])
        do {
            _ = try invalid.tokens(updating: tokens)
            throw Failure(detail: "reject a delta outside the previous token data")
        } catch LSPFailure.invalidMessage {}
    }

    private static func wait(_ detail: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            try require(ContinuousClock.now < deadline, detail)
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func require(_ succeeded: Bool, _ detail: String) throws {
        if !succeeded { throw Failure(detail: detail) }
    }
}
