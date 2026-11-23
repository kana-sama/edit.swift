import Foundation

enum BracketSyntax {
    struct EmbeddedLanguage: Sendable {
        let range: NSRange
        let language: SyntaxLanguage
    }

    struct Context: Sendable {
        let ignoredRanges: [NSRange]
        let embeddedLanguages: [EmbeddedLanguage]

        static let empty = Self(ignoredRanges: [], embeddedLanguages: [])
    }
}
