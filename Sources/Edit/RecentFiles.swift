import Darwin
import Foundation

struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        birthSeconds = status.st_birthtimespec.tv_sec
        birthNanoseconds = status.st_birthtimespec.tv_nsec
    }

    static func at(_ url: URL) -> Self? {
        at(url, type: S_IFREG)
    }

    fileprivate static func directory(at url: URL) -> Self? {
        at(url, type: S_IFDIR)
    }

    fileprivate func isMissing(at url: URL, on volume: URL?) -> Bool {
        var status = stat()
        let error = Self.statusAt(url, &status)
        guard error == ENOENT || error == ENOTDIR else { return false }
        guard let volume, Self.statusAt(volume, &status) == 0 else { return false }
        return status.st_dev == device
    }

    private static func at(_ url: URL, type: mode_t) -> Self? {
        var status = stat()
        guard statusAt(url, &status) == 0, status.st_mode & S_IFMT == type else { return nil }
        return Self(status)
    }

    private static func statusAt(_ url: URL, _ status: inout stat) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return stat(path, &status) == 0 ? 0 : errno
        }
    }
}

struct RecentFile: Codable, Hashable, Sendable {
    let url: URL
    let canonicalURL: URL
    let identity: FileIdentity
    let volume: URL?
    let opened: Date
    fileprivate var project: URL? = nil

    static func read(_ url: URL) -> Self? {
        let url = url.standardizedFileURL
        let canonical = FileBuffer.canonicalURL(url)
        guard let identity = FileIdentity.at(canonical) else { return nil }
        let volume = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume
        return Self(url: url, canonicalURL: canonical, identity: identity, volume: volume, opened: Date())
    }

    var isMissing: Bool {
        identity.isMissing(at: url, on: volume)
    }

    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

struct RecentFolder: Codable, Hashable, Sendable {
    let url: URL
    let canonicalURL: URL
    let identity: FileIdentity
    let volume: URL?
    let opened: Date
    fileprivate var lastFileURL: URL?

    fileprivate static func read(_ url: URL) -> Self? {
        let url = url.standardizedFileURL
        let canonical = FileBuffer.canonicalURL(url)
        guard let identity = FileIdentity.directory(at: canonical) else { return nil }
        let volume = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume
        return Self(url: url, canonicalURL: canonical, identity: identity, volume: volume, opened: Date())
    }

    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    fileprivate var isMissing: Bool {
        identity.isMissing(at: url, on: volume)
    }

    fileprivate func contains(_ file: URL) -> Bool {
        let folderPath = canonicalURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return file.path.hasPrefix(prefix)
    }
}

@MainActor
final class RecentFiles {
    private struct FileKeys {
        var paths: Set<URL> = []
        var canonicalPaths: Set<URL> = []
        var identities: Set<FileIdentity> = []

        mutating func insert(_ entry: RecentFile) -> Bool {
            guard !paths.contains(entry.url), !canonicalPaths.contains(entry.canonicalURL),
                  !identities.contains(entry.identity) else { return false }
            paths.insert(entry.url)
            canonicalPaths.insert(entry.canonicalURL)
            identities.insert(entry.identity)
            return true
        }
    }

    private struct History: Codable, Sendable {
        var files: [RecentFile]
        var folders: [RecentFolder]
        var positions: [SavedPosition]? = nil
    }

    private struct SavedPosition: Codable, Sendable {
        var url: URL
        var identity: FileIdentity?
        var position: EditorPosition

        func matches(_ url: URL, identity: FileIdentity?) -> Bool {
            self.url == url || (identity != nil && self.identity == identity)
        }
    }

    private static let positionLimit = 100
    private nonisolated static let fileLimit = 500
    private let url: URL
    private let initialRead: Task<History, Never>
    private var loaded = false
    private var recording: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private(set) var entries: [RecentFile] = []
    private(set) var folders: [RecentFolder] = []
    private var positions: [SavedPosition] = []

    init(url: URL) {
        self.url = url
        initialRead = Task.detached(priority: .utility) {
            guard let bytes = try? Data(contentsOf: url) else { return History(files: [], folders: []) }
            let decoder = JSONDecoder()
            let history = try? decoder.decode(History.self, from: bytes)
            let legacyFiles = history == nil ? try? decoder.decode([RecentFile].self, from: bytes) : nil
            let folders = history?.folders ?? []
            let files = Self.assignProjects(to: history?.files ?? legacyFiles ?? [], using: folders)
            return History(files: files, folders: folders,
                           positions: history?.positions)
        }
    }

    func entries(in folder: URL?) -> [RecentFile] {
        let project = folder?.path
        var seen = FileKeys()
        return entries.filter { ($0.project == nil || $0.project?.path == project) && seen.insert($0) }
    }

    func load() async {
        guard !loaded else { return }
        let existing = await initialRead.value
        if !loaded {
            entries = existing.files
            folders = existing.folders
            positions = Array((existing.positions ?? []).prefix(Self.positionLimit))
            loaded = true
        }
    }

    func record(_ url: URL, in folder: URL? = nil, rememberInFolder: Bool = true) async {
        let metadata = Task.detached {
            let entry = RecentFile.read(url)
            let canonicalFolder = folder.map(FileBuffer.canonicalURL)
            return (entry, canonicalFolder)
        }
        await enqueueRecording {
            let (entry, canonicalFolder) = await metadata.value
            guard let entry else { return }
            self.promote(entry, in: canonicalFolder, rememberInFolder: rememberInFolder)
            self.persist()
        }.value
    }

    func recordFolder(_ url: URL, opening file: URL? = nil) async {
        let metadata = Task.detached { (RecentFolder.read(url), file.flatMap(RecentFile.read)) }
        await enqueueRecording {
            let (recordedFolder, openedFile) = await metadata.value
            guard var folder = recordedFolder else { return }
            let matches: (RecentFolder) -> Bool = { [folder] in
                $0.url.path == folder.url.path || $0.canonicalURL == folder.canonicalURL || $0.identity == folder.identity
            }
            folder.lastFileURL = self.folders.lazy.filter(matches).compactMap(\.lastFileURL).first(where: folder.contains)
            let isNewRoot = !self.folders.contains { $0.canonicalURL.path == folder.canonicalURL.path }
            self.folders.removeAll(where: matches)
            self.folders.insert(folder, at: 0)
            if isNewRoot { self.entries = Self.assignProjects(to: self.entries, using: self.folders) }
            if let openedFile { self.promote(openedFile, in: folder.canonicalURL) }
            self.persist()
        }.value
    }

    func rememberPosition(_ position: EditorPosition, for url: URL, identity: FileIdentity?) {
        let canonical = Task.detached { FileBuffer.canonicalURL(url) }
        enqueueRecording {
            let target = await canonical.value
            self.positions.removeAll { $0.matches(target, identity: identity) }
            self.positions.insert(SavedPosition(url: target, identity: identity, position: position), at: 0)
            if self.positions.count > Self.positionLimit { self.positions.removeLast() }
            self.persist()
        }
    }

    func position(for url: URL, identity: FileIdentity?) async -> EditorPosition? {
        let canonical = Task.detached { FileBuffer.canonicalURL(url) }
        await recording?.value
        await load()
        let target = await canonical.value
        return positions.first { $0.matches(target, identity: identity) }?.position
    }

    private func promote(_ opened: RecentFile, in canonicalFolder: URL?, rememberInFolder: Bool = true) {
        var entry = opened
        let owner = folders.lazy.filter { $0.contains(entry.canonicalURL) }
            .max { $0.canonicalURL.path.count < $1.canonicalURL.path.count }?.canonicalURL
        // A known project owns files under its root, even when opened from a different window.
        // For other paths, keep the context of the explicit open instead of promoting them globally.
        if let canonicalFolder, FolderFileSearch.relativeDirectory(of: entry.canonicalURL, in: canonicalFolder) != nil,
           canonicalFolder.path.count > (owner?.path.count ?? 0) {
            entry.project = canonicalFolder
        } else {
            entry.project = owner ?? canonicalFolder
        }
        let bucket = entry.project?.path
        var count = 0
        entries.removeAll { previous in
            guard previous.project?.path == bucket else { return false }
            if previous.url == entry.url || previous.canonicalURL == entry.canonicalURL || previous.identity == entry.identity {
                return true
            }
            count += 1
            return count >= Self.fileLimit
        }
        entries.insert(entry, at: 0)
        if rememberInFolder, let canonicalFolder, let index = folders.firstIndex(where: { $0.canonicalURL == canonicalFolder }),
           folders[index].contains(entry.canonicalURL) {
            folders[index].lastFileURL = entry.canonicalURL
        }
    }

    private nonisolated static func assignProjects(to files: [RecentFile], using folders: [RecentFolder]) -> [RecentFile] {
        let roots = folders.sorted { $0.canonicalURL.path.count > $1.canonicalURL.path.count }
        var buckets: [String?: FileKeys] = [:]
        return files.compactMap { file in
            var entry = file
            // Old archives have no opening context. Recover it from previously opened roots where possible.
            let recordedRootLength = file.project.flatMap { project in
                FolderFileSearch.relativeDirectory(of: file.canonicalURL, in: project).map { _ in project.path.count }
            } ?? 0
            if let owner = roots.first(where: { $0.contains(file.canonicalURL) })?.canonicalURL,
               owner.path.count > recordedRootLength {
                entry.project = owner
            }
            let scope = entry.project?.path
            return keep(entry, in: &buckets[scope, default: FileKeys()]) ? entry : nil
        }

        func keep(_ entry: RecentFile, in bucket: inout FileKeys) -> Bool {
            bucket.paths.count < fileLimit && bucket.insert(entry)
        }
    }

    func lastFile(in folder: URL) async -> URL? {
        let canonical = Task.detached { FileBuffer.canonicalURL(folder) }
        await recording?.value
        await load()
        let canonicalFolder = await canonical.value
        return folders.first(where: { $0.canonicalURL == canonicalFolder })?.lastFileURL
    }

    @discardableResult
    private func enqueueRecording(_ update: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = recording
        let operation = Task {
            await previous?.value
            await load()
            await update()
        }
        recording = operation
        return operation
    }

    func dismiss(_ entry: RecentFile) {
        entries.removeAll {
            $0.project?.path == entry.project?.path && ($0.identity == entry.identity || $0.canonicalURL == entry.canonicalURL)
        }
        persist()
    }

    func prune() async {
        await load()
        let snapshot = History(files: entries, folders: folders)
        let (missingFiles, missingFolders) = await Task.detached(priority: .utility) {
            (Set(snapshot.files.filter(\.isMissing)), Set(snapshot.folders.filter(\.isMissing)))
        }.value
        let previousCount = entries.count + folders.count
        entries.removeAll { missingFiles.contains($0) }
        folders.removeAll { missingFolders.contains($0) }
        if entries.count + folders.count != previousCount { persist() }
    }

    func removeIfMissing(_ url: URL) async {
        let candidates = entries.filter { $0.url == url }
        let missing = await Task.detached { Set(candidates.filter(\.isMissing)) }.value
        let previousCount = entries.count
        entries.removeAll { missing.contains($0) }
        if entries.count != previousCount {
            persist()
        }
        if let folder = folders.first(where: { $0.url.path == url.path }),
           await Task.detached(operation: { folder.isMissing }).value, folders.contains(folder) {
            folders.removeAll { $0 == folder }
            persist()
        }
    }

    func finishWrites() async {
        await recording?.value
        await writing?.value
    }

    private func persist() {
        let snapshot = History(files: entries, folders: folders, positions: positions.isEmpty ? nil : positions)
        let previous = writing
        let url = url
        writing = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                NSLog("Could not save recent files and folders: %@", error.localizedDescription)
            }
        }
    }
}
