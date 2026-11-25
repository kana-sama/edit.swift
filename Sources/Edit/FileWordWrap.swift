import Foundation

@MainActor
final class FileWordWrap {
    private static let key = "wordWrappedFilePaths"
    private let defaults: UserDefaults?
    private var paths: Set<String>

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        paths = Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(for file: URL?) -> Bool {
        file.map { paths.contains($0.path) } ?? false
    }

    func set(_ enabled: Bool, for file: URL) {
        if enabled {
            guard paths.insert(file.path).inserted else { return }
        } else {
            guard paths.remove(file.path) != nil else { return }
        }
        persist()
    }

    func move(from source: URL, to destination: URL) {
        let moved = paths.compactMap { path -> (String, String)? in
            guard let suffix = DocumentWindow.worktreePathSuffix(from: source, to: URL(fileURLWithPath: path)) else {
                return nil
            }
            return (path, suffix.isEmpty ? destination.path : destination.appending(path: suffix).path)
        }
        guard !moved.isEmpty else { return }
        paths.subtract(moved.map { $0.0 })
        paths.formUnion(moved.map { $0.1 })
        persist()
    }

    private func persist() {
        defaults?.set(paths.sorted(), forKey: Self.key)
    }
}
