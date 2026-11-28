import Foundation

enum TypingDelimiters {
    static let brackets: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
    static let closingBrackets = Set(brackets.values)
    private static let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let pairBoundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ")]},;:."))
    private static let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_"))

    static func contains(_ key: String) -> Bool {
        pairs[key] != nil || pairs.values.contains(key)
    }

    struct Pair {
        let opening: Int
        let closing: Int

        func remapped(after changes: [EditorTextChange]) -> Pair? {
            func move(_ character: Int) -> Int? {
                var offset = 0
                for change in changes {
                    if change.range.upperBound <= character { offset += change.delta }
                    else if change.range.location <= character { return nil }
                    else { break }
                }
                return character + offset
            }
            guard let opening = move(opening), let closing = move(closing) else { return nil }
            return Pair(opening: opening, closing: closing)
        }
    }

    static func edit(for key: String, in text: NSString, selection: NSRange, canSkip: Bool, language: SyntaxLanguage)
        -> (edit: LineEditing.Edit, tracksPair: Bool)? {
        guard selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        let offset = selection.location
        if selection.length > 0 {
            let contents = text.substring(with: selection)
            guard let closer = pairs[key], contents.utf16.contains(where: { ![9, 10, 13, 32].contains($0) }) else { return nil }
            return (LineEditing.Edit(range: selection, replacement: key + contents + closer,
                                     selection: NSRange(location: offset + 1, length: selection.length)), false)
        }

        let closer = pairs[key]
        let isQuote = key == closer
        if isQuote {
            var before = offset
            while before > 0, text.character(at: before - 1) == 0x5C { before -= 1 }
            if (offset - before) % 2 == 1 { return nil }
        }
        if canSkip, offset < text.length, text.character(at: offset) == key.utf16.first {
            return (LineEditing.Edit(range: selection, replacement: "", selection: NSRange(location: offset + 1, length: 0)), false)
        }
        guard let closer else { return nil }
        if key == "`" {
            switch language {
            case .swift, .javascript, .javascriptJSX, .typescript, .tsx: break
            default: return nil
            }
        }
        if offset < text.length {
            let next = text.substring(with: text.rangeOfComposedCharacterSequence(at: offset))
            guard next.rangeOfCharacter(from: pairBoundaries) != nil else { return nil }
        }
        if isQuote, key != "`", offset > 0 {
            let previous = text.substring(with: text.rangeOfComposedCharacterSequence(at: offset - 1))
            guard previous.rangeOfCharacter(from: wordCharacters) == nil else { return nil }
        }
        return (LineEditing.Edit(range: selection, replacement: key + closer,
                                 selection: NSRange(location: offset + 1, length: 0)), true)
    }
}
