import Darwin
import Foundation

enum BracketSyntax {
    struct EmbeddedLanguage: Sendable {
        let range: NSRange
        let language: SyntaxLanguage
    }

    struct Context: Sendable {
        let ignoredRanges: [NSRange]
        let embeddedLanguages: [EmbeddedLanguage]
    }

    private typealias Capture = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafePointer<CChar>?) -> Void
    private typealias Cancelled = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias ReadContext = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<UInt16>, UInt32,
        Capture, Cancelled, UnsafeMutableRawPointer?
    ) -> Bool

    private final class Captures {
        var excluded: [NSRange] = []
        var languages: [EmbeddedLanguage] = []

        func context() -> Context {
            var merged: [NSRange] = []
            for range in excluded.sorted(by: { $0.location < $1.location }) {
                if let previous = merged.last, range.location <= previous.upperBound {
                    merged[merged.count - 1] = NSUnionRange(previous, range)
                } else {
                    merged.append(range)
                }
            }
            return Context(ignoredRanges: merged, embeddedLanguages: languages)
        }
    }

    private static let readContext: ReadContext? = {
        guard let directory = Bundle.main.privateFrameworksURL,
              let handle = dlopen(directory.appending(path: "libEditSyntax.dylib").path, RTLD_LOCAL | RTLD_NOW) else {
            return nil
        }
        guard let entry = dlsym(handle, "edit_syntax_bracket_context") else {
            dlclose(handle)
            return nil
        }
        return unsafeBitCast(entry, to: ReadContext.self)
    }()

    static func context(in text: String, language: SyntaxLanguage) -> Context {
        let empty = Context(ignoredRanges: [], embeddedLanguages: [])
        guard language != .plainText, !text.isEmpty, !Task.isCancelled, let readContext,
              let queries = Bundle.main.resourceURL?.appending(path: "syntax/queries").path else { return empty }
        let units = Array(text.utf16)
        guard !Task.isCancelled, let count = UInt32(exactly: units.count) else { return empty }
        let captures = Captures()
        let context = Unmanaged.passUnretained(captures).toOpaque()
        let success = units.withUnsafeBufferPointer { buffer in
            guard let start = buffer.baseAddress else { return false }
            return readContext(language.rawValue, queries, start, count, { context, from, to, name in
                guard let context, from < to else { return }
                let captures = Unmanaged<Captures>.fromOpaque(context).takeUnretainedValue()
                let range = NSRange(location: Int(from), length: Int(to - from))
                if let name {
                    if let language = SyntaxLanguage(rawValue: String(cString: name)) {
                        captures.languages.append(EmbeddedLanguage(range: range, language: language))
                    }
                } else {
                    captures.excluded.append(range)
                }
            }, { _ in Task.isCancelled }, context)
        }
        guard success, !Task.isCancelled else { return empty }
        return captures.context()
    }
}
