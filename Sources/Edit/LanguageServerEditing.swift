import Foundation

struct LSPMarkup: Decodable, Sendable {
    let value: String
    let isMarkdown: Bool

    private enum CodingKeys: String, CodingKey { case value, kind }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            value = string
            isMarkdown = false
        } else {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            value = try fields.decode(String.self, forKey: .value)
            isMarkdown = try fields.decode(String.self, forKey: .kind) == "markdown"
        }
    }
}

struct LSPCompletionList: Decodable, Sendable {
    var items: [LSPCompletionItem]
    let isIncomplete: Bool

    init(items: [LSPCompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }

    private enum CodingKeys: String, CodingKey { case items, isIncomplete }

    init(from decoder: Decoder) throws {
        if let fields = try? decoder.container(keyedBy: CodingKeys.self) {
            items = try fields.decode([LSPCompletionItem].self, forKey: .items)
            isIncomplete = try fields.decode(Bool.self, forKey: .isIncomplete)
        } else {
            items = try decoder.singleValueContainer().decode([LSPCompletionItem].self)
            isIncomplete = false
        }
    }
}

struct LSPCompletionItem: Decodable, Sendable {
    let label: String
    let detail: String?
    let documentation: LSPMarkup?
    let kind: Int?
    let insertText: String?
    let textEdit: LSPCompletionTextEdit?
    let additionalTextEdits: [LSPTextEdit]?
    let sortText: String?
    let filterText: String?
    let insertTextFormat: Int?
    let commitCharacters: [String]?

    // The resolve request must echo the item, including opaque server data.
    var wire: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case label, detail, documentation, kind, insertText, textEdit, additionalTextEdits
        case sortText, filterText, insertTextFormat, commitCharacters
    }
}

struct LSPCompletionTextEdit: Decodable, Sendable {
    let insertRange: LSPRange
    let replaceRange: LSPRange
    let newText: String

    private enum CodingKeys: String, CodingKey { case range, insert, replace, newText }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        newText = try fields.decode(String.self, forKey: .newText)
        if let range = try fields.decodeIfPresent(LSPRange.self, forKey: .range) {
            insertRange = range
            replaceRange = range
        } else {
            insertRange = try fields.decode(LSPRange.self, forKey: .insert)
            replaceRange = try fields.decode(LSPRange.self, forKey: .replace)
        }
    }
}

struct LSPSignatureHelp: Decodable, Sendable {
    struct Signature: Decodable, Sendable {
        struct Parameter: Decodable, Sendable {
            enum Label: Decodable, Sendable {
                case string(String)
                case range(NSRange)

                init(from decoder: Decoder) throws {
                    let field = try decoder.singleValueContainer()
                    if let text = try? field.decode(String.self) {
                        self = .string(text)
                    } else {
                        let bounds = try field.decode([Int].self)
                        guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0] else {
                            throw LSPFailure.invalidMessage
                        }
                        self = .range(NSRange(location: bounds[0], length: bounds[1] - bounds[0]))
                    }
                }
            }

            let label: Label
            let documentation: LSPMarkup?
        }

        let label: String
        let documentation: LSPMarkup?
        let parameters: [Parameter]?
        let activeParameter: Int?
    }

    let signatures: [Signature]
    let activeSignature: Int?
    let activeParameter: Int?
}
