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
    static func rankFiles(_ entries: [ControlEntry], query: String) -> [ControlMatch] {
        if query.allSatisfy(\.isWhitespace) {
            let recent = entries.filter { $0.openedAt != nil }.sorted { fileOrder($0, $1) == .orderedAscending }
            return rank(recent, query: query)
        }
        return rank(entries, query: query, preferRecentFiles: true)
    }

    private static func fileOrder(_ lhs: ControlEntry, _ rhs: ControlEntry) -> ComparisonResult {
        let left = lhs.openedAt ?? .distantPast
        let right = rhs.openedAt ?? .distantPast
        if left != right { return left > right ? .orderedAscending : .orderedDescending }
        return lhs.title.localizedStandardCompare(rhs.title)
    }

    static func rank(_ entries: [ControlEntry], query: String, preferShorterTitles: Bool = false,
                     preferRecentFiles: Bool = false) -> [ControlMatch] {
        let parts = terms(in: query)
        let queryName = parts.joined(separator: " ")
        let terms = parts.map {
            $0.map { String($0).lowercased() }
        }
        if terms.isEmpty {
            return entries.map { ControlMatch(entry: $0, titleCharacters: [], detailCharacters: []) }
        }
        var matches: [(score: Int, titleLength: Int, index: Int, match: ControlMatch)] = []
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { return [] }
            let title = Array(entry.title)
            let detail = Array(entry.detail ?? "")
            let prefix = detail.isEmpty ? [] : detail + ["/"]
            let path = prefix + title
            var score = 0
            var titleCharacters: Set<Int> = []
            var detailCharacters: Set<Int> = []
            var found = 0
            for term in terms {
                if let titleMatch = best(term, in: title) {
                    score += titleMatch.score + 70
                    titleCharacters.formUnion(titleMatch.indices)
                    found += 1
                } else if let pathMatch = best(term, in: path) {
                    score += pathMatch.score
                    for character in pathMatch.indices {
                        if character < detail.count {
                            detailCharacters.insert(character)
                        } else if character >= prefix.count {
                            titleCharacters.insert(character - prefix.count)
                        }
                    }
                    found += 1
                } else {
                    break
                }
            }
            guard found == terms.count else { continue }
            let label = entry.title.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            if entry.title.compare(queryName, options: .caseInsensitive) == .orderedSame ||
                label?.compare(queryName, options: .caseInsensitive) == .orderedSame { score += 150 }
            matches.append((score, title.count, index, ControlMatch(entry: entry, titleCharacters: titleCharacters,
                                                                    detailCharacters: detailCharacters)))
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if preferRecentFiles {
                let order = fileOrder($0.match.entry, $1.match.entry)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if preferShorterTitles, $0.titleLength != $1.titleLength { return $0.titleLength < $1.titleLength }
            return $0.index < $1.index
        }.map(\.match)
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

    private static func best(_ term: [String], in field: [Character]) -> (score: Int, indices: [Int])? {
        guard field.count >= term.count else { return nil }
        let folded = field.map { String($0).lowercased() }
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
