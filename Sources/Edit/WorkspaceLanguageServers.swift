import Foundation

@MainActor
final class WorkspaceLanguageServers {
    private static let key = "stoppedLanguageServersByWorkspace"
    private let defaults: UserDefaults?
    private var stopped: [String: Set<String>]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.dictionary(forKey: Self.key) as? [String: [String]]
        stopped = saved?.mapValues(Set.init) ?? [:]
    }

    func isStopped(_ server: LanguageServer, in workspace: URL) -> Bool {
        stopped[FileBuffer.canonicalURL(workspace).path]?.contains(server.executable) == true
    }

    func setStopped(_ value: Bool, for server: LanguageServer, in workspace: URL) {
        let path = FileBuffer.canonicalURL(workspace).path
        var servers = stopped[path] ?? []
        if value {
            guard servers.insert(server.executable).inserted else { return }
        } else {
            guard servers.remove(server.executable) != nil else { return }
        }
        stopped[path] = servers.isEmpty ? nil : servers
        defaults?.set(stopped.mapValues { $0.sorted() }, forKey: Self.key)
    }
}
