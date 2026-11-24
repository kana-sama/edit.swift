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
    private let width: Int
    private let opening: String
    private let closing: String
    private let lineEnding: String
    private let endsWithNewline: Bool

    var canChangeStyle: Bool { bases.count == sides.count - 1 }

    var startingResult: String {
        for segment in segments {
            if case let .snapshot(side) = segment.kind { return sides[side].text }
        }
        return sides[0].text
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
        if !terminated {
            // In this encoding jj adds one line ending to every term in the final block.
            for index in sides.indices { sides[index].text = removingPadding(from: sides[index].text, lineEnding: lineEnding) }
            for index in bases.indices { bases[index].text = removingPadding(from: bases[index].text, lineEnding: lineEnding) }
        }
        highlights.append(highlight(last, .marker))
        let range = NSRange(location: first.start, length: last.start + last.text.utf16.count - first.start)
        return Self(range: range, source: lines.map(\.text).joined(), style: style,
                    sides: sides, bases: bases, segments: segments, highlights: highlights, width: open.width,
                    opening: git ? "conflict" : open.label, closing: git ? "conflict ends" : close.label,
                    lineEnding: lineEnding, endsWithNewline: terminated)
    }

    func rendered(as style: Style) -> String? {
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
