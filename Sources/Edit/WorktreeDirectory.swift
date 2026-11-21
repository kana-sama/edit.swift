import Foundation

enum WorktreeDirectory {
    struct Entry: Sendable {
        let url: URL
        let isDirectory: Bool
        let isIgnored: Bool
        let isHidden: Bool
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]

    static func read(_ directory: URL, within root: URL) throws -> [Entry] {
        let root = root.standardizedFileURL
        let canonicalRoot = FileBuffer.canonicalURL(root)
        let directory = directory.standardizedFileURL
        guard let relative = relativePath(directory, in: root) ?? relativePath(directory, in: canonicalRoot) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
        }

        // Rules outside an opened subfolder can affect it only inside the containing worktree.
        var ancestors = gitAncestors(of: canonicalRoot)
        ancestors.append(canonicalRoot)
        var location = canonicalRoot
        for component in relative.split(separator: "/") {
            try Task.checkCancellation()
            location = location.appending(path: String(component), directoryHint: .isDirectory)
            let values = try location.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: location.path])
            }
            ancestors.append(location)
        }

        var rules: [FolderIgnoreRules] = []
        var ignoredAncestor = false
        for ancestor in ancestors {
            try Task.checkCancellation()
            ignoredAncestor = isIgnored(ancestor, isDirectory: true, rules: rules)
            if ignoredAncestor { break }
            if let local = FolderIgnoreRules.read(in: ancestor) { rules.append(local) }
        }

        let children = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: Array(keys))
        var entries: [Entry] = []
        entries.reserveCapacity(children.count)
        for child in children {
            try Task.checkCancellation()
            guard !FolderFileSearch.isExcludedFile(child), let values = try? child.resourceValues(forKeys: keys) else {
                continue
            }
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            entries.append(Entry(
                url: directory.appending(path: child.lastPathComponent, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                isDirectory: isDirectory,
                isIgnored: ignoredAncestor || isIgnored(child, isDirectory: isDirectory, rules: rules),
                isHidden: child.lastPathComponent.hasPrefix(".") || values.isHidden == true
            ))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    private static func relativePath(_ directory: URL, in root: URL) -> Substring? {
        let directoryPath = directory.path
        let rootPath = root.path
        if directoryPath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return directoryPath.hasPrefix(prefix) ? directoryPath.dropFirst(prefix.count) : nil
    }

    private static func isIgnored(_ url: URL, isDirectory: Bool, rules: [FolderIgnoreRules]) -> Bool {
        rules.reversed().lazy.compactMap { $0.ignores(url, isDirectory: isDirectory) }.first == true
    }

    private static func gitAncestors(of root: URL) -> [URL] {
        var directory = root
        var ancestors: [URL] = []
        while !Task.isCancelled {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
                return ancestors.reversed()
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, !parent.path.isEmpty else { return [] }
            ancestors.append(parent)
            directory = parent
        }
        return []
    }
}
