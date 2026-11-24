import Foundation

struct LSPPosition: Codable, Comparable, Sendable {
    let line: Int
    let character: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.line, lhs.character) < (rhs.line, rhs.character)
    }

    static func at(utf16Offset: Int, in text: String) -> Self? {
        LSPTextIndex(text).position(at: utf16Offset)
    }

    var parameters: [String: Int] { ["line": line, "character": character] }
}

struct LSPRange: Codable, Hashable, Sendable {
    let start: LSPPosition
    let end: LSPPosition

    func nsRange(in text: String) -> NSRange? {
        LSPTextIndex(text).nsRange(self)
    }

    var parameters: [String: [String: Int]] { ["start": start.parameters, "end": end.parameters] }
}

extension LSPPosition: Hashable {}

/// Maps protocol positions to the UTF-16 offsets used by AppKit. A position cannot split
/// a surrogate pair or the CRLF separator between two lines.
struct LSPTextIndex {
    private let text: NSString
    private let lineStarts: [Int]
    private let lineEnds: [Int]

    init(_ source: String) {
        let text = source as NSString
        self.text = text
        var starts = [0]
        var ends: [Int] = []
        var offset = 0
        while offset < text.length {
            let character = text.character(at: offset)
            if character == 10 || character == 13 {
                ends.append(offset)
                if character == 13 && offset + 1 < text.length && text.character(at: offset + 1) == 10 {
                    offset += 1
                }
                starts.append(offset + 1)
            }
            offset += 1
        }
        ends.append(text.length)
        lineStarts = starts
        lineEnds = ends
    }

    var fullRange: LSPRange {
        let lastLine = lineStarts.count - 1
        return LSPRange(start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: lastLine, character: text.length - lineStarts[lastLine]))
    }

    func position(at offset: Int) -> LSPPosition? {
        guard (0...text.length).contains(offset), isScalarBoundary(offset) else { return nil }
        var lower = 0
        var upper = lineStarts.count
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= offset { lower = middle } else { upper = middle }
        }
        guard offset <= lineEnds[lower] else { return nil }
        return LSPPosition(line: lower, character: offset - lineStarts[lower])
    }

    func nsRange(_ range: LSPRange) -> NSRange? {
        guard range.start <= range.end, let start = offset(of: range.start),
              let end = offset(of: range.end), start <= end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func offset(of position: LSPPosition) -> Int? {
        guard lineStarts.indices.contains(position.line), position.character >= 0 else { return nil }
        let start = lineStarts[position.line]
        let offset = start + min(position.character, lineEnds[position.line] - start)
        return isScalarBoundary(offset) ? offset : nil
    }

    private func isScalarBoundary(_ offset: Int) -> Bool {
        guard offset > 0 && offset < text.length else { return true }
        return !(0xD800...0xDBFF).contains(text.character(at: offset - 1)) ||
            !(0xDC00...0xDFFF).contains(text.character(at: offset))
    }
}

struct LSPLocation: Decodable, Hashable, Sendable {
    let url: URL
    let range: LSPRange
    let originRange: LSPRange?

    init(url: URL, range: LSPRange, originRange: LSPRange? = nil) {
        self.url = url
        self.range = range
        self.originRange = originRange
    }

    private enum CodingKeys: String, CodingKey {
        case uri, range, targetUri, targetSelectionRange, originSelectionRange
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let target = try values.decodeIfPresent(URL.self, forKey: .targetUri) {
            url = target
            range = try values.decode(LSPRange.self, forKey: .targetSelectionRange)
            originRange = try values.decodeIfPresent(LSPRange.self, forKey: .originSelectionRange)
        } else {
            url = try values.decode(URL.self, forKey: .uri)
            range = try values.decode(LSPRange.self, forKey: .range)
            originRange = nil
        }
    }
}

struct LSPHover: Decodable, Sendable {
    let content: String
    let range: LSPRange?
    let isMarkdown: Bool

    private struct Content: Decodable {
        let value: String
        let kind: String?
        let language: String?

        var markdown: String {
            guard let language, !language.contains("\n"), !language.contains("`") else { return value }
            let longestFence = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longestFence + 1))
            return "\(fence)\(language)\n\(value)\n\(fence)"
        }
    }

    private enum CodingKeys: String, CodingKey { case contents, range }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        range = try values.decodeIfPresent(LSPRange.self, forKey: .range)
        if let contents = try? values.decode(Content.self, forKey: .contents) {
            isMarkdown = contents.kind != "plaintext"
            content = isMarkdown ? contents.markdown : contents.value
        } else if let text = try? values.decode(String.self, forKey: .contents) {
            content = text
            isMarkdown = true
        } else {
            content = try values.decode([MarkedString].self, forKey: .contents)
                .map(\.markdown).joined(separator: "\n\n")
            isMarkdown = true
        }
    }

    private struct MarkedString: Decodable {
        let markdown: String

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { markdown = string }
            else { markdown = try value.decode(Content.self).markdown }
        }
    }
}
