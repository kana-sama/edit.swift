import Foundation

struct SolidityHoverSignature: Sendable {
    private struct Clause: Sendable {
        let prefix: String
        let arguments: [String]?

        var inline: String {
            guard let arguments else { return prefix }
            return prefix + arguments.joined(separator: ", ") + ")"
        }

        func lines(indentedBy indentation: String, ending: String, fits: (String) -> Bool) -> [String] {
            let singleLine = indentation + inline + ending
            guard let arguments, !arguments.isEmpty, !fits(singleLine) else { return [singleLine] }
            let items = arguments.enumerated().map { index, argument in
                indentation + "  " + argument + (index < arguments.count - 1 ? "," : "")
            }
            return [indentation + prefix] + items + [indentation + ")" + ending]
        }
    }

    private let parameters: Clause
    private let suffix: [Clause]
    private let terminator: String

    init?(_ snippet: String) {
        let text = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isNewline), let opening = text.firstIndex(of: "(") else { return nil }
        let head = text[..<opening].split(whereSeparator: \.isWhitespace)
        let declarationKeywords: Set<Substring> = ["function", "constructor", "modifier", "fallback", "receive", "event", "error"]
        guard let keyword = head.first, declarationKeywords.contains(keyword), head.count <= 2,
              head.dropFirst().allSatisfy({ $0.allSatisfy(Self.isNameCharacter) }) else { return nil }

        terminator = text.hasSuffix(";") ? ";" : ""
        var input = Input(remaining: text[opening...].dropLast(terminator.count))
        guard let arguments = input.readArguments() else { return nil }
        parameters = Clause(prefix: head.joined(separator: " ") + "(", arguments: arguments)
        input.skipWhitespace()
        var suffix: [Clause] = []
        while !input.remaining.isEmpty {
            let name = input.remaining.prefix(while: Self.isNameCharacter)
            guard !name.isEmpty else { return nil }
            input.remaining = input.remaining.dropFirst(name.count)
            input.skipWhitespace()
            if input.remaining.first == "(" {
                guard let arguments = input.readArguments() else { return nil }
                suffix.append(Clause(prefix: String(name) + (name == "returns" ? " (" : "("), arguments: arguments))
            } else {
                guard name != "returns" else { return nil }
                suffix.append(Clause(prefix: String(name), arguments: nil))
            }
            input.skipWhitespace()
        }
        self.suffix = suffix
    }

    func formatted(fits: (String) -> Bool) -> String {
        let singleLine = ([parameters.inline] + suffix.map(\.inline)).joined(separator: " ") + terminator
        if fits(singleLine) { return singleLine }

        var lines = parameters.lines(indentedBy: "", ending: suffix.isEmpty ? terminator : "", fits: fits)
        var current = lines.count > 1 ? lines.removeLast() : ""
        for (index, clause) in suffix.enumerated() {
            let ending = index == suffix.count - 1 ? terminator : ""
            let candidate = (current.isEmpty ? "  " : current + " ") + clause.inline + ending
            if fits(candidate) {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                var wrapped = clause.lines(indentedBy: "  ", ending: ending, fits: fits)
                current = wrapped.removeLast()
                lines.append(contentsOf: wrapped)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_$.".contains(character)
    }

    private struct Input {
        var remaining: Substring

        mutating func skipWhitespace() { remaining = remaining.drop(while: \.isWhitespace) }

        mutating func readArguments() -> [String]? {
            guard remaining.first == "(" else { return nil }
            let inner = remaining.dropFirst()
            var start = inner.startIndex
            var arguments: [String] = []
            var closers: [Character] = []
            var quote: Character?
            var escaped = false
            for index in inner.indices {
                let character = inner[index]
                if let delimiter = quote {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == delimiter { quote = nil }
                    continue
                }
                switch character {
                case "\"", "'": quote = character
                case "(": closers.append(")")
                case "[": closers.append("]")
                case "{": closers.append("}")
                case ")" where closers.isEmpty:
                    let item = inner[start..<index].trimmingCharacters(in: .whitespaces)
                    guard !item.isEmpty || arguments.isEmpty else { return nil }
                    if !item.isEmpty { arguments.append(item) }
                    remaining = inner[inner.index(after: index)...]
                    return arguments
                case ")", "]", "}":
                    guard closers.popLast() == character else { return nil }
                case "," where closers.isEmpty:
                    let item = inner[start..<index].trimmingCharacters(in: .whitespaces)
                    guard !item.isEmpty else { return nil }
                    arguments.append(item)
                    start = inner.index(after: index)
                case "/":
                    let next = inner[inner.index(after: index)...].first
                    if next == "/" || next == "*" { return nil }
                default: break
                }
            }
            return nil
        }
    }
}
