import Foundation

@MainActor
final class WorkspaceFormatOnSave {
    private static let key = "format-on-save-enabled-workspaces"
    private let defaults: UserDefaults?
    private var enabledPaths: Set<String>

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        enabledPaths = Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(in folder: URL?) -> Bool {
        enabledPaths.contains(folder?.standardizedFileURL.path ?? "")
    }

    func setEnabled(_ enabled: Bool, in folder: URL?) {
        let path = folder?.standardizedFileURL.path ?? ""
        if enabled {
            guard enabledPaths.insert(path).inserted else { return }
        } else {
            guard enabledPaths.remove(path) != nil else { return }
        }
        defaults?.set(enabledPaths.sorted(), forKey: Self.key)
    }
}
