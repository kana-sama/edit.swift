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
        let typingWindow = app.makeDocument()
        let windows = [document, swiftWindow, otherWindow, typingWindow]
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
        let zigText = "pub const none: ?u64 = null;\r\nconst label = \"🧩\"; pub const ZigWidget = struct {};\r\n"
            + "pub const WidgetAlias = ZigWidget;\r\npub var Counter: u64 = 3;\r\nconst wordSize = @sizeOf(u64);\r\n"
        try zigText.write(to: zig, atomically: true, encoding: .utf8)
        try swiftText.write(to: swift, atomically: true, encoding: .utf8)
        try "fn marker() -> i32 { 7 }\n".write(to: rust, atomically: true, encoding: .utf8)
        swiftWindow.setFolder(root)
        otherWindow.setFolder(otherRoot)
        try require(try await app.openFile(swift, in: swiftWindow) === swiftWindow, "open Swift")
        try await wait("show SourceKit-LSP tokens (\(swiftWindow.languageFeatures.session.state.title))") {
            hasSemanticColor("struct", in: swiftWindow)
        }
        try require(hasColor("// fixture", in: swiftWindow, layer: .lsp, color: .comment),
                    "request Swift syntactic tokens from SourceKit-LSP")
        document.setFolder(root)
        try require(try await app.openFile(zig, in: document) === document, "open Zig")
        try await wait("show ZLS tokens after an astral character") { hasSemanticColor("ZigWidget", in: document) }
        try await wait("use the same keyword literal color in both layers") {
            hasColor("null", in: document, color: .control) && hasColor("null", in: document, layer: .lsp, color: .control)
                && paintedColor("null", in: document) == SyntaxColor.control.nativeColor
        }
        try require(hasColor("@sizeOf", in: document, color: .function) && hasColor("@sizeOf", in: document, layer: .lsp, color: .function)
                    && paintedColor("@sizeOf", in: document) == SyntaxColor.function.nativeColor,
                    "use the same built-in function color in both layers")
        try require(hasColor("ZigWidget", in: document, color: .type) && hasColor("ZigWidget", in: document, layer: .lsp, color: .type)
                    && paintedColor("ZigWidget", in: document) == SyntaxColor.type.nativeColor,
                    "use the same type color for a direct container declaration")
        try require(!hasColor("Counter", in: document) && hasColor("Counter", in: document, layer: .lsp, color: .plain)
                    && paintedColor("Counter", in: document) == .textColor &&
                    !hasColor("WidgetAlias", in: document) && paintedColor("WidgetAlias", in: document) == SyntaxColor.type.nativeColor,
                    "let ZLS classify ambiguous declarations while Tree-sitter paints syntax")

        document.performFind(.find)
        let control = ControlPanel(app: app)
        try control.checkToggleSwitches(in: document, lspEnabled: true, treeEnabled: true, click: .lsp) {
            try captureControl($0, "switches-on")
        }
        try require(!swiftWindow.isHighlightingEnabled(.lsp) && otherWindow.isHighlightingEnabled(.lsp),
                    "share the setting in one workspace only")
        try require(paintedColor("null", in: document) == SyntaxColor.control.nativeColor,
                    "keep the literal color when removing the semantic overlay")
        try require(paintedColor("@sizeOf", in: document) == SyntaxColor.function.nativeColor,
                    "keep the built-in function color when removing the semantic overlay")
        try require(paintedColor("ZigWidget", in: document) == SyntaxColor.type.nativeColor
                    && paintedColor("WidgetAlias", in: document) == .textColor,
                    "keep the direct type declaration colored and leave the alias to ZLS")
        try await wait("keep Tree-sitter in both windows") {
            [document, swiftWindow].allSatisfy {
                $0.editor.syntaxHighlighting?.usesLSPForCheck == false
                    && $0.editor.syntaxHighlighting?.treeSpansForCheck.isEmpty == false
            }
        }
        try require(document.languageFeatures.session.supportsDefinition && swiftWindow.languageFeatures.session.supportsDefinition,
                    "keep language-server navigation enabled with highlighting off")
        try control.checkToggleSwitches(in: document, lspEnabled: false, treeEnabled: true, click: .treeSitter) {
            try captureControl($0, "switches-lsp-off")
        }
        try require(!swiftWindow.isHighlightingEnabled(.treeSitter) && otherWindow.isHighlightingEnabled(.treeSitter)
                    && paintedColor("null", in: document) == .textColor,
                    "turn off both layers only in the current workspace")
        try control.checkToggleSwitches(in: document, lspEnabled: false, treeEnabled: false, click: .lsp) {
            try captureControl($0, "switches-both-off")
        }
        try await wait("restore semantic colors in both windows") {
            hasSemanticColor("ZigWidget", in: document) && hasSemanticColor("struct", in: swiftWindow)
        }
        try require(document.editor.syntaxHighlighting?.treeSpansForCheck.isEmpty == true
                    && paintedColor("null", in: document) == SyntaxColor.control.nativeColor,
                    "draw only the LSP layer when Tree-sitter is off")
        try control.checkToggleSwitches(in: document, lspEnabled: true, treeEnabled: false, click: .treeSitter) {
            try captureControl($0, "switches-tree-off")
        }
        try await wait("restore Tree-sitter under the unchanged overlay") {
            hasColor("null", in: document, color: .control) && paintedColor("null", in: document) == SyntaxColor.control.nativeColor
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
        try await Task.sleep(for: .milliseconds(450))
        try require(document.window.title == outgoingTitle && hasColor("null", in: document, color: .control)
                    && hasColor("null", in: document, layer: .lsp, color: .control)
                    && paintedColor("null", in: document) == SyntaxColor.control.nativeColor,
                    "keep both layers and the title while a replacement overlay is held")
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
        try await checkWholeTokens(in: app, document: typingWindow, folder: root.appending(path: "typing"),
                                   capture: captureWindow)
        try await checkViewportPreview(in: app, document: document, folder: root, capture: captureWindow)
        for window in windows { window.window.close() }
        try await wait("stop fixture language servers before discarding the profile") {
            windows.allSatisfy { $0.languageFeatures.serversStoppedForCheck }
        }
    }

    private static func hasSemanticColor(_ token: String, in document: DocumentWindow) -> Bool {
        hasColor(token, in: document, layer: .lsp)
    }

    private static func hasColor(_ token: String, in document: DocumentWindow, layer: HighlightingLayer = .treeSitter,
                                 color: SyntaxColor? = nil) -> Bool {
        let range = (document.editor.string as NSString).range(of: token)
        guard let syntax = document.editor.syntaxHighlighting, range.location != NSNotFound else { return false }
        let spans = layer == .lsp ? syntax.semanticSpansForCheck : syntax.treeSpansForCheck
        return spans.contains {
            $0.start == range.location && $0.end == range.upperBound && (color == nil || $0.color == color)
        }
    }

    private static func paintedColor(_ token: String, in document: DocumentWindow) -> NSColor? {
        let editor = document.editor
        let range = (editor.string as NSString).range(of: token)
        guard range.location != NSNotFound else { return nil }
        return editor.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private static func checkWholeTokens(in app: Edit, document: DocumentWindow, folder: URL,
                                         capture: (NSWindow, String) throws -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Typing.zig")
        let source = "pub const Stable = struct {};\ntest \"typing\" {\n"
            + String(repeating: "    return error.Other;\n", count: 4) + "    return erro;\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        document.setFolder(folder)
        let window = document.window
        window.appearance = NSAppearance(named: .darkAqua)
        try require(try await app.openFile(file, in: document) === document, "open a Zig typing fixture")
        window.layoutIfNeeded()
        let editor = document.editor
        guard let highlighting = editor.syntaxHighlighting else { throw Failure(detail: "attach typing highlighting") }
        let prefix = (source as NSString).range(of: "erro", options: .backwards)
        try await wait("classify the incomplete identifier with ZLS") {
            highlighting.semanticSpansForCheck.contains { $0.range == prefix && $0.color == .plain }
                && hasSemanticColor("Stable", in: document)
        }

        var holdTree = true
        var holdSemantic = true
        var heldTree = 0
        var heldSemantic = 0
        highlighting.beforeInstallTreeTokensForCheck = {
            heldTree += 1
            defer { heldTree -= 1 }
            while holdTree && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        highlighting.beforeInstallSemanticTokensForCheck = {
            heldSemantic += 1
            defer { heldSemantic -= 1 }
            while holdSemantic && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        defer {
            holdTree = false
            holdSemantic = false
            highlighting.beforeInstallTreeTokensForCheck = nil
            highlighting.beforeInstallSemanticTokensForCheck = nil
        }
        let title = window.title
        editor.setSelectedRange(NSRange(location: prefix.upperBound, length: 0))
        editor.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))
        let keyword = NSRange(location: prefix.location, length: 5)
        try require(highlighting.semanticSpansForCheck.contains { $0.range == keyword && $0.color == .plain && $0.provisional },
                    "keep the old variable color over all five glyphs while both results are pending")
        try require(hasSemanticColor("Other", in: document), "preserve an unaffected semantic token beside the edit")
        try requireGlyphColors(in: keyword, document: document, expected: .plain)
        try capture(window, "keyword-first")
        try await wait("hold both results for the new keyword") { heldTree > 0 && heldSemantic > 0 }
        try requireGlyphColors(in: keyword, document: document, expected: .plain)
        holdTree = false
        try await wait("use Tree-sitter's keyword color while the semantic update is held") {
            highlighting.treeSpansForCheck.contains { $0.range == keyword && $0.color == .keyword }
        }
        try require(window.title == title, "preserve the title while the response is held")
        try require(!highlighting.semanticSpansForCheck.contains { NSIntersectionRange($0.range, keyword).length > 0 },
                    "replace the provisional semantic color even when the ranges match")
        try requireGlyphColors(in: keyword, document: document, expected: .keyword)
        try capture(window, "keyword-tree")

        holdSemantic = false
        try await wait("finish installing the semantic response") { !highlighting.needsFullSemanticTokensForCheck }
        try requireGlyphColors(in: keyword, document: document, expected: .keyword)
        try capture(window, "keyword-settled")

        let dot = NSRange(location: keyword.upperBound, length: 1)
        for (index, character) in ".Hello".enumerated() {
            holdTree = true
            holdSemantic = true
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            let tag = NSRange(location: dot.upperBound, length: index)
            let suffix = String(".Hello".prefix(index + 1))
            let typed = NSRange(location: dot.location, length: suffix.utf16.count)
            try require((editor.string as NSString).substring(with: typed) == suffix, "type \(suffix) at the end of the keyword")

            func verifyFrame(tagColor: SyntaxColor, phase: String) throws {
                try requireGlyphColors(in: keyword, document: document, expected: .keyword)
                try requireGlyphColors(in: dot, document: document, expected: .plain)
                if tag.length > 0 { try requireGlyphColors(in: tag, document: document, expected: tagColor) }
                try capture(window, "typing-\(index + 1)-\(phase)")
            }
            let firstColor: SyntaxColor = index > 1 ? .type : .plain
            try verifyFrame(tagColor: firstColor, phase: "first")
            try await wait("hold both results for \(suffix)") { heldTree > 0 && heldSemantic > 0 }
            try verifyFrame(tagColor: firstColor, phase: "held")

            holdTree = false
            try await wait("show the current Tree-sitter colors for \(suffix)") {
                heldTree == 0 && (tag.length == 0 || highlighting.treeSpansForCheck.contains {
                    $0.range == tag && $0.color == .type && !$0.provisional
                })
            }
            try verifyFrame(tagColor: .type, phase: "tree")

            holdSemantic = false
            try await wait("finish applying the semantic response for \(suffix)") { !highlighting.needsFullSemanticTokensForCheck }
            try verifyFrame(tagColor: .type, phase: "settled")
        }

        document.toggleHighlighting(.lsp)
        holdTree = true
        for (index, character) in "Ab".enumerated() {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            let tag = NSRange(location: dot.upperBound, length: "Hello".utf16.count + index + 1)
            try requireGlyphColors(in: keyword, document: document, expected: .keyword)
            try requireGlyphColors(in: tag, document: document, expected: .type)
        }
        try await wait("hold the Tree-sitter result after successive keystrokes") { heldTree > 0 }
        holdTree = false
        try await wait("finish the Tree-sitter update with semantic colors off") { heldTree == 0 }

        // Deleting the separator joins two colored keywords. Clear both in the first frame.
        let separator = NSRange(location: prefix.location - 1, length: 1)
        editor.setSelectedRange(separator)
        editor.deleteBackward(nil)
        let joined = NSRange(location: prefix.location - 7, length: 11)
        try require((editor.string as NSString).substring(with: joined) == "returnerror", "join the two keywords")
        try capture(window, "whole-token-joined")
        try requireGlyphColors(in: joined, document: document, expected: .plain)

        let returnKeyword = NSRange(location: joined.location, length: 6)
        document.toggleHighlighting(.lsp)

        func setLine(_ content: String) async throws {
            let text = editor.string as NSString
            let line = LineEditing.line(at: returnKeyword.location, in: text)
            let range = NSRange(location: returnKeyword.location, length: line.contentEnd - returnKeyword.location)
            editor.insertText(content, replacementRange: range)
            try await wait("prepare the separator fixture \(content)") {
                !highlighting.needsFullSemanticTokensForCheck && highlighting.treeSpansForCheck.contains {
                    $0.range == returnKeyword && $0.color == .keyword && !$0.provisional
                }
            }
        }

        func checkSeparatorEdit(_ name: String, result: String, words: [NSRange], edit: () -> Void) async throws {
            holdTree = true
            holdSemantic = true
            edit()
            let actual = (editor.string as NSString).substring(with: NSRange(location: returnKeyword.location,
                                                                             length: result.utf16.count + 1))
            try require(actual == result + "\n", "edit the expected line for \(name)")
            func verify(_ phase: String) throws {
                for word in words { try requireGlyphColors(in: word, document: document, expected: .keyword) }
                try capture(window, "separator-\(name)-\(phase)")
            }
            try verify("first")
            try await wait("hold both results after \(name)") { heldTree > 0 && heldSemantic > 0 }
            try verify("held")
            holdTree = false
            try await wait("install Tree-sitter after \(name)") { heldTree == 0 }
            try verify("tree")
            holdSemantic = false
            try await wait("install ZLS after \(name)") { !highlighting.needsFullSemanticTokensForCheck }
            try verify("settled")
        }

        try await setLine("return")
        try await checkSeparatorEdit("insert-space", result: "return ", words: [returnKeyword]) {
            editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try await checkSeparatorEdit("delete-space", result: "return", words: [returnKeyword]) {
            editor.deleteBackward(nil)
        }
        try await setLine("return error.")
        try await checkSeparatorEdit("delete-dot", result: "return error", words: [returnKeyword, keyword]) {
            editor.deleteBackward(nil)
        }
        try await setLine("return  error")
        editor.setSelectedRange(NSRange(location: returnKeyword.upperBound + 2, length: 0))
        try await checkSeparatorEdit("delete-leading-space", result: "return error", words: [returnKeyword, keyword]) {
            editor.deleteBackward(nil)
        }
    }

    private static func requireGlyphColors(in range: NSRange, document: DocumentWindow, expected: SyntaxColor) throws {
        let window = document.window
        let editor = document.editor
        let clip = document.scrollView.contentView
        guard let manager = editor.textLayoutManager, let visible = manager.textViewportLayoutController.viewportRange,
              NSIntersectionRange(editor.charRange(visible, in: manager), range) == range else {
            throw Failure(detail: "show the entire edited token in the frame being sampled")
        }
        let columns = (range.location...range.upperBound).map { offset in
            let position = NSRange(location: offset, length: 0)
            return clip.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: position, actualRange: nil)), from: nil)
        }
        let bounds = clip.bounds
        guard let bitmap = clip.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure(detail: "capture typed glyphs") }
        clip.cacheDisplay(in: bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / bounds.width
        for (index, (left, right)) in zip(columns, columns.dropFirst()).enumerated() {
            let x = Int(((left.minX - bounds.minX) * scale).rounded())..<Int(((right.minX - bounds.minX) * scale).rounded())
            let y = Int(((left.minY - bounds.minY) * scale).rounded())..<Int(((left.maxY - bounds.minY) * scale).rounded())
            var colors = Set<SyntaxColor>()
            for row in y where (0..<bitmap.pixelsHigh).contains(row) {
                for column in x where (0..<bitmap.pixelsWide).contains(column) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    let (red, green, blue) = (pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                    if blue > red + 0.2 && blue > green + 0.1 { colors.insert(.keyword) }
                    if green > red + 0.2 && green > blue + 0.03 { colors.insert(.type) }
                    if min(red, green, blue) > 0.7 { colors.insert(.plain) }
                }
            }
            try require(colors == [expected],
                        "glyph \(index + 1) of \(range.length) has \(expected) paint: found \(colors)")
        }
    }

    private static func checkViewportPreview(in app: Edit, document: DocumentWindow, folder: URL,
                                             capture: (NSWindow, String) throws -> Void) async throws {
        let target = folder.appending(path: "Large.zig")
        let source = "pub const Visible = struct {};\n"
            + (0..<2500).map { "pub fn sample\($0)(value: u64) u64 { return value + \($0); }\n" }.joined()
            + "pub const Offscreen = struct {};\n"
            + String(repeating: "// spacer\n", count: 40)
        try source.write(to: target, atomically: true, encoding: .utf8)
        guard let drawing = document.editor.syntaxHighlighting else { throw Failure(detail: "prepare range preview") }
        let (pending, release) = AsyncStream<Void>.makeStream()
        var fullPending = false
        drawing.beforeInstallSemanticTokensForCheck = {
            fullPending = true
            for await _ in pending { break }
        }
        defer {
            drawing.beforeInstallSemanticTokensForCheck = nil
            release.finish()
        }
        try require(try await app.openFile(target, in: document) === document, "open the large Zig fixture")
        document.window.layoutIfNeeded()
        try await wait("show viewport semantic tokens while the whole file is pending") {
            fullPending && hasSemanticColor("Visible", in: document)
        }
        try require(document.window.title.hasSuffix("Large.zig") && drawing.needsFullSemanticTokensForCheck
                    && !hasSemanticColor("Offscreen", in: document),
                    "keep the preview limited to the viewport until the full update")
        try capture(document.window, "viewport")
        release.finish()
        try await wait("extend semantic colors offscreen after the full result") {
            !drawing.needsFullSemanticTokensForCheck && hasSemanticColor("Offscreen", in: document)
        }
        let editor = document.editor
        let keyword = (source as NSString).range(of: "struct", options: .backwards)
        document.window.appearance = NSAppearance(named: .darkAqua)
        editor.setSelectedRange(NSRange(location: keyword.upperBound, length: 0))
        editor.revealNavigationSelection(editor.selectedRange())
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try capture(document.window, "whole-token-scrolled-before")
        try requireGlyphColors(in: keyword, document: document, expected: .keyword)
        editor.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
        let extended = NSRange(location: keyword.location, length: keyword.length + 1)
        try require((editor.string as NSString).substring(with: extended) == "structs", "extend a token after scrolling")
        try capture(document.window, "whole-token-scrolled")
        try requireGlyphColors(in: extended, document: document, expected: .keyword)
    }

    private static func checkPreferences(root: URL, other: URL) throws {
        let suite = "dev.edit-swift.lsp-highlighting.check.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(detail: "create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkspaceHighlighting(defaults: defaults)
        try require(HighlightingLayer.allCases.allSatisfy { preferences.isEnabled($0, in: root) }, "default both layers to enabled")
        preferences.setEnabled(false, for: .lsp, in: root)
        preferences.setEnabled(false, for: .treeSitter, in: other)
        let reopened = WorkspaceHighlighting(defaults: defaults)
        try require(!reopened.isEnabled(.lsp, in: root) && reopened.isEnabled(.treeSitter, in: root)
                    && reopened.isEnabled(.lsp, in: other) && !reopened.isEnabled(.treeSitter, in: other),
                    "restore independent workspace settings for both layers")
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
        try require(index.semanticRequestRange(NSRange(location: 2, length: 8)) ==
                    LSPRange(start: .init(line: 0, character: 0), end: .init(line: 1, character: 5)),
                    "request complete visible lines using UTF-16 positions")
        let spans = try delta.tokens(updating: tokens).spans(in: index, legend: legend)
        try require(spans.count == 2 && spans[0].start == 3 && spans[0].end == 6 && spans[0].color == .type && spans[1].color == .plain,
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
