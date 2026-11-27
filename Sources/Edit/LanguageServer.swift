import Foundation

enum LanguageServer: CaseIterable, Sendable {
    case zig, sourceKit, odin, solidity

    var name: String {
        switch self {
        case .zig: "ZLS"
        case .sourceKit: "SourceKit-LSP"
        case .odin: "OLS"
        case .solidity: "Solar"
        }
    }

    var executable: String {
        switch self {
        case .zig: "zls"
        case .sourceKit: "sourcekit-lsp"
        case .odin: "ols"
        case .solidity: "forge"
        }
    }

    var arguments: [String] { self == .solidity ? ["lsp", "--stdio"] : [] }

    var usesCanonicalFileURLs: Bool { self != .zig }

    init?(language: SyntaxLanguage) {
        switch language {
        case .zig: self = .zig
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP: self = .sourceKit
        case .odin: self = .odin
        case .solidity: self = .solidity
        default: return nil
        }
    }
}
