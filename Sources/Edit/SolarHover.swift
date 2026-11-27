enum SolarHover {
    static func markdownWithoutCommentMargins(_ markdown: String) -> String {
        var lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var fence: Substring?
        var index = 0
        while index + 1 < lines.count {
            let line = lines[index]
            let trimmed = line.drop(while: \.isWhitespace)
            index += 1
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let delimiter = trimmed.prefix { $0 == marker }
                if delimiter.count >= 3 {
                    fence = delimiter
                    continue
                }
            }
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
