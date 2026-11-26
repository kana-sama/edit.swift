import Foundation

struct OLSHover: Sendable {
    let declaration: String
    let documentation: String?

    struct Field: Sendable {
        let label: NSRange
        let padding: NSRange
    }

    init?(markdown: String) {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "```odin", let closing = lines.dropFirst().firstIndex(of: "```") else { return nil }
        let declaration = lines[1..<closing].joined(separator: "\n")
        guard !declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.declaration = declaration

        var description = lines.dropFirst(closing + 1)
        if description.first == "---" { description = description.dropFirst() }
        documentation = description.allSatisfy { $0.allSatisfy(\.isWhitespace) }
            ? nil : Self.markdownWithIndentedExamples(description.joined(separator: "\n"))
    }

    static func alignedFields(in paragraph: String) -> [Field]? {
        let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3 else { return nil }
        var fields: [Field] = []
        var valueColumn: Int?
        var paddedLines = 0
        var offset = 0
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let label = line[..<colon]
            guard label.first?.isLetter == true,
                  label.last?.isWhitespace == false,
                  label.allSatisfy({ $0.isLetter || $0.isNumber || " _-".contains($0) }) else { return nil }
            let tail = line[line.index(after: colon)...]
            let padding = tail.prefix { $0 == " " }
            let column = label.count + 1 + padding.count
            guard !padding.isEmpty, tail[padding.endIndex...].first?.isWhitespace == false,
                  valueColumn == nil || valueColumn == column else { return nil }
            valueColumn = column
            if padding.count > 1 { paddedLines += 1 }
            let labelLength = label.utf16.count + 1
            fields.append(Field(label: NSRange(location: offset, length: labelLength),
                                padding: NSRange(location: offset + labelLength, length: padding.count)))
            offset += line.utf16.count + 1
        }
        // Repeated padding to the same source column distinguishes fields from prose.
        return paddedLines >= 2 ? fields : nil
    }

    private static func markdownWithIndentedExamples(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.map { $0.hasPrefix("\t") || $0.hasPrefix("    ") }
        guard indented.contains(true),
              let parsed = try? AttributedString(markdown: markdown, options: .init(appliesSourcePositionAttributes: true))
        else { return markdown }

        // Some Odin docs attach indented examples directly to prose. CommonMark
        // folds those lines into the paragraph. Split only top-level paragraphs.
        var paragraphs: [Int: Int] = [:]
        for run in parsed.runs {
            guard let components = run.presentationIntent?.components, components.count == 1,
                  components[0].kind == .paragraph, let position = run.markdownSourcePosition,
                  position.startLine == position.endLine else { continue }
            paragraphs[position.startLine - 1] = components[0].identity
        }
        return lines.enumerated().map { index, line in
            if index > 0, indented[index] != indented[index - 1],
               let paragraph = paragraphs[index], paragraphs[index - 1] == paragraph {
                return "\n" + line
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
