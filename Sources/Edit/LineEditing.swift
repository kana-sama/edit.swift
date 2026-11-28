import Foundation

enum LineEditing {
    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int

        var range: NSRange {
            NSRange(location: start, length: end - start)
        }

        var contentRange: NSRange {
            NSRange(location: start, length: contentEnd - start)
        }

        var separatorRange: NSRange {
            NSRange(location: contentEnd, length: end - contentEnd)
        }

        func offset(of index: Int, withSeparatorLength separatorLength: Int) -> Int {
            guard index > contentEnd else { return index - start }
            let separatorOffset = index == end ? separatorLength : min(index - contentEnd, separatorLength)
            return contentEnd - start + separatorOffset
        }
    }

    struct LineAnchor {
        let offset: Int
        let number: Int
    }

    static func indent(_ text: NSString, selection: NSRange, outdent: Bool, settings: Indentation) -> Edit? {
        guard let block = affectedLines(in: text, selection: selection) else { return nil }

        var replacement = ""
        var selectionStart = selection.location
        var selectionEnd = NSMaxRange(selection)
        var lineStart = block.start
        var changed = false
        let unit = outdent ? "" : settings.whitespace(to: settings.width)
        let added = unit.utf16.count
        repeat {
            let line = line(at: lineStart, in: text)
            let removed = outdent ? outdentLength(in: line, text: text, width: settings.width) : 0
            replacement += unit
            replacement += text.substring(with: NSRange(location: line.start + removed, length: line.range.length - removed))

            if selection.location >= line.start {
                selectionStart += added - min(removed, selection.location - line.start)
            }
            if NSMaxRange(selection) >= line.start {
                selectionEnd += added - min(removed, NSMaxRange(selection) - line.start)
            }

            changed = changed || removed > 0 || added > 0
            lineStart = line.end
        } while lineStart < block.end

        guard changed else { return nil }
        return Edit(
            range: block.range,
            replacement: replacement,
            selection: NSRange(location: selectionStart, length: selectionEnd - selectionStart)
        )
    }

    static func insertLine(_ text: NSString, selection: NSRange, above: Bool) -> Edit? {
        guard selection.location >= 0, selection.location <= text.length else { return nil }

        let current = line(at: selection.location, in: text)
        let indent = NSRange(location: current.start, length: indentationEnd(in: current, text: text) - current.start)
        let indentation = text.substring(with: indent)
        let separator: String
        if current.separatorRange.length > 0 {
            separator = text.substring(with: current.separatorRange)
        } else if current.start > 0 {
            let previous = line(at: current.start - 1, in: text)
            separator = text.substring(with: previous.separatorRange)
        } else {
            separator = "\n"
        }

        let location = above ? current.start : current.end
        let needsLeadingSeparator = !above && current.separatorRange.length == 0
        let replacement = needsLeadingSeparator ? separator + indentation : indentation + separator
        let caret = location + (needsLeadingSeparator ? replacement.utf16.count : indent.length)
        return Edit(
            range: NSRange(location: location, length: 0),
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }

    struct Movement {
        let range: NSRange
        let replacement: String
        let block: Line
        let start: Int
        let followingSeparatorLength: Int

        func selection(_ range: NSRange) -> NSRange {
            let startOffset = block.offset(of: range.location, withSeparatorLength: followingSeparatorLength)
            let endOffset = block.offset(of: NSMaxRange(range), withSeparatorLength: followingSeparatorLength)
            return NSRange(location: start + startOffset, length: endOffset - startOffset)
        }
    }

    static func moveLines(_ text: NSString, selection: NSRange, up: Bool) -> Edit? {
        guard let block = affectedLines(in: text, selection: selection),
              let movement = move(text, block: block, up: up) else { return nil }
        return Edit(range: movement.range, replacement: movement.replacement, selection: movement.selection(selection))
    }

    static func move(_ text: NSString, block: Line, up: Bool) -> Movement? {
        let first: Line
        let second: Line
        if up {
            guard block.start > 0 else { return nil }
            first = line(at: block.start - 1, in: text)
            second = block
        } else {
            guard block.end > block.contentEnd else { return nil }
            first = block
            second = line(at: block.end, in: text)
        }

        // Swap the contents around their shared separator. The final separator
        // stays in place, including when the original last line had none.
        let separator = text.substring(with: first.separatorRange)
        let replacement = text.substring(with: second.contentRange) + separator + text.substring(with: first.contentRange)
        let movedStart = up ? first.start : first.start + second.contentRange.length + first.separatorRange.length
        let followingSeparatorLength = up ? first.separatorRange.length : second.separatorRange.length
        return Movement(
            range: NSRange(location: first.start, length: second.contentEnd - first.start),
            replacement: replacement,
            block: block,
            start: movedStart,
            followingSeparatorLength: followingSeparatorLength
        )
    }

    static func affectedLines(in text: NSString, selection: NSRange) -> Line? {
        guard selection.location >= 0, selection.location <= text.length,
              selection.length >= 0, selection.length <= text.length - selection.location else { return nil }

        let first = line(at: selection.location, in: text)
        guard selection.length > 0 else { return first }
        // A selection ending at the start of a line does not cover that line.
        let last = line(at: NSMaxRange(selection) - 1, in: text)
        return Line(start: first.start, contentEnd: last.contentEnd, end: last.end)
    }

    static func line(at index: Int, in text: NSString) -> Line {
        var start = 0
        var end = 0
        var contentEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: index, length: 0))
        return Line(start: start, contentEnd: contentEnd, end: end)
    }

    static func lineNumber(at lineStart: Int, from anchor: LineAnchor?, in text: NSString) -> Int {
        let reference = anchor.flatMap {
            $0.offset <= text.length && abs($0.offset - lineStart) <= lineStart ? $0 : nil
        }
        var cursor = reference?.offset ?? 0
        var number = reference?.number ?? 0
        while cursor < lineStart {
            let next = line(at: cursor, in: text).end
            guard next > cursor else { break }
            cursor = next
            number += 1
        }
        while cursor > lineStart {
            let previous = line(at: cursor - 1, in: text).start
            guard previous < cursor else { break }
            cursor = previous
            number -= 1
        }
        return number
    }

    static func indentationEnd(in line: Line, text: NSString) -> Int {
        var index = line.start
        while index < line.contentEnd {
            let character = text.character(at: index)
            guard character == 0x20 || character == 0x09 else { break }
            index += 1
        }
        return index
    }

    static func tab(in text: NSString, at location: Int, settings: Indentation, language: SyntaxLanguage,
                    contextual: Bool = true) -> EditorTextEdit {
        let current = line(at: location, in: text)
        if contextual, indentationEnd(in: current, text: text) == current.contentEnd, current.start > 0 {
            var previous = line(at: current.start - 1, in: text)
            let lookback = max(0, current.start - 64 * 1_024)
            while previous.start > lookback, indentationEnd(in: previous, text: text) == previous.contentEnd {
                previous = line(at: previous.start - 1, in: text)
            }
            let end = indentationEnd(in: previous, text: text)
            if end < previous.contentEnd {
                let prefix = text.substring(with: NSRange(previous.start..<end))
                let column = settings.column(after: prefix)
                let extra = opensIndent(in: text, from: end, to: previous.contentEnd, language: language)
                let desired = settings.whitespace(to: extra ? settings.nextStop(after: column) : column)
                if !text.substring(with: current.contentRange).hasPrefix(desired) {
                    return EditorTextEdit(range: current.contentRange, text: desired)
                }
            }
        }
        let prefix = text.substring(with: NSRange(current.start..<location))
        let column = settings.column(after: prefix)
        let indentation = settings.style == .tabs ? "\t" : settings.whitespace(to: settings.nextStop(after: column) - column)
        return EditorTextEdit(range: NSRange(location: location, length: 0), text: indentation)
    }

    static func newline(_ text: NSString, selection: NSRange, separator: String,
                        settings: Indentation, language: SyntaxLanguage) -> Edit {
        let current = line(at: selection.location, in: text)
        let indentEnd = min(selection.location, indentationEnd(in: current, text: text))
        let indent = text.substring(with: NSRange(location: current.start, length: indentEnd - current.start))
        let end = trailingContentEnd(in: text, from: indentEnd, to: selection.location)
        let closer = end > indentEnd ? TypingDelimiters.brackets[text.character(at: end - 1)] : nil
        let deepens = closer != nil || isPythonHeader(in: text, from: indentEnd, to: end, language: language)
        let column = settings.column(after: indent)
        let insertion = separator + (deepens ? settings.whitespace(to: settings.nextStop(after: column)) : indent)
        var suffix = ""
        if let closer, selection.length == 0 {
            var next = selection.location
            while next < current.contentEnd, isIndentation(text.character(at: next)) { next += 1 }
            if next < current.contentEnd, text.character(at: next) == closer {
                suffix = separator + indent
            }
        }
        return Edit(range: selection, replacement: insertion + suffix,
                    selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
    }

    static func deleteIndentation(in text: NSString, before location: Int, settings: Indentation) -> NSRange? {
        let current = line(at: location, in: text)
        guard location > current.start, location <= indentationEnd(in: current, text: text) else { return nil }
        let prefix = text.substring(with: NSRange(current.start..<location))
        let target = settings.previousStop(before: settings.column(after: prefix))
        var column = 0
        var offset = current.start
        while column < target, offset < location {
            column = text.character(at: offset) == 0x09 ? settings.nextStop(after: column) : column + 1
            offset += 1
        }
        return NSRange(offset..<location)
    }

    private static func opensIndent(in text: NSString, from start: Int, to limit: Int, language: SyntaxLanguage) -> Bool {
        let end = trailingContentEnd(in: text, from: start, to: limit)
        guard end > start else { return false }
        return TypingDelimiters.brackets[text.character(at: end - 1)] != nil ||
            isPythonHeader(in: text, from: start, to: end, language: language)
    }

    private static func isPythonHeader(in text: NSString, from start: Int, to end: Int, language: SyntaxLanguage) -> Bool {
        guard language == .python, end > start, text.character(at: end - 1) == 0x3A else { return false }
        let header = /(?:async\s+)?(?:def|class|for|if|elif|else|while|try|with|finally|except)\b.*?:/
        return text.substring(with: NSRange(start..<end)).wholeMatch(of: header) != nil
    }

    private static func trailingContentEnd(in text: NSString, from start: Int, to end: Int) -> Int {
        var offset = end
        while offset > start, isIndentation(text.character(at: offset - 1)) { offset -= 1 }
        return offset
    }

    private static func isIndentation(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    static func outdentLength(in line: Line, text: NSString, width: Int) -> Int {
        guard line.start < line.contentEnd else { return 0 }
        if text.character(at: line.start) == 0x09 { return 1 }

        var removed = 0
        while removed < width, line.start + removed < line.contentEnd, text.character(at: line.start + removed) == 0x20 {
            removed += 1
        }
        return removed
    }
}
