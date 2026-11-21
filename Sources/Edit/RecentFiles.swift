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
        var status = stat()
        guard statusAt(url, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(status)
    }

    fileprivate static func statusAt(_ url: URL, _ status: inout stat) -> Int32 {
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
        var status = stat()
        let error = FileIdentity.statusAt(url, &status)
        guard error == ENOENT || error == ENOTDIR else { return false }
        guard let volume, FileIdentity.statusAt(volume, &status) == 0 else { return false }
        return status.st_dev == identity.device
    }

    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

@MainActor
final class RecentFiles {
    private let url: URL
    private let initialRead: Task<[RecentFile], Never>
    private var loaded = false
    private var recording: Task<Void, Never>?
    private var writing: Task<Void, Never>?
    private(set) var entries: [RecentFile] = []

    init(url: URL) {
        self.url = url
        initialRead = Task.detached(priority: .utility) {
            guard let bytes = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([RecentFile].self, from: bytes) else { return [] }
            return Array(entries.prefix(500))
        }
    }

    func load() async {
        guard !loaded else { return }
        let existing = await initialRead.value
        if !loaded {
            entries = existing
            loaded = true
        }
    }

    func record(_ url: URL) async {
        let metadata = Task.detached { RecentFile.read(url) }
        let previous = recording
        let operation = Task {
            await previous?.value
            guard let entry = await metadata.value else { return }
            await load()
            entries.removeAll {
                $0.url == entry.url || $0.canonicalURL == entry.canonicalURL || $0.identity == entry.identity
            }
            entries.insert(entry, at: 0)
            if entries.count > 500 { entries.removeLast(entries.count - 500) }
            persist()
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
        let snapshot = entries
        let missing = await Task.detached(priority: .utility) { Set(snapshot.filter(\.isMissing)) }.value
        let previousCount = entries.count
        entries.removeAll { missing.contains($0) }
        if entries.count != previousCount { persist() }
    }

    func removeIfMissing(_ url: URL) async {
        guard let entry = entries.first(where: { $0.url == url }) else { return }
        guard await Task.detached(operation: { entry.isMissing }).value, entries.contains(entry) else { return }
        dismiss(entry)
    }

    func finishWrites() async {
        await recording?.value
        await writing?.value
    }

    private func persist() {
        let snapshot = entries
        let previous = writing
        let url = url
        writing = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                NSLog("Could not save recent files: %@", error.localizedDescription)
            }
        }
    }
}
