import Foundation

struct EditorTextChange {
    let range: NSRange
    let delta: Int

    var replacementLength: Int { range.length + delta }
}

struct EditorTextEdit {
    var range: NSRange
    var text: String

    var lengthChange: Int { text.utf16.count - range.length }

    func result(at offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: text.utf16.count)
    }
}

enum MultiCaretEditing {
    typealias Replacement = EditorTextEdit

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

    static func toggleLineComments(in text: NSString, for selections: [NSRange], prefix: String) -> [Replacement] {
        let prefixLength = prefix.utf16.count
        var lines: [(indentationEnd: Int, commentLength: Int)] = []
        for selection in ordered(selections) {
            guard let block = LineEditing.affectedLines(in: text, selection: selection) else { continue }
            var start = block.start
            repeat {
                let line = LineEditing.line(at: start, in: text)
                let indentationEnd = LineEditing.indentationEnd(in: line, text: text)
                if indentationEnd > (lines.last?.indentationEnd ?? -1) {
                    let prefixEnd = indentationEnd + prefixLength
                    let prefixRange = NSRange(location: indentationEnd, length: prefixLength)
                    var commentLength = 0
                    if prefixEnd <= line.contentEnd, text.substring(with: prefixRange) == prefix {
                        commentLength = prefixLength
                        if prefixEnd < line.contentEnd, text.character(at: prefixEnd) == 0x20 {
                            commentLength += 1
                        }
                    }
                    lines.append((indentationEnd, commentLength))
                }
                start = line.end
            } while start < block.end
        }

        let uncomment = lines.allSatisfy { $0.commentLength > 0 }
        return lines.map { line in
            Replacement(range: NSRange(location: line.indentationEnd, length: uncomment ? line.commentLength : 0),
                        text: uncomment ? "" : prefix + " ")
        }
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
