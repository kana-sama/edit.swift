import Darwin
import Foundation

enum WorktreeFileOperations {
    struct Transfer: Sendable {
        let source: URL
        let destination: URL
    }

    struct TransferResult: Sendable {
        let completed: [Transfer]
        let failure: String?
    }

    static func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        // Foundation can keep the private prefix once the original has been moved away.
        for alias in ["/private/var", "/private/tmp", "/private/etc"] {
            if path == alias || path.hasPrefix(alias + "/") { return String(path.dropFirst("/private".count)) }
        }
        return path
    }

    static func contains(_ item: URL, in directory: URL) -> Bool {
        let parent = path(directory)
        let path = path(item)
        return path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    static func create(_ path: String, in directory: URL, root: URL, isDirectory: Bool) throws -> URL {
        let components = try nameComponents(path)
        let folder = try writableDirectory(directory, within: root)
        var parent = folder
        var createdParents: [URL] = []
        do {
            for component in components.dropLast() {
                let child = parent.appending(path: component, directoryHint: .isDirectory)
                if try itemStatus(at: child) == nil {
                    try makeDirectory(at: child)
                    createdParents.append(child)
                }
                parent = try writableDirectory(child, within: root)
            }
            let target = parent.appending(path: components[components.count - 1],
                                          directoryHint: isDirectory ? .isDirectory : .notDirectory)
            guard try itemStatus(at: target) == nil else { throw conflict(at: target) }
            if isDirectory {
                try makeDirectory(at: target)
            } else {
                try Data().write(to: target, options: .withoutOverwriting)
            }
            return target
        } catch {
            for created in createdParents.reversed() {
                // Keep a directory if another process added content after it was created.
                _ = created.withUnsafeFileSystemRepresentation { path in
                    path.map { rmdir($0) } ?? -1
                }
            }
            throw error
        }
    }

    static func rename(_ item: URL, to name: String, within root: URL) throws -> Transfer? {
        guard contains(item, in: root), item.standardizedFileURL.path != root.standardizedFileURL.path else {
            throw outside(item)
        }
        let components = try nameComponents(name)
        guard components.count == 1 else { throw WorktreeError.invalidName }
        let parent = try writableDirectory(item.deletingLastPathComponent(), within: root)
        let source = parent.appending(path: item.lastPathComponent)
        let destination = parent.appending(path: name)
        guard source.path != destination.path else { return nil }

        try moveExclusively(from: source, to: destination)
        return Transfer(source: source, destination: destination)
    }

    static func canTrash(_ item: URL, within root: URL) -> Bool {
        contains(item, in: root) && path(item) != path(root)
    }

    static func trashTargets(_ items: [URL], within root: URL) throws -> [URL] {
        var paths: Set<String> = []
        let targets = try items.compactMap { item -> URL? in
            guard canTrash(item, within: root) else { throw outside(item) }
            let parent = try writableDirectory(item.deletingLastPathComponent(), within: root)
            let target = parent.appending(path: item.lastPathComponent)
            return paths.insert(target.path).inserted ? target : nil
        }
        let roots = targets.filter { !containsSelectedParent(of: $0, in: paths) }
        for target in roots {
            guard try itemStatus(at: target) != nil else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: target.path])
            }
        }
        return roots
    }

    static func restoreTrashed(_ transfers: [Transfer], within root: URL) -> TransferResult {
        var completed: [Transfer] = []
        var failure: String?
        for transfer in transfers {
            do {
                guard canTrash(transfer.source, within: root) else { throw outside(transfer.source) }
                let parent = try writableDirectory(transfer.source.deletingLastPathComponent(), within: root)
                let original = parent.appending(path: transfer.source.lastPathComponent)
                try moveExclusively(from: transfer.destination, to: original)
                completed.append(transfer)
            } catch {
                if failure == nil { failure = error.localizedDescription }
            }
        }
        return TransferResult(completed: completed, failure: failure)
    }

    private static func moveExclusively(from source: URL, to destination: URL) throws {
        // RENAME_EXCL also handles capitalization-only renames on case-insensitive volumes.
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                return renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            if result == EEXIST { throw conflict(at: destination) }
            throw pathError(result, path: source.path)
        }
    }

    static func transfer(_ sources: [URL], into destination: URL, move: Bool, within root: URL) throws -> TransferResult {
        let folder = try writableDirectory(destination, within: root)
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var uniqueSources: Set<String> = []
        var candidates: [URL] = []
        for url in sources {
            guard url.isFileURL, url.standardizedFileURL.path != "/" else { throw outside(url) }
            // Resolve ancestors but keep a symlink as the entry being transferred.
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let source = parent.appending(path: url.lastPathComponent)
            if uniqueSources.insert(source.path).inserted { candidates.append(source) }
        }
        var transfers: [Transfer] = []
        var targetPaths: Set<String> = []
        for source in candidates {
            if containsSelectedParent(of: source, in: uniqueSources) { continue }
            guard source.path != root.path, !contains(folder, in: source) else { throw WorktreeError.recursiveTransfer }
            let target = folder.appending(path: source.lastPathComponent)
            if move && target.path == source.path { continue }
            guard try itemStatus(at: source) != nil else { throw CocoaError(.fileNoSuchFile) }
            guard targetPaths.insert(target.path).inserted, try itemStatus(at: target) == nil else {
                throw conflict(at: target)
            }
            transfers.append(Transfer(source: source, destination: target))
        }

        let files = FileManager.default
        var completed: [Transfer] = []
        for transfer in transfers {
            do {
                if move {
                    try files.moveItem(at: transfer.source, to: transfer.destination)
                } else {
                    try files.copyItem(at: transfer.source, to: transfer.destination)
                }
                completed.append(transfer)
            } catch {
                return TransferResult(completed: completed, failure: error.localizedDescription)
            }
        }
        return TransferResult(completed: completed, failure: nil)
    }

    static func isUnderSelection(_ item: URL, paths: Set<String>) -> Bool {
        let itemPath = path(item)
        return paths.contains(itemPath) || containsSelectedParent(of: URL(filePath: itemPath), in: paths)
    }

    private static func containsSelectedParent(of source: URL, in paths: Set<String>) -> Bool {
        var parent = source.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            if paths.contains(parent.path) { return true }
            parent.deleteLastPathComponent()
        }
        return false
    }

    private static func nameComponents(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, !path.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorktreeError.invalidName
        }
        return components
    }

    private static func writableDirectory(_ directory: URL, within root: URL) throws -> URL {
        guard directory.isFileURL, root.isFileURL, contains(directory, in: root) else { throw outside(directory) }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let boundary = root.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, in: boundary) else { throw outside(directory) }
        guard let status = try itemStatus(at: resolved), (status.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: resolved.path])
        }
        return resolved
    }

    private static func itemStatus(at url: URL) throws -> stat? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return lstat(path, &status) == 0 ? 0 : errno
        }
        if result == ENOENT { return nil }
        guard result == 0 else { throw pathError(result, path: url.path) }
        return status
    }

    private static func makeDirectory(at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return mkdir(path, 0o777) == 0 ? 0 : errno
        }
        guard result == 0 else {
            if result == EEXIST { throw conflict(at: url) }
            throw pathError(result, path: url.path)
        }
    }

    private static func conflict(at url: URL) -> CocoaError {
        CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func pathError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    private static func outside(_ url: URL) -> WorktreeError { .outside(url.lastPathComponent) }

    private enum WorktreeError: LocalizedError {
        case invalidName
        case outside(String)
        case recursiveTransfer

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a valid name or relative path."
            case .outside(let name): return "“\(name)” is outside the open folder."
            case .recursiveTransfer: return "A folder can’t be placed inside itself."
            }
        }
    }
}
