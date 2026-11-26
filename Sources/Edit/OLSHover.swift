import Foundation

struct OLSHover: Sendable {
    let declaration: String
    let documentation: String?

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
