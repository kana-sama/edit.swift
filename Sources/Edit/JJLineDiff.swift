import Foundation

struct JJLineMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
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
            return JJTextAnalysis(marks: [], lineStarts: [], isChanged: changed, remainsConflicted: nil)
        }
        var budget = Budget()
        guard let newLines = try? split(current, budget: &budget) else {
            return JJTextAnalysis(marks: [], lineStarts: [], isChanged: changed, remainsConflicted: remainsConflicted)
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
        if changed == true, let base, hasReliableFraming {
            do {
                let oldLines = try split(base, budget: &budget)
                let (oldIDs, newIDs) = try lineIDs(oldLines, newLines, normalizeCRLF: normalizeCRLF, budget: &budget)
                ordinary = try differences(oldIDs, newIDs, budget: &budget)
            } catch {
                // File status and confirmed conflict marks remain available without a line diff.
            }
        }
        let marks = compose(ordinary, with: conflicts)
        return JJTextAnalysis(marks: marks, lineStarts: marks.isEmpty ? [] : newLines.map(\.start),
                              isChanged: changed, remainsConflicted: remainsConflicted)
    }

    private enum Limit: Error { case exceeded }

    private struct Budget {
        let deadline = ContinuousClock.now + .seconds(1)
        private var work = 0

        mutating func check(immediately: Bool = false) throws {
            work += 1
            if immediately || work.isMultiple(of: 128) {
                if Task.isCancelled || ContinuousClock.now >= deadline { throw Limit.exceeded }
            }
        }
    }

    private struct Line {
        let start: Int
        let text: String
    }

    private struct ExactLine: Hashable {
        let text: String

        static func == (left: Self, right: Self) -> Bool {
            left.text.utf8.elementsEqual(right.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            var contiguous = text
            contiguous.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    private static func split(_ text: String, budget: inout Budget) throws -> [Line] {
        try budget.check(immediately: true)
        guard text.utf8.count <= 8 * 1_024 * 1_024, !text.utf8.contains(0) else { throw Limit.exceeded }
        let source = text as NSString
        let length = source.length
        var lines: [Line] = []
        var start = 0
        while start < length {
            try budget.check()
            guard lines.count < 150_000 else { throw Limit.exceeded }
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            lines.append(Line(start: start, text: source.substring(with: range)))
            start = NSMaxRange(range)
        }
        return lines
    }

    private static func lineIDs(
        _ old: [Line], _ new: [Line], normalizeCRLF: Bool, budget: inout Budget
    ) throws -> ([Int], [Int]) {
        var identifiers: [ExactLine: Int] = [:]
        func encode(_ lines: [Line]) throws -> [Int] {
            try lines.map { line in
                try budget.check()
                // Only comparison keys normalize endings. Offsets still address the original buffer.
                let content = normalizeCRLF && line.text.hasSuffix("\r\n")
                    ? String(line.text.dropLast()) + "\n" : line.text
                let key = ExactLine(text: content)
                if let existing = identifiers[key] { return existing }
                let id = identifiers.count
                identifiers[key] = id
                return id
            }
        }
        let oldIDs = try encode(old)
        return (oldIDs, try encode(new))
    }

    private enum DiffStep {
        case compare(old: Range<Int>, new: Range<Int>)
        case equal(oldStart: Int, newStart: Int, count: Int)
    }

    private static func differences(_ old: [Int], _ new: [Int], budget: inout Budget) throws -> [JJLineMark] {
        var steps: [DiffStep] = [.compare(old: old.indices, new: new.indices)]
        var marks: [JJLineMark] = []
        var previousOldEnd = 0
        var previousNewEnd = 0

        func recordEqual(_ oldStart: Int, _ newStart: Int, count: Int) {
            let removed = previousOldEnd < oldStart
            if previousNewEnd < newStart {
                marks.append(JJLineMark(kind: removed ? .replacement : .insertion, lines: previousNewEnd..<newStart))
            } else if removed {
                marks.append(JJLineMark(kind: .deletion, lines: newStart..<newStart))
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
        return marks
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

    private enum Delimiter: UInt8 {
        case open = 60, close = 62, snapshot = 43, ancestor = 45
        case diff = 37, diffTo = 92, gitAncestor = 124, gitSeparator = 61
    }

    private struct Token {
        let delimiter: Delimiter
        let width: Int
        let label: String

        init?(_ text: String) {
            let bytes = text.utf8
            guard let first = bytes.first, let delimiter = Delimiter(rawValue: first) else { return nil }
            let end = bytes.firstIndex { $0 != first } ?? bytes.endIndex
            let width = bytes.distance(from: bytes.startIndex, to: end)
            guard end == bytes.endIndex || [9, 10, 13, 32].contains(bytes[end]) else { return nil }
            self.delimiter = delimiter
            self.width = width
            label = String(decoding: bytes[end...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        in lines: [Line], matching reference: [Line], budget: inout Budget
    ) throws -> (ranges: [Range<Int>], uncertain: Bool) {
        var delimitersByWidth: [Int: Set<Delimiter>] = [:]
        var labelsByWidth: [Int: [Delimiter: Set<String>]] = [:]
        var markerWidth = 0
        for line in reference {
            try budget.check()
            guard let token = Token(line.text), token.width >= 7 else { continue }
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
            guard let token = Token(line.text) else { continue }

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
