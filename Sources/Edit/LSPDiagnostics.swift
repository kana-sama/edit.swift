import Foundation

struct LSPPublishedDiagnostics: Decodable {
    struct Diagnostic: Decodable {
        let range: LSPRange
        let severity: Int?
    }

    let url: URL
    let version: Int?
    let diagnostics: [Diagnostic]

    private enum CodingKeys: String, CodingKey { case uri, version, diagnostics }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try LSPDocumentURI.url(values.decode(String.self, forKey: .uri), from: decoder)
        version = try values.decodeIfPresent(Int.self, forKey: .version)
        diagnostics = try values.decode([Diagnostic].self, forKey: .diagnostics)
    }

    func errors(for document: LSPDocument, index: LSPTextIndex) -> [NSRange]? {
        guard version == nil || version == document.revision, let documentURL = document.url, url.isFileURL,
              url.standardizedFileURL == documentURL.standardizedFileURL
                || FileBuffer.canonicalURL(url) == FileBuffer.canonicalURL(documentURL) else { return nil }
        let ranges: [NSRange] = diagnostics.compactMap { diagnostic in
            guard diagnostic.severity == nil || diagnostic.severity == 1 else { return nil }
            return index.nsRange(diagnostic.range)
        }
        return Array(Set(ranges)).sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    }
}

struct LSPDocumentErrors: Sendable {
    let revision: Int
    let ranges: [NSRange]
}
