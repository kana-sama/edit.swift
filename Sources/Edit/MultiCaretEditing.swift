import Foundation

enum MultiCaretEditing {
    struct Replacement {
        var range: NSRange
        var text: String

        func result(at offset: Int) -> NSRange {
            NSRange(location: range.location + offset, length: text.utf16.count)
        }
    }

    struct LineBlock {
        var line: LineEditing.Line
        var indices: [Int]
    }

    static func ordered(_ ranges: [NSRange]) -> [NSRange] {
        ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    }

    // Keep selections in creation order. The last selection is the primary.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.enumerated().sorted {
            ($0.element.location, $0.element.length) < ($1.element.location, $1.element.length)
        }
        var merged: [(index: Int, range: NSRange)] = []
        for (index, range) in sorted {
            if let previous = merged.last, NSMaxRange(previous.range) >= range.location {
                merged[merged.count - 1] = (max(previous.index, index), NSUnionRange(previous.range, range))
            } else {
                merged.append((index, range))
            }
        }
        return merged.sorted { $0.index < $1.index }.map(\.range)
    }

    static func lineBlocks(in text: NSString, for ranges: [NSRange]) -> [LineBlock] {
        let blocks = ranges.enumerated().compactMap { index, range in
            LineEditing.affectedLines(in: text, selection: range).map { LineBlock(line: $0, indices: [index]) }
        }.sorted { $0.line.start < $1.line.start }

        var result: [LineBlock] = []
        for block in blocks {
            if let previous = result.last, previous.line.end >= block.line.start {
                let last = previous.line.end > block.line.end ? previous.line : block.line
                result[result.count - 1] = LineBlock(
                    line: LineEditing.Line(start: previous.line.start, contentEnd: last.contentEnd, end: last.end),
                    indices: previous.indices + block.indices
                )
            } else {
                result.append(block)
            }
        }
        return result
    }

    static func indentation(in text: NSString, for ranges: [NSRange], outdent: Bool) -> [Replacement] {
        var edits: [Replacement] = []
        var seen: Set<Int> = []
        for range in ordered(ranges) {
            guard let lines = LineEditing.affectedLines(in: text, selection: range) else { continue }
            var start = lines.start
            repeat {
                let line = LineEditing.line(at: start, in: text)
                if seen.insert(start).inserted {
                    let removed = outdent ? LineEditing.outdentLength(in: line, text: text) : 0
                    if !outdent || removed > 0 {
                        edits.append(Replacement(
                            range: NSRange(location: start, length: removed), text: outdent ? "" : "    "
                        ))
                    }
                }
                start = line.end
            } while start < lines.end
        }
        return edits
    }

    static func mapped(_ selections: [NSRange], after replacements: [Replacement]) -> [NSRange] {
        func offset(for location: Int) -> Int {
            var delta = 0
            for replacement in replacements {
                if replacement.range.location > location { break }
                if NSMaxRange(replacement.range) >= location {
                    return replacement.result(at: delta).upperBound
                }
                delta += replacement.text.utf16.count - replacement.range.length
            }
            return location + delta
        }
        return selections.map { range in
            let start = offset(for: range.location)
            return NSRange(location: start, length: offset(for: NSMaxRange(range)) - start)
        }
    }

    static func selectionEnds(in selection: NSRange, text: NSString) -> [NSRange] {
        guard selection.length > 0,
              let block = LineEditing.affectedLines(in: text, selection: selection) else { return [] }
        var result: [NSRange] = []
        var start = block.start
        repeat {
            let line = LineEditing.line(at: start, in: text)
            result.append(NSRange(location: min(line.contentEnd, NSMaxRange(selection)), length: 0))
            start = line.end
        } while start < block.end
        return result
    }
}
