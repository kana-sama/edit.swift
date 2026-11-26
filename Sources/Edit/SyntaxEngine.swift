import Darwin
import EditSyntaxABI
import Foundation

enum SyntaxColor: Sendable, Hashable, CaseIterable {
    case plain, keyword, control, type, function, string, number, comment, property, markup, attribute

    fileprivate var priority: Int {
        switch self {
        case .plain: 0
        case .property, .attribute, .function, .control: 3
        case .comment, .markup, .type: 2
        case .keyword, .string, .number: 1
        }
    }

    init?(capture: String) {
        switch capture {
        case "string.special.key":
            self = .property
        case let name where name.hasPrefix("keyword.control"), let name where name.hasPrefix("keyword.directive"):
            self = .control
        default:
            switch capture.split(separator: ".").first {
            case "keyword", "constant", "boolean", "operator":
                self = .keyword
            case "include", "conditional", "repeat", "exception", "preproc", "directive":
                self = .control
            case "type", "namespace", "module", "constructor":
                self = .type
            case "function", "method":
                self = .function
            case "string", "character", "escape":
                self = .string
            case "number", "float":
                self = .number
            case "comment":
                self = .comment
            case "property", "field", "symbol":
                self = .property
            case "tag":
                self = capture.hasPrefix("tag.attribute") ? .attribute : .markup
            case "heading", "title", "emphasis", "strong", "text", "markup":
                self = .markup
            case "attribute":
                self = .attribute
            default:
                return nil
            }
        }
    }
}

struct SyntaxSpan: Sendable {
    let start: Int
    let end: Int
    let color: SyntaxColor
    var provisional = false

    var range: NSRange { NSRange(location: start, length: end - start) }
}

struct SyntaxSnapshot: Sendable {
    let language: SyntaxLanguage
    let analysis: SyntaxAnalysis
    let coversDocument: Bool
    var tree: SyntaxEngine.Tree? = nil
}

struct SyntaxAnalysis: Sendable {
    let spans: [SyntaxSpan]
    let brackets: BracketSyntax.Context

    static let empty = Self(spans: [], brackets: .empty)
}

enum SyntaxEngine {
    private final class Captures {
        var values: [SyntaxSpan] = []
        var excluded: [NSRange] = []
        var languages: [BracketSyntax.EmbeddedLanguage] = []
        private var colors: [UnsafePointer<CChar>: SyntaxColor?] = [:]
        private let length: Int
        private let onPreview: (@Sendable ([SyntaxSpan]) -> Void)?
        private let deadline: ContinuousClock.Instant?

        init(length: Int, onPreview: (@Sendable ([SyntaxSpan]) -> Void)? = nil,
             deadline: ContinuousClock.Instant? = nil) {
            self.length = length
            self.onPreview = onPreview
            self.deadline = deadline
        }

        var cancelled: Bool { Task.isCancelled || deadline.map { ContinuousClock.now >= $0 } == true }

        func publishPreview() {
            guard let onPreview else { return }
            let spans = resolveOverlaps(values, length: length)
            values.removeAll(keepingCapacity: true)
            if !Task.isCancelled { onPreview(spans) }
        }

        func append(start: UInt32, end: UInt32, name: UnsafePointer<CChar>) {
            let color: SyntaxColor?
            if let cached = colors[name] {
                color = cached
            } else {
                color = SyntaxColor(capture: String(cString: name))
                colors.updateValue(color, forKey: name)
            }
            if let color {
                values.append(SyntaxSpan(start: Int(start), end: Int(end), color: color))
            }
        }

        func appendBracket(start: UInt32, end: UInt32, name: UnsafePointer<CChar>?) {
            guard start < end else { return }
            let range = NSRange(location: Int(start), length: Int(end - start))
            if let name {
                if let language = SyntaxLanguage(rawValue: String(cString: name)) {
                    languages.append(.init(range: range, language: language))
                }
            } else {
                excluded.append(range)
            }
        }

        func bracketContext() -> BracketSyntax.Context {
            var merged: [NSRange] = []
            for range in excluded.sorted(by: { $0.location < $1.location }) {
                if let previous = merged.last, range.location <= previous.upperBound {
                    merged[merged.count - 1] = NSUnionRange(previous, range)
                } else {
                    merged.append(range)
                }
            }
            return .init(ignoredRanges: merged, embeddedLanguages: languages)
        }
    }

    // The signed library is loaded only when the first supported file needs highlighting.
    // The handle is intentionally kept for the process lifetime with the function pointer.
    nonisolated(unsafe) private static let library: UnsafeMutableRawPointer? = {
        guard let directory = Bundle.main.privateFrameworksURL,
              let handle = dlopen(directory.appending(path: "libEditSyntax.dylib").path, RTLD_LOCAL | RTLD_NOW) else {
            return nil
        }
        return handle
    }()

    private static let analyze: EditSyntaxAnalyze? = {
        guard let library, let entry = dlsym(library, "edit_syntax_analyze_v1") else { return nil }
        return unsafeBitCast(entry, to: EditSyntaxAnalyze.self)
    }()

    private static let treeAPI: (project: EditSyntaxTreeProject, parse: EditSyntaxTreeParse,
                                 query: EditSyntaxTreeQuery, release: EditSyntaxTreeRelease)? = {
        guard let library, let project = dlsym(library, "edit_syntax_tree_project_v1"),
              let parse = dlsym(library, "edit_syntax_tree_parse_v2"),
              let query = dlsym(library, "edit_syntax_tree_query_v1"),
              let release = dlsym(library, "edit_syntax_tree_release_v1") else { return nil }
        return (unsafeBitCast(project, to: EditSyntaxTreeProject.self), unsafeBitCast(parse, to: EditSyntaxTreeParse.self),
                unsafeBitCast(query, to: EditSyntaxTreeQuery.self), unsafeBitCast(release, to: EditSyntaxTreeRelease.self))
    }()

    static func supportsIncremental(_ language: SyntaxLanguage) -> Bool {
        switch language {
        case .odin, .ruby, .shell, .swift, .zig: treeAPI != nil && queries != nil
        default: false
        }
    }

    // The native entry points copy the immutable tree before editing or querying it.
    final class Tree: @unchecked Sendable {
        let language: SyntaxLanguage
        private let units: [UInt16]
        private let tree: UnsafeMutableRawPointer
        var length: Int { units.count }

        private init(language: SyntaxLanguage, units: [UInt16], tree: UnsafeMutableRawPointer) {
            self.language = language
            self.units = units
            self.tree = tree
        }

        convenience init?(source: String, language: SyntaxLanguage, previous: Tree?, prefix: Int = 0, suffix: Int = 0,
                          deadline: ContinuousClock.Instant? = nil) {
            guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
            let units = Array(source.utf16)
            let projected: Tree?
            if let previous, previous.language == language {
                guard let result = previous.projected(on: units, prefix: prefix, suffix: suffix, deadline: deadline) else {
                    return nil
                }
                projected = result
            } else {
                projected = nil
            }
            guard let tree = Self.parse(language: language, units: units, previous: projected, deadline: deadline) else {
                return nil
            }
            self.init(language: language, units: units, tree: tree)
        }

        func projected(on source: String, prefix: Int, suffix: Int, deadline: ContinuousClock.Instant) -> Tree? {
            projected(on: Array(source.utf16), prefix: prefix, suffix: suffix, deadline: deadline)
        }

        private func projected(on units: [UInt16], prefix: Int, suffix: Int, deadline: ContinuousClock.Instant?) -> Tree? {
            guard let api = treeAPI, let count = UInt32(exactly: units.count),
                  let prefix = UInt32(exactly: prefix), let suffix = UInt32(exactly: suffix),
                  deadline.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
            let sink = Captures(length: units.count, deadline: deadline)
            let context = Unmanaged.passUnretained(sink).toOpaque()
            let previousCount = UInt32(self.units.count)
            let projected = withExtendedLifetime(sink) {
                self.units.withUnsafeBufferPointer { old in
                    units.withUnsafeBufferPointer { new in
                        guard let oldBuffer = old.baseAddress, let newBuffer = new.baseAddress else { return nil as UnsafeMutableRawPointer? }
                        return api.project(UnsafeRawPointer(tree), oldBuffer, previousCount, newBuffer, count, prefix, suffix,
                                           Self.cancelled, context)
                    }
                }
            }
            return projected.map { Tree(language: language, units: units, tree: $0) }
        }

        func reparsed(deadline: ContinuousClock.Instant?) -> Tree? {
            Self.parse(language: language, units: units, previous: self, deadline: deadline)
                .map { Tree(language: language, units: units, tree: $0) }
        }

        private static let cancelled: EditSyntaxCancelled = { context in
            guard let context else { return true }
            return Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().cancelled
        }

        private static func parse(language: SyntaxLanguage, units: [UInt16], previous: Tree?,
                                  deadline: ContinuousClock.Instant?) -> UnsafeMutableRawPointer? {
            guard let api = treeAPI, let count = UInt32(exactly: units.count), count > 0,
                  deadline.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
            let sink = Captures(length: units.count, deadline: deadline)
            let context = Unmanaged.passUnretained(sink).toOpaque()
            return withExtendedLifetime((sink, previous)) {
                units.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return nil }
                    return api.parse(language.rawValue, base, count, previous.map { UnsafeRawPointer($0.tree) }, Self.cancelled, context)
                }
            }
        }

        deinit { treeAPI?.release(tree) }

        func highlights(in range: NSRange, deadline: ContinuousClock.Instant? = nil) -> [SyntaxSpan]? {
            if range.length == 0 { return [] }
            guard let sink = query(range, highlight: { context, start, end, name in
                guard let context, let name else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().append(start: start, end: end, name: name)
            }, bracket: nil, deadline: deadline) else { return nil }
            return resolveOverlaps(sink.values.filter { NSIntersectionRange($0.range, range).length > 0 }, length: length)
        }

        func bracketContext() -> BracketSyntax.Context? {
            query(NSRange(location: 0, length: 0), highlight: nil, bracket: { context, start, end, name in
                guard let context else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().appendBracket(start: start, end: end, name: name)
            }, deadline: nil)?.bracketContext()
        }

        private func query(_ range: NSRange, highlight: EditSyntaxCapture?, bracket: EditSyntaxCapture?,
                           deadline: ContinuousClock.Instant?) -> Captures? {
            guard let api = treeAPI, let queries, range.location >= 0, range.upperBound <= length else { return nil }
            let sink = Captures(length: length, deadline: deadline)
            let success = units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return false }
                return api.query(UnsafeRawPointer(tree), language.rawValue, queries, base, UInt32(length), UInt32(range.location),
                                 UInt32(range.upperBound), highlight, bracket, { context in
                    guard let context else { return true }
                    return Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().cancelled
                }, Unmanaged.passUnretained(sink).toOpaque())
            }
            return success && !sink.cancelled ? sink : nil
        }
    }

    private static let markdownTable: EditMarkdownTable? = {
        guard let library, let entry = dlsym(library, "edit_markdown_table_v1") else { return nil }
        return unsafeBitCast(entry, to: EditMarkdownTable.self)
    }()

    static func markdownTableRows(in source: String, caret: Int) -> [NSRange] {
        guard let markdownTable, let caret = UInt32(exactly: caret), !source.isEmpty else { return [] }
        let units = Array(source.utf16)
        guard let count = UInt32(exactly: units.count) else { return [] }
        var rows: [NSRange] = []
        let found = withUnsafeMutablePointer(to: &rows) { rows in
            units.withUnsafeBufferPointer { buffer in
                markdownTable(buffer.baseAddress!, count, caret, { context, start, end, _ in
                    context?.assumingMemoryBound(to: [NSRange].self).pointee.append(
                        NSRange(location: Int(start), length: Int(end - start))
                    )
                }, rows)
            }
        }
        return found ? rows : []
    }

    private static let queries = Bundle.main.resourceURL?.appending(path: "syntax/queries").path

    private static let viewportQueryByteThreshold = 64 * 1_024

    static func prepareOpening(
        _ text: String, language: SyntaxLanguage, topOffset: Int, visibleLines: Int
    ) -> SyntaxSnapshot? {
        // Start at the beginning for lexical context, and bound the work before showing the file.
        let maximumPrefixLength = 16 * 1_024
        guard language != .plainText, topOffset >= 0, topOffset < maximumPrefixLength else { return nil }
        let units = text.utf16
        let prefix = units.prefix(maximumPrefixLength)
        if prefix.endIndex == units.endIndex {
            if supportsIncremental(language), let tree = Tree(source: text, language: language, previous: nil),
               let spans = tree.highlights(in: NSRange(location: 0, length: tree.length)),
               let brackets = tree.bracketContext() {
                return SyntaxSnapshot(language: language, analysis: SyntaxAnalysis(spans: spans, brackets: brackets),
                                      coversDocument: true, tree: tree)
            }
            guard let analysis = analysis(in: text, language: language) else { return nil }
            return SyntaxSnapshot(language: language, analysis: analysis, coversDocument: true)
        }
        let lines = String(decoding: prefix, as: UTF16.self) as NSString
        guard topOffset <= lines.length else { return nil }

        // A few extra lines preserve context at the edge and cover initial layout adjustments.
        var end = lines.lineRange(for: NSRange(location: topOffset, length: 0)).location
        for line in 0..<(visibleLines + 16) {
            if end == lines.length { break }
            let next = NSMaxRange(lines.lineRange(for: NSRange(location: end, length: 0)))
            if next == lines.length {
                // An unusually long line or a deep viewport can open without a preview.
                guard line >= visibleLines else { return nil }
                break
            }
            end = next
        }

        guard let analysis = analysis(in: lines.substring(to: end), language: language, includesBrackets: false) else { return nil }
        return SyntaxSnapshot(language: language, analysis: analysis, coversDocument: false)
    }

    #if EDIT_AGENT_CHECKS
    static func spans(in text: String, language: SyntaxLanguage) -> [SyntaxSpan]? {
        analysis(in: text, language: language, includesBrackets: false)?.spans
    }
    #endif

    static func analysis(
        in text: String, language: SyntaxLanguage, visibleRange: NSRange? = nil,
        includesBrackets: Bool = true, onPreview: (@Sendable ([SyntaxSpan]) -> Void)? = nil
    ) -> SyntaxAnalysis? {
        guard !text.isEmpty else { return .empty }
        guard language != .plainText, let analyze, let queries, !Task.isCancelled else { return nil }
        let units = Array(text.utf16)
        guard let count = UInt32(exactly: units.count) else { return nil }
        let viewport = visibleRange ?? NSRange(location: 0, length: min(4_096, units.count))
        let prioritizesViewport = onPreview != nil && text.utf8.count > viewportQueryByteThreshold
            && viewport.length < units.count / 4
        let previewStart = prioritizesViewport ? UInt32(min(viewport.location, units.count)) : 0
        let previewEnd = prioritizesViewport ? UInt32(min(NSMaxRange(viewport), units.count)) : 0
        let sink = Captures(length: units.count, onPreview: onPreview)
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let bracket: EditSyntaxCapture = { context, start, end, name in
            guard let context else { return }
            Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().appendBracket(start: start, end: end, name: name)
        }
        let success = units.withUnsafeBufferPointer { buffer in
            analyze(language.rawValue, queries, buffer.baseAddress!, count, previewStart, previewEnd, { context in
                guard let context else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().publishPreview()
            }, { context, start, end, name in
                guard let context, let name else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().append(start: start, end: end, name: name)
            }, includesBrackets ? bracket : nil, { _ in Task.isCancelled }, context)
        }
        guard success, !Task.isCancelled else { return nil }
        return SyntaxAnalysis(spans: resolveOverlaps(sink.values, length: units.count), brackets: sink.bracketContext())
    }

    private static func resolveOverlaps(_ input: [SyntaxSpan], length: Int) -> [SyntaxSpan] {
        let byStart = input.indices.sorted {
            let left = input[$0]
            let right = input[$1]
            return left.start == right.start ? $0 < $1 : left.start < right.start
        }
        var spans: [SyntaxSpan] = []
        var active: [Int] = []
        var next = 0
        var at = 0
        while next < byStart.count || !active.isEmpty {
            if Task.isCancelled { return [] }
            active.removeAll { input[$0].end <= at }
            while next < byStart.count, input[byStart[next]].start <= at {
                active.append(byStart[next])
                next += 1
            }
            let nextStart = next < byStart.count ? input[byStart[next]].start : length
            let nextEnd = active.reduce(length) { min($0, input[$1].end) }
            let end = min(nextStart, nextEnd)
            guard end > at else { break }
            if let winner = active.min(by: {
                let first = input[$0]
                let second = input[$1]
                let firstLength = first.end - first.start
                let secondLength = second.end - second.start
                if firstLength != secondLength { return firstLength < secondLength }
                if first.color.priority != second.color.priority { return first.color.priority > second.color.priority }
                return $0 > $1
            }) {
                let color = input[winner].color
                if let last = spans.last, last.end == at, last.color == color {
                    spans[spans.count - 1] = SyntaxSpan(start: last.start, end: end, color: color)
                } else {
                    spans.append(SyntaxSpan(start: at, end: end, color: color))
                }
            }
            at = end
        }
        return spans
    }
}
