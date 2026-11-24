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
        return JJTextAnalysis(marks: marks, lineStarts: marks.isEmpty ? [] : newLines.map(\.start),
                              isChanged: changed, remainsConflicted: remainsConflicted, hunks: hunks,
                              conflicts: conflicts.compactMap { JJConflict.parse(newLines[$0]) })
    }

    private enum Limit: Error { case exceeded }

    private struct Budget {
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

    private static func wordHighlights(
        _ removed: String, _ inserted: String, normalizeCRLF: Bool, budget: inout Budget
    ) throws -> (removed: [NSRange], inserted: [NSRange]) {
        let removedLength = removed.utf16.count
        let insertedLength = inserted.utf16.count
        guard removedLength > 0, insertedLength > 0, removedLength + insertedLength <= 8_192 else { return ([], []) }
        let oldWords = try words(in: removed, budget: &budget)
        let newWords = try words(in: inserted, budget: &budget)
        let (oldIDs, newIDs) = try textIDs(oldWords, newWords, normalizeCRLF: normalizeCRLF, budget: &budget)
        let changes = try differences(oldIDs, newIDs, budget: &budget)
        let oldHighlights = changes.compactMap { change in
            change.before.isEmpty ? nil : textRange(change.before, in: oldWords, length: removedLength)
        }
        let newHighlights = changes.compactMap { change in
            change.after.isEmpty ? nil : textRange(change.after, in: newWords, length: insertedLength)
        }
        return (oldHighlights, newHighlights)
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
