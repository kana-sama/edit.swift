import Foundation

struct ControlEntry: Sendable {
    let id: String
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    var recent: RecentFile? = nil
    var folderFileURL: URL? = nil
    var folderFileIdentity: FileIdentity? = nil
    var iconLanguage: String? = nil
    var scratch: ScratchFile? = nil
    var navigation: ControlNavigation? = nil
    var directoryDepth: Int? = nil

    var fileURL: URL? { recent?.url ?? folderFileURL }
    var openedAt: Date? { recent?.opened ?? scratch?.openedAt }
}

extension ControlEntry {
    init(scratch: ScratchFile) {
        self.init(id: "scratch:\(scratch.id.uuidString)", title: scratch.name, detail: scratch.folderLabel, scratch: scratch)
    }
}

struct ControlMatch: Sendable {
    let entry: ControlEntry
    let titleCharacters: Set<Int>
    let detailCharacters: Set<Int>
}

enum ControlMatching {
    private struct QueryVariant {
        let name: String
        let terms: [[String]]

        init(_ parts: [String]) {
            name = parts.joined(separator: " ")
            terms = parts.map { $0.map { String($0).lowercased() } }
        }
    }

    private static let alternateLayoutPenalty = 8

    static func rankFiles(_ entries: [ControlEntry], query: String,
                          alternateCharacters: [Character: Character] = [:]) -> [ControlMatch] {
        if query.allSatisfy(\.isWhitespace) {
            let recent = entries.filter { $0.openedAt != nil }.sorted { fileOrder($0, $1) == .orderedAscending }
            return rank(recent, query: query)
        }
        return rank(entries, query: query, alternateCharacters: alternateCharacters, preferRecentFiles: true)
    }

    private static func fileOrder(_ lhs: ControlEntry, _ rhs: ControlEntry) -> ComparisonResult {
        let left = lhs.openedAt ?? .distantPast
        let right = rhs.openedAt ?? .distantPast
        if left != right { return left > right ? .orderedAscending : .orderedDescending }
        return lhs.title.localizedStandardCompare(rhs.title)
    }

    static func rank(_ entries: [ControlEntry], query: String, alternateCharacters: [Character: Character] = [:],
                     preferShorterTitles: Bool = false,
                     preferRecentFiles: Bool = false, preferredDirectoryDepth: Int = 0) -> [ControlMatch] {
        let parts = terms(in: query)
        if parts.isEmpty {
            return entries.map { ControlMatch(entry: $0, titleCharacters: [], detailCharacters: []) }
        }
        let typedQuery = QueryVariant(parts)
        var alternateQuery: QueryVariant?
        if !alternateCharacters.isEmpty {
            let converted = QueryVariant(parts.map { String($0.map { alternateCharacters[$0] ?? $0 }) })
            if converted.terms != typedQuery.terms { alternateQuery = converted }
        }

        var matches: [(score: Int, typedExact: Bool, titleLength: Int, index: Int, match: ControlMatch)] = []
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { return [] }
            // Location breaks close matches without overriding much stronger text matches.
            let locationBonus = entry.directoryDepth.map { 12 - min(8, max(0, $0 - preferredDirectoryDepth)) } ?? 0
            let candidate = Candidate(entry)
            let typed = candidate.match(typedQuery)
            let typedExact = typed?.exact == true
            if !typedExact, let alternateQuery, let alternate = candidate.match(alternateQuery),
               alternate.score - alternateLayoutPenalty > typed?.score ?? Int.min {
                matches.append((alternate.score - alternateLayoutPenalty + locationBonus, false, candidate.title.count, index,
                                alternate.result))
            } else if let typed {
                matches.append((typed.score + locationBonus, typedExact, candidate.title.count, index, typed.result))
            }
        }
        return matches.sorted {
            if alternateQuery != nil, $0.typedExact != $1.typedExact { return $0.typedExact }
            if $0.score != $1.score { return $0.score > $1.score }
            if preferRecentFiles {
                let order = fileOrder($0.match.entry, $1.match.entry)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if preferShorterTitles, $0.titleLength != $1.titleLength { return $0.titleLength < $1.titleLength }
            return $0.index < $1.index
        }.map(\.match)
    }

    private struct Candidate {
        let entry: ControlEntry
        let title: [Character]
        let foldedTitle: [String]
        let path: [Character]
        let foldedPath: [String]
        let detailLength: Int
        let prefixLength: Int

        init(_ entry: ControlEntry) {
            self.entry = entry
            title = Array(entry.title)
            foldedTitle = title.map { String($0).lowercased() }
            let detail = Array(entry.detail ?? "")
            let prefix = detail.isEmpty ? [] : detail + ["/"]
            path = prefix + title
            foldedPath = prefix.map { String($0).lowercased() } + foldedTitle
            detailLength = detail.count
            prefixLength = prefix.count
        }

        func match(_ query: QueryVariant) -> (score: Int, exact: Bool, result: ControlMatch)? {
            var score = 0
            var titleCharacters: Set<Int> = []
            var detailCharacters: Set<Int> = []
            for term in query.terms {
                if let titleMatch = best(term, in: title, folded: foldedTitle) {
                    score += titleMatch.score + 70
                    titleCharacters.formUnion(titleMatch.indices)
                } else if let pathMatch = best(term, in: path, folded: foldedPath) {
                    score += pathMatch.score
                    for character in pathMatch.indices {
                        if character < detailLength {
                            detailCharacters.insert(character)
                        } else if character >= prefixLength {
                            titleCharacters.insert(character - prefixLength)
                        }
                    }
                } else {
                    return nil
                }
            }
            let label = entry.title.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            let exact = entry.title.compare(query.name, options: .caseInsensitive) == .orderedSame ||
                label?.compare(query.name, options: .caseInsensitive) == .orderedSame
            if exact { score += 150 }
            return (score, exact, ControlMatch(entry: entry, titleCharacters: titleCharacters,
                                              detailCharacters: detailCharacters))
        }
    }

    private static func terms(in query: String) -> [String] {
        var terms: [String] = []
        var term = ""
        var index = query.startIndex
        while index < query.endIndex {
            let character = query[index]
            index = query.index(after: index)
            if character == "\\", index < query.endIndex, query[index] == " " {
                term.append(" ")
                index = query.index(after: index)
            } else if character.isWhitespace {
                if !term.isEmpty { terms.append(term) }
                term = ""
            } else {
                term.append(character)
            }
        }
        if !term.isEmpty { terms.append(term) }
        return terms
    }

    private static func best(_ term: [String], in field: [Character], folded: [String]) -> (score: Int, indices: [Int])? {
        guard field.count >= term.count else { return nil }
        var best: (score: Int, indices: [Int])?
        for start in field.indices where folded[start] == term[0] {
            var indices = [start]
            var score = max(0, 20 - start)
            var next = 1
            var previous = start
            if start == 0 || !field[start - 1].isLetter && !field[start - 1].isNumber { score += 12 }
            if next < term.count {
                for index in (start + 1)..<field.count where folded[index] == term[next] {
                    let gap = index - previous - 1
                    score += gap == 0 ? 16 : -min(gap, 16)
                    if !field[index - 1].isLetter && !field[index - 1].isNumber { score += 8 }
                    indices.append(index)
                    previous = index
                    next += 1
                    if next == term.count { break }
                }
            }
            if next == term.count {
                if indices.count == field.count { score += 100 }
                if score > best?.score ?? Int.min { best = (score, indices) }
            }
        }
        return best
    }
}
