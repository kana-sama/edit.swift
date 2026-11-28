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

    /// Project only the part of a published diagnostic that still has an anchor in the edited text.
    func remapped(after changes: [EditorTextChange], in text: NSString) -> LSPError? {
        guard let first = changes.first else { return nil }
        if first.range.location > max(lineEnd, displayRange.upperBound) { return self }
        var start = displayRange.location
        var end = displayRange.upperBound
        var point = range.location
        var appendedLength = 0
        for change in changes.reversed() {
            let edit = change.range
            if range.length == 0, edit.location <= point {
                point = max(point, edit.upperBound) + change.delta
            }
            // A newline typed at a line-end point leaves the error on its original row.
            if start == end, start == lineEnd, edit.location == start, edit.length == 0 {
                appendedLength = change.replacementLength
                continue
            }
            if edit.upperBound <= start {
                start += change.delta
                end += change.delta
            } else if edit.location <= start, end <= edit.upperBound {
                return nil
            } else if edit.location < end {
                if edit.location <= start { start = edit.location + change.replacementLength }
                end = end <= edit.upperBound ? edit.location : end + change.delta
            } else if edit.location == end, edit.length == 0 {
                appendedLength = change.replacementLength
            }
        }
        guard start >= 0, start <= end, end <= text.length else { return nil }
        if range.length == 0 {
            let anchor: Int
            if start == end {
                let line = LineEditing.line(at: start, in: text)
                anchor = min(start + appendedLength, line.contentEnd)
            } else {
                anchor = (start..<end).contains(point) ? point : start
            }
            let line = LineEditing.line(at: anchor, in: text)
            let mapped = NSRange(location: anchor, length: 0)
            let word = EditorWordBoundary.wordRange(containing: anchor, within: line.start..<line.contentEnd, in: text)
            return LSPError(range: mapped, lineEnd: line.contentEnd, message: message, displayRange: word ?? mapped)
        }
        let line = LineEditing.line(at: start, in: text)
        let bounds = line.start..<line.contentEnd
        if appendedLength > 0, end > start,
           let word = EditorWordBoundary.wordRange(containing: end - 1, within: bounds, in: text) {
            end = min(word.upperBound, end + appendedLength)
        }
        let mapped = NSRange(location: start, length: end - start)
        return LSPError(range: mapped, lineEnd: line.contentEnd, message: message)
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
