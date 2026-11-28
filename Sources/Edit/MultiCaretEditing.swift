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

    static func indentation(in text: NSString, for ranges: [NSRange], outdent: Bool, settings: Indentation) -> [Replacement] {
        var edits: [Replacement] = []
        var seen: Set<Int> = []
        let unit = outdent ? "" : settings.whitespace(to: settings.width)
        for range in ordered(ranges) {
            guard let lines = LineEditing.affectedLines(in: text, selection: range) else { continue }
            var start = lines.start
            repeat {
                let line = LineEditing.line(at: start, in: text)
                if seen.insert(start).inserted {
                    let removed = outdent ? LineEditing.outdentLength(in: line, text: text, width: settings.width) : 0
                    if !outdent || removed > 0 {
                        edits.append(Replacement(
                            range: NSRange(location: start, length: removed), text: unit
                        ))
                    }
                }
                start = line.end
            } while start < lines.end
        }
        return edits
    }

    static func toggleLineComments(in text: NSString, for selections: [NSRange], prefix: String,
                                   settings: Indentation) -> [Replacement] {
        let prefixLength = prefix.utf16.count
        let insertion = prefix + " "
        var edits: [Replacement] = []
        var seen: Set<Int> = []
        // The primary selection takes precedence on a line shared by multiple selections.
        for selection in selections.reversed() {
            guard let block = LineEditing.affectedLines(in: text, selection: selection) else { continue }
            var lines: [(indentation: NSRange, isBlank: Bool, comment: NSRange?)] = []
            var lineStart = block.start
            repeat {
                let line = LineEditing.line(at: lineStart, in: text)
                if seen.insert(lineStart).inserted {
                    let indentationEnd = LineEditing.indentationEnd(in: line, text: text)
                    let prefixEnd = indentationEnd + prefixLength
                    let prefixRange = NSRange(location: indentationEnd, length: prefixLength)
                    var comment: NSRange?
                    if prefixEnd <= line.contentEnd, text.substring(with: prefixRange) == prefix {
                        let hasSpace = prefixEnd < line.contentEnd && text.character(at: prefixEnd) == 0x20
                        comment = NSRange(location: indentationEnd, length: prefixLength + (hasSpace ? 1 : 0))
                    }
                    lines.append((NSRange(lineStart..<indentationEnd), indentationEnd == line.contentEnd, comment))
                }
                lineStart = line.end
            } while lineStart < block.end

            let nonBlank = lines.filter { !$0.isBlank }
            if !nonBlank.isEmpty { lines = nonBlank }
            let comments = lines.compactMap(\.comment)
            if comments.count == lines.count {
                edits.append(contentsOf: comments.map { Replacement(range: $0, text: "") })
                continue
            }

            let columns = lines.lazy.map { settings.column(after: text.substring(with: $0.indentation)) }
            guard let minimum = columns.min() else { continue }
            let insertionColumn = minimum - minimum % settings.width
            for line in lines {
                var column = 0
                var offset = line.indentation.location
                while offset < line.indentation.upperBound && column < insertionColumn {
                    let nextColumn = text.character(at: offset) == 0x09 ? settings.nextStop(after: column) : column + 1
                    guard nextColumn <= insertionColumn else { break }
                    column = nextColumn
                    offset += 1
                }
                edits.append(Replacement(range: NSRange(location: offset, length: 0), text: insertion))
            }
        }
        return edits.sorted { $0.range.location < $1.range.location }
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

    // Each local edit reports its selection in the document after only that edit.
    static func typingPlan(_ localEdits: [LineEditing.Edit], deleting: [NSRange] = [])
        -> (edits: [Replacement], selections: [NSRange]) {
        var selections = localEdits.map(\.selection)
        let inputs = localEdits.enumerated().map { (index: Optional($0.offset), range: $0.element.range, text: $0.element.replacement) }
            + deleting.map { (index: nil, range: $0, text: "") }
        var offset = 0
        let edits = inputs.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }.map { input in
            if let index = input.index { selections[index].location += offset }
            let replacement = Replacement(range: input.range, text: input.text)
            offset += replacement.lengthChange
            return replacement
        }
        return (edits, selections)
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
