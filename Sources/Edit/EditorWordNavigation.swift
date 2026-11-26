import AppKit

// Default macOS VS Code word commands (no custom separators or segmenter locales).
enum EditorWordBoundary {
    private enum Kind { case word, separator, space }
    private static let separators = Set(#"`~!@#$%^&*()-=+[{]}\|;:'",.<>/?"#.utf16)
    private static let lineBreaks = CharacterSet(charactersIn: "\r\n")

    private static func kind(at offset: Int, in text: NSString) -> Kind {
        let unit = text.character(at: offset)
        if unit == 0x20 || unit == 0x09 { return .space }
        return separators.contains(unit) ? .separator : .word
    }

    // VS Code's model uses CR, LF, and CRLF, not Foundation's additional Unicode line breaks.
    private static func line(at offset: Int, in text: NSString) -> Range<Int> {
        let before = text.rangeOfCharacter(from: lineBreaks, options: .backwards,
                                           range: NSRange(location: 0, length: offset))
        let after = text.rangeOfCharacter(from: lineBreaks,
                                          range: NSRange(location: offset, length: text.length - offset))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let end = after.location == NSNotFound ? text.length : after.location
        return start..<end
    }

    private static func previousLineEnd(before start: Int, in text: NSString) -> Int {
        if start >= 2, text.character(at: start - 1) == 0x0A, text.character(at: start - 2) == 0x0D {
            return start - 2
        }
        return start - 1
    }

    private static func nextLineStart(after end: Int, in text: NSString) -> Int {
        if end + 1 < text.length, text.character(at: end) == 0x0D, text.character(at: end + 1) == 0x0A {
            return end + 2
        }
        return end + 1
    }

    private static func skip(_ target: Kind, from position: Int, toward limit: Int, in text: NSString) -> Int {
        let backward = limit < position
        var index = position
        while index != limit, kind(at: backward ? index - 1 : index, in: text) == target {
            index += backward ? -1 : 1
        }
        return index
    }

    static func move(from offset: Int, backward: Bool, multipleCarets: Bool, in text: NSString) -> Int {
        var position = offset
        var bounds = line(at: offset, in: text)
        if backward, position == bounds.lowerBound, position > 0 {
            position = previousLineEnd(before: position, in: text)
            bounds = line(at: position, in: text)
        } else if !backward, position == bounds.upperBound, position < text.length {
            position = nextLineStart(after: position, in: text)
            bounds = line(at: position, in: text)
        }

        let limit = backward ? bounds.lowerBound : bounds.upperBound
        let start = skip(.space, from: position, toward: limit, in: text)
        guard start != limit else { return limit }
        let type = kind(at: backward ? start - 1 : start, in: text)
        let end = skip(type, from: start, toward: limit, in: text)

        // A lone separator next to a word can share that word's stop. Check the
        // whole run when starting inside punctuation; only left with multiple
        // carets disables this shortcut.
        if type == .separator, end != limit, abs(end - start) == 1, (!backward || !multipleCarets),
           kind(at: backward ? end - 1 : end, in: text) == .word,
           skip(.separator, from: start, toward: backward ? bounds.upperBound : bounds.lowerBound, in: text) == start {
            return skip(.word, from: end, toward: limit, in: text)
        }
        return end
    }

    static func deletion(from offset: Int, backward: Bool, in text: NSString) -> NSRange {
        let bounds = line(at: offset, in: text)
        let limit = backward ? bounds.lowerBound : bounds.upperBound
        let nonSpace = skip(.space, from: offset, toward: limit, in: text)
        let target: Int
        if offset == limit {
            // Left joins lines; right also removes indentation on the next line.
            if backward, offset > 0 {
                target = previousLineEnd(before: offset, in: text)
            } else if !backward, offset < text.length {
                let next = nextLineStart(after: offset, in: text)
                target = skip(.space, from: next, toward: line(at: next, in: text).upperBound, in: text)
            } else {
                target = offset
            }
        } else if nonSpace == limit || (backward ? offset - nonSpace >= 2 : nonSpace > offset) {
            target = nonSpace
        } else {
            let type = kind(at: backward ? nonSpace - 1 : nonSpace, in: text)
            target = skip(type, from: nonSpace, toward: limit, in: text)
        }
        return NSRange(location: min(offset, target), length: abs(target - offset))
    }
}

final class EditorWordNavigation: NSTextSelectionNavigation {
    override func destinationSelection(
        for selection: NSTextSelection, direction: Direction, destination: Destination, extending: Bool, confined: Bool
    ) -> NSTextSelection? {
        if destination == .word, !confined,
           let target = moveWord(from: selection, direction: direction, extending: extending, multipleCarets: false) {
            return target
        }
        return super.destinationSelection(for: selection, direction: direction, destination: destination,
                                          extending: extending, confined: confined)
    }

    func moveWord(from selection: NSTextSelection, direction: Direction, extending: Bool,
                  multipleCarets: Bool) -> NSTextSelection? {
        guard let layout = textSelectionDataSource as? NSTextLayoutManager,
              let text = (layout.textContentManager as? NSTextContentStorage)?.textStorage?.mutableString,
              selection.textRanges.count == 1, let original = selection.textRanges.first else { return nil }
        let start = layout.documentRange.location
        let upstream = selection.affinity == .upstream
        let head = upstream ? original.location : original.endLocation
        let offset = layout.offset(from: start, to: head)
        guard 0...text.length ~= offset else { return nil }
        let destination = EditorWordBoundary.move(from: offset, backward: direction == .left || direction == .backward,
                                                  multipleCarets: multipleCarets, in: text)
        guard let target = layout.location(start, offsetBy: destination) else { return nil }
        if !extending { return NSTextSelection(target, affinity: .downstream) }

        let anchor = upstream ? original.endLocation : original.location
        let reversed = target.compare(anchor) == .orderedAscending
        guard let range = NSTextRange(location: reversed ? target : anchor, end: reversed ? anchor : target) else { return nil }
        return NSTextSelection(range: range, affinity: reversed ? .upstream : .downstream, granularity: .character)
    }
}
