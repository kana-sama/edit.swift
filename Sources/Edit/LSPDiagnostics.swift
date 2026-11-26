import Foundation

struct LSPPublishedDiagnostics: Decodable {
    struct Diagnostic: Decodable {
        let range: LSPRange
        let severity: Int?
        let message: String?
        var isError: Bool { severity == nil || severity == 1 }
    }

    let url: URL
    let version: Int?
    let diagnostics: [Diagnostic]
    var hasErrors: Bool { diagnostics.contains(where: \.isError) }

    private enum CodingKeys: String, CodingKey { case uri, version, diagnostics }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try LSPDocumentURI.url(values.decode(String.self, forKey: .uri), from: decoder)
        version = try values.decodeIfPresent(Int.self, forKey: .version)
        diagnostics = try values.decode([Diagnostic].self, forKey: .diagnostics)
    }

    func errors(for document: LSPDocument, index: LSPTextIndex) -> [LSPError]? {
        guard version == nil || version == document.revision, let documentURL = document.url, url.isFileURL,
              url.standardizedFileURL == documentURL.standardizedFileURL
                || FileBuffer.canonicalURL(url) == FileBuffer.canonicalURL(documentURL) else { return nil }
        var seen: Set<LSPError> = []
        let errors: [LSPError] = diagnostics.compactMap { diagnostic in
            guard diagnostic.isError,
                  let range = index.nsRange(diagnostic.range),
                  let lineEnd = index.lineContentEnd(at: diagnostic.range.start.line) else { return nil }
            let displayRange = index.diagnosticDisplayRange(range, on: diagnostic.range.start.line)
            let error = LSPError(range: range, lineEnd: lineEnd, message: diagnostic.message ?? "", displayRange: displayRange)
            return seen.insert(error).inserted ? error : nil
        }
        return errors.sorted { $0.range.location < $1.range.location }
    }
}

struct LSPError: Hashable, Sendable {
    let range: NSRange
    let displayRange: NSRange
    let lineEnd: Int
    let message: String

    init(range: NSRange, lineEnd: Int, message: String, displayRange: NSRange? = nil) {
        self.range = range
        self.displayRange = displayRange ?? range
        self.lineEnd = lineEnd
        self.message = message
    }
}

struct LSPDocumentErrors: Sendable {
    let revision: Int
    let errors: [LSPError]
}

struct LSPDiagnosticUpdate: Sendable {
    let path: String
    let hasErrors: Bool
    let documentErrors: LSPDocumentErrors?
}
