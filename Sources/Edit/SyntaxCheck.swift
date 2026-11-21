import AppKit

@MainActor
enum SyntaxCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(in app: Edit) async throws {
        try await checkFirstDraw(in: app, appearance: .aqua)
        try await checkFirstDraw(in: app, appearance: .darkAqua)
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

    private static func checkFirstDraw(in app: Edit, appearance: NSAppearance.Name) async throws {
        let document = app.makeDocument()
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
        print("Syntax in the first frame of a \(source.utf8.count)-byte file: open \(opened), scroll \(scrolled).")
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
        let otherChannel = 1 - primaryChannel
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<min(300, bitmap.pixelsWide) {
                let offset = y * bitmap.bytesPerRow + x * 4
                let color = Int(pixels[offset + primaryChannel])
                if color - Int(pixels[offset + otherChannel]) > 32,
                   color - Int(pixels[offset + 2]) > 32 { return }
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

    private static func waitForColor(at token: NSRange, in manager: NSTextLayoutManager) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            manager.textViewportLayoutController.layoutViewport()
            let origin = manager.documentRange.location
            guard let start = manager.location(origin, offsetBy: token.location) else { break }
            var colored = false
            manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
                let offset = manager.offset(from: origin, to: range.location)
                colored = offset == token.location && attributes[.foregroundColor] is NSColor
                return false
            }
            if colored { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw Failure("TextKit did not render Rust syntax at offset \(token.location).")
    }

    private nonisolated static func checkGrammars() throws {
        let fixtures: [(SyntaxLanguage, String, String, SyntaxColor)] = [
            (.c, "int main(void) { return 0; }", "return", .keyword),
            (.cpp, "namespace shapes { class Circle {}; }", "Circle", .type),
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
            (.python, "def greet():\n    return 1\n", "greet", .function),
            (.ruby, "def greet\n  'hello'\nend", "greet", .function),
            (.rust, "fn main() { let café = \"🦜\"; }", "\"🦜\"", .string),
            (.shell, "greet() { echo hello; }", "greet", .function),
            (.solidity, "contract Counter { function get() public pure returns (uint) { return 1; } }", "get", .function),
            (.swift, "func greet() -> String { return \"hello\" }", "greet", .function),
            (.toml, "title = \"Edit\"", "title", .property),
            (.typescript, "type Shape = { radius: number };", "Shape", .type),
            (.tsx, "const card = <section />;", "section", .markup),
            (.yaml, "name: Edit\n", "name", .property),
            (.zig, ".{ .version = \"0.1.0\", .id = 0x0123456789abcdef }", "version", .property),
        ]
        for (mode, source, text, color) in fixtures {
            let token = (source as NSString).range(of: text)
            guard let spans = SyntaxEngine.spans(in: source, language: mode),
                  spans.contains(where: { $0.start <= token.location && $0.end >= NSMaxRange(token) && $0.color == color }) else {
                throw Failure("Missing \(mode.displayName) capture for \(text).")
            }
        }
        let names: [(String, SyntaxLanguage)] = [
            ("main.RS", .rust), ("widget.test.ts", .typescript), ("widget.tsx", .tsx),
            ("tsconfig.json", .json), (".zshrc", .shell), ("Cargo.lock", .toml),
            ("Gemfile", .ruby), ("library.h", .cpp), ("Counter.t.sol", .solidity),
            ("build.zig.zon", .zig), ("app.app.src", .erlang), ("rebar.config", .erlang),
            ("deps.edn", .clojure), ("extensionless", .plainText)
        ]
        for (name, language) in names {
            guard SyntaxLanguage.detected(at: URL(fileURLWithPath: name)) == language else {
                throw Failure("Unexpected syntax mode for \(name).")
            }
        }
    }
}
