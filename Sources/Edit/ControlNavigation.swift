import Foundation

enum ControlNavigation: Sendable {
    case line(NSRange, text: String)
    case symbol(LSPLocation, kind: Int)

    static func lineQuery(_ query: String) -> Bool {
        !query.isEmpty && query.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func lineResult(_ query: String, text: String) -> ControlMatch? {
        guard let number = Int(query), number > 0 else { return nil }
        let start = LSPPosition(line: number - 1, character: 0)
        guard let range = LSPRange(start: start, end: start).nsRange(in: text) else { return nil }
        let entry = ControlEntry(id: "line:\(number)", title: "Line \(number)", navigation: .line(range, text: text))
        return ControlMatch(entry: entry, titleCharacters: [], detailCharacters: [])
    }

    static func symbolResults(_ symbols: [LSPSymbol], query: String, workspace: Bool, folder: URL?,
                              alternateCharacters: [Character: Character]) -> [ControlMatch] {
        var knownIDs: Set<String> = []
        var paths: [URL: String] = [:]
        let canonicalFolder = workspace ? folder.map(FileBuffer.canonicalURL) : nil
        let entries = symbols.compactMap { symbol -> ControlEntry? in
            guard !Task.isCancelled else { return nil }
            let url = symbol.location.url
            let start = symbol.location.range.start
            let id = "symbol:\(url.absoluteString):\(start.line):\(start.character):\(symbol.name)"
            guard knownIDs.insert(id).inserted else { return nil }
            let container = symbol.detail.flatMap { $0.isEmpty ? nil : $0 }
            let detail: String?
            if workspace {
                let path: String
                if let cached = paths[url] {
                    path = cached
                } else {
                    let relative = folder.flatMap { FolderFileSearch.relativeDirectory(of: url, in: $0) }
                        ?? canonicalFolder.flatMap { FolderFileSearch.relativeDirectory(of: FileBuffer.canonicalURL(url), in: $0) }
                    path = relative.map { $0.isEmpty ? url.lastPathComponent : "\($0)/\(url.lastPathComponent)" }
                        ?? (url.path as NSString).abbreviatingWithTildeInPath
                    paths[url] = path
                }
                detail = [container, path].compactMap { $0 }.joined(separator: " · ")
            } else {
                detail = container
            }
            return ControlEntry(id: id, title: symbol.name, detail: detail,
                                navigation: .symbol(symbol.location, kind: symbol.kind))
        }
        let ranked = ControlMatching.rank(entries, query: query, alternateCharacters: alternateCharacters)
        guard workspace else { return ranked }

        // ZLS owns the workspace search. Keep matches that its name normalization accepts,
        // including any that the local matcher cannot highlight.
        let highlights = Dictionary(uniqueKeysWithValues: ranked.map { ($0.entry.id, $0) })
        return entries.map { highlights[$0.id] ?? ControlMatch(entry: $0, titleCharacters: [], detailCharacters: []) }
    }
}
