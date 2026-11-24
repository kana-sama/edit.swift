import Foundation

enum LanguageServer: CaseIterable, Sendable {
    case zig, swift

    var name: String {
        switch self {
        case .zig: "ZLS"
        case .swift: "SourceKit-LSP"
        }
    }

    var executable: String {
        switch self {
        case .zig: "zls"
        case .swift: "sourcekit-lsp"
        }
    }

    var languageID: String {
        switch self {
        case .zig: "zig"
        case .swift: "swift"
        }
    }

    init?(language: SyntaxLanguage?) {
        switch language {
        case .zig: self = .zig
        case .swift: self = .swift
        default: return nil
        }
    }
}
