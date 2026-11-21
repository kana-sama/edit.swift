import AppKit

@MainActor
enum SyntaxCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(in app: Edit) async throws {
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
        let origin = manager.documentRange.location
        let token = (input as NSString).range(of: "main")
        let deadline = ContinuousClock.now + .seconds(4)
        var colored = false
        repeat {
            manager.textViewportLayoutController.layoutViewport()
            manager.enumerateRenderingAttributes(from: origin, reverse: false) { _, attributes, range in
                let offset = manager.offset(from: origin, to: range.location)
                if offset == token.location, attributes[.foregroundColor] is NSColor {
                    colored = true
                    return false
                }
                return true
            }
            if !colored { try await Task.sleep(for: .milliseconds(20)) }
        } while !colored && ContinuousClock.now < deadline
        guard colored else { throw Failure("TextKit did not render Rust syntax.") }
        document.setSyntaxLanguage(.plainText)
        var coloredAfterReset = false
        manager.enumerateRenderingAttributes(from: origin, reverse: false) { _, attributes, _ in
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
