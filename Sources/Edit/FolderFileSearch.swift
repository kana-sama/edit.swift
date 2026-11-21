import Foundation

enum FolderFileSearch {
    static func entries(in folder: URL) -> [ControlEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]
        guard let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                        options: [.skipsPackageDescendants]) else { return [] }
        let rootPath = folder.path
        let prefixLength = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        var files: [ControlEntry] = []
        for case let url as URL in urls {
            if Task.isCancelled { return [] }
            let title = url.lastPathComponent
            if title == ".git" {
                urls.skipDescendants()
                continue
            }
            guard let resource = try? url.resourceValues(forKeys: keys),
                  resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            let parent = String(url.deletingLastPathComponent().path.dropFirst(prefixLength))
            let identity = (resource.linkCount ?? 1) > 1 ? FileIdentity.at(url) : nil
            files.append(ControlEntry(id: url.absoluteString, title: title, detail: parent.isEmpty ? nil : parent,
                                      folderFileURL: url, folderFileIdentity: identity))
        }
        return files.sorted { $0.id < $1.id }
    }

    static func rank(_ recent: [ControlEntry], folderFiles: [ControlEntry], query: String) -> [ControlMatch] {
        let matches = ControlMatching.rank(recent + folderFiles, query: query)

        // Rank both paths before merging. A recent may use an alias while the query matches the real name.
        let matchingRecents = matches.compactMap { $0.entry.recent }
        let paths = Set(matchingRecents.map { $0.canonicalURL.path })
        let identities = Set(matchingRecents.map(\.identity))
        return matches.filter { match in
            guard let url = match.entry.folderFileURL else { return true }
            return !paths.contains(url.path) && match.entry.folderFileIdentity.map(identities.contains) != true
        }
    }
}
