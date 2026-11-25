import Foundation

@MainActor
final class WorkspaceLSPHighlighting {
    private static let key = "lsp-highlighting-disabled-workspaces"
    private let defaults: UserDefaults?
    private var disabled: Set<String>

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        disabled = Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(in folder: URL?) -> Bool {
        !disabled.contains(folder?.standardizedFileURL.path ?? "")
    }

    func setEnabled(_ enabled: Bool, in folder: URL?) {
        let path = folder?.standardizedFileURL.path ?? ""
        if enabled {
            guard disabled.remove(path) != nil else { return }
        } else {
            guard disabled.insert(path).inserted else { return }
        }
        defaults?.set(disabled.sorted(), forKey: Self.key)
    }
}
