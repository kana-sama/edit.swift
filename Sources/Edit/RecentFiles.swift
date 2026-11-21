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
    private struct History: Codable, Sendable {
        var files: [RecentFile]
        var folders: [RecentFolder]
    }

    private let url: URL
    private let initialRead: Task<History, Never>
    private var loaded = false
    private var recording: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private(set) var entries: [RecentFile] = []
    private(set) var folders: [RecentFolder] = []

    init(url: URL) {
        self.url = url
        initialRead = Task.detached(priority: .utility) {
            guard let bytes = try? Data(contentsOf: url) else { return History(files: [], folders: []) }
            let decoder = JSONDecoder()
            let history = try? decoder.decode(History.self, from: bytes)
            let legacyFiles = history == nil ? try? decoder.decode([RecentFile].self, from: bytes) : nil
            let files = history?.files ?? legacyFiles ?? []
            return History(files: Array(files.prefix(500)), folders: history?.folders ?? [])
        }
    }

    func load() async {
        guard !loaded else { return }
        let existing = await initialRead.value
        if !loaded {
            entries = existing.files
            folders = existing.folders
            loaded = true
        }
    }

    func record(_ url: URL, in folder: URL? = nil) async {
        let metadata = Task.detached {
            let entry = RecentFile.read(url)
            let canonicalFolder = folder.map(FileBuffer.canonicalURL)
            return (entry, canonicalFolder)
        }
        await enqueueRecording {
            let (entry, canonicalFolder) = await metadata.value
            guard let entry else { return }
            self.promote(entry, in: canonicalFolder)
            self.persist()
        }
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
            self.folders.removeAll(where: matches)
            self.folders.insert(folder, at: 0)
            if let openedFile { self.promote(openedFile, in: folder.canonicalURL) }
            self.persist()
        }
    }

    private func promote(_ entry: RecentFile, in canonicalFolder: URL?) {
        entries.removeAll {
            $0.url == entry.url || $0.canonicalURL == entry.canonicalURL || $0.identity == entry.identity
        }
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        if let canonicalFolder, let index = folders.firstIndex(where: { $0.canonicalURL == canonicalFolder }),
           folders[index].contains(entry.canonicalURL) {
            folders[index].lastFileURL = entry.canonicalURL
        }
    }

    func lastFile(in folder: URL) async -> URL? {
        let canonical = Task.detached { FileBuffer.canonicalURL(folder) }
        await recording?.value
        await load()
        let canonicalFolder = await canonical.value
        return folders.first(where: { $0.canonicalURL == canonicalFolder })?.lastFileURL
    }

    private func enqueueRecording(_ update: @escaping @MainActor () async -> Void) async {
        let previous = recording
        let operation = Task {
            await previous?.value
            await load()
            await update()
        }
        recording = operation
        await operation.value
    }

    func dismiss(_ entry: RecentFile) {
        entries.removeAll { $0.identity == entry.identity || $0.canonicalURL == entry.canonicalURL }
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
        if let entry = entries.first(where: { $0.url == url }),
           await Task.detached(operation: { entry.isMissing }).value, entries.contains(entry) {
            dismiss(entry)
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
        let snapshot = History(files: entries, folders: folders)
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
