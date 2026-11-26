import Foundation

struct LSPSemanticTokenOptions: Decodable, Sendable {
    struct Legend: Decodable, Sendable {
        let tokenTypes: [String]
        let tokenModifiers: [String]
    }

    let legend: Legend
    let full: Bool
    let delta: Bool
    let range: Bool

    private enum Key: String, CodingKey { case legend, full, range }
    private struct Full: Decodable { let delta: Bool? }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        legend = try values.decode(Legend.self, forKey: .legend)
        let fullOptions = try? values.decode(Full.self, forKey: .full)
        full = fullOptions != nil || (try? values.decode(Bool.self, forKey: .full)) == true
        delta = fullOptions?.delta == true
        if let enabled = try? values.decode(Bool.self, forKey: .range) {
            range = enabled
        } else {
            range = (try? values.nestedContainer(keyedBy: Key.self, forKey: .range)) != nil
        }
    }
}

struct LSPSemanticTokens: Sendable {
    struct Response: Decodable {
        struct Edit: Decodable {
            let start: Int
            let deleteCount: Int
            let data: [UInt32]?
        }

        let resultId: String?
        let data: [UInt32]?
        let edits: [Edit]?

        func tokens(updating previous: LSPSemanticTokens?) throws -> LSPSemanticTokens {
            if let data { return LSPSemanticTokens(resultID: resultId, data: data) }
            guard let edits, let previous else { throw LSPFailure.invalidMessage }
            var end = 0
            var data: [UInt32] = []
            data.reserveCapacity(previous.data.count)
            for edit in edits.sorted(by: { $0.start < $1.start }) {
                guard edit.start >= end, edit.start <= previous.data.count,
                      (0...(previous.data.count - edit.start)).contains(edit.deleteCount) else {
                    throw LSPFailure.invalidMessage
                }
                data.append(contentsOf: previous.data[end..<edit.start])
                if let insertion = edit.data { data.append(contentsOf: insertion) }
                end = edit.start + edit.deleteCount
            }
            data.append(contentsOf: previous.data[end...])
            return LSPSemanticTokens(resultID: resultId, data: data)
        }
    }

    let resultID: String?
    let data: [UInt32]

    static let tokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter",
        "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword",
        "modifier", "comment", "string", "number", "regexp", "operator", "decorator", "label"
    ]
    static let tokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
        "modification", "documentation", "defaultLibrary"
    ]

    func spans(in index: LSPTextIndex, legend: LSPSemanticTokenOptions.Legend, wholeWords: Bool = false) throws -> [SyntaxSpan] {
        guard data.count.isMultiple(of: 5) else { throw LSPFailure.invalidMessage }
        let colors = legend.tokenTypes.map(Self.color)
        let readonly = legend.tokenModifiers.firstIndex(of: "readonly")
        let readonlyMask: UInt32 = readonly.map { 1 << $0 } ?? 0
        var spans: [SyntaxSpan] = []
        spans.reserveCapacity(data.count / 5)
        var line = 0
        var column = 0
        var lastEnd = 0
        for i in stride(from: 0, to: data.count, by: 5) {
            if i.isMultiple(of: 5_120) { try Task.checkCancellation() }
            let deltaLine = Int(data[i])
            line += deltaLine
            column = (deltaLine == 0 ? column : 0) + Int(data[i + 1])
            let type = Int(data[i + 3])
            guard colors.indices.contains(type) else { throw LSPFailure.invalidMessage }
            let color = legend.tokenTypes[type] == "variable" && data[i + 4] & readonlyMask != 0
                ? .property : colors[type]
            guard let color, let range = index.semanticTokenRange(line: line, column: column, length: Int(data[i + 2])),
                  range.location >= lastEnd else { continue }
            if wholeWords {
                switch color {
                case .plain, .keyword, .control, .type, .function, .property:
                    if index.splitsBareWord(at: range.location) || index.splitsBareWord(at: range.upperBound) { continue }
                default: break
                }
            }
            spans.append(SyntaxSpan(start: range.location, end: range.upperBound, color: color))
            lastEnd = range.upperBound
        }
        return spans
    }

    private static func color(_ type: String) -> SyntaxColor? {
        switch type {
        case "variable": .plain
        case "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
             "concept", "union", "opaque", "errorTag": .type
        case "function", "method", "builtin": .function
        case "macro", "label", "keywordLiteral": .control
        case "keyword", "modifier", "operator": .keyword
        case "comment": .comment
        case "string", "regexp", "character": .string
        case "number": .number
        case "property", "enumMember", "event", "field", "member", "parameter": .property
        case "decorator", "attribute": .attribute
        default: nil
        }
    }
}
