import Foundation

enum SolarHover {
    struct Documentation: Sendable {
        var notice: String?
        var developer: String?
        var parameters: [(name: String, text: String)] = []
        var returns: [String] = []

        var isEmpty: Bool { notice == nil && developer == nil && parameters.isEmpty && returns.isEmpty }
    }

    static func documentation(in source: String, at location: LSPRange, symbol: String) -> Documentation? {
        let text = source as NSString
        guard let name = LSPTextIndex(source).nsRange(location, clampingColumns: false), name.length > 0,
              text.substring(with: name) == symbol else { return nil }
        let prefix = text.substring(to: name.location) as NSString
        let declaration = prefix.range(
            of: #"\b(?:abstract[ \t]+)?(?:function|modifier|event|error|contract|interface|library|struct|enum|type)\s+\z"#,
            options: .regularExpression)
        guard declaration.location != NSNotFound else { return nil }
        let before = prefix.substring(to: declaration.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [Substring]
        if before.hasSuffix("*/"), let opening = before.range(of: "/*", options: .backwards),
           before[opening.lowerBound...].hasPrefix("/**") {
            let body = before[opening.lowerBound...].dropFirst(3).dropLast(2)
            let rawLines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let indentation = rawLines.dropFirst().filter { !$0.allSatisfy(\.isWhitespace) }
                .map { $0.prefix(while: \.isWhitespace).count }.min() ?? 0
            lines = rawLines.enumerated().map { index, line in
                if let margin = commentMargin(in: line) { return content(of: line, after: margin) }
                return index == 0 ? line.drop(while: \.isWhitespace) : line.dropFirst(indentation)
            }
        } else {
            let preceding = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reversed()
            lines = preceding.lazy.map { $0.drop(while: \.isWhitespace) }.prefix { $0.hasPrefix("///") }.reversed().map {
                let body = $0.dropFirst(3)
                return body.first == " " ? body.dropFirst() : body
            }
        }
        return documentation(from: lines)
    }

    private static func documentation(from lines: [Substring]) -> Documentation? {
        var fields: [(tag: Substring, lines: [Substring])] = [("notice", [])]
        var fence = MarkdownFence()
        for line in lines {
            let trimmed = line.drop(while: \.isWhitespace)
            if !fence.contains(line), trimmed.hasPrefix("@") {
                let tag = trimmed.dropFirst().prefix { $0.isLetter || $0 == "-" || $0 == ":" }
                if !tag.isEmpty, trimmed[tag.endIndex...].first?.isWhitespace != false {
                    // Solar resolves inherited sections when the source contains an inheritance directive.
                    if tag == "inheritdoc" { return nil }
                    fields.append((tag, [trimmed[tag.endIndex...].drop(while: \.isWhitespace)]))
                    continue
                }
            }
            fields[fields.count - 1].lines.append(line)
        }
        var result = Documentation()
        for field in fields {
            let body = field.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            switch field.tag {
            case "notice": result.notice = [result.notice, body].compactMap { $0 }.joined(separator: "\n\n")
            case "dev": result.developer = [result.developer, body].compactMap { $0 }.joined(separator: "\n\n")
            case "param":
                let name = body.prefix(while: { !$0.isWhitespace })
                let text = body[name.endIndex...].drop(while: \.isWhitespace)
                if !text.isEmpty { result.parameters.append((String(name), String(text))) }
            case "return": result.returns.append(body)
            default: break
            }
        }
        return result.isEmpty ? nil : result
    }

    private struct MarkdownFence {
        private var delimiter: Substring?

        mutating func contains(_ line: Substring) -> Bool {
            let trimmed = line.drop(while: \.isWhitespace)
            if let open = delimiter {
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) {
                    delimiter = nil
                }
                return true
            }
            guard let marker = trimmed.first, marker == "`" || marker == "~" else { return false }
            let opening = trimmed.prefix { $0 == marker }
            guard opening.count >= 3 else { return false }
            delimiter = opening
            return true
        }
    }

    static func markdownWithoutCommentMargins(_ markdown: String) -> String {
        var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var fence = MarkdownFence()
        var index = 0
        while index + 1 < lines.count {
            let line = lines[index]
            index += 1
            if fence.contains(line) { continue }
            guard !line.isEmpty, line.first?.isWhitespace == false,
                  let margin = commentMargin(in: lines[index]) else { continue }

            let end = lines[index...].prefix { commentMargin(in: $0) == margin }.endIndex
            let continuation = index..<end
            let firstMargin = commentMargin(in: line)
            // Solar leaves the original indentation and asterisk on continuation lines.
            // A bare margin marks a blank line. Preserve ordinary Markdown bullets.
            let hasBlankLine = continuation.contains { lines[$0].dropFirst(margin.count).allSatisfy(\.isWhitespace) }
            let listIndent = line.hasPrefix("- ") ? "  " : ""
            let hasSourceIndent = margin.count - 1 >= listIndent.count + 4 || margin.contains("\t")
            if hasBlankLine || (firstMargin == nil && hasSourceIndent) {
                if let firstMargin {
                    lines[index - 1] = content(of: line, after: firstMargin)
                }
                for row in continuation {
                    let text = content(of: lines[row], after: margin)
                    lines[row] = text.isEmpty ? "" : Substring(listIndent + text)
                }
            }
            index = end
        }
        return lines.joined(separator: "\n")
    }

    private static func commentMargin(in line: Substring) -> Substring? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let content = line[indentation.endIndex...]
        guard content.first == "*", content.dropFirst().first?.isWhitespace != false else { return nil }
        return line.prefix(indentation.count + 1)
    }

    private static func content(of line: Substring, after margin: Substring) -> Substring {
        let tail = line.dropFirst(margin.count)
        return tail.allSatisfy(\.isWhitespace) ? "" : tail.dropFirst()
    }
}
