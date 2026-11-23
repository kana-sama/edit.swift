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
    }

    struct Scope: Equatable, Sendable {
        let folder: URL
        let components: [String]?

        fileprivate var directory: (url: URL, insidePackage: Bool)? {
            var directory = folder
            var insidePackage = false
            for component in components ?? [] {
                if Task.isCancelled || component == ".." || component.utf8.contains(0) { return nil }
                directory = directory.appending(path: component, directoryHint: .isDirectory)
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                insidePackage = insidePackage || values.isPackage == true
            }
            return (directory, insidePackage)
        }
    }

    struct Index: Sendable {
        fileprivate enum RecentScope: Sendable {
            case project(FolderSearchExclusions)
            case listedFiles(Set<String>)
        }

        fileprivate let files: [ControlEntry]
        fileprivate let recentScope: RecentScope

        func rank(_ recent: [ControlEntry], query: String, alternateCharacters: [Character: Character],
                  pinnedFiles: [ControlEntry], scratches: [ControlEntry]) -> [ControlMatch] {
            let eligible: [ControlEntry]
            switch recentScope {
            case .project(var exclusions):
                eligible = exclusions.filter(recent)
            case .listedFiles(let paths):
                eligible = recent.filter { $0.recent.map { paths.contains($0.canonicalURL.path) } == true }
            }
            return FolderFileSearch.rank(eligible, folderFiles: files, pinnedFiles: pinnedFiles, scratches: scratches,
                                         query: query, alternateCharacters: alternateCharacters)
        }
    }

    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .linkCountKey]

    static func isExcludedFile(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare(".DS_Store") == .orderedSame
    }

    static func relativeDirectory(of file: URL, in folder: URL) -> String? {
        let folderPath = folder.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let path = file.path
        guard path.hasPrefix(prefix) else { return nil }
        let relative = path.dropFirst(prefix.count)
        guard let slash = relative.lastIndex(of: "/") else { return "" }
        return String(relative[..<slash])
    }

    static func index(in scope: Scope) -> Index {
        guard let (directory, insidePackage) = scope.directory else {
            return Index(files: [], recentScope: .listedFiles([]))
        }
        var exclusions = FolderSearchExclusions(root: scope.folder)
        let files: [ControlEntry]
        if !insidePackage, exclusions.includes(directory) {
            files = recursiveFiles(in: directory, relativeTo: scope.folder, exclusions: &exclusions)
        } else {
            // An explicit path can reveal an excluded directory or a package one level at a time.
            let children = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(fileKeys)
            )
            files = fileEntries(children ?? [], relativeTo: scope.folder)
        }
        if scope.components != nil {
            return Index(files: files, recentScope: .listedFiles(Set(files.compactMap { $0.folderFileURL?.path })))
        }
        return Index(files: files, recentScope: .project(exclusions))
    }

    private static func recursiveFiles(in directory: URL, relativeTo folder: URL,
                                       exclusions: inout FolderSearchExclusions) -> [ControlEntry] {
        var files: [ControlEntry] = []
        let keys = fileKeys.union([.isDirectoryKey])
        if let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsPackageDescendants]) {
            for case let url as URL in urls {
                if Task.isCancelled { return [] }
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if !exclusions.includes(url) { urls.skipDescendants() }
                } else if let entry = fileEntry(url, values: values, relativeTo: folder) {
                    files.append(entry)
                }
            }
        }
        return files.sorted { $0.id < $1.id }
    }

    static func recentMatches(_ recent: [ControlEntry], scratches: [ControlEntry], in folder: URL) -> [ControlMatch] {
        var exclusions = FolderSearchExclusions(root: folder)
        return ControlMatching.rankFiles(exclusions.filter(recent) + scratches, query: "")
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
        guard values.isRegularFile == true, !isExcludedFile(url),
              let parent = relativeDirectory(of: url, in: folder) else { return nil }
        let identity = (values.linkCount ?? 1) > 1 ? FileIdentity.at(url) : nil
        return ControlEntry(id: url.absoluteString, title: url.lastPathComponent,
                            detail: parent.isEmpty ? nil : parent, folderFileURL: url, folderFileIdentity: identity)
    }

    private static func rank(_ recent: [ControlEntry], folderFiles: [ControlEntry], pinnedFiles: [ControlEntry],
                             scratches: [ControlEntry], query: String,
                             alternateCharacters: [Character: Character]) -> [ControlMatch] {
        let matches = ControlMatching.rank(recent + scratches + folderFiles + pinnedFiles, query: query,
                                           alternateCharacters: alternateCharacters, preferRecentFiles: true)

        // Rank both paths before merging. A recent may use an alias while the query matches the real name.
        let matchingRecents = matches.compactMap { $0.entry.recent }
        let paths = Set(matchingRecents.map { $0.canonicalURL.path })
        let identities = Set(matchingRecents.map(\.identity))
        var seen: Set<String> = []
        return matches.filter { match in
            if let url = match.entry.folderFileURL,
               paths.contains(url.path) || match.entry.folderFileIdentity.map(identities.contains) == true {
                return false
            }
            return pinnedFiles.isEmpty || seen.insert(match.entry.id).inserted
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
