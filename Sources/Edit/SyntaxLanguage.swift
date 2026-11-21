import Foundation

enum SyntaxLanguage: String, CaseIterable, Sendable {
    case plainText = "plain-text"
    case c
    case cpp
    case clojure
    case css
    case erlang
    case go
    case html
    case javascript
    case javascriptJSX = "javascript-jsx"
    case json
    case lua
    case markdown
    case python
    case ruby
    case rust
    case shell
    case solidity
    case swift
    case toml
    case typescript
    case tsx
    case yaml
    case zig

    var displayName: String {
        switch self {
        case .plainText: "Plain Text"
        case .c: "C"
        case .cpp: "C++"
        case .clojure: "Clojure"
        case .css: "CSS"
        case .erlang: "Erlang"
        case .go: "Go"
        case .html: "HTML"
        case .javascript: "JavaScript"
        case .javascriptJSX: "JavaScript JSX"
        case .json: "JSON"
        case .lua: "Lua"
        case .markdown: "Markdown"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .shell: "Shell Script"
        case .solidity: "Solidity"
        case .swift: "Swift"
        case .toml: "TOML"
        case .typescript: "TypeScript"
        case .tsx: "TypeScript JSX"
        case .yaml: "YAML"
        case .zig: "Zig"
        }
    }

    var iconIdentifier: String {
        switch self {
        case .shell: "shellscript"
        case .javascriptJSX: "javascriptreact"
        case .tsx: "typescriptreact"
        default: rawValue
        }
    }

    static func detected(at url: URL?) -> Self {
        guard let name = url?.lastPathComponent.lowercased() else { return .plainText }
        if let exact = exactNames[name] { return exact }
        for (suffix, language) in suffixes where name.hasSuffix(suffix) {
            return language
        }
        return .plainText
    }

    private static let exactNames: [String: Self] = [
        "emakefile": .erlang, "rebar.config": .erlang, "jakefile": .javascript,
        "sconscript": .python, "sconstruct": .python,
        "brewfile": .ruby, "gemfile": .ruby, "podfile": .ruby, "rakefile": .ruby, "vagrantfile": .ruby,
        ".bash_profile": .shell, ".bashrc": .shell, ".envrc": .shell, ".profile": .shell,
        ".zprofile": .shell, ".zshenv": .shell, ".zshrc": .shell, "apkbuild": .shell, "pkgbuild": .shell,
        "cargo.lock": .toml
    ]

    private static let suffixes: [(String, Self)] = {
        let groups: [(Self, [String])] = [
            (.c, ["c", "i"]),
            (.cpp, ["c++", "cc", "cpp", "cppm", "cxx", "h", "h++", "hh", "hpp", "hxx", "inl", "ipp", "ixx", "tpp"]),
            (.clojure, ["clj", "cljc", "cljs", "edn"]),
            (.css, ["css"]),
            (.erlang, ["app.src", "erl", "erlang", "escript", "hrl", "xrl", "yrl"]),
            (.go, ["go"]),
            (.html, ["htm", "html", "xhtml"]),
            (.javascript, ["cjs", "js", "mjs"]),
            (.javascriptJSX, ["jsx"]),
            (.json, ["code-workspace", "geojson", "json", "jsonc", "jsonld", "webmanifest"]),
            (.lua, ["lua"]),
            (.markdown, ["markdown", "md", "mdown", "mkd"]),
            (.python, ["py", "pyi", "pyw"]),
            (.ruby, ["gemspec", "podspec", "rake", "rb", "rbi", "ru"]),
            (.rust, ["rs"]),
            (.shell, ["bash", "bats", "sh", "zsh"]),
            (.solidity, ["sol"]),
            (.swift, ["swift", "swiftinterface"]),
            (.toml, ["toml"]),
            (.typescript, ["cts", "d.ts", "mts", "ts"]),
            (.tsx, ["tsx"]),
            (.yaml, ["yaml", "yml"]),
            (.zig, ["zig", "zon"])
        ]
        return groups.flatMap { language, values in values.map { ("." + $0, language) } }
            .sorted { $0.0.count > $1.0.count }
    }()
}

@MainActor
final class SyntaxLanguageOverrides {
    private let defaults: UserDefaults?
    private var values: [[String: String]]
    private static let key = "syntaxLanguageOverrides"

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        values = (defaults?.array(forKey: Self.key) as? [[String: String]]) ?? []
    }

    func language(for url: URL?) -> SyntaxLanguage? {
        guard let url, let raw = values.first(where: { $0["path"] == url.path })?["language"] else {
            return nil
        }
        return SyntaxLanguage(rawValue: raw)
    }

    func set(_ language: SyntaxLanguage?, for url: URL?) {
        guard let url else { return }
        let path = url.path
        let previous = values
        values.removeAll { $0["path"] == path }
        if let language {
            values.insert(["path": path, "language": language.rawValue], at: 0)
        }
        if values.count > 100 {
            values.removeSubrange(100...)
        }
        if values != previous {
            defaults?.set(values, forKey: Self.key)
        }
    }
}
