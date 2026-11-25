import CoreServices
import Foundation

extension LanguageServer {
    private var manifests: [String] {
        switch self {
        case .zig: ["build.zig", "build.zig.zon"]
        case .sourceKit: ["Package.swift", "buildServer.json", "compile_commands.json", "compile_flags.txt"]
        }
    }

    func projectRoot(in directory: URL, activeFile: URL?, previousRoot: URL?, searchesParents: Bool) -> URL? {
        let folder = if self == .sourceKit {
            URL(filePath: FileBuffer.canonicalURL(directory).path, directoryHint: .isDirectory)
        } else {
            directory.resolvingSymlinksInPath().standardizedFileURL
        }
        let active = activeFile.map { file in
            self == .sourceKit ? FileBuffer.canonicalURL(file) : file.resolvingSymlinksInPath().standardizedFileURL
        }
        if let file = active,
           contains(file, in: folder), FileManager.default.fileExists(atPath: file.path) {
            return nearestManifest(from: file.deletingLastPathComponent(), within: searchesParents ? nil : folder) ?? folder
        }
        if searchesParents, let parent = nearestManifest(from: folder, within: nil) { return parent }
        if let previousRoot, contains(previousRoot, in: folder), hasManifest(in: previousRoot) { return previousRoot }
        if hasManifest(in: folder) { return folder }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if searchesParents { options.insert(.skipsSubdirectoryDescendants) }
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                         options: options) else { return nil }
        var hasLooseSources = false
        for case let url as URL in files {
            if Task.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if excludesDirectory(url.lastPathComponent) { files.skipDescendants() }
            } else if values.isRegularFile == true {
                if manifests.contains(url.lastPathComponent) { return url.deletingLastPathComponent() }
                if isSource(url) { hasLooseSources = true }
            }
        }
        return hasLooseSources ? folder : nil
    }

    func affectsProjectDiscovery(_ event: FileSystemEvents.Event, in folder: URL) -> Bool {
        if event.requiresRescan { return true }
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                  | kFSEventStreamEventFlagItemRenamed)
        guard event.flags & structural != 0 else { return false }
        let path = URL(filePath: event.path)
        let isDirectory = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let components = (isDirectory ? path : path.deletingLastPathComponent()).pathComponents
        let relative = components.dropFirst(folder.pathComponents.count)
        return !relative.contains(where: excludesDirectory) &&
            (isDirectory || isSource(path) || manifests.contains(path.lastPathComponent))
    }

    func indexChanges(_ events: [FileSystemEvents.Event], in folder: URL) -> [LSPWatchedFileChange] {
        let root = folder.pathComponents
        let alternateRoot = folder.resolvingSymlinksInPath().pathComponents
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                  | kFSEventStreamEventFlagItemRenamed)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        return events.compactMap { event in
            let path = URL(filePath: event.path)
            let components = path.pathComponents
            let prefix = components.starts(with: root) ? root : alternateRoot
            guard components.starts(with: prefix), components.count > prefix.count,
                  !components.dropFirst(prefix.count).dropLast().contains(where: excludesDirectory),
                  isSource(path) || manifests.contains(path.lastPathComponent) else { return nil }
            let isStructural = event.flags & structural != 0
            guard isStructural || event.flags & modified != 0 else { return nil }
            let url = folder.appending(path: components.dropFirst(prefix.count).joined(separator: "/"), directoryHint: .notDirectory)
            return LSPWatchedFileChange(url: url, structural: isStructural,
                                        removed: event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0)
        }
    }

    private func nearestManifest(from directory: URL, within limit: URL?) -> URL? {
        var current = directory
        while !Task.isCancelled {
            if hasManifest(in: current) { return current }
            if current.path == limit?.path { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path.isEmpty { break }
            current = parent
        }
        return nil
    }

    private func hasManifest(in folder: URL) -> Bool {
        manifests.contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appending(path: name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func isSource(_ file: URL) -> Bool {
        LanguageServer(language: .detected(at: file)) == self
    }

    private func contains(_ url: URL, in folder: URL) -> Bool {
        url.pathComponents.starts(with: folder.pathComponents)
    }

    private func excludesDirectory(_ name: String) -> Bool {
        name.hasPrefix(".") || ["zig-cache", "zig-out", "node_modules", "deriveddata"].contains(name.lowercased())
    }
}
