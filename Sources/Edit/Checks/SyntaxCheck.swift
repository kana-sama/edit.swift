import AppKit

@MainActor
enum SyntaxCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(in app: Edit) async throws {
        // These pixel checks exercise Tree-sitter even when a server handles loose Swift files.
        let wasEnabled = app.workspaceHighlighting.isEnabled(.lsp, in: nil)
        app.workspaceHighlighting.setEnabled(false, for: .lsp, in: nil)
        defer { app.workspaceHighlighting.setEnabled(wasEnabled, for: .lsp, in: nil) }

        try await checkTyping(in: app, expiresForegroundParse: false)
        try await checkTyping(in: app, expiresForegroundParse: true)
        try await checkTyping(in: app, expiresForegroundParse: true, expiresProjectedQuery: true)
        try await checkUnclosedRubyString(in: app)
        try await checkFirstDraw(in: app, appearance: .aqua)
        try await checkFirstDraw(in: app, appearance: .darkAqua)
        try await checkSwiftDrawing(in: app, requiresFirstFrame: true)
        try await checkSwiftDrawing(in: app, requiresFirstFrame: false)
        try await checkModeRepaint(in: app)
        try await checkSharedAnalysis()
        try await Task.detached { try checkGrammars() }.value
        let document = app.makeDocument()
        defer { document.window.close() }
        let editor = document.editor
        let input = "fn main() { let café = \"🦜\"; }"
        editor.string = input
        editor.setSelectedRange(NSRange(location: 4, length: 2))
        editor.didChangeText()
        document.setSyntaxLanguage(.rust)
        guard document.manualSyntaxLanguage == .rust,
              document.sessionDocument().syntaxLanguage == SyntaxLanguage.rust.rawValue,
              editor.string == input, editor.selectedRange() == NSRange(location: 4, length: 2),
              let manager = editor.textLayoutManager else {
            throw Failure("Changing syntax mode modified the document or selection.")
        }
        let token = (input as NSString).range(of: "main")
        try await waitForColor(at: token, in: manager)
        try await checkScrolling(document: document, manager: manager)
        document.setSyntaxLanguage(.plainText)
        var coloredAfterReset = false
        manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, _ in
            coloredAfterReset = coloredAfterReset || attributes[.foregroundColor] is NSColor
            return true
        }
        guard !coloredAfterReset else { throw Failure("Plain Text left syntax attributes on the document.") }
        let record = document.sessionDocument()
        document.setSyntaxLanguage(nil)
        document.restoreDraft(record, text: input)
        guard document.resolvedSyntaxLanguage == .plainText, document.manualSyntaxLanguage == .plainText else {
            throw Failure("Session restoration lost the manual Plain Text mode.")
        }
    }

    private static func checkTyping(in app: Edit, expiresForegroundParse: Bool, expiresProjectedQuery: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        struct Fixture {
            let filename: String
            let language: SyntaxLanguage
            let prefix: String
            let initial: String
            let suffix: String
            let typed: [String]
            let color: SyntaxColor
            let comment: (marker: String, beforeToken: Int)?
            var colorsOpeningDelimiter = false
        }
        var fixtures = [
            Fixture(filename: "Brewfile", language: .ruby, prefix: "brew \"café\"\n\n", initial: "b",
                    suffix: "\n", typed: ["r", "e", "w"], color: .function, comment: ("# ", 0)),
            Fixture(filename: "Method.rb", language: .ruby, prefix: "def ", initial: "ready?",
                    suffix: "\nend\n", typed: [], color: .function, comment: nil),
            Fixture(filename: "example.bash", language: .shell, prefix: "# café\n", initial: "p",
                    suffix: "\n", typed: ["r", "i", "n", "t", "f"], color: .function, comment: ("# ", 0)),
            Fixture(filename: "heredoc.bash", language: .shell, prefix: "cat <<'EOF'\nfirst\n", initial: "café",
                    suffix: "\nlast\nEOF\n", typed: ["s"], color: .string, comment: nil),
            Fixture(filename: "Example.swift", language: .swift, prefix: "// café\nfunc ", initial: "café",
                    suffix: "() {}\n", typed: ["N", "o", "w"], color: .function, comment: ("// ", 5)),
            Fixture(filename: "Empty.rb", language: .ruby, prefix: "", initial: "",
                    suffix: "", typed: ["b", "r"], color: .function, comment: nil),
            Fixture(filename: "Example.ODIN", language: .odin, prefix: "package example\n\n",
                    initial: "caféNow", suffix: " :: proc() {}\n", typed: ["_", "2"], color: .function, comment: ("// ", 0)),
            Fixture(filename: "Numbers.odin", language: .odin, prefix: "package example\n\nvalue :: ", initial: "0xA",
                    suffix: "\n", typed: ["b", "2"], color: .number, comment: nil),
            Fixture(filename: "RawString.odin", language: .odin, prefix: "package example\n\nmessage :: `first\n",
                    initial: "café", suffix: "`\n", typed: ["!", "?"], color: .string, comment: nil),
            Fixture(filename: "CallingConvention.odin", language: .odin, prefix: "package example\n\nf :: proc ",
                    initial: "", suffix: "\n", typed: ["\"", "c", "\""], color: .control, comment: nil,
                    colorsOpeningDelimiter: true),
            Fixture(filename: "Quote.odin", language: .odin, prefix: "package example\n\nmessage ",
                    initial: "", suffix: "\n", typed: ["\"", "é", "\""], color: .string, comment: nil,
                    colorsOpeningDelimiter: true),
            Fixture(filename: "Rune.odin", language: .odin, prefix: "package example\n\nletter :: ",
                    initial: "", suffix: "\n", typed: ["'", "é", "'"], color: .string, comment: nil,
                    colorsOpeningDelimiter: true),
            Fixture(filename: "LineComment.sol", language: .solidity,
                    prefix: "contract Counter {\n    function read() public {\n        // - доля\n        // - ",
                    initial: "debtToRepay", suffix: "\n        // - collateralToWithdraw\n    }\n}\n",
                    typed: ["a", "s", "d"], color: .comment, comment: nil),
            Fixture(filename: "NatSpec.sol", language: .solidity, prefix: "contract Counter {\n    /// @notice ",
                    initial: "café", suffix: "\n    function read() public {}\n}\n", typed: ["s", "!"],
                    color: .comment, comment: nil),
            Fixture(filename: "BlockComment.sol", language: .solidity,
                    prefix: "contract Counter {\n    function read() public {\n        /* comment\n           ",
                    initial: "café", suffix: " */\n    }\n}\n", typed: ["s", "!"], color: .comment, comment: nil),
            Fixture(filename: "YulComment.sol", language: .solidity,
                    prefix: "contract Counter {\n    function read() public {\n        assembly {\n            // ",
                    initial: "café", suffix: "\n        }\n    }\n}\n", typed: ["s", "!"], color: .comment, comment: nil),
            Fixture(filename: "Function.sol", language: .solidity, prefix: "contract Counter {\n    function ",
                    initial: "read", suffix: "() public {}\n}\n", typed: ["V", "2"],
                    color: .function, comment: ("// ", "function ".utf16.count)),
            Fixture(filename: "String.zig", language: .zig, prefix: "const value = ", initial: "",
                    suffix: ";\nconst next = 1;\n", typed: ["\"", "h", "e", "l", "l", "o", "\""],
                    color: .string, comment: nil),
            Fixture(filename: "Number.zig", language: .zig, prefix: "const value = ", initial: "123",
                    suffix: ";\n", typed: ["4", "5"], color: .number, comment: ("// ", "const value = ".utf16.count)),
            Fixture(filename: "Comment.zig", language: .zig, prefix: "// ", initial: "café",
                    suffix: "\nconst value = 1;\n", typed: ["s"], color: .comment, comment: nil),
            Fixture(filename: "Multiline.zig", language: .zig, prefix: "const value =\n\\\\first\n\\\\", initial: "second",
                    suffix: "\n;\n", typed: ["s"], color: .string, comment: nil),
            Fixture(filename: "build.zig.zon", language: .zig, prefix: ".{ .value = ", initial: "0x1",
                    suffix: " }\n", typed: ["2", "a"], color: .number, comment: nil),
        ]
        if expiresProjectedQuery {
            fixtures.append(Fixture(filename: "Large.swift", language: .swift, prefix: "func ", initial: "café",
                                    suffix: "() {}\n" + String(repeating: "// padding\n", count: 25_000), typed: ["N", "o"],
                                    color: .function, comment: ("// ", 5)))
            fixtures.append(Fixture(filename: "Large.zig", language: .zig, prefix: "const value = ", initial: "123",
                                    suffix: ";\n" + String(repeating: "// padding\n", count: 25_000), typed: ["4", "5"],
                                    color: .number, comment: nil))
        }

        for fixture in fixtures {
            let file = directory.appendingPathComponent(fixture.filename)
            let source = fixture.prefix + fixture.initial + fixture.suffix
            try source.write(to: file, atomically: true, encoding: .utf8)
            let document = app.makeDocument()
            let window = document.window
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            guard try await app.openFile(file, in: document) === document, window.alphaValue == 0, !window.isVisible,
                  let highlighting = document.editor.syntaxHighlighting,
                  document.editor.syntaxLanguage == fixture.language else {
                throw Failure("Could not open a hidden typing fixture for \(fixture.filename).")
            }
            window.layoutIfNeeded()
            let editor = document.editor
            highlighting.expireForegroundParseForCheck = expiresForegroundParse
            highlighting.expireProjectedQueryForCheck = expiresProjectedQuery
            var hold = false
            var waiting = false
            highlighting.beforeInstallTreeTokensForCheck = {
                waiting = true
                defer { waiting = false }
                while hold && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(3)) }
            }
            defer {
                hold = false
                highlighting.beforeInstallTreeTokensForCheck = nil
            }

            let start = fixture.prefix.utf16.count
            var token = NSRange(location: start, length: fixture.initial.utf16.count)
            func expect(_ color: SyntaxColor, _ phase: String) throws {
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                do {
                    try requireGlyphColors(in: token, document: document, expected: color)
                } catch {
                    throw Failure("\(fixture.filename) \(phase), expired parse \(expiresForegroundParse), expired query \(expiresProjectedQuery), token \(token): \(error.localizedDescription)")
                }
            }
            func checkEdit(_ color: SyntaxColor, pending: SyntaxColor? = nil, _ edit: () throws -> Void) async throws {
                hold = true
                try edit()
                try expect(pending ?? color, "first edited frame")
                try await waitForFrame("background result pending for \(fixture.filename)") { waiting }
                try expect(pending ?? color, "pending frame")
                hold = false
                try await waitForFrame("background result applied for \(fixture.filename)") { !waiting }
                try expect(color, "first updated frame")
            }

            if token.length > 0 { try expect(fixture.color, "opening frame") }
            func type(_ character: String) {
                editor.setSelectedRange(NSRange(location: token.upperBound, length: 0))
                editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                token.length += character.utf16.count
            }
            if expiresForegroundParse, token.length > 0, fixture.typed.count > 1 {
                // Inspect successive edits before the background parser can publish any of them.
                try await checkEdit(fixture.color) {
                    for character in fixture.typed {
                        type(character)
                        try expect(fixture.color, "typing burst")
                    }
                }
            } else {
                for character in fixture.typed {
                    let pending: SyntaxColor? = expiresForegroundParse && token.length == 0
                        && fixture.language != .zig && !fixture.colorsOpeningDelimiter ? .plain : nil
                    try await checkEdit(fixture.color, pending: pending) { type(character) }
                }
            }
            try await checkEdit(fixture.color) {
                editor.setSelectedRange(NSRange(location: token.upperBound, length: 0))
                editor.deleteBackward(nil)
                token.length -= 1
            }
            if let comment = fixture.comment {
                try await checkEdit(.comment, pending: expiresForegroundParse ? fixture.color : nil) {
                    editor.setSelectedRange(NSRange(location: token.location - comment.beforeToken, length: 0))
                    editor.insertText(comment.marker, replacementRange: NSRange(location: NSNotFound, length: 0))
                    token.location += comment.marker.utf16.count
                }
            }
            guard !highlighting.usesLSPForCheck else { throw Failure("Typing fixture used LSP colors.") }
        }
    }

    private static func waitForFrame(_ detail: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure("Timed out waiting for \(detail).") }
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    private static func checkUnclosedRubyString(in app: Edit) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Ruby-string-\(UUID()).rb")
        let source = "\"hello\ndef fn\nend"
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = app.makeDocument()
        defer { document.window.close() }
        document.window.appearance = NSAppearance(named: .darkAqua)
        guard try await app.openFile(file, in: document) === document, !document.window.isVisible,
              document.window.alphaValue == 0, let highlighting = document.editor.syntaxHighlighting else {
            throw Failure("Could not prepare the hidden Ruby string fixture.")
        }
        document.window.layoutIfNeeded()
        let editor = document.editor
        let closingQuote = NSRange(location: "\"hello".utf16.count, length: 0)
        func expect(_ nextLine: SyntaxColor, method: SyntaxColor) throws {
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let text = editor.string as NSString
            try requireGlyphColors(in: text.range(of: "\"hello"), document: document, expected: .string)
            try requireGlyphColors(in: text.range(of: "def"), document: document, expected: nextLine)
            try requireGlyphColors(in: text.range(of: "fn"), document: document, expected: method)
        }

        try expect(.string, method: .string)
        var hold = true
        var pending = false
        highlighting.expireForegroundParseForCheck = true
        highlighting.beforeInstallTreeTokensForCheck = {
            pending = true
            defer { pending = false }
            while hold && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(3)) }
        }
        defer {
            hold = false
            highlighting.beforeInstallTreeTokensForCheck = nil
        }
        editor.setSelectedRange(closingQuote)
        editor.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(.string, method: .string)
        try await waitForFrame("hold the Ruby parse after closing the quote") { pending }
        try expect(.string, method: .string)
        hold = false
        try await waitForFrame("apply the Ruby parse after closing the quote") { !pending }
        try expect(.keyword, method: .function)

        editor.deleteBackward(nil)
        try await waitForFrame("restore string color when Backspace reopens the Ruby string") {
            highlighting.treeSpansForCheck.contains { $0.start == 0 && $0.end == source.utf16.count && $0.color == .string }
        }
        try expect(.string, method: .string)
    }

    static func requireGlyphColors(in range: NSRange, document: DocumentWindow, expected: SyntaxColor) throws {
        let window = document.window
        let editor = document.editor
        let clip = document.scrollView.contentView
        guard let manager = editor.textLayoutManager, let visible = manager.textViewportLayoutController.viewportRange,
              NSIntersectionRange(editor.charRange(visible, in: manager), range) == range else {
            throw Failure("show the entire edited token in the frame being sampled")
        }
        let columns = (range.location...range.upperBound).map { offset in
            let position = NSRange(location: offset, length: 0)
            return clip.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: position, actualRange: nil)), from: nil)
        }
        let bounds = clip.bounds
        guard let bitmap = clip.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure("capture typed glyphs") }
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
                    if expected == .control, red > green + 0.12 && blue > green + 0.12 { colors.insert(.control) }
                    if green > red + 0.2 && green > blue + 0.03 { colors.insert(.type) }
                    if expected == .function, (red - green).magnitude < 0.05 && green > blue + 0.12 { colors.insert(.function) }
                    if expected == .comment, green > red + 0.08 && green > blue + 0.11 { colors.insert(.comment) }
                    if expected == .string, red > green + 0.11 && green > blue + 0.04 { colors.insert(.string) }
                    if expected == .number, green > red + 0.06 && red > blue + 0.03 { colors.insert(.number) }
                    if min(red, green, blue) > 0.7 { colors.insert(.plain) }
                }
            }
            // The typing fixtures can have a white caret sharing a cell with a colored glyph.
            if [.control, .function, .comment, .string, .number].contains(expected) { colors.remove(.plain) }
            guard colors == [expected] else {
                throw Failure("Glyph \(index + 1) of \(range.length) expected \(expected) paint, found \(colors).")
            }
        }
    }

    private static func checkSharedAnalysis() async throws {
        let source = "# Example\n\n```rs\nfn main() { let text = \"(\"; }\n```\n"
        let cache = EditorSyntaxAnalysis()
        let colors = cache.request(in: source, language: .markdown, publishesPreview: true)
        let brackets = cache.request(in: source, language: .markdown)
        guard colors.task == brackets.task, let analysis = await colors.task.value else {
            throw Failure("Syntax highlighting and bracket navigation did not share one parse.")
        }
        let function = (source as NSString).range(of: "main")
        let ignored = (source as NSString).range(of: "\"(\"")
        guard analysis.spans.contains(where: { $0.color == .function && $0.start <= function.location && $0.end >= function.upperBound }),
              analysis.brackets.embeddedLanguages.contains(where: { $0.language == .rust && NSLocationInRange(ignored.location, $0.range) }),
              analysis.brackets.ignoredRanges.contains(where: { NSIntersectionRange($0, ignored).length == ignored.length }),
              cache.request(in: source + "Changed", language: .markdown).task != colors.task else {
            throw Failure("Embedded colors or bracket context were missing from the current parse.")
        }
        let odin = "f :: proc \"(\n"
        let quote = (odin as NSString).range(of: "\"(")
        guard let analysis = SyntaxEngine.analysis(in: odin, language: .odin),
              analysis.brackets.ignoredRanges.contains(where: { NSIntersectionRange($0, quote) == quote }) else {
            throw Failure("An unfinished Odin calling convention exposed its contents to bracket matching.")
        }
    }

    private static func checkFirstDraw(in app: Edit, appearance: NSAppearance.Name) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        guard !document.window.isVisible, document.window.alphaValue == 0 else {
            throw Failure("The Rust drawing fixture must start hidden and transparent (alpha: \(document.window.alphaValue)).")
        }
        let scrollView = document.scrollView
        let clip = scrollView.contentView
        document.window.appearance = NSAppearance(named: appearance)
        let source = String(repeating: "let marker = \"sample\";\n", count: 85)
            + String(repeating: "// comment in a different viewport\n", count: 150)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Syntax display-\(UUID()).rs")
        try Data(source.utf8).write(to: url)
        let start = ContinuousClock.now
        guard try await app.openFile(url, in: document) === document else {
            throw Failure("Could not open the small syntax drawing fixture.")
        }
        document.window.layoutIfNeeded()

        // Inspect the actual first frame. Polling layout or the attribute map can hide a missed draw.
        try expectDrawnColor(in: clip, primaryChannel: 0, after: "opening the small Rust file")
        let opened = start.duration(to: .now)
        let scrollStart = ContinuousClock.now
        clip.scroll(to: NSPoint(x: 0, y: clip.documentRect.maxY - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
        try expectDrawnColor(in: clip, primaryChannel: 1, after: "scrolling to comment lines")
        let scrolled = scrollStart.duration(to: .now)
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        try expectDrawnColor(in: clip, primaryChannel: 0, after: "scrolling back to string literals")
        document.editor.selectAll(nil)
        try expectDrawnColor(in: clip, primaryChannel: 0, after: "selecting the Rust source")
        guard !document.window.isVisible else { throw Failure("Drawing the Rust fixture ordered its window onscreen.") }
        print("Syntax in the first frame of a \(source.utf8.count)-byte file: open \(opened), scroll \(scrolled).")
    }

    private static func checkSwiftDrawing(in app: Edit, requiresFirstFrame: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let warmup = directory.appending(path: "Warmup.swift")
        let target = directory.appending(path: "Target.swift")
        let source = (0..<720).map {
            "func sample\($0)(value: Int) -> Int {\n    let doubled = value * 2\n    return doubled\n}\n"
        }.joined() + String(repeating: "// comment in a different viewport\n", count: 250)
        try Data(String(repeating: "// warm up Swift\n", count: 35).utf8).write(to: warmup)
        try Data(source.utf8).write(to: target)
        let anchor = (source as NSString).range(of: "func sample300").location
        if !requiresFirstFrame {
            app.recentFiles.rememberPosition(
                EditorPosition(selections: [NSRange(location: anchor, length: 0)], horizontalOffset: 0,
                               verticalOffset: 300 * 4 * 18, topLine: .init(textOffset: anchor, offsetIntoLine: 0)),
                for: target, identity: FileIdentity.at(target)
            )
        }

        let document = app.makeDocument()
        let window = document.window
        let scroll = document.scrollView
        let clip = scroll.contentView
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.close() }
        guard window.isVisible, !NSApp.isActive else { throw Failure("Could not prepare a quiet Swift editor window.") }
        guard try await app.openFile(warmup, in: document) === document else {
            throw Failure("Could not open the Swift warmup fixture.")
        }

        let start = ContinuousClock.now
        for pass in 0..<(requiresFirstFrame ? 1 : 2) {
            if pass > 0 {
                guard try await app.openFile(warmup, in: document) === document else {
                    throw Failure("Could not switch away from the Swift fixture.")
                }
            }
            guard try await app.openFile(target, in: document) === document else {
                throw Failure("Could not open the Swift drawing fixture.")
            }
            let editor = document.editor
            let selection = editor.selectedRange()
            if requiresFirstFrame {
                window.layoutIfNeeded()
                try expectDrawnColor(in: clip, primaryChannel: 2, after: "opening a Swift file with a prepared viewport")
                try await waitForPaint(in: clip, language: .swift)
            } else {
                // Do not scroll, force layout, or sample the layer while the async update settles.
                try await Task.sleep(for: .milliseconds(200))
                guard try paintMatches(in: clip, language: .swift),
                      editor.capturePosition().topLine?.textOffset == anchor else {
                    throw Failure("Deferred Swift highlighting did not repaint the stationary viewport.")
                }
            }
            guard editor.string == source, editor.selectedRange() == selection,
                  !window.isDocumentEdited, editor.undoManager?.canUndo == false else {
                throw Failure("Highlighting changed the text, selection, dirty state, or undo history.")
            }
        }
        if !requiresFirstFrame {
            let editor = document.editor
            let edit = (source as NSString).range(of: "    let doubled = value * 2", range: NSRange(location: anchor, length: 100))
            let caret = NSRange(location: edit.upperBound, length: 0)
            editor.setSelectedRange(caret)
            let bounds = clip.bounds
            clip.postsBoundsChangedNotifications = true
            var moved = false
            let movement = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: clip, queue: nil) { _ in
                MainActor.assumeIsolated { moved = moved || clip.bounds != bounds }
            }
            defer { NotificationCenter.default.removeObserver(movement) }
            editor.doCommand(by: #selector(NSTextView.insertNewline(_:)))
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<5 {
                editor.doCommand(by: #selector(NSTextView.deleteBackward(_:)))
                try await Task.sleep(for: .milliseconds(30))
            }
            guard !moved, clip.bounds == bounds, editor.string == source, editor.selectedRange() == caret else {
                throw Failure("Return and Backspace displaced the highlighted Swift viewport.")
            }
        }
        print("Checked color in a \(source.utf8.count)-byte Swift file at \(start.duration(to: .now)).")
        let scrollStart = ContinuousClock.now
        let comment = (source as NSString).range(of: "// comment in a different viewport", options: .backwards)
        guard let manager = document.editor.textLayoutManager else { throw Failure("Missing Swift text layout manager.") }
        document.editor.scrollRangeToVisible(comment)
        try await waitForColor(at: comment, in: manager, expected: .comment)
        document.editor.scrollRangeToVisible(comment)
        try expectDrawnColor(in: clip, primaryChannel: 1, after: "scrolling to newly visible Swift comments")
        print("Scroll to colored Swift comments: \(scrollStart.duration(to: .now)).")
    }

    private static func checkModeRepaint(in app: Edit) async throws {
        let document = app.makeDocument()
        let window = document.window
        let scroll = document.scrollView
        let clip = scroll.contentView
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let source = String(repeating: "// comment only in Rust\n\n# Title only in Markdown\n\n", count: 750)
        // An ordered but invisible test window gives AppKit a live backing layer.
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        guard window.isVisible, !NSApp.isActive else { throw Failure("Could not prepare the quiet syntax repaint fixture.") }
        document.editor.string = source
        window.layoutIfNeeded()

        try await waitForPaint(in: clip, language: .plainText)
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 0, y: 16_000))
        try await waitForPaint(in: clip, language: .plainText)
        let origin = scroll.visibleContentOrigin
        let bounds = clip.bounds
        let frame = document.editor.frame
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        var moved = false
        let movement = center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { moved = moved || clip.bounds != bounds }
        }
        var storageChanged = false
        let storageEdit = center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                             object: document.editor.textStorage, queue: nil) { _ in
            MainActor.assumeIsolated { storageChanged = true }
        }
        defer {
            center.removeObserver(movement)
            center.removeObserver(storageEdit)
        }

        document.setSyntaxLanguage(.rust)
        try await waitForPaint(in: clip, language: .rust)
        for enabled in [false, true] {
            document.toggleHighlighting(.treeSitter)
            try await waitForPaint(in: clip, language: enabled ? .rust : .plainText)
        }
        document.setSyntaxLanguage(.markdown)
        try await waitForPaint(in: clip, language: .markdown)
        document.setSyntaxLanguage(.rust)
        document.setSyntaxLanguage(.plainText)
        try await waitForPaint(in: clip, language: .plainText)
        try await Task.sleep(for: .milliseconds(100))
        guard try paintMatches(in: clip, language: .plainText),
              scroll.visibleContentOrigin == origin, document.editor.frame == frame,
              document.editor.string == source, !moved, !storageChanged else {
            throw Failure("Changing syntax colors edited the text storage or moved the live viewport.")
        }
    }

    private static func waitForPaint(in clip: NSClipView, language: SyntaxLanguage) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if try paintMatches(in: clip, language: language) { return }
            try await Task.sleep(for: .milliseconds(16))
        } while ContinuousClock.now < deadline
        throw Failure("Switching to \(language.displayName) did not repaint the visible glyphs.")
    }

    private static func paintMatches(in clip: NSClipView, language: SyntaxLanguage) throws -> Bool {
        let bounds = clip.bounds
        guard let layer = clip.layer?.presentation() ?? clip.layer else { return false }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure("Could not inspect the editor's live backing layer.") }
        bitmap.size = bounds.size
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure("Could not create the live syntax graphics context.")
        }
        let context = graphics.cgContext
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        // Rendering the presentation layer samples the current pixels without requesting display.
        layer.render(in: context)

        var hasText = false
        var hasGreen = false
        var hasBlue = false
        for y in stride(from: 48, to: min(220, bitmap.pixelsHigh), by: 3) {
            for x in stride(from: 8, to: min(240, bitmap.pixelsWide), by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent - max(color.redComponent, color.blueComponent) > 0.1 { hasGreen = true }
                if color.blueComponent - max(color.redComponent, color.greenComponent) > 0.1 { hasBlue = true }
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.64 { hasText = true }
            }
        }
        switch language {
        case .rust: return hasGreen
        case .markdown, .swift: return hasBlue && !hasGreen
        default: return hasText && !hasGreen && !hasBlue
        }
    }

    private static func expectDrawnColor(in clip: NSClipView, primaryChannel: Int, after action: String) throws {
        let bounds = clip.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure("Could not capture the editor viewport.") }
        bitmap.size = bounds.size
        clip.cacheDisplay(in: bounds, to: bitmap)
        guard let pixels = bitmap.bitmapData else { throw Failure("No viewport pixels were drawn.") }
        let otherChannel = (primaryChannel + 1) % 3
        let thirdChannel = (primaryChannel + 2) % 3
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<min(300, bitmap.pixelsWide) {
                let offset = y * bitmap.bytesPerRow + x * 4
                let color = Int(pixels[offset + primaryChannel])
                if color - Int(pixels[offset + otherChannel]) > 32,
                   color - Int(pixels[offset + thirdChannel]) > 32 { return }
            }
        }
        throw Failure("Missing syntax color in the first frame after \(action).")
    }

    private static func checkScrolling(document: DocumentWindow, manager: NSTextLayoutManager) async throws {
        let editor = document.editor
        let lines = (0..<2_400).map { "    let token_\($0) = \"sample\"; // comment \($0)\n" }
        let input = "fn main() {\n" + lines.joined() + "}\n"
        let text = input as NSString
        // Use a different mode first so the full-buffer installation requests an immediate result.
        document.setSyntaxLanguage(.plainText)
        editor.string = input
        editor.didChangeText()
        let start = ContinuousClock.now
        document.setSyntaxLanguage(.rust)
        let openingToken = text.range(of: "\"sample\"")
        try await waitForColor(at: openingToken, in: manager)
        let initial = start.duration(to: .now)
        print("Syntax first visible color in \(text.length) UTF-16 units: \(initial).")

        for line in [1_200, 2_370, 40] {
            let marker = text.range(of: "token_\(line) = ")
            let token = NSRange(location: NSMaxRange(marker), length: 8)
            editor.scrollRangeToVisible(token)
            manager.textViewportLayoutController.layoutViewport()
            guard let viewport = manager.textViewportLayoutController.viewportRange,
                  NSLocationInRange(token.location, editor.charRange(viewport, in: manager)) else {
                throw Failure("The test scroll did not reach source line \(line).")
            }
            try await waitForColor(at: token, in: manager)
        }
    }

    static func renderingForeground(at offset: Int, in manager: NSTextLayoutManager) -> NSColor? {
        guard offset != NSNotFound, let location = manager.location(manager.documentRange.location, offsetBy: offset) else { return nil }
        var foreground: NSColor?
        manager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, range in
            if range.contains(location) { foreground = attributes[.foregroundColor] as? NSColor }
            return false
        }
        return foreground
    }

    static func waitForColor(at token: NSRange, in manager: NSTextLayoutManager,
                             expected: SyntaxColor? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            manager.textViewportLayoutController.layoutViewport()
            if let foreground = renderingForeground(at: token.location, in: manager),
               foreground == expected?.nativeColor || (expected == nil && foreground != .textColor) { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw Failure("TextKit did not render syntax at offset \(token.location).")
    }

    private nonisolated static func checkGrammars() throws {
        let fixtures: [(SyntaxLanguage, String, String, SyntaxColor)] = [
            (.c, "int main(void) { return 0; }", "return", .keyword),
            (.cpp, "namespace shapes { class Circle {}; }", "Circle", .type),
            (.cpp, "#include <stdint.h>\n", "<stdint.h>", .string),
            (.cpp, "typedef void (*FixtureCallback)(uint32_t value);", "typedef", .keyword),
            (.clojure, "{:deps {:lib \"1.2\"} :count 2}", ":deps", .keyword),
            (.css, ".card { color: red; }", "color", .property),
            (.erlang, "greet() -> \"hello\".", "greet", .function),
            (.go, "package shapes\nfunc area() int { return 1 }", "area", .function),
            (.html, "<section class=\"card\">Hi</section>", "section", .markup),
            (.javascript, "const name = \"Edit\";", "\"Edit\"", .string),
            (.javascriptJSX, "const card = <section />;", "section", .markup),
            (.json, "{ /* comment */ \"name\": \"Edit\" }", "\"name\"", .property),
            (.lua, "local function greet() return 1 end", "greet", .function),
            (.markdown, "# Edit\n\n**Bold**\n\n```rs\nfn main() {}\n```\n", "main", .function),
            (.markdown, "# Edit ###\n", "# Edit ###", .markup),
            (.markdown, "| `Head` | Name |\n| --- | --- |\n| `cell` | Example |\n", "`Head`", .markup),
            (.markdown, "| `Head` | Name |\n| --- | --- |\n| `cell` | Example |\n", "`cell`", .markup),
            (.markdown, "<!-- open\n\n# Hidden\n", "<!-- open\n\n# Hidden\n", .comment),
            (.markdown, "Text <!-- open\n\n# Hidden\n\n```rs\nfn main() {}\n```\n", "# Hidden\n\n```rs\nfn main() {}\n```\n", .comment),
            (.markdown, "Text <!-- closed -->\n\n# Visible\n", "# Visible", .markup),
            (.markdown, "Code `<!-- literal`\n\n# Visible\n", "# Visible", .markup),
            (.markdown, "```text\n<!-- literal\n```\n\n# Visible\n", "# Visible", .markup),
            (.markdown, "```objective-c++\n@interface Widget\n@end\n```\n", "@interface", .keyword),
            (.objectiveC, "@interface Widget\n- (void)update:(id)value;\n@end\n", "update", .function),
            (.objectiveC, "id title(void) { return @\"Edit\"; }", "@\"Edit\"", .string),
            (.objectiveCPP, "namespace ui { template <typename T> class Box {}; }\n@interface Widget\n@end\n", "template", .keyword),
            (.objectiveCPP, "namespace ui { int run() { return [Widget count]; } }", "count", .function),
            (.odin, "package shapes\n\nArea :: proc(n: f64) -> f64 { return n }\n", "proc", .keyword),
            (.odin, "package shapes\n\nArea :: proc(n: f64) -> f64 { return n }\n", "Area", .function),
            (.odin, "package shapes\n\nArea :: proc(n: f64) -> f64 { return n }\n", "f64", .type),
            (.odin, "package shapes\n\nArea :: proc(n: f64) -> f64 { return n }\n", "return", .control),
            (.odin, "package shapes\n\nimport \"core:fmt\"\nmain :: proc() { fmt.println(\"café 🦜\") }\n", "\"café 🦜\"", .string),
            (.odin, "package shapes\n\nCallback :: #type proc(n: int) -> int\n", "Callback", .type),
            (.odin, "package shapes\n\npending :: proc(n: int) -> int {\n    return", "pending", .function),
            (.odin, "package shapes\n\n/* outer /* nested */ still a comment */\n", "still a comment", .comment),
            (.odin, "proc \"", "\"", .control),
            (.odin, "f :: proc \"cust", "\"cust", .control),
            (.odin, "f :: proc /* ABI */\n \"c\" () {}", "\"c\"", .control),
            (.odin, "callback_proc :: \"", "\"", .string),
            (.odin, "callback_proc \"", "\"", .string),
            (.odin, "foo() '", "'", .string),
            (.odin, "\"", "\"", .string),
            (.odin, "'", "'", .string),
            (.odin, "text :: \"left\\\"right\nnext :: 42", "\"left\\\"right", .string),
            (.odin, "text :: \"left\\\"right\nnext :: 42", "42", .number),
            (.odin, "r :: '\\''\nnext :: 42", "'\\''", .string),
            (.odin, "text :: \"\"\"\nproc \"\nthird line", "third line", .string),
            (.odin, "text :: `proc \" ' still raw", "still raw", .string),
            (.odin, "/*\" proc \" ' still a comment", "still a comment", .comment),
            (.markdown, "```odin\npackage shapes\nArea :: proc() {}\n```\n", "Area", .function),
            (.python, "def greet():\n    return 1\n", "greet", .function),
            (.ruby, "def greet\n  'hello'\nend", "greet", .function),
            (.ruby, "\"", "\"", .string),
            (.ruby, "\"hello\ndef fn", "\"hello\ndef fn", .string),
            (.ruby, "puts 'hello\ndef fn", "'hello\ndef fn", .string),
            (.ruby, "%q(hello\ndef fn", "%q(hello\ndef fn", .string),
            (.ruby, #""escaped \"# + "\n" + "def fn", "def fn", .string),
            (.ruby, #""escape\"#, #""escape\"#, .string),
            (.ruby, "\"hello #{name}\ndef fn", "def fn", .string),
            (.ruby, "\"hello #{name}\ndef fn", "name", .function),
            (.ruby, "\"hello\"\ndef fn\nend", "def", .keyword),
            (.rust, "fn main() { let café = \"🦜\"; }", "\"🦜\"", .string),
            (.shell, "greet() { echo hello; }", "greet", .function),
            (.solidity, "contract Counter { function get() public pure returns (uint) { return 1; } }", "get", .function),
            (.swift, "func greet() -> String { return \"hello\" }", "greet", .function),
            (.toml, "title = \"Edit\"", "title", .property),
            (.typescript, "type Shape = { radius: number };", "Shape", .type),
            (.tsx, "const card = <section />;", "section", .markup),
            (.yaml, "name: Edit\n", "name", .property),
            (.zig, ".{ .version = \"0.1.0\" }", "version", .property),
            (.zig, ".{ .version = \"0.1.0\", .id = 0x0123456789abcdef }", "\"0.1.0\"", .string),
            (.zig, "const value = \"", "\"", .string),
            (.zig, "const value = \"hello", "\"hello", .string),
            (.zig, "\"hello\nconst next = 1;", "\"hello", .string),
            (.zig, "\"hello\nconst next = 1;", "const", .keyword),
            (.zig, ".{ .name = \"hello", "\"hello", .string),
            (.zig, #"const s = "escaped \" tail"#, #""escaped \" tail"#, .string),
            (.zig, #"const s = "escape\"#, #""escape\"#, .string),
            (.zig, "fn use(arg: u32) void {}", "u32", .type),
            (.zig, #"const @"quoted\nname" = "ordinary\ntext";"#, #""ordinary\ntext""#, .string),
        ]
        for (mode, source, text, color) in fixtures {
            let token = (source as NSString).range(of: text)
            guard let spans = SyntaxEngine.spans(in: source, language: mode),
                  spans.contains(where: { $0.start <= token.location && $0.end >= NSMaxRange(token) && $0.color == color }) else {
                throw Failure("Missing \(mode.displayName) capture for \(text).")
            }
        }
        for source in [#"const @"open"#, #"const @"escape\"#, #"// "comment"#] {
            guard let spans = SyntaxEngine.spans(in: source, language: .zig), !spans.contains(where: { $0.color == .string }) else {
                throw Failure("Recovered Zig string highlighting leaked into \(source).")
            }
        }
        for literal in ["null", "undefined", "unreachable", "true", "false"] {
            let source = "const value = \(literal);"
            let token = (source as NSString).range(of: literal)
            guard let spans = SyntaxEngine.spans(in: source, language: .zig),
                  spans.contains(where: { $0.start == token.location && $0.end == token.upperBound && $0.color == .control }) else {
                throw Failure("Missing Zig keyword literal color for \(literal).")
            }
        }
        let zigSource = #"""
            const std = @import("module");
            const MAX_SIZE = 32;
            const Record = struct { field: u32, null: f80 };
            const Tuple = struct { TupleItem, TupleItem };
            const KnownTuple = struct { u8, bool };
            const Explicit: type = struct {};
            const Options = enum { One, @"two words", true };
            const Variant = union(enum) { empty, tagged: c_char };
            const Faults = error{ Declared };
            const missing = error.Missing;
            const frameType = anyframe->void;
            const frameValue = anyframe;
            const ByteSlice = []const u8;
            const unresolved: UnknownType = struct {};
            const unknownSlice = []UnknownType;
            const claimedType: type = 21;
            const @"quoted\nname" = "ordinary\ntext";
            var Counter: u32 = 0;
            var usingnamespace = 42;
            var async = 1;
            var await = 2;
            extern "c" fn variadic(ordinaryParam: c_int, ...) void;
            fn declare(comptime TypeParam: type, someInt: u32, zeroBit: u0, obj: InputType) void {
                _ = obj.Member;
                _ = obj.size;
                _ = obj.c_char;
                _ = .looseTag;
                _ = Record{ .designator = 1 };
                callee();
                obj.callback();
                blockName: { break :breakTarget; }
            }
            """#
        guard let zigSpans = SyntaxEngine.spans(in: zigSource, language: .zig) else {
            throw Failure("Missing Zig Tree-sitter captures.")
        }
        let source = zigSource as NSString
        let coloredTokens: [(String, SyntaxColor)] = [
            ("@import", .function),
            ("Record", .type), ("KnownTuple", .type), ("Explicit", .type), ("Options", .type), ("Variant", .type), ("Faults", .type),
            ("Declared", .type), ("Missing", .type), ("f80", .type), ("c_char", .type), ("ByteSlice", .type),
            ("TypeParam", .type), ("u0", .type), ("...", .type),
            ("field", .property), ("null", .property), ("One", .property), (#"@"two words""#, .property),
            ("true", .property), ("empty", .property), ("tagged", .property), ("designator", .property),
            ("ordinaryParam", .property), ("someInt", .property), ("zeroBit", .property),
            ("blockName", .control), ("breakTarget", .control), ("anyframe", .keyword),
        ]
        for (spelling, color) in coloredTokens {
            let token = source.range(of: spelling)
            guard zigSpans.contains(where: { $0.start == token.location && $0.end == token.upperBound && $0.color == color }) else {
                throw Failure("Expected Zig Tree-sitter color \(color) for \(spelling).")
            }
        }
        let standaloneFrame = source.range(of: "anyframe", options: .backwards)
        guard zigSpans.contains(where: { $0.start == standaloneFrame.location && $0.end == standaloneFrame.upperBound && $0.color == .type }) else {
            throw Failure("Expected the standalone Zig anyframe type color.")
        }
        for name in ["std", "MAX_SIZE", "Counter", "Member", "size", "looseTag", "obj.c_char", "Tuple", "TupleItem",
                     #"@"quoted\nname""#, "usingnamespace", "async", "await", "declare", "obj", "InputType", "callee",
                     "callback", "unresolved", "UnknownType", "unknownSlice", "claimedType"] {
            let token = source.range(of: name)
            guard token.location != NSNotFound,
                  !zigSpans.contains(where: { $0.start < token.upperBound && $0.end > token.location }) else {
                throw Failure("Expected an uncolored Zig identifier for \(name).")
            }
        }
        let names: [(String, SyntaxLanguage)] = [
            ("main.RS", .rust), ("widget.test.ts", .typescript), ("widget.tsx", .tsx),
            ("tsconfig.json", .json), (".zshrc", .shell), ("Cargo.lock", .toml),
            ("Gemfile", .ruby), ("library.h", .cpp), ("Counter.t.sol", .solidity),
            ("widget.c", .c), ("widget.cc", .cpp), ("widget.M", .objectiveC), ("widget.mm", .objectiveCPP),
            ("build.zig.zon", .zig), ("main.odin", .odin), ("example.ODIN", .odin),
            ("app.app.src", .erlang), ("rebar.config", .erlang),
            ("deps.edn", .clojure), ("extensionless", .plainText)
        ]
        for (name, language) in names {
            guard SyntaxLanguage.detected(at: URL(fileURLWithPath: name)) == language else {
                throw Failure("Unexpected syntax mode for \(name).")
            }
        }
    }
}
