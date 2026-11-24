import Foundation

struct JJConflict: Equatable, Sendable {
    enum Style: Int, Sendable {
        case diff, snapshot, git
    }

    enum Delimiter: UInt8 {
        case open = 60, close = 62, snapshot = 43, ancestor = 45
        case diff = 37, diffTo = 92, gitAncestor = 124, gitSeparator = 61
    }

    struct Marker {
        let delimiter: Delimiter
        let width: Int
        let label: String

        init?(_ line: String) {
            let bytes = line.utf8
            guard let first = bytes.first, let delimiter = Delimiter(rawValue: first) else { return nil }
            let end = bytes.firstIndex { $0 != first } ?? bytes.endIndex
            guard end == bytes.endIndex || [9, 10, 13, 32].contains(bytes[end]) else { return nil }
            self.delimiter = delimiter
            width = bytes.distance(from: bytes.startIndex, to: end)
            label = String(decoding: bytes[end...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Term: Equatable, Sendable {
        var label: String
        var text = ""
    }

    enum Role: Equatable, Sendable {
        case marker, addition, removal
    }

    struct Highlight: Equatable, Sendable {
        let range: NSRange
        let role: Role
        var changes: [NSRange] = []
    }

    struct Segment: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case snapshot(side: Int), diff(base: Int, side: Int)
        }

        let anchor: NSRange
        let kind: Kind
    }

    let range: NSRange
    let source: String
    let style: Style
    let sides: [Term]
    private let bases: [Term]
    let segments: [Segment]
    let highlights: [Highlight]
    let resultRange: NSRange?
    let resultSide: Int
    private let width: Int
    private let opening: String
    private let closing: String
    let lineEnding: String
    let resultSeparator: String
    private let emptyResult: String
    private let endsWithNewline: Bool
    let hasEditedResult: Bool

    var canChangeStyle: Bool { !hasEditedResult && bases.count == sides.count - 1 }

    var startingResult: String { sides[resultSide].text }
    var resultNeedsSeparator: Bool { resultSeparator.isEmpty }

    func resolvedResult(_ editable: String) -> String {
        // At EOF, jj adds a separator that never belonged to the underlying side.
        guard endsWithNewline else { return editable }
        if editable.isEmpty { return emptyResult }
        return editable + (resultSeparator.isEmpty ? lineEnding : resultSeparator)
    }

    func displayedResult(_ resolved: String) -> String {
        guard endsWithNewline else { return resolved }
        return Self.removingPadding(from: resolved, lineEnding: Self.trailingLineEnding(in: resolved))
    }

    func displayingResult(in text: NSString, blockRange: NSRange, resultRange: NSRange, hasSeparator: Bool) -> Self {
        guard let originalResultRange = self.resultRange,
              blockRange.location >= 0, resultRange.location >= blockRange.location,
              NSMaxRange(blockRange) <= text.length, NSMaxRange(resultRange) <= NSMaxRange(blockRange) else { return self }
        let before = blockRange.location - range.location
        let after = NSMaxRange(blockRange) - NSMaxRange(range)
        func shifted(_ range: NSRange) -> NSRange {
            let offset = range.location < NSMaxRange(originalResultRange) ? before : after
            return NSRange(location: range.location + offset, length: range.length)
        }

        // The original marker lines and alternative payloads are protected. Only the snapshot's
        // text can change, even when its new contents look like conflict markers themselves.
        let editable = text.substring(with: resultRange)
        let separator = hasSeparator ? (resultSeparator.isEmpty ? lineEnding : resultSeparator) : ""
        let projectedSource = text.substring(with: blockRange)
        var sides = self.sides
        sides[resultSide].text = resolvedResult(editable)
        return Self(
            range: blockRange, source: projectedSource, style: style, sides: sides, bases: bases,
            segments: segments.map { Segment(anchor: shifted($0.anchor), kind: $0.kind) },
            highlights: highlights.map { Highlight(range: shifted($0.range), role: $0.role, changes: $0.changes.map(shifted)) },
            resultRange: resultRange, resultSide: resultSide,
            width: width, opening: opening, closing: closing,
            lineEnding: lineEnding, resultSeparator: separator, emptyResult: emptyResult, endsWithNewline: endsWithNewline,
            hasEditedResult: hasEditedResult || !projectedSource.utf8.elementsEqual(source.utf8)
        )
    }

    func applyingDiff(for segment: Segment, onto text: String) -> String? {
        guard case let .diff(base, side) = segment.kind else { return nil }
        return JJLineDiff.applyConflictDelta(from: bases[base].text, to: sides[side].text, onto: text)
    }

    private enum Section {
        case side(Int), base(Int), diff(base: Int, side: Int)
    }

    private struct DiffLine {
        let row: Int
        let text: Substring
    }

    static func parse(
        _ lines: ArraySlice<JJLineDiff.TextPart>, normalizeCRLF: Bool, budget: inout JJLineDiff.Budget
    ) -> Self? {
        guard let first = lines.first, let last = lines.last,
              let open = Marker(first.text), let close = Marker(last.text),
              open.delimiter == .open, close.delimiter == .close, open.width == close.width else { return nil }
        let inner = lines.dropFirst().dropLast()
        let git = inner.contains { line in
            let marker = Marker(line.text)
            return marker?.delimiter == .gitSeparator && marker?.width == open.width
        }
        var sides: [Term] = git ? [Term(label: open.label)] : []
        var bases: [Term] = []
        var section: Section? = git ? .side(0) : nil
        var highlights: [Highlight] = [highlight(first, .marker)]
        var markerRanges = [fullRange(first)]
        var segments: [Segment] = git ? [Segment(anchor: highlights[0].range, kind: .snapshot(side: 0))] : []
        var style: Style = git ? .git : .snapshot
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func finishDiffRun() {
            defer {
                removed.removeAll(keepingCapacity: true)
                added.removeAll(keepingCapacity: true)
            }
            guard !removed.isEmpty, !added.isEmpty,
                  let ranges = try? JJLineDiff.wordHighlights(removed.map(\.text).joined(), added.map(\.text).joined(),
                                                               normalizeCRLF: normalizeCRLF, budget: &budget) else { return }
            placeChanges(ranges.removed, on: removed, in: &highlights)
            placeChanges(ranges.inserted, on: added, in: &highlights)
        }

        for line in inner {
            if let marker = Marker(line.text), marker.width == open.width {
                finishDiffRun()
                let header = highlight(line, .marker)
                switch marker.delimiter {
                case .snapshot where !git, .gitSeparator where git:
                    segments.append(Segment(anchor: header.range, kind: .snapshot(side: sides.count)))
                    section = .side(sides.count)
                    sides.append(Term(label: git ? close.label : marker.label))
                case .ancestor where !git, .gitAncestor where git:
                    section = .base(bases.count)
                    bases.append(Term(label: marker.label))
                case .diff where !git:
                    segments.append(Segment(anchor: header.range, kind: .diff(base: bases.count, side: sides.count)))
                    section = .diff(base: bases.count, side: sides.count)
                    bases.append(Term(label: label(marker.label, removing: "diff from:")))
                    sides.append(Term(label: ""))
                    style = .diff
                case .diffTo:
                    guard case let .diff(base, side) = section, bases[base].text.isEmpty, sides[side].text.isEmpty else {
                        return nil
                    }
                    sides[side].label = label(marker.label, removing: "to:")
                default:
                    return nil
                }
                highlights.append(header)
                markerRanges.append(fullRange(line))
                continue
            }
            switch section {
            case let .side(index):
                sides[index].text += line.text
            case let .base(index):
                bases[index].text += line.text
            case let .diff(base, side):
                let payload = line.text.dropFirst()
                switch line.text.first {
                case " ":
                    finishDiffRun()
                    bases[base].text += payload
                    sides[side].text += payload
                case "-":
                    bases[base].text += payload
                    removed.append(DiffLine(row: highlights.count, text: payload))
                    highlights.append(highlight(line, .removal))
                case "+":
                    sides[side].text += payload
                    added.append(DiffLine(row: highlights.count, text: payload))
                    highlights.append(highlight(line, .addition))
                default: return nil
                }
            case nil:
                return nil
            }
        }
        finishDiffRun()
        guard sides.count >= 2, bases.count == sides.count - 1 || (git && sides.count == 2 && bases.isEmpty) else { return nil }
        let lineEnding = first.text.hasSuffix("\r\n") ? "\r\n" : "\n"
        let terminated = last.text.utf8.last == 10
        let resultAnchor = segments.first {
            if case .snapshot = $0.kind { return true }
            return false
        }
        let resultSide: Int
        let resultRange: NSRange?
        let resultSeparator: String
        if let resultAnchor, case let .snapshot(side) = resultAnchor.kind,
           let header = markerRanges.first(where: { $0.location == resultAnchor.anchor.location }) {
            resultSide = side
            let materialized = sides[side].text
            // An unterminated block has exactly the marker line ending appended to each term,
            // even when a side's own bytes end in a carriage return.
            if !terminated, materialized.utf8.suffix(lineEnding.utf8.count).elementsEqual(lineEnding.utf8) {
                resultSeparator = lineEnding
            } else {
                resultSeparator = trailingLineEnding(in: materialized)
            }
            resultRange = NSRange(location: NSMaxRange(header), length: materialized.utf16.count - resultSeparator.utf16.count)
        } else {
            resultSide = 0
            resultRange = nil
            resultSeparator = ""
        }
        if !terminated {
            // In this encoding jj adds one line ending to every term in the final block.
            for index in sides.indices { sides[index].text = removingPadding(from: sides[index].text, lineEnding: lineEnding) }
            for index in bases.indices { bases[index].text = removingPadding(from: bases[index].text, lineEnding: lineEnding) }
        }
        highlights.append(highlight(last, .marker))
        let range = NSRange(location: first.start, length: last.start + last.text.utf16.count - first.start)
        return Self(range: range, source: lines.map(\.text).joined(), style: style,
                    sides: sides, bases: bases, segments: segments, highlights: highlights,
                    resultRange: resultRange, resultSide: resultSide, width: open.width,
                    opening: git ? "conflict" : open.label, closing: git ? "conflict ends" : close.label,
                    lineEnding: lineEnding, resultSeparator: resultSeparator,
                    emptyResult: terminated && sides[resultSide].text == resultSeparator ? resultSeparator : "",
                    endsWithNewline: terminated, hasEditedResult: false)
    }

    func rendered(as style: Style) -> String? {
        guard !hasEditedResult else { return nil }
        if style == self.style { return source }
        guard canChangeStyle, style != .git else { return nil }
        func marker(_ character: Character, _ label: String, ending: String) -> String {
            String(repeating: character, count: width) + (label.isEmpty ? "" : " " + label) + ending
        }
        func payload(_ term: Term) -> String {
            endsWithNewline ? term.text : term.text + lineEnding
        }
        var result = marker("<", opening, ending: lineEnding)
        if style == .snapshot {
            for index in sides.indices {
                result += marker("+", sides[index].label, ending: lineEnding) + payload(sides[index])
                if bases.indices.contains(index) {
                    result += marker("-", bases[index].label, ending: lineEnding) + payload(bases[index])
                }
            }
        } else {
            result += marker("+", sides[0].label, ending: lineEnding) + payload(sides[0])
            for (base, side) in zip(bases, sides.dropFirst()) {
                guard let diff = JJLineDiff.conflictDelta(from: payload(base), to: payload(side)) else { return nil }
                result += marker("%", "diff from: " + base.label, ending: lineEnding)
                result += marker("\\", "       to: " + side.label, ending: lineEnding) + diff
            }
        }
        return result + marker(">", closing, ending: endsWithNewline ? lineEnding : "")
    }

    private static func label(_ label: String, removing prefix: String) -> String {
        label.hasPrefix(prefix) ? label.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : label
    }

    private static func removingPadding(from term: String, lineEnding: String) -> String {
        guard term.utf8.last == 10 else { return term }
        return String(decoding: term.utf8.dropLast(lineEnding.utf8.count), as: UTF8.self)
    }

    private static func trailingLineEnding(in text: String) -> String {
        if text.hasSuffix("\r\n") { return "\r\n" }
        return text.hasSuffix("\n") ? "\n" : ""
    }

    private static func fullRange(_ line: JJLineDiff.TextPart) -> NSRange {
        NSRange(location: line.start, length: line.text.utf16.count)
    }

    private static func highlight(_ line: JJLineDiff.TextPart, _ role: Role) -> Highlight {
        let length = line.text.utf8.last == 10 ? line.text.dropLast().utf16.count : line.text.utf16.count
        return Highlight(range: NSRange(location: line.start, length: length), role: role)
    }

    private static func placeChanges(_ changes: [NSRange], on lines: [DiffLine], in highlights: inout [Highlight]) {
        var offset = 0
        var firstChange = 0
        for line in lines {
            let row = highlights[line.row].range
            // The comparison joins the payloads without their diff prefixes.
            let payload = NSRange(location: offset, length: row.length - 1)
            while firstChange < changes.count, NSMaxRange(changes[firstChange]) <= offset { firstChange += 1 }
            for change in changes[firstChange...] {
                guard change.location < NSMaxRange(payload) else { break }
                let overlap = NSIntersectionRange(payload, change)
                if overlap.length > 0 {
                    highlights[line.row].changes.append(NSRange(location: row.location + 1 + overlap.location - offset,
                                                               length: overlap.length))
                }
            }
            offset += line.text.utf16.count
        }
    }
}
