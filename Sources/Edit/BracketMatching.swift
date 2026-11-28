import Foundation

struct BracketMatching: Sendable {
    struct Pair: Equatable, Sendable {
        let opening: NSRange
        let closing: NSRange
    }

    private enum Kind: Hashable, Sendable {
        case round, square, curly, angle, htmlComment
    }

    private struct Delimiter: Sendable {
        let units: [UInt16]
        let kind: Kind
        let opens: Bool

        init(_ text: String, _ kind: Kind, opens: Bool) {
            units = Array(text.utf16)
            self.kind = kind
            self.opens = opens
        }

        private static let round = pair("(", ")", .round)
        private static let square = pair("[", "]", .square)
        private static let curly = pair("{", "}", .curly)
        private static let angles = pair("<", ">", .angle)
        private static let substitution = Delimiter("${", .curly, opens: true)
        private static let common = group(round + square + curly)
        private static let html = group(round + curly + pair("<!--", "-->", .htmlComment))
        private static let json = group(square + curly)
        private static let script = group(round + square + curly + [substitution])
        private static let typedScript = group(round + square + curly + angles + [substitution])

        static func byFirstUnit(for language: SyntaxLanguage) -> [UInt16: [Self]] {
            switch language {
            case .html: html
            case .json: json
            case .javascript, .javascriptJSX: script
            case .typescript, .tsx: typedScript
            default: common
            }
        }

        private static func pair(_ open: String, _ close: String, _ kind: Kind) -> [Self] {
            [Self(open, kind, opens: true), Self(close, kind, opens: false)]
        }

        private static func group(_ delimiters: [Self]) -> [UInt16: [Self]] {
            Dictionary(grouping: delimiters.sorted { $0.units.count > $1.units.count }, by: { $0.units[0] })
        }
    }

    private struct Token: Sendable {
        let range: NSRange
        var opening: OpeningKind?
        var partner: Int?
        var enclosingOpening: Int?
    }

    private struct OpeningKind: Hashable, Sendable {
        let kind: Kind
        let region: Int
    }

    private struct LanguageRun: Sendable {
        let end: Int
        let region: Int
        let delimiters: [UInt16: [Delimiter]]
    }

    private struct Block: Sendable {
        let range: NSRange
        let tokens: [Token]
        let lastUnmatchedCloser: [OpeningKind: Int]

        func firstTokenStarting(after position: Int) -> Int {
            var lower = 0
            var upper = tokens.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if tokens[middle].range.location <= position { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }

        func touchingPair(at position: Int, before next: Int) -> Pair? {
            guard next > 0 else { return nil }
            let right = next - 1
            let range = tokens[right].range
            if position <= range.upperBound, let pair = pair(for: right) { return pair }
            if position == range.location, right > 0, tokens[right - 1].range.upperBound == position {
                return pair(for: right - 1)
            }
            return nil
        }

        func enclosingPair(before next: Int) -> Pair? {
            guard next > 0, let opening = tokens[next - 1].enclosingOpening else { return nil }
            return pair(for: opening)
        }

        func nextBracket(at position: Int, before next: Int) -> NSRange? {
            if next > 0, position < tokens[next - 1].range.upperBound { return tokens[next - 1].range }
            return next < tokens.count ? tokens[next].range : nil
        }

        private func pair(for index: Int) -> Pair? {
            guard let partner = tokens[index].partner else { return nil }
            return Pair(opening: tokens[min(index, partner)].range, closing: tokens[max(index, partner)].range)
        }
    }

    private let blocks: [Block]
    private let languageRuns: [LanguageRun]
    private let masks: [NSRange]?

    init(
        text: String, language: SyntaxLanguage, ignoredRanges: [NSRange]?, scope: [NSRange]? = nil,
        embeddedLanguages: [(range: NSRange, language: SyntaxLanguage)] = []
    ) {
        let units = Array(text.utf16)
        let masks = ignoredRanges.map { Self.mergeMasks($0, length: units.count) }
        self.masks = masks
        let ranges = scope ?? [NSRange(location: 0, length: units.count)]
        let runs = Self.languageRuns(in: units.count, host: language, embedded: embeddedLanguages)
        languageRuns = runs
        var blocks: [Block] = []
        var maskIndex = 0
        var languageIndex = 0
        for range in ranges where Self.isValid(range, length: units.count) {
            if Task.isCancelled { break }
            blocks.append(Self.scan(units, in: range, masks: masks ?? [], maskIndex: &maskIndex,
                                    runs: runs, languageIndex: &languageIndex))
        }
        self.blocks = blocks
    }

    func hasUnmatchedCloser(for opening: UInt16, at position: Int) -> Bool {
        guard let block = block(at: position), let run = languageRuns.first(where: { $0.end > position }),
              let delimiter = run.delimiters[opening]?.first(where: { $0.opens && $0.units.count == 1 }),
              let last = block.lastUnmatchedCloser[OpeningKind(kind: delimiter.kind, region: run.region)] else { return false }
        return last >= position
    }

    // Locate the opener a newly typed delimiter would close, including an opener
    // whose existing partner is later in the buffer.
    func opening(for closing: UInt16, at position: Int, deadline: ContinuousClock.Instant) -> Int? {
        guard let block = block(at: position), let masks, position > block.range.location,
              let lastRun = languageRuns.last else { return nil }
        // The caller has confirmed whitespace before the caret. Test that character
        // as well at EOF, where the mask of an unfinished literal can end.
        let preceding = position - 1
        var lower = 0
        var upper = masks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if masks[middle].upperBound <= preceding { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower == masks.count || masks[lower].location > preceding else { return nil }

        let probe = min(position, lastRun.end - 1)
        lower = 0
        upper = languageRuns.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if languageRuns[middle].end <= probe { lower = middle + 1 }
            else { upper = middle }
        }
        let run = languageRuns[lower]
        guard let delimiter = run.delimiters[closing]?.first(where: { !$0.opens && $0.units.count == 1 }) else { return nil }
        let kind = OpeningKind(kind: delimiter.kind, region: run.region)
        var index = block.firstTokenStarting(after: preceding) - 1
        while index >= 0, ContinuousClock.now < deadline {
            let token = block.tokens[index]
            if token.opening == kind { return token.range.location }
            // A completed pair also consumed any unfinished inner brackets.
            if let partner = token.partner, partner < index { index = partner }
            index -= 1
        }
        return nil
    }

    func pair(at position: Int) -> Pair? {
        guard let block = block(at: position) else { return nil }
        let next = block.firstTokenStarting(after: position)
        return block.touchingPair(at: position, before: next) ?? block.enclosingPair(before: next)
    }

    func jump(from position: Int) -> Int {
        guard let block = block(at: position) else { return position }
        let next = block.firstTokenStarting(after: position)
        if let pair = block.touchingPair(at: position, before: next) {
            return Self.contains(position, in: pair.closing) ? pair.opening.location : pair.closing.location
        }
        if let pair = block.enclosingPair(before: next) { return pair.closing.location }
        return block.nextBracket(at: position, before: next)?.location ?? position
    }

    func selection(from position: Int) -> (anchor: Int, head: Int)? {
        guard let block = block(at: position) else { return nil }
        let next = block.firstTokenStarting(after: position)
        var pair = block.touchingPair(at: position, before: next) ?? block.enclosingPair(before: next)
        if pair == nil, let following = block.nextBracket(at: position, before: next) {
            let start = following.location
            pair = block.touchingPair(at: start, before: block.firstTokenStarting(after: start))
        }
        guard let pair else { return nil }
        if Self.contains(position, in: pair.closing) { return (pair.closing.upperBound, pair.opening.location) }
        return (pair.opening.location, pair.closing.upperBound)
    }

    private func block(at position: Int) -> Block? {
        var lower = 0
        var upper = blocks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if blocks[middle].range.location <= position { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0, position <= blocks[lower - 1].range.upperBound else { return nil }
        return blocks[lower - 1]
    }

    private static func scan(
        _ units: [UInt16], in range: NSRange, masks: [NSRange], maskIndex: inout Int,
        runs: [LanguageRun], languageIndex: inout Int
    ) -> Block {
        var tokens: [Token] = []
        var lastUnmatchedCloser: [OpeningKind: Int] = [:]
        var openings: [(index: Int, kind: OpeningKind)] = []
        var openingCounts: [OpeningKind: Int] = [:]
        var position = range.location
        var iterations = 0
        while position < range.upperBound {
            if iterations.isMultiple(of: 4_096), Task.isCancelled { break }
            iterations += 1
            while maskIndex < masks.count, masks[maskIndex].upperBound <= position { maskIndex += 1 }
            let nextMask = maskIndex < masks.count ? masks[maskIndex] : nil
            if let nextMask, nextMask.location <= position {
                position = nextMask.upperBound
                continue
            }
            while runs[languageIndex].end <= position { languageIndex += 1 }
            let run = runs[languageIndex]
            let limit = min(range.upperBound, nextMask?.location ?? range.upperBound, run.end)
            guard let delimiter = run.delimiters[units[position]]?.first(where: { delimiter in
                let end = position + delimiter.units.count
                return end <= limit && units[position..<end].elementsEqual(delimiter.units)
            }) else {
                position += 1
                continue
            }

            let marker = NSRange(location: position, length: delimiter.units.count)
            position = marker.upperBound
            let kind = OpeningKind(kind: delimiter.kind, region: run.region)
            if delimiter.opens {
                openings.append((tokens.count, kind))
                openingCounts[kind, default: 0] += 1
                tokens.append(Token(range: marker, opening: kind))
            } else if openingCounts[kind, default: 0] > 0,
                      let matching = openings.lastIndex(where: { $0.kind == kind }) {
                let opening = openings[matching].index
                tokens[opening].partner = tokens.count
                tokens.append(Token(range: marker, partner: opening))
                // Closing an ancestor leaves any unfinished inner openings available to Go to Bracket.
                for item in openings[matching...] { openingCounts[item.kind, default: 0] -= 1 }
                openings.removeLast(openings.count - matching)
            } else {
                lastUnmatchedCloser[kind] = marker.location
            }
        }

        var completeOpenings: [Int] = []
        for index in tokens.indices {
            if index.isMultiple(of: 4_096), Task.isCancelled { break }
            if let partner = tokens[index].partner {
                if partner > index { completeOpenings.append(index) }
                else { completeOpenings.removeLast() }
            }
            tokens[index].enclosingOpening = completeOpenings.last
        }
        return Block(range: range, tokens: tokens, lastUnmatchedCloser: lastUnmatchedCloser)
    }

    private static func languageRuns(
        in length: Int, host: SyntaxLanguage, embedded: [(range: NSRange, language: SyntaxLanguage)]
    ) -> [LanguageRun] {
        let regions = embedded.filter { isValid($0.range, length: length) && $0.range.length > 0 }.sorted {
            $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
        }
        var runs: [LanguageRun] = []
        var active: [Int] = []
        var incoming = 0
        var position = 0
        while position < length {
            while let last = active.last, regions[last].range.upperBound <= position { active.removeLast() }
            while incoming < regions.count, regions[incoming].range.location <= position {
                active.append(incoming)
                incoming += 1
            }
            let region = active.last
            let end = min(region.map { regions[$0].range.upperBound } ?? length,
                          incoming < regions.count ? regions[incoming].range.location : length)
            let language = region.map { regions[$0].language } ?? host
            runs.append(LanguageRun(end: end, region: (region ?? -1) + 1, delimiters: Delimiter.byFirstUnit(for: language)))
            position = end
        }
        return runs
    }

    private static func mergeMasks(_ input: [NSRange], length: Int) -> [NSRange] {
        let sorted = input.filter { isValid($0, length: length) && $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1].length = max(last.upperBound, range.upperBound) - last.location
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
    }

    private static func contains(_ position: Int, in range: NSRange) -> Bool {
        range.location <= position && position <= range.upperBound
    }
}
