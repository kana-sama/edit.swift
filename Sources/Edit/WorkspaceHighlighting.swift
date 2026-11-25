import Foundation

enum HighlightingLayer: CaseIterable {
    case treeSitter, lsp

    var defaultsKey: String {
        switch self {
        case .treeSitter: "tree-sitter-highlighting-disabled-workspaces"
        case .lsp: "lsp-highlighting-disabled-workspaces"
        }
    }
}

@MainActor
final class WorkspaceHighlighting {
    private let defaults: UserDefaults?
    private var disabled: [HighlightingLayer: Set<String>]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        disabled = Dictionary(uniqueKeysWithValues: HighlightingLayer.allCases.map { layer in
            (layer, Set(defaults?.stringArray(forKey: layer.defaultsKey) ?? []))
        })
    }

    func isEnabled(_ layer: HighlightingLayer, in folder: URL?) -> Bool {
        disabled[layer]?.contains(folder?.standardizedFileURL.path ?? "") != true
    }

    func setEnabled(_ enabled: Bool, for layer: HighlightingLayer, in folder: URL?) {
        let path = folder?.standardizedFileURL.path ?? ""
        if enabled {
            guard disabled[layer]?.remove(path) != nil else { return }
        } else {
            guard disabled[layer, default: []].insert(path).inserted else { return }
        }
        defaults?.set(disabled[layer]?.sorted(), forKey: layer.defaultsKey)
    }
}
