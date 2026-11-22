import Foundation

// VS Code chooses the word using the language pattern, then searches with its default word separators.
enum OccurrenceSearch {
    private static let wordSeparators = Set("`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/? \t\r\n".utf16)
    private static let whitespace = #"\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"#
    private static let decimalWord = #"-?[0-9]*\.[0-9][A-Za-z_0-9]*"#
    private static let defaultWordPattern = wordPattern()
    private static let cWordPattern = wordPattern(allowing: "$")
    private static let scriptWordPattern = wordPattern(allowing: "#$")
    private static let htmlWordPattern = wordPattern(allowing: "#-?")
    private static let cssWordPattern = try? NSRegularExpression(
        pattern: #"(#?"# + decimalWord + #"%?)|(::?[A-Za-z_0-9-]*(?=[^,{;]*[,{]))|(([@#.!])?[A-Za-z_0-9?-]+%?|[@#!.])"#
    )
    private static let markdownWordPattern = try? NSRegularExpression(
        pattern: #"[\p{Alphabetic}\p{Number}\p{Nonspacing_Mark}](?:[\p{Alphabetic}\p{Number}\p{Nonspacing_Mark}_]?[\p{Alphabetic}\p{Number}\p{Nonspacing_Mark}])*"#
    )

    private static func wordPattern(allowing extra: String = "") -> NSRegularExpression? {
        let punctuation = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?".filter { !extra.contains($0) }
        let excluded = punctuation.map { "\\" + String($0) }.joined()
        return try? NSRegularExpression(pattern: "\(decimalWord)|[^\(excluded)\(whitespace)]+")
    }

    struct Query: Equatable, Sendable {
        let text: String
        let caseSensitive: Bool
        let wholeWord: Bool

        func hasSameText(as candidate: String) -> Bool {
            if caseSensitive { return text.utf16.elementsEqual(candidate.utf16) }
            return text.lowercased().utf16.elementsEqual(candidate.lowercased().utf16)
        }
    }

    struct Input: Sendable {
        let text: String
        let scopes: [NSRange]?
        let selections: [[NSRange]]
        let activeEnd: Int?

        func wordMatches(language: SyntaxLanguage) -> [NSRange] {
            guard let group = selections.last, group.count == 1, let selection = group.first else { return [] }
            let source = text as NSString
            guard selection.location <= source.length, selection.upperBound <= source.length,
                  let scope = searchScopes(in: source).first(where: {
                      $0.location <= selection.location && selection.upperBound <= $0.upperBound
                  }), let startWord = word(at: selection.location, source: source, scope: scope, language: language),
                  selection.upperBound <= startWord.upperBound else { return [] }
            let position = activeEnd ?? selection.location
            guard let activeWord = position == selection.location ? startWord :
                word(at: position, source: source, scope: scope, language: language) else { return [] }
            let query = Query(text: source.substring(with: activeWord), caseSensitive: true, wholeWord: true)
            return matches(query, in: source)
        }

        func selectionMatches(find: FindSettings, session: Query?) -> [NSRange] {
            let source = text as NSString
            guard let group = selections.last, let primary = singleLineSelection(group, in: source) else { return [] }
            let query = session ?? Query(text: source.substring(with: primary),
                                        caseSensitive: find.options.caseSensitive, wholeWord: find.options.wholeWord)
            guard !query.text.isEmpty, query.text.utf16.count <= 200,
                  !query.text.utf16.allSatisfy({ $0 == 32 || $0 == 9 }),
                  !query.text.utf16.contains(10), !query.text.utf16.contains(13) else { return [] }
            if session == nil {
                for group in selections.dropLast() {
                    guard let range = singleLineSelection(group, in: source),
                          query.hasSameText(as: source.substring(with: range)) else { return [] }
                }
            }
            if find.visible && !find.options.regularExpression && query.caseSensitive == find.options.caseSensitive
                && query.wholeWord == find.options.wholeWord && query.hasSameText(as: find.query) {
                return []
            }
            guard !sourceIsTooLarge(source) else { return [] }
            let selectedRanges: [NSRange] = selections.flatMap { $0 }
            let ranges = selectedRanges.sorted { first, second in
                if first.location == second.location { return first.length < second.length }
                return first.location < second.location
            }
            return excludingSelections(ranges, from: matches(query, in: source))
        }

        private func singleLineSelection(_ group: [NSRange], in source: NSString) -> NSRange? {
            guard group.count == 1, let range = group.first, range.length > 0,
                  range.location < source.length, range.upperBound <= source.length,
                  range.upperBound <= LineEditing.line(at: range.location, in: source).contentEnd else { return nil }
            return range
        }

        private func sourceIsTooLarge(_ source: NSString) -> Bool {
            if source.length > 20 * 1024 * 1024 { return true }
            if source.length < 300_000 { return false }
            var lines = 1
            var offset = 0
            while offset < source.length && !Task.isCancelled {
                let line = LineEditing.line(at: offset, in: source)
                if line.separatorRange.length == 0 { break }
                lines += 1
                if lines > 300_000 { return true }
                offset = line.end
            }
            return false
        }

        private func searchScopes(in source: NSString) -> [NSRange] {
            scopes ?? [NSRange(location: 0, length: source.length)]
        }

        private func matches(_ query: Query, in source: NSString) -> [NSRange] {
            let length = query.text.utf16.count
            let options: NSString.CompareOptions = query.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            var results: [NSRange] = []
            // Each Focus block contributes whole logical lines, separated by a line break.
            // These queries are single-line, so scanning blocks independently preserves their source offsets.
            for scope in searchScopes(in: source) {
                var offset = scope.location
                while offset < scope.upperBound && results.count < 999 && !Task.isCancelled {
                    let end = min(scope.upperBound, offset + max(4096, length + 1))
                    let match = source.range(of: query.text, options: options,
                                             range: NSRange(location: offset, length: end - offset))
                    if match.location == NSNotFound {
                        // Retain enough of this window to find a match straddling the next window.
                        if end == scope.upperBound { break }
                        offset = end - length + 1
                    } else if match.length != length {
                        // Foundation case folding accepts expansions such as ß and SS. VS Code does not.
                        offset = match.location + 1
                    } else {
                        if !query.wholeWord || isWholeWord(match, in: source, scope: scope) {
                            results.append(match)
                        }
                        offset = match.upperBound
                    }
                }
                if results.count == 999 || Task.isCancelled { break }
            }
            return results
        }
    }

    private static func word(at position: Int, source: NSString, scope: NSRange, language: SyntaxLanguage) -> NSRange? {
        guard !Task.isCancelled, position >= scope.location, position <= scope.upperBound else { return nil }
        let line = LineEditing.line(at: position, in: source)
        var start = max(line.start, scope.location)
        var end = min(line.contentEnd, scope.upperBound)
        guard position <= end else { return nil }
        if end - start > 1000 {
            start = max(start, position - 500)
            end = min(end, position + 500)
        }
        guard start < end else { return nil }
        let range = NSRange(location: start, length: end - start)
        let text = source.substring(with: range)
        let pattern = switch language {
        case .c, .cpp: cWordPattern
        case .javascript, .javascriptJSX, .typescript, .tsx: scriptWordPattern
        case .css: cssWordPattern
        case .html: htmlWordPattern
        case .markdown: markdownWordPattern
        default: defaultWordPattern
        }
        var result: NSRange?
        pattern?.enumerateMatches(in: text, range: NSRange(location: 0, length: range.length)) { match, _, stop in
            guard let match else { return }
            let word = NSRange(location: match.range.location + start, length: match.range.length)
            if word.location <= position && position <= word.upperBound { result = word }
            if result != nil || word.location > position { stop.pointee = true }
        }
        return result
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString, scope: NSRange) -> Bool {
        let left = range.location == scope.location || wordSeparators.contains(text.character(at: range.location - 1))
            || wordSeparators.contains(text.character(at: range.location))
        let right = range.upperBound == scope.upperBound || wordSeparators.contains(text.character(at: range.upperBound))
            || wordSeparators.contains(text.character(at: range.upperBound - 1))
        return left && right
    }

    private static func excludingSelections(_ selections: [NSRange], from matches: [NSRange]) -> [NSRange] {
        var index = 0
        return matches.filter { match in
            while index < selections.count {
                let selection = selections[index]
                if match == selection {
                    index += 1
                    return false
                }
                if match.location < selection.location
                    || (match.location == selection.location && match.length < selection.length) {
                    // Match VS Code's forward pass, including its treatment of right-hand overlaps.
                    return selection.length == 0 || NSIntersectionRange(match, selection).length == 0
                }
                index += 1
            }
            return true
        }
    }
}
