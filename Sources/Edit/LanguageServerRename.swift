import Foundation

struct LSPPreparedRename: Decodable, Sendable {
    let range: LSPRange
    let placeholder: String?

    private enum CodingKeys: String, CodingKey { case range, placeholder }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if let range = try fields.decodeIfPresent(LSPRange.self, forKey: .range) {
            self.range = range
            placeholder = try fields.decodeIfPresent(String.self, forKey: .placeholder)
        } else {
            range = try LSPRange(from: decoder)
            placeholder = nil
        }
    }
}

struct LSPTextEdit: Decodable, Sendable {
    let range: LSPRange
    let newText: String
}

struct LSPDocumentEdits: Sendable {
    let url: URL
    let version: Int?
    let edits: [LSPTextEdit]
}

struct LSPWorkspaceEdit: Decodable, Sendable {
    let documents: [LSPDocumentEdits]

    private enum CodingKeys: String, CodingKey { case changes, documentChanges }

    private struct VersionedEdit: Decodable {
        struct Document: Decodable {
            let uri: String
            let version: Int?
        }

        let textDocument: Document
        let edits: [LSPTextEdit]
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if let versioned = try fields.decodeIfPresent([VersionedEdit].self, forKey: .documentChanges) {
            documents = try versioned.map {
                LSPDocumentEdits(url: try LSPDocumentURI.url($0.textDocument.uri, from: decoder),
                                 version: $0.textDocument.version, edits: $0.edits)
            }
        } else if let changes = try fields.decodeIfPresent([String: [LSPTextEdit]].self, forKey: .changes) {
            documents = try changes.sorted(by: { $0.key < $1.key }).map { uri, edits in
                LSPDocumentEdits(url: try LSPDocumentURI.url(uri, from: decoder), version: nil, edits: edits)
            }
        } else {
            documents = []
        }
    }
}
