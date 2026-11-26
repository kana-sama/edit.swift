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
        try await checkIncrementalZigTree()
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
            + "pub const FirstAlias = ZigWidget;\r\npub const WidgetAlias = ZigWidget;\r\n"
            + "pub const LastAlias = ZigWidget;\r\npub var Counter: u64 = 3;\r\nconst wordSize = @sizeOf(u64);\r\n"
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
        let session = document.languageFeatures.session
        let generation = session.generation
        var holdProjectRoot = true
        var projectRootPending = false
        session.beforeApplyProjectRootForCheck = {
            projectRootPending = true
            while holdProjectRoot && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        var holdResult = true
        var responsePending = false
        highlighting.beforeInstallSemanticTokensForCheck = {
            responsePending = true
            while holdResult && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        defer {
            highlighting.beforeInstallSemanticTokensForCheck = nil
            holdResult = false
            session.beforeApplyProjectRootForCheck = nil
            holdProjectRoot = false
        }
        let outgoingTitle = document.window.title
        document.window.appearance = NSAppearance(named: .darkAqua)
        document.window.layoutIfNeeded()
        func checkUnchangedAliases(_ frame: String) throws {
            for alias in ["FirstAlias", "LastAlias"] {
                try require(!hasColor(alias, in: document) && hasColor(alias, in: document, layer: .lsp, color: .type),
                            "retain the LSP-only color of \(alias) \(frame)")
                let range = (editor.string as NSString).range(of: alias)
                try SyntaxCheck.requireGlyphColors(in: range, document: document, expected: .type)
            }
        }
        try checkUnchangedAliases("before editing")
        let alias = (editor.string as NSString).range(of: "WidgetAlias")
        let extended = NSRange(location: alias.location, length: alias.length + 1)
        let start = ContinuousClock.now
        editor.insertText("X", replacementRange: NSRange(location: alias.upperBound, length: 0))
        try checkUnchangedAliases("in the first edited frame")
        try SyntaxCheck.requireGlyphColors(in: extended, document: document, expected: .type)
        try await wait("receive an edited token result") { responsePending }
        await document.flushAutosave()
        try await wait("hold the project rediscovery triggered by the atomic save") { projectRootPending }
        try require(session.supportsSemanticTokens && session.generation == generation,
                    "keep the same semantic provider while checking the saved file's project")
        try checkUnchangedAliases("while project rediscovery is pending")
        try captureWindow(document.window, "pending")
        try await Task.sleep(until: start + .milliseconds(1_750), clock: .continuous)
        try captureWindow(document.window, "pending-after-deadline")
        try checkUnchangedAliases("after the stale color deadline with ZLS still held")
        try SyntaxCheck.requireGlyphColors(in: extended, document: document, expected: .plain)
        try require(document.window.title == outgoingTitle && hasColor("null", in: document, color: .control)
                    && hasColor("null", in: document, layer: .lsp, color: .control)
                    && paintedColor("null", in: document) == SyntaxColor.control.nativeColor,
                    "keep both layers and the title while a replacement overlay is held")
        session.beforeApplyProjectRootForCheck = nil
        holdProjectRoot = false
        highlighting.beforeInstallSemanticTokensForCheck = nil
        holdResult = false
        try await wait("paint the new semantic tokens") { hasSemanticColor("WidgetAliasX", in: document) }
        try checkUnchangedAliases("in the first frame with the fresh response")
        try SyntaxCheck.requireGlyphColors(in: extended, document: document, expected: .type)
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
        try require(document.window.title == outgoingTitle && hasSemanticColor("WidgetAliasX", in: document),
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
        guard range.location != NSNotFound, let manager = editor.textLayoutManager else { return nil }
        return SyntaxCheck.renderingForeground(at: range.location, in: manager) ?? .textColor
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
        let incrementalBefore = editor.syntaxAnalysis.treeReusesForCheck
        editor.setSelectedRange(NSRange(location: prefix.upperBound, length: 0))
        editor.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))
        let keyword = NSRange(location: prefix.location, length: 5)
        try require(editor.syntaxAnalysis.treeReusesForCheck > incrementalBefore,
                    "parse the completed keyword using the previous Zig tree before drawing")
        try require(hasSemanticColor("Other", in: document), "preserve an unaffected semantic token beside the edit")
        try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
        try capture(window, "keyword-first")
        try await wait("hold both results for the new keyword") { heldTree > 0 && heldSemantic > 0 }
        try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
        holdTree = false
        try await wait("install the viewport colors while the semantic update is held") {
            heldTree == 0 && highlighting.syntaxCoveredRangeForCheck != nil
        }
        try require(window.title == title, "preserve the title while the response is held")
        try require(!highlighting.semanticSpansForCheck.contains { NSIntersectionRange($0.range, keyword).length > 0 },
                    "replace the provisional semantic color even when the ranges match")
        try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
        try capture(window, "keyword-tree")

        holdSemantic = false
        try await wait("finish installing the semantic response") { !highlighting.needsFullSemanticTokensForCheck }
        try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
        try capture(window, "keyword-settled")

        let dot = NSRange(location: keyword.upperBound, length: 1)
        for (index, character) in ".Hello".enumerated() {
            holdTree = true
            holdSemantic = true
            let immediateBefore = highlighting.zigImmediateUpdatesForCheck
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            let tag = NSRange(location: dot.upperBound, length: index)
            let suffix = String(".Hello".prefix(index + 1))
            let typed = NSRange(location: dot.location, length: suffix.utf16.count)
            try require((editor.string as NSString).substring(with: typed) == suffix, "type \(suffix) at the end of the keyword")
            if index == 1 {
                try require(highlighting.zigImmediateUpdatesForCheck > immediateBefore,
                            "query the edited line from the incremental tree before drawing the first H")
            }

            func verifyFrame(_ phase: String) throws {
                try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
                try SyntaxCheck.requireGlyphColors(in: dot, document: document, expected: .plain)
                if tag.length > 0 { try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type) }
                try capture(window, "typing-\(index + 1)-\(phase)")
            }
            try verifyFrame("first")
            try await wait("hold both results for \(suffix)") { heldTree > 0 && heldSemantic > 0 }
            try verifyFrame("held")

            holdTree = false
            try await wait("show the current Tree-sitter colors for \(suffix)") {
                heldTree == 0 && (tag.length == 0 || highlighting.treeSpansForCheck.contains {
                    $0.range == tag && $0.color == .type && !$0.provisional
                })
            }
            try verifyFrame("tree")

            holdSemantic = false
            try await wait("finish applying the semantic response for \(suffix)") { !highlighting.needsFullSemanticTokensForCheck }
            try verifyFrame("settled")
        }

        let hello = NSRange(location: dot.upperBound, length: "Hello".utf16.count)
        let extraSemicolons = ";;;"
        editor.insertText(extraSemicolons, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait("start Backspace checks with a ZLS-colored error tag before repeated semicolons") {
            !highlighting.needsFullSemanticTokensForCheck && highlighting.semanticSpansForCheck.contains {
                $0.range == hello && $0.color == .type
            }
        }
        for (index, deletion) in [4, 2, 0].enumerated() {
            holdTree = true
            holdSemantic = true
            let immediateBefore = highlighting.zigImmediateUpdatesForCheck
            editor.setSelectedRange(NSRange(location: hello.location + deletion + 1, length: 0))
            editor.deleteBackward(nil)
            let tag = NSRange(location: hello.location, length: hello.length - index - 1)
            let shortened = ["Hell", "Hel", "el"][index]
            try require((editor.string as NSString).substring(with: tag) == shortened,
                        "shorten the error tag to \(shortened)")
            try require(highlighting.zigImmediateUpdatesForCheck > immediateBefore,
                        "query the shortened error tag from the updated tree before painting it")
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
            try require(highlighting.treeSpansForCheck.contains { $0.range == tag && $0.color == .type && !$0.provisional },
                        "classify the whole shortened tag \(shortened) locally before either response")
            try require(!highlighting.semanticSpansForCheck.contains { NSIntersectionRange($0.range, tag).length > 0 },
                        "clear the old semantic range for the locally classified tag \(shortened)")
            try capture(window, "backspace-\(shortened)-first")
            try await wait("hold both results for \(shortened)") { heldTree > 0 && heldSemantic > 0 }
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
            try capture(window, "backspace-\(shortened)-held")
            holdTree = false
            try await wait("show the current Tree-sitter color for \(shortened)") {
                heldTree == 0 && highlighting.treeSpansForCheck.contains {
                    $0.range == tag && $0.color == .type && !$0.provisional
                }
            }
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
            try capture(window, "backspace-\(shortened)-tree")
            holdSemantic = false
            try await wait("apply the ZLS color for \(shortened)") {
                !highlighting.needsFullSemanticTokensForCheck && highlighting.semanticSpansForCheck.contains {
                    $0.range == tag && $0.color == .type && !$0.provisional
                }
            }
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
            try capture(window, "backspace-\(shortened)-settled")
        }
        let shortenedTagAndExtraSemicolons = NSRange(location: hello.location, length: 2 + extraSemicolons.utf16.count)
        editor.insertText("Hello", replacementRange: shortenedTagAndExtraSemicolons)
        try await wait("restore the classified error tag") {
            !highlighting.needsFullSemanticTokensForCheck && highlighting.treeSpansForCheck.contains {
                $0.range == hello && $0.color == .type && !$0.provisional
            }
        }

        document.toggleHighlighting(.lsp)
        holdTree = true
        for (index, character) in "Ab".enumerated() {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            let tag = NSRange(location: dot.upperBound, length: "Hello".utf16.count + index + 1)
            try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
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
        try SyntaxCheck.requireGlyphColors(in: joined, document: document, expected: .plain)

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
                for word in words { try SyntaxCheck.requireGlyphColors(in: word, document: document, expected: .keyword) }
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

        try await setLine("return error.")
        holdTree = true
        holdSemantic = true
        for (index, character) in "He".enumerated() {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            let tag = NSRange(location: dot.upperBound, length: index + 1)
            try SyntaxCheck.requireGlyphColors(in: tag, document: document, expected: .type)
            try SyntaxCheck.requireGlyphColors(in: dot, document: document, expected: .plain)
            try capture(window, "new-error-tag-at-line-end-\(tag.length)")
        }
        try await wait("hold the results after two successive error-tag letters") { heldTree > 0 && heldSemantic > 0 }
        try SyntaxCheck.requireGlyphColors(in: NSRange(location: dot.upperBound, length: 2), document: document, expected: .type)
        holdTree = false
        holdSemantic = false
        try await wait("publish the completed color for the new tag") { heldTree == 0 && !highlighting.needsFullSemanticTokensForCheck }

        try await setLine("return error.Hello;")
        try require(highlighting.semanticSpansForCheck.contains { $0.range == returnKeyword && $0.color == .keyword },
                    "start with a ZLS keyword that could mask the local update")
        try SyntaxCheck.requireGlyphColors(in: returnKeyword, document: document, expected: .keyword)
        holdTree = true
        holdSemantic = true
        let immediateBefore = highlighting.zigImmediateUpdatesForCheck
        editor.setSelectedRange(NSRange(location: returnKeyword.upperBound, length: 0))
        editor.deleteBackward(nil)
        let shortenedReturn = NSRange(location: returnKeyword.location, length: returnKeyword.length - 1)
        try require((editor.string as NSString).substring(with: shortenedReturn) == "retur", "shorten the return keyword")
        try require(highlighting.zigImmediateUpdatesForCheck > immediateBefore,
                    "remove the old keyword color with a query on the updated tree")
        try SyntaxCheck.requireGlyphColors(in: shortenedReturn, document: document, expected: .plain)
        try require(!highlighting.semanticSpansForCheck.contains { NSIntersectionRange($0.range, shortenedReturn).length > 0 },
                    "drop the stale semantic keyword on the first frame")
        try require(window.title == title, "preserve the document title during local highlighting")
        try capture(window, "backspace-retur-first")
        try await wait("hold both responses for retur") { heldTree > 0 && heldSemantic > 0 }
        try SyntaxCheck.requireGlyphColors(in: shortenedReturn, document: document, expected: .plain)
        try capture(window, "backspace-retur-held")
        // Exercise the opposite completion order to the error-tag checks above.
        holdSemantic = false
        try await wait("install ZLS while Tree-sitter is held for retur") { !highlighting.needsFullSemanticTokensForCheck }
        try SyntaxCheck.requireGlyphColors(in: shortenedReturn, document: document, expected: .plain)
        try capture(window, "backspace-retur-zls")
        holdTree = false
        try await wait("install Tree-sitter for retur") { heldTree == 0 }
        try SyntaxCheck.requireGlyphColors(in: shortenedReturn, document: document, expected: .plain)
        try capture(window, "backspace-retur-settled")
    }

    private static func checkIncrementalZigTree() async throws {
        let analysis = EditorSyntaxAnalysis()
        let source = NSMutableString(string: "const label = \"🧩\";\r\ntest \"typing\" {\r\n    return error.Hello;\r\n}\r\n")
        guard await analysis.tree(in: source as String, language: .zig) != nil else { throw Failure(detail: "parse the initial Zig tree") }
        for (original, replacement) in [("🧩", "🚀!"), ("return", "retur"), ("Hello", "Hell")] {
            let range = source.range(of: original)
            source.replaceCharacters(in: range, with: replacement)
            let length = replacement.utf16.count
            analysis.recordEdit(NSRange(location: range.location, length: length), delta: length - range.length, length: source.length)
        }
        let tag = source.range(of: "Hell")
        let insideTag = NSRange(location: tag.location + 1, length: 1)
        guard let updated = await analysis.tree(in: source as String, language: .zig), let ranged = updated.highlights(in: insideTag),
              let full = SyntaxEngine.spans(in: source as String, language: .zig) else {
            throw Failure(detail: "resolve a range after several UTF-16 edits against the same Zig tree")
        }
        let expected = full.filter { NSIntersectionRange($0.range, insideTag).length > 0 }
        try require(analysis.treeReusesForCheck == 1 && ranged.count == 1 && expected.count == 1
                    && ranged[0].range == tag && ranged[0].range == expected[0].range && ranged[0].color == expected[0].color,
                    "reuse the original tree across CRLF and emoji edits and return the whole token across query boundaries")
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
        let sourceLength = source.utf16.count
        let initialKeyword = (source as NSString).range(of: "struct")
        try await wait("query syntax for the initial viewport without querying the whole large buffer") {
            guard let covered = drawing.syntaxCoveredRangeForCheck else { return false }
            return NSIntersectionRange(covered, initialKeyword) == initialKeyword && covered.length < sourceLength / 4
        }
        let keyword = (source as NSString).range(of: "struct", options: .backwards)
        document.window.appearance = NSAppearance(named: .darkAqua)
        editor.setSelectedRange(NSRange(location: keyword.upperBound, length: 0))
        editor.revealNavigationSelection(editor.selectedRange())
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try await wait("query Tree-sitter colors for the viewport after scrolling") {
            guard let covered = drawing.syntaxCoveredRangeForCheck else { return false }
            return NSIntersectionRange(covered, keyword) == keyword && covered.length < sourceLength / 4
                && drawing.treeSpansForCheck.contains { $0.range == keyword && $0.color == .keyword }
        }
        try capture(document.window, "whole-token-scrolled-before")
        try SyntaxCheck.requireGlyphColors(in: keyword, document: document, expected: .keyword)
        editor.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
        let extended = NSRange(location: keyword.location, length: keyword.length + 1)
        try require((editor.string as NSString).substring(with: extended) == "structs", "extend a token after scrolling")
        try capture(document.window, "whole-token-scrolled")
        try SyntaxCheck.requireGlyphColors(in: extended, document: document, expected: .keyword)
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
        let errorTags = LSPSemanticTokens(resultID: nil, data: [0, 6, 2, 0, 0, 1, 6, 4, 0, 0])
        let wholeTags = try errorTags.spans(in: LSPTextIndex("error.Hello\r\nerror.Hell"), legend: legend, wholeWords: true)
        try require(wholeTags.count == 1 && wholeTags.first?.range == NSRange(location: 19, length: 4),
                    "reject a partial semantic range without losing the next whole token")
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
