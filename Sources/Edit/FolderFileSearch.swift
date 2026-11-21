import Foundation

enum FolderFileSearch {
    struct DirectoryQuery: Sendable {
        let components: [String]
        let filter: String

        init?(_ query: String) {
            let query = query.drop(while: \.isWhitespace)
            guard let slash = query.lastIndex(of: "/"), !query.hasPrefix("/") else { return nil }
            let path = query[..<slash].replacingOccurrences(of: "\\ ", with: " ")
            components = path.split(separator: "/").map(String.init).filter { $0 != "." }
            filter = String(query[query.index(after: slash)...])
        }

        func rank(_ recent: [ControlEntry], in folder: URL) -> [ControlMatch] {
            var directory = folder
            for component in components {
                if Task.isCancelled || component == ".." || component.utf8.contains(0) { return [] }
                directory = directory.appending(path: component, directoryHint: .isDirectory)
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return [] }
            }

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(fileKeys)
            ) else { return [] }
            let files = fileEntries(urls, relativeTo: folder)
            let paths = Set(files.compactMap { $0.folderFileURL?.path })
            let localRecents = recent.filter { $0.recent.map { paths.contains($0.canonicalURL.path) } == true }
            return FolderFileSearch.rank(localRecents, folderFiles: files, query: filter)
        }
    }

    struct Index: Sendable {
        fileprivate let files: [ControlEntry]
        fileprivate let exclusions: FolderSearchExclusions

        func rank(_ recent: [ControlEntry], query: String) -> [ControlMatch] {
            var exclusions = exclusions
            return FolderFileSearch.rank(exclusions.filter(recent), folderFiles: files, query: query)
        }
    }

    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]

    static func index(in folder: URL) -> Index {
        var exclusions = FolderSearchExclusions(root: folder)
        var files: [ControlEntry] = []
        let keys = fileKeys.union([.isDirectoryKey])
        if let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsPackageDescendants]) {
            for case let url as URL in urls {
                if Task.isCancelled { return Index(files: [], exclusions: exclusions) }
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if !exclusions.includes(url) { urls.skipDescendants() }
                } else if let entry = fileEntry(url, values: values, relativeTo: folder) {
                    files.append(entry)
                }
            }
        }
        return Index(files: files.sorted { $0.id < $1.id }, exclusions: exclusions)
    }

    static func recentMatches(_ recent: [ControlEntry], in folder: URL) -> [ControlMatch] {
        var exclusions = FolderSearchExclusions(root: folder)
        return ControlMatching.rank(exclusions.filter(recent), query: "")
    }

    private static func fileEntries(_ urls: [URL], relativeTo folder: URL) -> [ControlEntry] {
        var entries: [ControlEntry] = []
        for url in urls {
            if Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: fileKeys), values.isSymbolicLink != true,
                  let entry = fileEntry(url, values: values, relativeTo: folder) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.id < $1.id }
    }

    private static func fileEntry(_ url: URL, values: URLResourceValues, relativeTo folder: URL) -> ControlEntry? {
        guard values.isRegularFile == true else { return nil }
        let folderPath = folder.path
        let prefixLength = folderPath.hasSuffix("/") ? folderPath.count : folderPath.count + 1
        let parent = String(url.deletingLastPathComponent().path.dropFirst(prefixLength))
        let identity = (values.linkCount ?? 1) > 1 ? FileIdentity.at(url) : nil
        return ControlEntry(id: url.absoluteString, title: url.lastPathComponent,
                            detail: parent.isEmpty ? nil : parent, folderFileURL: url, folderFileIdentity: identity)
    }

    private static func rank(_ recent: [ControlEntry], folderFiles: [ControlEntry], query: String) -> [ControlMatch] {
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

fileprivate struct FolderSearchExclusions: Sendable {
    private enum Directory {
        case included([FolderIgnoreRules])
        case excluded
    }

    private static let excludedNames: Set<String> = [
        "node_modules", "bower_components", "venv", "__pycache__", "deriveddata", "zig-out",
    ]
    private let prefix: String
    private var directories: [String: Directory]

    init(root: URL) {
        let path = root.path
        prefix = path.hasSuffix("/") ? path : path + "/"
        var rules = Self.inheritedRules(for: root)
        if let local = FolderIgnoreRules.read(in: root) { rules.append(local) }
        directories = [path: .included(rules)]
    }

    mutating func includes(_ directory: URL) -> Bool {
        if case .included = rules(for: directory) { return true }
        return false
    }

    mutating func filter(_ recent: [ControlEntry]) -> [ControlEntry] {
        recent.filter { row in
            guard !Task.isCancelled, let file = row.recent else { return false }
            return includesRecent(file.canonicalURL) && includesRecent(file.url)
        }
    }

    private mutating func includesRecent(_ file: URL) -> Bool {
        !file.path.hasPrefix(prefix) || includes(file.deletingLastPathComponent())
    }

    private mutating func rules(for directory: URL) -> Directory {
        let path = directory.path
        if let cached = directories[path] { return cached }
        guard path.hasPrefix(prefix) else { return .excluded }

        let parent = directory.deletingLastPathComponent()
        guard !Self.isExcludedName(directory.lastPathComponent, parent: parent),
              case .included(var inherited) = rules(for: parent),
              inherited.reversed().lazy.compactMap({ $0.ignores(directory) }).first != true else {
            directories[path] = .excluded
            return .excluded
        }

        if let local = FolderIgnoreRules.read(in: directory) { inherited.append(local) }
        let entry = Directory.included(inherited)
        directories[path] = entry
        return entry
    }

    private static func isExcludedName(_ name: String, parent: URL) -> Bool {
        if name.hasPrefix(".") || excludedNames.contains(name.lowercased()) { return true }
        guard name.lowercased() == "target" else { return false }
        let manifest = parent.appending(path: "Cargo.toml", directoryHint: .notDirectory)
        return (try? manifest.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func inheritedRules(for root: URL) -> [FolderIgnoreRules] {
        // Opening a subfolder still uses ignore files between it and the containing Git root.
        var directory = root
        var ancestors: [URL] = []
        while !Task.isCancelled {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
                return ancestors.reversed().compactMap { FolderIgnoreRules.read(in: $0) }
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path && !parent.path.isEmpty else { return [] }
            ancestors.append(parent)
            directory = parent
        }
        return []
    }
}
