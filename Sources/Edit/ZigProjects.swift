import CoreServices
import Foundation

enum ZigProjects {
    private static let manifests = ["build.zig", "build.zig.zon"]
    private static let generatedDirectories: Set<String> = ["zig-cache", "zig-out", "node_modules"]

    static func root(in directory: URL, activeFile: URL?, previousRoot: URL?, searchesParents: Bool) -> URL? {
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL
        if let file = activeFile?.resolvingSymlinksInPath().standardizedFileURL,
           isZigSource(file), contains(file, in: folder), FileManager.default.fileExists(atPath: file.path) {
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
                if isZigSource(url) { hasLooseSources = true }
            }
        }
        return hasLooseSources ? folder : nil
    }

    static func affectsDiscovery(_ event: FileSystemEvents.Event, in folder: URL) -> Bool {
        if event.requiresRescan { return true }
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                  | kFSEventStreamEventFlagItemRenamed)
        guard event.flags & structural != 0 else { return false }
        let path = URL(filePath: event.path)
        let isDirectory = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        let components = (isDirectory ? path : path.deletingLastPathComponent()).pathComponents
        let relative = components.dropFirst(folder.pathComponents.count)
        return !relative.contains(where: excludesDirectory) && (isDirectory || isZigSource(path))
    }

    private static func nearestManifest(from directory: URL, within limit: URL?) -> URL? {
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

    private static func hasManifest(in folder: URL) -> Bool {
        manifests.contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appending(path: name).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private static func isZigSource(_ file: URL) -> Bool {
        let suffix = file.pathExtension.lowercased()
        return suffix == "zig" || suffix == "zon"
    }

    private static func contains(_ url: URL, in folder: URL) -> Bool {
        url.pathComponents.starts(with: folder.pathComponents)
    }

    private static func excludesDirectory(_ name: String) -> Bool {
        name.hasPrefix(".") || generatedDirectories.contains(name.lowercased())
    }
}
