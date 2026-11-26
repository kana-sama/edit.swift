import Foundation

enum LanguageServer: CaseIterable, Sendable {
    case zig, sourceKit, odin

    var name: String {
        switch self {
        case .zig: "ZLS"
        case .sourceKit: "SourceKit-LSP"
        case .odin: "OLS"
        }
    }

    var executable: String {
        switch self {
        case .zig: "zls"
        case .sourceKit: "sourcekit-lsp"
        case .odin: "ols"
        }
    }

    init?(language: SyntaxLanguage) {
        switch language {
        case .zig: self = .zig
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP: self = .sourceKit
        case .odin: self = .odin
        default: return nil
        }
    }
}
