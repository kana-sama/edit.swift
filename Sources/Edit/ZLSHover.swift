import Foundation

struct ZLSHover: Sendable {
    struct Reference: Sendable {
        let title: String
        let url: URL
    }

    let declaration: String
    let types: [String]
    let hasMoreTypes: Bool
    let documentation: String?
    let references: [Reference]

    init?(markdown: String) {
        var input = Input(remaining: markdown[...])
        guard let declaration = input.readFence("zig"),
              !declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var types: [String] = []
        var hasMoreTypes = false
        var references: [Reference] = []
        // Builtin documentation follows its lone fence directly.
        if !Self.isBuiltin(declaration) {
            while input.nextLine == "```zig" {
                guard let wrapped = input.readFence("zig"), let type = Self.unwrapType(wrapped) else { return nil }
                types.append(type)
            }
            guard !types.isEmpty else { return nil }
            if input.nextLine == "```txt" {
                guard input.readFence("txt") == "(...)" else { return nil }
                hasMoreTypes = true
            }
            if !input.remaining.isEmpty {
                guard input.readLine() == "" else { return nil }
            }
            if let line = input.nextLine, line.hasPrefix("Go to "),
               line.range(of: "](file:", options: .caseInsensitive) != nil {
                guard let parsed = Self.readReferences(line.dropFirst("Go to ".count)) else { return nil }
                references = parsed
                _ = input.readLine()
                if !input.remaining.isEmpty {
                    guard input.readLine() == "" else { return nil }
                }
            }
        }

        // Some field accesses concatenate complete hover records. Their boundary
        // is indistinguishable from fenced examples in the preceding documentation.
        guard !Self.containsAnotherDeclaration(input.remaining) else { return nil }
        self.declaration = Self.dedentContinuation(of: declaration)
        self.types = types
        self.hasMoreTypes = hasMoreTypes
        self.documentation = input.remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : String(input.remaining)
        self.references = references
    }

    private static func isBuiltin(_ declaration: String) -> Bool {
        guard declaration.first == "@" else { return false }
        let tail = declaration.dropFirst()
        let name = tail.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return !name.isEmpty && tail[name.endIndex...].first == "("
    }

    private static func unwrapType(_ text: String) -> String? {
        guard text.first == "(", text.last == ")" else { return nil }
        let type = text.dropFirst().dropLast()
        return type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(type)
    }

    private static func readReferences(_ markdown: Substring) -> [Reference]? {
        guard let parsed = try? AttributedString(
            markdown: String(markdown), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        var references: [Reference] = []
        var needsReference = true
        for (url, range) in parsed.runs[\.link] {
            let text = String(parsed[range].characters)
            if needsReference {
                guard let url, case .definition? = HoverLink(url),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                references.append(Reference(title: text, url: url))
            } else {
                guard url == nil, text == " | " else { return nil }
            }
            needsReference.toggle()
        }
        return needsReference ? nil : references
    }

    private static func containsAnotherDeclaration(_ documentation: Substring) -> Bool {
        var input = Input(remaining: documentation)
        while let line = input.nextLine {
            guard line == "```zig" else {
                _ = input.readLine()
                continue
            }
            guard input.readFence("zig") != nil else { break }
            var following = input
            if let wrapped = following.readFence("zig"), unwrapType(wrapped) != nil { return true }
        }
        return false
    }

    private static func dedentContinuation(of declaration: String) -> String {
        let lines = declaration.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return declaration }
        let nonblank = lines.dropFirst().filter { !$0.allSatisfy(isIndentation) }
        guard var indentation = nonblank.first?.prefix(while: isIndentation) else { return declaration }
        for line in nonblank.dropFirst() {
            let common = zip(indentation, line).prefix { $0 == $1 }.count
            indentation = indentation.prefix(common)
            if indentation.isEmpty { return declaration }
        }
        guard !indentation.isEmpty else { return declaration }
        return ([first] + lines.dropFirst().map { line in
            line.hasPrefix(indentation) ? line.dropFirst(indentation.count) : line
        }).joined(separator: "\n")
    }

    private static func isIndentation(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private struct Input {
        var remaining: Substring

        var nextLine: Substring? {
            guard !remaining.isEmpty else { return nil }
            return remaining.prefix { $0 != "\n" && $0 != "\r\n" }
        }

        mutating func readLine() -> Substring? {
            guard let line = nextLine else { return nil }
            remaining = remaining[line.endIndex...].dropFirst()
            return line
        }

        mutating func readFence(_ language: String) -> String? {
            guard nextLine == "```\(language)" else { return nil }
            _ = readLine()
            var lines: [Substring] = []
            while let line = readLine() {
                if line == "```" { return lines.joined(separator: "\n") }
                lines.append(line)
            }
            return nil
        }
    }
}
