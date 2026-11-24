import Foundation

struct JJLineMark: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case insertion, replacement, deletion, conflict
    }

    let kind: Kind
    // Deletions use an empty range at the boundary after this many current lines.
    let lines: Range<Int>
}

struct JJTextAnalysis: Sendable {
    let marks: [JJLineMark]
    let lineStarts: [Int]
    let isChanged: Bool?
    let remainsConflicted: Bool?
    let hunks: [JJDiffHunk]
    var conflicts: [JJConflict] = []
}

struct JJDiffHunk: Equatable, Sendable {
    let mark: JJLineMark
    let baseRange: NSRange
    let currentRange: NSRange
    let removedText: String
    let insertedText: String
    let removedHighlights: [NSRange]
    let insertedHighlights: [NSRange]
}

enum JJLineDiff {
    static func parseConflict(_ text: String, at offset: Int) -> JJConflict? {
        var budget = Budget()
        guard let lines = try? split(text, budget: &budget) else { return nil }
        let positioned = lines.map { TextPart(start: offset + $0.start, text: $0.text) }
        return JJConflict.parse(positioned[...], normalizeCRLF: text.utf8.contains(13), budget: &budget)
    }

    static func analyze(
        base: String?, current: String, isConflicted: Bool, recordedConflict: String?,
        normalizeCRLF: Bool = false
    ) -> JJTextAnalysis {
        let changed = base.map { old in
            guard !old.utf8.elementsEqual(current.utf8) else { return false }
            guard normalizeCRLF else { return true }
            let left = old.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
            let right = current.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
            return !left.utf8.elementsEqual(right.utf8)
        }
        var remainsConflicted: Bool? = isConflicted ? true : nil
        guard changed == true || isConflicted else {
            return JJTextAnalysis(marks: [], lineStarts: [], isChanged: changed, remainsConflicted: nil, hunks: [])
        }
        var budget = Budget()
        guard let newLines = try? split(current, budget: &budget) else {
            return JJTextAnalysis(marks: [], lineStarts: [], isChanged: changed,
                                  remainsConflicted: remainsConflicted, hunks: [])
        }

        var conflicts: [Range<Int>] = []
        var hasReliableFraming = !isConflicted
        if isConflicted, let recordedConflict,
           let reference = try? split(recordedConflict, budget: &budget),
           let scan = try? conflictRanges(in: newLines, matching: reference, budget: &budget) {
            conflicts = scan.ranges
            hasReliableFraming = !scan.uncertain
            remainsConflicted = scan.uncertain || !conflicts.isEmpty
        }

        var ordinary: [JJLineMark] = []
        var hunks: [JJDiffHunk] = []
        if changed == true, let base, hasReliableFraming {
            do {
                let oldLines = try split(base, budget: &budget)
                let (oldIDs, newIDs) = try textIDs(oldLines, newLines, normalizeCRLF: normalizeCRLF, budget: &budget)
                let unaligned = try differences(oldIDs, newIDs, budget: &budget)
                let changes = conflicts.isEmpty ? alignRepeatedLines(unaligned, old: oldIDs, new: newIDs) : unaligned
                ordinary = changes.map(\.mark)
                hunks = try makeHunks(changes, oldLines: oldLines, newLines: newLines,
                                      base: base as NSString, current: current as NSString, conflicts: conflicts,
                                      normalizeCRLF: normalizeCRLF, budget: &budget)
            } catch {
                // Keep known marks and status if the budget runs out before expansion data is ready.
            }
        }
        let marks = compose(ordinary, with: conflicts)
        var conflictWordBudget = Budget(deadline: min(budget.deadline, ContinuousClock.now + .milliseconds(80)))
        return JJTextAnalysis(marks: marks, lineStarts: marks.isEmpty ? [] : newLines.map(\.start),
                              isChanged: changed, remainsConflicted: remainsConflicted, hunks: hunks,
                              conflicts: conflicts.compactMap {
                                  JJConflict.parse(newLines[$0], normalizeCRLF: normalizeCRLF, budget: &conflictWordBudget)
                              })
    }

    private enum Limit: Error { case exceeded }

    struct Budget {
        let deadline: ContinuousClock.Instant
        private var work = 0

        init(deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(1)) {
            self.deadline = deadline
        }

        mutating func check(immediately: Bool = false) throws {
            work += 1
            if immediately || work.isMultiple(of: 128) {
                if Task.isCancelled || ContinuousClock.now >= deadline { throw Limit.exceeded }
            }
        }
    }

    struct TextPart {
        let start: Int
        let text: String
    }

    private struct ExactText: Hashable {
        let text: String

        static func == (left: Self, right: Self) -> Bool {
            left.text.utf8.elementsEqual(right.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            var contiguous = text
            contiguous.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    private static func split(_ text: String, budget: inout Budget) throws -> [TextPart] {
        try budget.check(immediately: true)
        guard text.utf8.count <= 8 * 1_024 * 1_024, !text.utf8.contains(0) else { throw Limit.exceeded }
        let source = text as NSString
        let length = source.length
        var lines: [TextPart] = []
        var start = 0
        while start < length {
            try budget.check()
            guard lines.count < 150_000 else { throw Limit.exceeded }
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            lines.append(TextPart(start: start, text: source.substring(with: range)))
            start = NSMaxRange(range)
        }
        return lines
    }

    private static func textIDs(
        _ old: [TextPart], _ new: [TextPart], normalizeCRLF: Bool, budget: inout Budget
    ) throws -> ([Int], [Int]) {
        var identifiers: [ExactText: Int] = [:]
        func encode(_ parts: [TextPart]) throws -> [Int] {
            try parts.map { part in
                try budget.check()
                // Only comparison keys normalize endings. Offsets still address the original buffer.
                let content = normalizeCRLF && part.text.hasSuffix("\r\n")
                    ? String(part.text.dropLast()) + "\n" : part.text
                let key = ExactText(text: content)
                if let existing = identifiers[key] { return existing }
                let id = identifiers.count
                identifiers[key] = id
                return id
            }
        }
        let oldIDs = try encode(old)
        return (oldIDs, try encode(new))
    }

    static func conflictDelta(from base: String, to side: String) -> String? {
        var budget = Budget()
        guard let old = try? split(base, budget: &budget), let new = try? split(side, budget: &budget),
              let (oldIDs, newIDs) = try? textIDs(old, new, normalizeCRLF: false, budget: &budget),
              let changes = try? differences(oldIDs, newIDs, budget: &budget) else { return nil }
        var result = ""
        var previous = 0
        for change in changes {
            for line in old[previous..<change.before.lowerBound] { result += " " + line.text }
            for line in old[change.before] { result += "-" + line.text }
            for line in new[change.after] { result += "+" + line.text }
            previous = change.before.upperBound
        }
        for line in old[previous...] { result += " " + line.text }
        return result
    }

    static func applyConflictDelta(from base: String, to side: String, onto result: String) -> String? {
        var budget = Budget()
        do {
            let original = try split(base, budget: &budget)
            let incoming = try split(side, budget: &budget)
            let draft = try split(result, budget: &budget)
            return try replay(original, incoming: incoming, draft: draft, mergeLineEdits: true, budget: &budget)
        } catch {
            return nil
        }
    }

    static func confirmConflictEdits(
        from base: String, to side: String, in result: String, runs: [JJConflict.DiffRun],
        confirmed: inout [Int: [NSRange]], budget: inout Budget
    ) throws {
        let original = try split(base, budget: &budget)
        let incoming = try split(side, budget: &budget)
        let draft = try split(result, budget: &budget)
        let edits = try replayChanges(from: original, to: draft, budget: &budget)

        for run in runs {
            try budget.check()
            // At EOF a physical marker line can represent an empty term with no newline.
            guard run.baseLines.upperBound <= original.count, run.sideLines.upperBound <= incoming.count else { continue }
            let window = try conflictWindow(for: run.baseLines, in: edits, budget: &budget)
            let removed = original[run.baseLines]
            let added = incoming[run.sideLines]
            let edited = draft[window.draft]

            if try matchesConflictRun(run.baseLines, removed: removed, added: added, window: window.base,
                                      original: original[window.base], edited: edited, edits: window.edits, budget: &budget) {
                confirmRows(run.removedRows, in: removed, confirmed: &confirmed)
                confirmRows(run.addedRows, in: added, confirmed: &confirmed)
            } else if removed.isEmpty {
                let inserted: [TextPart]
                if window.base.isEmpty {
                    guard let edit = window.edits.first, edit.firstPossibleStart == run.baseLines.lowerBound,
                          edit.lastPossibleEnd == run.baseLines.upperBound else { continue }
                    inserted = Array(edited)
                } else {
                    inserted = try insertedConflictLines(at: run.baseLines.lowerBound, in: original[window.base],
                                                         edited: edited, budget: &budget)
                }
                guard !inserted.isEmpty else { continue }
                let (wanted, actual) = try textIDs(Array(added), inserted, normalizeCRLF: false, budget: &budget)
                let pending = Set(try differences(wanted, actual, budget: &budget).flatMap(\.before))
                for (offset, pair) in zip(run.addedRows, added).enumerated() where !pending.contains(offset) {
                    let (row, line) = pair
                    confirmed[row] = [NSRange(location: 0, length: line.text.utf16.count + 1)]
                }
            } else if added.isEmpty {
                for edit in window.edits where edit.change.after.isEmpty &&
                    edit.firstPossibleStart == edit.change.before.lowerBound && edit.lastPossibleEnd == edit.change.before.upperBound {
                    let start = max(run.baseLines.lowerBound, edit.change.before.lowerBound)
                    let end = min(run.baseLines.upperBound, edit.change.before.upperBound)
                    guard start < end else { continue }
                    let offset = start - run.baseLines.lowerBound
                    confirmRows(run.removedRows[offset..<(offset + end - start)], in: original[start..<end], confirmed: &confirmed)
                }
            } else if let first = removed.first, !window.edits.isEmpty {
                let before = removed.map(\.text).joined()
                let after = added.map(\.text).joined()
                let baseWindow = original[window.base].map(\.text).joined()
                let draftWindow = edited.map(\.text).joined()
                guard before.utf16.count + after.utf16.count + baseWindow.utf16.count + draftWindow.utf16.count <= 16_384 else { continue }
                let beforeOffset = first.start - original[window.base.lowerBound].start
                let wanted = try wordChangeRanges(before, after, normalizeCRLF: false, budget: &budget)
                let actual = try wordChangeRanges(baseWindow, draftWindow, normalizeCRLF: false, budget: &budget)
                let actualText = draftWindow as NSString
                let wantedText = after as NSString
                for change in wanted {
                    try budget.check()
                    let range = NSRange(location: beforeOffset + change.removed.location, length: change.removed.length)
                    let replacement = wantedText.substring(with: change.inserted)
                    let matches = try actual.contains { applied in
                        try budget.check()
                        if range == applied.removed {
                            let appliedText = actualText.substring(with: applied.inserted)
                            if replacement.utf8.elementsEqual(appliedText.utf8) { return true }
                            // Two sides can add terms at the same offset. A complete term at
                            // the start of the insertion still counts when another follows it.
                            if range.length == 0, isFollowedByAdditiveTerm(replacement, in: appliedText) { return true }
                            if range.length > 0, try containsSeparateConflictWords(replacement, in: appliedText, budget: &budget) {
                                return true
                            }
                        }
                        return replacement.isEmpty && range.length > 0 && applied.inserted.length == 0 &&
                            NSIntersectionRange(range, applied.removed).length == range.length
                    }
                    let grouped = try !matches && actual.contains { applied in
                        if range.length > 0 { return applied.removed == range }
                        return applied.removed.length > 0 &&
                            (range.location == applied.removed.location || range.location == NSMaxRange(applied.removed))
                    } && confirmsGroupedConflictReplacement(replacement, at: range, in: original[window.base], edited: edited, budget: &budget)
                    if matches || grouped {
                        confirmWords(change.removed, rows: run.removedRows, in: removed, confirmed: &confirmed)
                        confirmWords(change.inserted, rows: run.addedRows, in: added, confirmed: &confirmed)
                    }
                }
            }
        }
    }

    private static func isFollowedByAdditiveTerm(_ expected: String, in insertion: String) -> Bool {
        let prefix = expected.utf8
        guard !prefix.isEmpty, insertion.utf8.starts(with: prefix) else { return false }
        let rest = insertion.utf8.dropFirst(prefix.count).drop(while: { $0 == 32 || $0 == 9 })
        guard let sign = rest.first, sign == 43 || sign == 45,
              let next = rest.dropFirst().first, next != sign, next != 61 else { return false }
        return rest.dropFirst().contains { $0 != 32 && $0 != 9 && $0 != 10 && $0 != 13 }
    }

    private static func containsSeparateConflictWords(_ expected: String, in replacement: String, budget: inout Budget) throws -> Bool {
        guard !expected.isEmpty else { return false }
        let wanted = try words(in: expected, budget: &budget)
        let actual = try words(in: replacement, budget: &budget)
        guard actual.count > wanted.count, wanted.contains(where: { $0.text.first.flatMap(WordGroup.init) == .identifier }) else { return false }

        // A neighboring word can be retained in the same replacement (for example `line`
        // to `my LINE`). Require whitespace and a separate word at the join. A partial
        // identifier, an operator joined to the edit, or a repeated match is inconclusive.
        func separated(at index: Int, direction: Int, includesSpace: Bool) -> Bool {
            guard actual.indices.contains(index) else { return true }
            if includesSpace { return actual[index].text.first.flatMap(WordGroup.init) == .identifier }
            guard actual[index].text.first.flatMap(WordGroup.init) == .whitespace else { return false }
            let neighbor = index + direction
            return !actual.indices.contains(neighbor) || actual[neighbor].text.first.flatMap(WordGroup.init) == .identifier
        }

        let startsWithSpace = wanted.first?.text.first.flatMap(WordGroup.init) == .whitespace
        let endsWithSpace = wanted.last?.text.first.flatMap(WordGroup.init) == .whitespace
        var matched = false
        for start in 0...(actual.count - wanted.count) {
            try budget.check()
            let end = start + wanted.count
            guard separated(at: start - 1, direction: -1, includesSpace: startsWithSpace),
                  separated(at: end, direction: 1, includesSpace: endsWithSpace),
                  try actual[start..<end].elementsEqual(wanted, by: { left, right in
                      try budget.check()
                      return left.text.utf8.elementsEqual(right.text.utf8)
                  }) else { continue }
            if matched { return false }
            matched = true
        }
        return matched
    }

    private static func confirmsGroupedConflictReplacement(
        _ replacement: String, at range: NSRange, in original: ArraySlice<TextPart>,
        edited: ArraySlice<TextPart>, budget: inout Budget
    ) throws -> Bool {
        guard !replacement.isEmpty, original.count == edited.count, let start = original.first?.start,
              let line = original.lastIndex(where: { $0.start <= start + range.location }) else { return false }
        let originalLine = original[line]
        let result = edited[edited.startIndex + line - original.startIndex].text
        let local = NSRange(location: start + range.location - originalLine.start, length: range.length)
        let base = originalLine.text as NSString
        guard NSMaxRange(local) <= base.length,
              try containsSeparateConflictWords(replacement, in: result, budget: &budget) else { return false }
        let expected = base.replacingCharacters(in: local, with: replacement)

        // Matching whitespace can assign a changed word to the neighboring replacement.
        // Align from the patched line as well. Removing and restoring this one change
        // must preserve the rest of the current line.
        let baseWords = try words(in: originalLine.text, budget: &budget)
        let expectedWords = try words(in: expected, budget: &budget)
        let resultWords = try words(in: result, budget: &budget)
        guard let reverted = try replay(expectedWords, incoming: baseWords, draft: resultWords, mergeLineEdits: false, budget: &budget),
              !reverted.utf8.elementsEqual(result.utf8) else { return false }
        let revertedWords = try words(in: reverted, budget: &budget)
        let restored = try replay(baseWords, incoming: expectedWords, draft: revertedWords, mergeLineEdits: false, budget: &budget)
        return restored?.utf8.elementsEqual(result.utf8) == true
    }

    private static func insertedConflictLines(
        at boundary: Int, in original: ArraySlice<TextPart>, edited: ArraySlice<TextPart>, budget: inout Budget
    ) throws -> [TextPart] {
        func uniqueIndex(in lines: ArraySlice<TextPart>, matching: (TextPart) throws -> Bool) throws -> Int? {
            var match: Int?
            for index in lines.indices {
                try budget.check()
                if try matching(lines[index]) {
                    guard match == nil else { return nil }
                    match = index
                }
            }
            return match
        }

        func anchor(_ index: Int) throws -> Int? {
            let line = original[index].text
            let exact: (TextPart) -> Bool = { $0.text.utf8.elementsEqual(line.utf8) }
            if try uniqueIndex(in: original, matching: exact) != nil,
               let match = try uniqueIndex(in: edited, matching: exact) { return match }

            // Neighboring lines may have other edits. A unique token prefix such as
            // `let departures =` can still anchor the gap without matching the whole line.
            func prefix(_ text: String, budget: inout Budget) throws -> [ExactText] {
                try words(in: text, budget: &budget).lazy.filter { !$0.text.allSatisfy(\.isWhitespace) }
                    .prefix(3).map { ExactText(text: $0.text) }
            }
            let key = try prefix(line, budget: &budget)
            guard key.count == 3 else { return nil }
            let originals = try original.map { try prefix($0.text, budget: &budget) }
            guard originals.filter({ $0 == key }).count == 1 else { return nil }
            let matches = try edited.indices.filter { try prefix(edited[$0].text, budget: &budget) == key }
            return matches.count == 1 ? matches.first : nil
        }

        let start = try boundary == original.startIndex ? edited.startIndex : anchor(boundary - 1).map { $0 + 1 }
        let end = try boundary == original.endIndex ? edited.endIndex : anchor(boundary)
        guard let start, let end, start < end else { return [] }
        return Array(edited[start..<end])
    }

    private static func matchesConflictRun(
        _ range: Range<Int>, removed: ArraySlice<TextPart>, added: ArraySlice<TextPart>, window: Range<Int>,
        original: ArraySlice<TextPart>, edited: ArraySlice<TextPart>, edits: ArraySlice<ReplayChange>, budget: inout Budget
    ) throws -> Bool {
        // Ignore equivalent alignments that can move a repeated line outside the selected region.
        guard edits.allSatisfy({ $0.firstPossibleStart >= window.lowerBound && $0.lastPossibleEnd <= window.upperBound }) else {
            return false
        }
        func equalLines(_ left: ArraySlice<TextPart>, _ right: ArraySlice<TextPart>) throws -> Bool {
            try left.elementsEqual(right) { a, b in
                try budget.check()
                return a.text.utf8.elementsEqual(b.text.utf8)
            }
        }
        if window == range, try equalLines(edited, added) { return true }
        guard !added.isEmpty, edited.count >= added.count else { return false }
        let startMatches = try range.lowerBound == window.lowerBound && equalLines(edited.prefix(added.count), added)
        let endMatches = try range.upperBound == window.upperBound && equalLines(edited.suffix(added.count), added)

        func occurrences(_ wanted: ArraySlice<TextPart>, in lines: ArraySlice<TextPart>, limit: Int = 1) throws -> Int {
            guard !wanted.isEmpty, lines.count >= wanted.count else { return 0 }
            var count = 0
            for start in lines.startIndex...(lines.endIndex - wanted.count) {
                if try equalLines(lines[start..<(start + wanted.count)], wanted) {
                    count += 1
                    if count == limit { break }
                }
            }
            return count
        }
        // Another side can insert lines inside the same aligned edit. A complete, unique
        // multiline replacement can still be recognized at the edge of that base region.
        let sharesBoundary = range.lowerBound == window.lowerBound || range.upperBound == window.upperBound
        let embedded = try sharesBoundary && !removed.isEmpty && added.count > 1 && occurrences(added, in: edited, limit: 2) == 1
        guard startMatches || endMatches || embedded else { return false }
        return try occurrences(added, in: original) == 0 && occurrences(removed, in: edited) == 0
    }

    private static func conflictWindow(
        for range: Range<Int>, in edits: [ReplayChange], budget: inout Budget
    ) throws -> (base: Range<Int>, draft: Range<Int>, edits: ArraySlice<ReplayChange>) {
        var first = 0
        var upper = edits.count
        while first < upper {
            let middle = first + (upper - first) / 2
            let before = edits[middle].change.before
            if before.upperBound < range.lowerBound || (before.upperBound == range.lowerBound && !before.isEmpty && !range.isEmpty) {
                first = middle + 1
            } else { upper = middle }
        }
        var last = first
        while last < edits.count {
            try budget.check()
            let before = edits[last].change.before
            if before.lowerBound > range.upperBound || (before.lowerBound == range.upperBound && !before.isEmpty && !range.isEmpty) { break }
            last += 1
        }
        let overlapping = edits[first..<last]
        let start = min(range.lowerBound, overlapping.first?.change.before.lowerBound ?? range.lowerBound)
        let end = max(range.upperBound, overlapping.last?.change.before.upperBound ?? range.upperBound)
        func displacement(at index: Int) -> Int {
            guard index > 0 else { return 0 }
            let change = edits[index - 1].change
            return change.after.upperBound - change.before.upperBound
        }
        return (start..<end, (start + displacement(at: first))..<(end + displacement(at: last)), overlapping)
    }

    private static func confirmRows(
        _ rows: some Sequence<Int>, in lines: ArraySlice<TextPart>, confirmed: inout [Int: [NSRange]]
    ) {
        for (row, line) in zip(rows, lines) {
            confirmed[row] = [NSRange(location: 0, length: line.text.utf16.count + 1)]
        }
    }

    private static func confirmWords(
        _ change: NSRange, rows: [Int], in lines: ArraySlice<TextPart>, confirmed: inout [Int: [NSRange]]
    ) {
        guard change.length > 0, let start = lines.first?.start else { return }
        for (row, line) in zip(rows, lines) {
            let range = NSRange(location: line.start - start, length: line.text.utf16.count)
            if range.location >= NSMaxRange(change) { break }
            let overlap = NSIntersectionRange(range, change)
            if overlap.length > 0 {
                confirmed[row, default: []].append(NSRange(location: overlap.location - range.location + 1, length: overlap.length))
            }
        }
    }

    private static func replay(
        _ original: [TextPart], incoming: [TextPart], draft: [TextPart], mergeLineEdits: Bool, budget: inout Budget
    ) throws -> String? {
        let patches = try replayChanges(from: original, to: incoming, budget: &budget)
        let draftEdits = try replayChanges(from: original, to: draft, budget: &budget)
        var patchIndex = 0
        var draftIndex = 0
        var previous = 0
        var merged = ""

        func append(_ change: Change, text: String) {
            for part in original[previous..<change.before.lowerBound] { merged += part.text }
            merged += text
            previous = change.before.upperBound
        }

        while patchIndex < patches.count || draftIndex < draftEdits.count {
            try budget.check()
            let patch = patchIndex < patches.count ? patches[patchIndex] : nil
            let draftEdit = draftIndex < draftEdits.count ? draftEdits[draftIndex] : nil
            if let patch, let draftEdit, patch.change.before == draftEdit.change.before {
                let patchText = incoming[patch.change.after].map(\.text).joined()
                let draftText = draft[draftEdit.change.after].map(\.text).joined()
                if patchText.utf8.elementsEqual(draftText.utf8) {
                    append(patch.change, text: patchText)
                } else if mergeLineEdits, patch.isSingleLineReplacement, draftEdit.isSingleLineReplacement {
                    let baseText = original[patch.change.before.lowerBound].text
                    guard baseText.utf16.count + patchText.utf16.count + draftText.utf16.count <= 8_192 else { return nil }
                    // jj can materialize a conflict when two sides changed different words on the same line.
                    let baseWords = try words(in: baseText, budget: &budget)
                    let patchWords = try words(in: patchText, budget: &budget)
                    let draftWords = try words(in: draftText, budget: &budget)
                    guard let combined = try replay(baseWords, incoming: patchWords, draft: draftWords,
                                                    mergeLineEdits: false, budget: &budget) else { return nil }
                    append(patch.change, text: combined)
                } else {
                    return nil
                }
                patchIndex += 1
                draftIndex += 1
            } else if let patch, draftEdit.map(patch.precedes) ?? true {
                append(patch.change, text: incoming[patch.change.after].map(\.text).joined())
                patchIndex += 1
            } else if let draftEdit, patch.map(draftEdit.precedes) ?? true {
                append(draftEdit.change, text: draft[draftEdit.change.after].map(\.text).joined())
                draftIndex += 1
            } else {
                return nil
            }
        }
        for part in original[previous...] { merged += part.text }
        try budget.check(immediately: true)
        return merged
    }

    private struct ReplayChange {
        let change: Change
        let firstPossibleStart: Int
        let lastPossibleEnd: Int

        var isSingleLineReplacement: Bool {
            change.before.count == 1 && change.after.count == 1 &&
                firstPossibleStart == change.before.lowerBound && lastPossibleEnd == change.before.upperBound
        }

        func precedes(_ other: Self) -> Bool {
            if change.before.isEmpty, other.change.before.isEmpty {
                return lastPossibleEnd < other.firstPossibleStart
            }
            return lastPossibleEnd <= other.firstPossibleStart
        }
    }

    private static func replayChanges(
        from original: [TextPart], to edited: [TextPart], budget: inout Budget
    ) throws -> [ReplayChange] {
        let (old, new) = try textIDs(original, edited, normalizeCRLF: false, budget: &budget)
        let changes = try differences(old, new, budget: &budget)
        return try changes.indices.map { index in
            try budget.check()
            let change = changes[index]
            let preceding = index > 0 ? changes[index - 1] : nil
            let following = index + 1 < changes.count ? changes[index + 1] : nil
            let leftLimit = change.before.lowerBound - (preceding?.before.upperBound ?? 0)
            let rightLimit = (following?.before.lowerBound ?? old.count) - change.before.upperBound
            var left = 0
            var right = 0
            // An equally valid alignment can move an edit across repeated text.
            // A replay is safe only if those placements also avoid other edits.
            while left < leftLimit, old[change.before.upperBound - left - 1] == new[change.after.upperBound - left - 1] {
                try budget.check()
                left += 1
            }
            while right < rightLimit, old[change.before.lowerBound + right] == new[change.after.lowerBound + right] {
                try budget.check()
                right += 1
            }
            return ReplayChange(change: change, firstPossibleStart: change.before.lowerBound - left,
                                lastPossibleEnd: change.before.upperBound + right)
        }
    }

    private struct Change {
        let before: Range<Int>
        let after: Range<Int>

        var mark: JJLineMark {
            let kind: JJLineMark.Kind
            if after.isEmpty { kind = .deletion }
            else { kind = before.isEmpty ? .insertion : .replacement }
            return JJLineMark(kind: kind, lines: after)
        }
    }

    private enum DiffStep {
        case compare(old: Range<Int>, new: Range<Int>)
        case equal(oldStart: Int, newStart: Int, count: Int)
    }

    private static func differences(_ old: [Int], _ new: [Int], budget: inout Budget) throws -> [Change] {
        var steps: [DiffStep] = [.compare(old: old.indices, new: new.indices)]
        var changes: [Change] = []
        var previousOldEnd = 0
        var previousNewEnd = 0

        func recordEqual(_ oldStart: Int, _ newStart: Int, count: Int) {
            if previousOldEnd < oldStart || previousNewEnd < newStart {
                changes.append(Change(before: previousOldEnd..<oldStart, after: previousNewEnd..<newStart))
            }
            previousOldEnd = oldStart + count
            previousNewEnd = newStart + count
        }

        while let step = steps.popLast() {
            try budget.check()
            switch step {
            case let .equal(oldStart, newStart, count):
                recordEqual(oldStart, newStart, count: count)
            case let .compare(oldRange, newRange):
                var oldStart = oldRange.lowerBound
                var newStart = newRange.lowerBound
                var oldEnd = oldRange.upperBound
                var newEnd = newRange.upperBound
                while oldStart < oldEnd, newStart < newEnd, old[oldStart] == new[newStart] {
                    try budget.check()
                    oldStart += 1
                    newStart += 1
                }
                let prefix = oldStart - oldRange.lowerBound
                if prefix > 0 { recordEqual(oldRange.lowerBound, newRange.lowerBound, count: prefix) }

                while oldStart < oldEnd, newStart < newEnd, old[oldEnd - 1] == new[newEnd - 1] {
                    try budget.check()
                    oldEnd -= 1
                    newEnd -= 1
                }
                let suffix = oldRange.upperBound - oldEnd
                if suffix > 0 { steps.append(.equal(oldStart: oldEnd, newStart: newEnd, count: suffix)) }

                if oldStart < oldEnd, newStart < newEnd,
                   let (x, y) = try bisect(old, new, oldStart..<oldEnd, newStart..<newEnd, budget: &budget),
                   (x > oldStart || y > newStart), (x < oldEnd || y < newEnd) {
                    steps.append(.compare(old: x..<oldEnd, new: y..<newEnd))
                    steps.append(.compare(old: oldStart..<x, new: newStart..<y))
                }
            }
        }
        recordEqual(old.count, new.count, count: 0)
        return changes
    }

    // Keep the earliest matching copies. A shift matches the leading pair in
    // place of the trailing pair and preserves both documents and the edit cost.
    private static func alignRepeatedLines(_ changes: [Change], old: [Int], new: [Int]) -> [Change] {
        var aligned: [Change] = []
        aligned.reserveCapacity(changes.count)
        for index in changes.indices {
            let change = changes[index]
            // Each shift visits only the unchanged lines before the next original hunk.
            let next = index + 1 < changes.count ? changes[index + 1] : nil
            let nextOld = next?.before.lowerBound ?? old.count
            let nextNew = next?.after.lowerBound ?? new.count
            var shift = 0
            while change.before.upperBound + shift < nextOld, change.after.upperBound + shift < nextNew,
                  old[change.before.lowerBound + shift] == new[change.after.lowerBound + shift] {
                shift += 1
            }
            let before = (change.before.lowerBound + shift)..<(change.before.upperBound + shift)
            let after = (change.after.lowerBound + shift)..<(change.after.upperBound + shift)
            if let previous = aligned.last, previous.before.upperBound == before.lowerBound,
               previous.after.upperBound == after.lowerBound {
                aligned[aligned.count - 1] = Change(before: previous.before.lowerBound..<before.upperBound,
                                                     after: previous.after.lowerBound..<after.upperBound)
            } else {
                aligned.append(Change(before: before, after: after))
            }
        }
        return aligned
    }

    private static func makeHunks(
        _ changes: [Change], oldLines: [TextPart], newLines: [TextPart], base: NSString, current: NSString,
        conflicts: [Range<Int>], normalizeCRLF: Bool, budget: inout Budget
    ) throws -> [JJDiffHunk] {
        var hunks: [JJDiffHunk] = []
        var firstConflict = 0
        // Word details are optional. Keep the line ranges and restore data if fine-grained comparison runs out of time.
        var wordBudget = Budget(deadline: min(budget.deadline, ContinuousClock.now + .milliseconds(80)))
        for change in changes {
            try budget.check()
            let line = change.after.lowerBound
            while firstConflict < conflicts.count, conflicts[firstConflict].upperBound <= line {
                firstConflict += 1
            }
            if firstConflict < conflicts.count {
                let conflict = conflicts[firstConflict]
                if change.after.isEmpty ? conflict.contains(line) : conflict.overlaps(change.after) { continue }
            }
            let baseRange = textRange(change.before, in: oldLines, length: base.length)
            let currentRange = textRange(change.after, in: newLines, length: current.length)
            let removed = base.substring(with: baseRange)
            let inserted = current.substring(with: currentRange)
            let highlights = try? wordHighlights(removed, inserted, normalizeCRLF: normalizeCRLF, budget: &wordBudget)
            hunks.append(JJDiffHunk(mark: change.mark, baseRange: baseRange, currentRange: currentRange,
                                   removedText: removed, insertedText: inserted,
                                   removedHighlights: highlights?.removed ?? [],
                                   insertedHighlights: highlights?.inserted ?? []))
        }
        return hunks
    }

    private static func textRange(_ indices: Range<Int>, in parts: [TextPart], length: Int) -> NSRange {
        let start = indices.lowerBound < parts.count ? parts[indices.lowerBound].start : length
        let end = indices.upperBound < parts.count ? parts[indices.upperBound].start : length
        return NSRange(location: start, length: end - start)
    }

    static func wordHighlights(
        _ removed: String, _ inserted: String, normalizeCRLF: Bool, budget: inout Budget
    ) throws -> (removed: [NSRange], inserted: [NSRange]) {
        let removedLength = removed.utf16.count
        let insertedLength = inserted.utf16.count
        guard removedLength > 0, insertedLength > 0, removedLength + insertedLength <= 8_192 else { return ([], []) }
        let changes = try wordChangeRanges(removed, inserted, normalizeCRLF: normalizeCRLF, budget: &budget)
        return (changes.map(\.removed).filter { $0.length > 0 }, changes.map(\.inserted).filter { $0.length > 0 })
    }

    private static func wordChangeRanges(
        _ removed: String, _ inserted: String, normalizeCRLF: Bool, budget: inout Budget
    ) throws -> [(removed: NSRange, inserted: NSRange)] {
        let oldWords = try words(in: removed, budget: &budget)
        let newWords = try words(in: inserted, budget: &budget)
        let (oldIDs, newIDs) = try textIDs(oldWords, newWords, normalizeCRLF: normalizeCRLF, budget: &budget)
        let oldLength = removed.utf16.count
        let newLength = inserted.utf16.count
        return try differences(oldIDs, newIDs, budget: &budget).map { change in
            (textRange(change.before, in: oldWords, length: oldLength), textRange(change.after, in: newWords, length: newLength))
        }
    }

    private enum WordGroup {
        case identifier, whitespace

        init?(_ character: Character) {
            if character.isNewline { return nil }
            if character.isWhitespace { self = .whitespace }
            else if character.isLetter || character.isNumber || character == "_" { self = .identifier }
            else { return nil }
        }
    }

    private static func words(in text: String, budget: inout Budget) throws -> [TextPart] {
        try budget.check(immediately: true)
        var result: [TextPart] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            try budget.check()
            let group = WordGroup(text[start])
            var end = text.index(after: start)
            if let group {
                while end < text.endIndex, WordGroup(text[end]) == group {
                    try budget.check()
                    text.formIndex(after: &end)
                }
            }
            let word = text[start..<end]
            result.append(TextPart(start: offset, text: String(word)))
            offset += word.utf16.count
            start = end
        }
        return result
    }

    // Linear-space Myers bisection. Frontiers meet when they reach the same diagonal.
    private static func bisect(
        _ old: [Int], _ new: [Int], _ oldRange: Range<Int>, _ newRange: Range<Int>, budget: inout Budget
    ) throws -> (Int, Int)? {
        let oldCount = oldRange.count
        let newCount = newRange.count
        let delta = oldCount - newCount
        let checkForward = !delta.isMultiple(of: 2)
        let limit = (oldCount + newCount + 1) / 2
        let offset = limit + 1
        var forward = [Int](repeating: -1, count: 2 * offset + 1)
        var reverse = forward
        forward[offset + 1] = 0
        reverse[offset + 1] = 0
        var forwardStart = 0, forwardEnd = 0, reverseStart = 0, reverseEnd = 0

        func advance(_ frontier: [Int], diagonal: Int, distance: Int) -> Int {
            let index = offset + diagonal
            if diagonal == -distance || (diagonal != distance && frontier[index - 1] < frontier[index + 1]) {
                return frontier[index + 1]
            }
            return frontier[index - 1] + 1
        }

        for distance in 0...limit {
            try budget.check(immediately: true)
            for diagonal in stride(from: -distance + forwardStart, through: distance - forwardEnd, by: 2) {
                try budget.check()
                let index = offset + diagonal
                var x = advance(forward, diagonal: diagonal, distance: distance)
                var y = x - diagonal
                while x < oldCount, y < newCount,
                      old[oldRange.lowerBound + x] == new[newRange.lowerBound + y] {
                    try budget.check()
                    x += 1
                    y += 1
                }
                forward[index] = x
                if x > oldCount { forwardEnd += 2 }
                else if y > newCount { forwardStart += 2 }
                else if checkForward, reverse.indices.contains(offset + delta - diagonal) {
                    let opposite = reverse[offset + delta - diagonal]
                    if opposite >= 0, x >= oldCount - opposite {
                        return (oldRange.lowerBound + x, newRange.lowerBound + y)
                    }
                }
            }
            for diagonal in stride(from: -distance + reverseStart, through: distance - reverseEnd, by: 2) {
                try budget.check()
                let index = offset + diagonal
                var x = advance(reverse, diagonal: diagonal, distance: distance)
                var y = x - diagonal
                while x < oldCount, y < newCount,
                      old[oldRange.upperBound - 1 - x] == new[newRange.upperBound - 1 - y] {
                    try budget.check()
                    x += 1
                    y += 1
                }
                reverse[index] = x
                if x > oldCount { reverseEnd += 2 }
                else if y > newCount { reverseStart += 2 }
                else if !checkForward, forward.indices.contains(offset + delta - diagonal) {
                    let opposite = forward[offset + delta - diagonal]
                    if opposite >= 0, opposite >= oldCount - x {
                        return (oldRange.lowerBound + opposite, newRange.lowerBound + opposite - (delta - diagonal))
                    }
                }
            }
        }
        return nil
    }

    private struct ConflictBlock {
        let start: Int
        let width: Int
        var snapshots = 0
        var diffs = 0
        var separatesGitSides = false

        var hasAlternatives: Bool { separatesGitSides || diffs + snapshots >= 2 }
    }

    private static func conflictRanges(
        in lines: [TextPart], matching reference: [TextPart], budget: inout Budget
    ) throws -> (ranges: [Range<Int>], uncertain: Bool) {
        var delimitersByWidth: [Int: Set<JJConflict.Delimiter>] = [:]
        var labelsByWidth: [Int: [JJConflict.Delimiter: Set<String>]] = [:]
        var markerWidth = 0
        for line in reference {
            try budget.check()
            guard let token = JJConflict.Marker(line.text), token.width >= 7 else { continue }
            if token.delimiter == .open { markerWidth = max(markerWidth, token.width) }
            delimitersByWidth[token.width, default: []].insert(token.delimiter)
            if !token.label.isEmpty {
                labelsByWidth[token.width, default: [:]][token.delimiter, default: []].insert(token.label)
            }
        }
        // jj chooses a width greater than the literal marker-like lines in the file.
        guard let fullDelimiters = delimitersByWidth[markerWidth], fullDelimiters.contains(.close) else {
            return ([], true)
        }
        let knownLabels = labelsByWidth[markerWidth] ?? [:]

        var ranges: [Range<Int>] = []
        var block: ConflictBlock?
        var uncertain = false
        for (index, line) in lines.enumerated() {
            try budget.check()
            guard let token = JJConflict.Marker(line.text) else { continue }

            if token.width < markerWidth {
                // An edited marker can lose part of its prefix while keeping its jj label.
                if knownLabels[token.delimiter]?.contains(token.label) == true {
                    uncertain = true
                    block = nil
                }
                continue
            }
            if token.delimiter == .open {
                if block != nil { uncertain = true }
                block = ConflictBlock(start: index, width: token.width)
                continue
            }
            guard var open = block else {
                if fullDelimiters.contains(token.delimiter) { uncertain = true }
                continue
            }
            guard token.width == open.width else {
                uncertain = true
                block = nil
                continue
            }
            switch token.delimiter {
            case .close:
                if open.hasAlternatives { ranges.append(open.start..<(index + 1)) }
                else { uncertain = true }
                block = nil
                continue
            case .snapshot: open.snapshots += 1
            case .diff: open.diffs += 1
            case .gitSeparator: open.separatesGitSides = true
            case .open, .ancestor, .diffTo, .gitAncestor: break
            }
            block = open
        }
        return (ranges, uncertain || block != nil)
    }

    private static func compose(_ ordinary: [JJLineMark], with conflicts: [Range<Int>]) -> [JJLineMark] {
        guard !conflicts.isEmpty else { return ordinary }
        var result: [JJLineMark] = []
        var firstConflict = 0
        for mark in ordinary {
            var start = mark.lines.lowerBound
            while firstConflict < conflicts.count, conflicts[firstConflict].upperBound <= start {
                firstConflict += 1
            }
            if mark.lines.isEmpty {
                if firstConflict == conflicts.count || !conflicts[firstConflict].contains(start) {
                    result.append(mark)
                }
                continue
            }
            let end = mark.lines.upperBound
            for conflict in conflicts[firstConflict...] {
                if conflict.lowerBound >= end { break }
                if start < conflict.lowerBound {
                    result.append(JJLineMark(kind: mark.kind, lines: start..<conflict.lowerBound))
                }
                start = max(start, conflict.upperBound)
                if start >= end { break }
            }
            if start < end { result.append(JJLineMark(kind: mark.kind, lines: start..<end)) }
        }
        result.append(contentsOf: conflicts.map { JJLineMark(kind: .conflict, lines: $0) })
        return result.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }
}
