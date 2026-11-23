import Foundation

struct FindOptions: Codable, Equatable, Sendable {
    var caseSensitive = true
    var wholeWord = false
    var regularExpression = false
}

struct FindSettings: Equatable, Sendable {
    var showsReplacement = false
    var query = ""
    var replacement = ""
    var options = FindOptions()
}

// Foundation produces immutable regular-expression results. Keeping the result preserves named captures.
struct FindHit: @unchecked Sendable {
    fileprivate let result: NSTextCheckingResult
    let scope: NSRange?

    var range: NSRange { sourceRange(result.range) }

    func replacement(using template: String, in text: NSString, isRegex: Bool) -> String {
        guard isRegex else { return template }

        var rest = template[...]
        var replacement = ""
        while let dollar = rest.firstIndex(of: "$") {
            replacement += rest[..<dollar]
            rest = rest[rest.index(after: dollar)...]
            if rest.first == "$" {
                replacement.append("$")
                rest = rest.dropFirst()
            } else if rest.first == "{", let close = rest.firstIndex(of: "}") {
                replacement += group(String(rest[rest.index(after: rest.startIndex)..<close]), in: text)
                rest = rest[rest.index(after: close)...]
            } else {
                let name = rest.prefix(while: \.isCaptureNameCharacter)
                if name.isEmpty {
                    replacement.append("$")
                } else {
                    replacement += group(String(name), in: text)
                    rest = rest.dropFirst(name.count)
                }
            }
        }
        return replacement + rest
    }

    private func group(_ name: String, in text: NSString) -> String {
        guard !name.isEmpty else { return "" }
        let capture: NSRange
        if let index = Int(name) {
            guard index >= 0 && index < result.numberOfRanges else { return "" }
            capture = result.range(at: index)
        } else {
            capture = result.range(withName: name)
        }
        guard capture.location != NSNotFound else { return "" }
        return text.substring(with: sourceRange(capture))
    }

    private func sourceRange(_ range: NSRange) -> NSRange {
        NSRange(location: range.location + (scope?.location ?? 0), length: range.length)
    }
}

private extension Character {
    var isCaptureNameCharacter: Bool { isASCII && (isLetter || isNumber || self == "_") }
}

enum FindSearch {
    enum Outcome: Sendable {
        case matches([FindHit])
        case invalidExpression
    }

    static func match(_ query: String, in text: String, options: FindOptions, ranges: [NSRange]? = nil) -> Outcome {
        guard !query.isEmpty else { return .matches([]) }
        var pattern = options.regularExpression ? normalizeNamedGroups(query) : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            if options.regularExpression {
                pattern = "\\b(?:\(pattern))\\b"
            } else {
                let word = "[\\p{L}\\p{N}_]"
                if let first = query.unicodeScalars.first, isWord(first) { pattern = "(?<!\(word))" + pattern }
                if let last = query.unicodeScalars.last, isWord(last) { pattern += "(?!\(word))" }
            }
        }
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive]
        ) else { return .invalidExpression }

        var hits: [FindHit] = []
        func collect(in fragment: String, scope: NSRange?) {
            regex.enumerateMatches(in: fragment, options: [.reportProgress],
                                   range: NSRange(fragment.startIndex..., in: fragment)) { match, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                } else if let match {
                    hits.append(FindHit(result: match, scope: scope))
                }
            }
        }
        if let ranges {
            // A real substring gives anchors and boundary tests the same view as an isolated buffer.
            let source = text as NSString
            for range in ranges {
                if Task.isCancelled { break }
                guard range.location >= 0, range.location <= source.length,
                      range.length >= 0, range.length <= source.length - range.location else { continue }
                collect(in: source.substring(with: range), scope: range)
            }
        } else {
            collect(in: text, scope: nil)
        }
        return .matches(hits)
    }

    private static func normalizeNamedGroups(_ query: String) -> String {
        guard query.contains("(?P<") else { return query }
        var pattern = ""
        var remaining = query[...]
        var classDepth = 0
        while let character = remaining.first {
            if classDepth == 0 && remaining.hasPrefix("(?P<") {
                pattern += "(?<"
                remaining = remaining.dropFirst(4)
                continue
            }
            remaining = remaining.dropFirst()
            pattern.append(character)
            switch character {
            case "\\":
                if let escaped = remaining.first {
                    pattern.append(escaped)
                    remaining = remaining.dropFirst()
                }
            case "[":
                classDepth += 1
            case "]":
                classDepth = max(0, classDepth - 1)
            default:
                break
            }
        }
        return pattern
    }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}

extension EditorTextEdit {
    static func moving(_ ranges: Set<NSRange>, through edits: [EditorTextEdit]) -> Set<NSRange> {
        guard !ranges.isEmpty else { return [] }
        var result: Set<NSRange> = []
        var editIndex = 0
        var offset = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            while editIndex < edits.count && NSMaxRange(edits[editIndex].range) <= range.location {
                let edit = edits[editIndex]
                offset += edit.lengthChange
                editIndex += 1
            }
            if editIndex == edits.count || edits[editIndex].range.location >= NSMaxRange(range) {
                result.insert(NSRange(location: range.location + offset, length: range.length))
            }
        }
        return result
    }

    static func moving(_ position: Int, through edits: [EditorTextEdit]) -> Int {
        var offset = 0
        for edit in edits {
            if edit.range.location > position { break }
            if position < NSMaxRange(edit.range) { return edit.range.location + offset }
            offset += edit.lengthChange
        }
        return position + offset
    }

    static func singleChange(from old: NSString, to new: NSString) -> EditorTextEdit {
        let oldLength = old.length
        let newLength = new.length
        let shorter = min(oldLength, newLength)
        var start = 0
        while start < shorter && old.character(at: start) == new.character(at: start) { start += 1 }

        var endOffset = 0
        while endOffset < shorter - start &&
            old.character(at: oldLength - endOffset - 1) == new.character(at: newLength - endOffset - 1) {
            endOffset += 1
        }

        return EditorTextEdit(
            range: NSRange(location: start, length: oldLength - start - endOffset),
            text: new.substring(with: NSRange(location: start, length: newLength - start - endOffset))
        )
    }
}
