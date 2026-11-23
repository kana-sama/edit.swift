import Foundation

/// UTF-16 positions in the live buffer and in the read-only text interleaved with it.
struct JJInlineDiffSelection {
    enum Position: Equatable {
        case live(Int)
        case removed(key: NSRange, offset: Int)
    }

    private struct Block {
        let key: NSRange
        let liveOffset: Int
        let text: NSString
        let rows: EditorTextRows
        let displayRange: NSRange
    }

    private let source: NSString
    private let blocks: [Block]
    let length: Int

    init(source: String, hunks: [JJDiffHunk], lineEnding: String = "\n") {
        let source = source as NSString
        self.source = source
        var inserted = 0
        var addedAtEnd = false
        let sorted = hunks.filter { !$0.removedText.isEmpty }.sorted {
            if $0.currentRange.location == $1.currentRange.location {
                return $0.baseRange.location < $1.baseRange.location
            }
            return $0.currentRange.location < $1.currentRange.location
        }
        blocks = sorted.enumerated().compactMap { index, hunk in
            let boundary = min(hunk.currentRange.location, source.length)
            guard !hunk.removedText.isEmpty, boundary >= 0 else { return nil }
            // Pending hunks can briefly have old offsets. The view still inserts removed rows between lines.
            let offset = boundary == source.length ? boundary
                : source.lineRange(for: NSRange(location: boundary, length: 0)).location
            let leading = boundary == source.length && source.length > 0 && !addedAtEnd &&
                (source as String).last?.isNewline == false ? lineEnding : ""
            if boundary == source.length { addedAtEnd = true }
            let trailing = (offset < source.length || index + 1 < sorted.count) &&
                hunk.removedText.last?.isNewline == false ? lineEnding : ""
            let text = (leading + hunk.removedText + trailing) as NSString
            let range = NSRange(location: offset + inserted, length: text.length)
            let removed = hunk.removedText as NSString
            let rows = EditorTextRows(in: removed, range: NSRange(location: 0, length: removed.length))
                .shifted(by: range.location + leading.utf16.count)
            inserted += range.length
            return Block(key: hunk.baseRange, liveOffset: offset, text: text, rows: rows, displayRange: range)
        }
        length = source.length + inserted
    }

    var string: String { text(in: NSRange(location: 0, length: length)) ?? "" }

    func removedRows(for key: NSRange) -> EditorTextRows? {
        blocks.first { $0.key == key }?.rows
    }

    func displayRange(forRemoved key: NSRange) -> NSRange? {
        removedRows(for: key)?.range
    }

    func displayOffset(for position: Position) -> Int? {
        switch position {
        case .live(let offset):
            guard (0...source.length).contains(offset) else { return nil }
            // The live caret at an insertion boundary sits after the removed rows.
            return offset + blocks.prefix { $0.liveOffset <= offset }.reduce(0) { $0 + $1.displayRange.length }
        case .removed(let key, let offset):
            guard let range = displayRange(forRemoved: key), (0...range.length).contains(offset) else { return nil }
            return range.location + offset
        }
    }

    func position(at offset: Int, preferPrevious: Bool = false) -> Position? {
        guard (0...length).contains(offset) else { return nil }
        var inserted = 0
        for block in blocks {
            let range = block.displayRange
            if offset < range.location { break }
            let end = NSMaxRange(range)
            if offset < end || (offset == end && preferPrevious) {
                return .removed(key: block.key, offset: max(0, min(block.rows.range.length, offset - block.rows.range.location)))
            }
            inserted += range.length
        }
        return .live(offset - inserted)
    }

    func liveRange(for displayRange: NSRange) -> NSRange? {
        guard contains(displayRange) else { return nil }
        let start = liveOffset(at: displayRange.location)
        return NSRange(location: start, length: liveOffset(at: NSMaxRange(displayRange)) - start)
    }

    func text(in range: NSRange) -> String? {
        guard contains(range) else { return nil }
        var result = ""
        var previousLiveOffset = 0
        var previousDisplayOffset = 0
        func append(_ text: NSString, from offset: Int, in span: NSRange) {
            let selection = NSIntersectionRange(range, span)
            guard selection.length > 0 else { return }
            result += text.substring(with: NSRange(location: offset + selection.location - span.location,
                                                    length: selection.length))
        }
        for block in blocks {
            append(source, from: previousLiveOffset, in: NSRange(location: previousDisplayOffset,
                                                                  length: block.liveOffset - previousLiveOffset))
            append(block.text, from: 0, in: block.displayRange)
            previousLiveOffset = block.liveOffset
            previousDisplayOffset = NSMaxRange(block.displayRange)
        }
        append(source, from: previousLiveOffset, in: NSRange(location: previousDisplayOffset,
                                                              length: source.length - previousLiveOffset))
        return result
    }

    private func contains(_ range: NSRange) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
    }

    private func liveOffset(at displayOffset: Int) -> Int {
        // Every endpoint inside a removed block maps to the same live insertion boundary.
        let inserted = blocks.prefix { $0.displayRange.location < displayOffset }.reduce(0) { count, block in
            count + min(block.displayRange.length, displayOffset - block.displayRange.location)
        }
        return displayOffset - inserted
    }
}
