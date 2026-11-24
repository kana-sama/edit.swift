import Foundation

struct JJSourceControlCommitLink: Equatable, Sendable {
    let url: URL
    let hostName: String

    static func lookup(
        for revision: JJSourceControlRevision, in workspace: JJWorkspace, at operationID: String
    ) async -> Self? {
        guard !revision.parents.isEmpty, JJRepository.isHexID(revision.id) else { return nil }
        // Use Jujutsu's recorded origin refs, including ancestors without a bookmark of their own.
        let published = #"ancestors(remote_bookmarks(remote=exact:"origin") | remote_tags(remote=exact:"origin"))"#
        guard let data = try? await JJRepository.readCommand([
            "log", "--no-graph", "--limit=1", "-r", "\(revision.id) & \(published)",
            "-T", #"json(git_web_url("origin"))"#,
        ], in: workspace, at: operationID, limit: 4096), !Task.isCancelled,
            let origin = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return Self(originWebURL: origin, commitID: revision.id)
    }

    init?(originWebURL: String, commitID: String) {
        guard [40, 64].contains(commitID.utf8.count), JJRepository.isHexID(commitID),
              var origin = URLComponents(string: originWebURL), origin.scheme == "https",
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.port == nil || origin.port == 443, let host = origin.host?.lowercased() else { return nil }

        let commitPath: String
        switch host {
        case "github.com":
            hostName = "GitHub"
            commitPath = "commit"
        case let enterprise where enterprise.hasSuffix(".ghe.com"):
            hostName = "GitHub"
            commitPath = "commit"
        case "codeberg.org":
            hostName = "Codeberg"
            commitPath = "commit"
        case "gitea.com":
            hostName = "Gitea"
            commitPath = "commit"
        case "gitlab.com":
            hostName = "GitLab"
            commitPath = "-/commit"
        case "bitbucket.org":
            hostName = "Bitbucket"
            commitPath = "commits"
        default:
            return nil
        }

        let path = origin.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (host == "gitlab.com" ? segments.count >= 2 : segments.count == 2),
              segments.allSatisfy({ segment in
                  guard let name = segment.removingPercentEncoding, !name.isEmpty else { return false }
                  return name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
              }) else { return nil }
        origin.percentEncodedPath = "/\(path)/\(commitPath)/\(commitID)"
        guard let url = origin.url else { return nil }
        self.url = url
    }
}
