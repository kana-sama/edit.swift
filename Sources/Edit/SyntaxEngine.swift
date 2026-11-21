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

enum SyntaxEngine {
    private typealias Capture = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafePointer<CChar>?) -> Void
    private typealias Cancelled = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias Highlight = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<UInt16>, UInt32,
        Capture, Cancelled, UnsafeMutableRawPointer?
    ) -> Bool

    private final class Captures {
        var values: [SyntaxSpan] = []
    }

    // The signed library is loaded only when the first supported file needs highlighting.
    // The handle is intentionally kept for the process lifetime with the function pointer.
    private static let highlight: Highlight? = {
        guard let directory = Bundle.main.privateFrameworksURL,
              let handle = dlopen(directory.appending(path: "libEditSyntax.dylib").path, RTLD_LOCAL | RTLD_NOW) else {
            return nil
        }
        guard let entry = dlsym(handle, "edit_syntax_highlight") else {
            dlclose(handle)
            return nil
        }
        return unsafeBitCast(entry, to: Highlight.self)
    }()

    private static let queries = Bundle.main.resourceURL?.appending(path: "syntax/queries").path

    static func spans(in text: String, language: SyntaxLanguage) -> [SyntaxSpan]? {
        guard !text.isEmpty else { return [] }
        guard language != .plainText, let highlight, let queries, !Task.isCancelled else { return nil }
        let units = Array(text.utf16)
        guard let count = UInt32(exactly: units.count) else { return nil }
        let sink = Captures()
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let success = units.withUnsafeBufferPointer { buffer in
            highlight(language.rawValue, queries, buffer.baseAddress!, count, { context, start, end, name in
                guard let context, let name, let color = SyntaxColor(capture: String(cString: name)) else { return }
                Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue().values.append(
                    SyntaxSpan(start: Int(start), end: Int(end), color: color)
                )
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
