import Darwin
import Foundation

enum SyntaxColor: Sendable, Hashable, CaseIterable {
    case keyword, control, type, function, string, number, comment, property, markup, attribute

    fileprivate var priority: Int {
        switch self {
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
}

struct SyntaxSnapshot: Sendable {
    let language: SyntaxLanguage
    let spans: [SyntaxSpan]
    let coversDocument: Bool
}

enum SyntaxEngine {
    private typealias Capture = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafePointer<CChar>?) -> Void
    private typealias Preview = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Cancelled = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias Highlight = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<UInt16>, UInt32,
        UInt32, UInt32, Preview?, Capture, Cancelled, UnsafeMutableRawPointer?
    ) -> Bool

    private final class Captures {
        var values: [SyntaxSpan] = []
        private var colors: [UnsafePointer<CChar>: SyntaxColor?] = [:]
        private let length: Int
        private let onPreview: (@Sendable ([SyntaxSpan]) -> Void)?

        init(length: Int, onPreview: (@Sendable ([SyntaxSpan]) -> Void)?) {
            self.length = length
            self.onPreview = onPreview
        }

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
    }

    // The signed library is loaded only when the first supported file needs highlighting.
    // The handle is intentionally kept for the process lifetime with the function pointer.
    private static let highlight: Highlight? = {
        guard let directory = Bundle.main.privateFrameworksURL,
              let handle = dlopen(directory.appending(path: "libEditSyntax.dylib").path, RTLD_LOCAL | RTLD_NOW) else {
            return nil
        }
        guard let entry = dlsym(handle, "edit_syntax_highlight_with_viewport") else {
            dlclose(handle)
            return nil
        }
        return unsafeBitCast(entry, to: Highlight.self)
    }()

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
            guard let colors = spans(in: text, language: language) else { return nil }
            return SyntaxSnapshot(language: language, spans: colors, coversDocument: true)
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

        guard let colors = spans(in: lines.substring(to: end), language: language) else { return nil }
        return SyntaxSnapshot(language: language, spans: colors, coversDocument: false)
    }

    static func spans(
        in text: String, language: SyntaxLanguage, visibleRange: NSRange? = nil,
        onPreview: (@Sendable ([SyntaxSpan]) -> Void)? = nil
    ) -> [SyntaxSpan]? {
        guard !text.isEmpty else { return [] }
        guard language != .plainText, let highlight, let queries, !Task.isCancelled else { return nil }
        let units = Array(text.utf16)
        guard let count = UInt32(exactly: units.count) else { return nil }
        let viewport = visibleRange ?? NSRange(location: 0, length: min(4_096, units.count))
        let prioritizesViewport = onPreview != nil && text.utf8.count > viewportQueryByteThreshold
            && viewport.length < units.count / 4
        let previewStart = prioritizesViewport ? UInt32(min(viewport.location, units.count)) : 0
        let previewEnd = prioritizesViewport ? UInt32(min(NSMaxRange(viewport), units.count)) : 0
        let sink = Captures(length: units.count, onPreview: onPreview)
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let success = units.withUnsafeBufferPointer { buffer in
            highlight(language.rawValue, queries, buffer.baseAddress!, count, previewStart, previewEnd, { context in
                guard let context else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().publishPreview()
            }, { context, start, end, name in
                guard let context, let name else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().append(start: start, end: end, name: name)
            }, { _ in Task.isCancelled }, context)
        }
        guard success, !Task.isCancelled else { return nil }
        return resolveOverlaps(sink.values, length: units.count)
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
