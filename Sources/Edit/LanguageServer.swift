import Foundation

enum LanguageServer: CaseIterable, Sendable {
    case zig, sourceKit

    var name: String {
        switch self {
        case .zig: "ZLS"
        case .sourceKit: "SourceKit-LSP"
        }
    }

    var executable: String {
        switch self {
        case .zig: "zls"
        case .sourceKit: "sourcekit-lsp"
        }
    }

    var iconIdentifier: String {
        switch self {
        case .zig: "zig"
        case .sourceKit: "swift"
        }
    }

    init?(language: SyntaxLanguage) {
        switch language {
        case .zig: self = .zig
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP: self = .sourceKit
        default: return nil
        }
    }
}
