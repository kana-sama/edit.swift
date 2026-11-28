import CryptoKit
import Darwin
import Foundation

/// Owns the generated sources and both Zig caches for a project and toolchain.
/// The group lock protects those files while a terminal is using them.
final class ZigTestCache: Sendable {
    private static let retention: TimeInterval = 14 * 24 * 60 * 60
    private static let releaseGrace: TimeInterval = 2
    private static let byteLimit: Int64 = 1_024 * 1_024 * 1_024
    private static let groupLimit = 24
    private static let marker = "last-use"
    private static let isolatedBase = FileManager.default.temporaryDirectory.appending(path: "Edit-Check-\(UUID())")

    private let root: URL
    let directory: URL
    private let descriptor: Int32

    var local: URL { directory.appending(path: "local", directoryHint: .isDirectory) }
    var global: URL { directory.appending(path: "global", directoryHint: .isDirectory) }

    private init(root: URL, directory: URL, descriptor: Int32) {
        self.root = root
        self.directory = directory
        self.descriptor = descriptor
    }

    deinit {
        try? Self.touch(directory)
        Darwin.close(descriptor)
        let root = root
        Task.detached(priority: .utility) {
            // A closing terminal may still be reaping Zig and its subprocesses.
            try? await Task.sleep(for: .seconds(Self.releaseGrace))
            try? Self.prune(in: root)
        }
    }

    static func location(isolated: Bool) -> URL {
        let base: URL
        if isolated {
            let profile = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }
            base = profile.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? isolatedBase
        } else {
            base = .cachesDirectory
        }
        return base.appending(path: "dev.edit-swift.zig-tests", directoryHint: .isDirectory)
    }

    static func prepare(in root: URL, project: URL, executable: URL, inputs: [String],
                        arguments: (URL, URL?) throws -> [String]) throws -> (ZigTestCache, [String]) {
        let files = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: permissions)
        return try withRootLock(in: root) {
            let group = key([project.path, executable.resolvingSymlinksInPath().path])
            let directory = root.appending(path: group, directoryHint: .isDirectory)
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: permissions)
            let descriptor = try lock(directory.appending(path: marker), operation: LOCK_SH)
            let cache = ZigTestCache(root: root, directory: directory, descriptor: descriptor)
            try touch(directory)

            let generated = directory.appending(path: key(inputs), directoryHint: .isDirectory)
            if files.fileExists(atPath: generated.path) {
                return (cache, try arguments(generated, nil))
            }
            // Publish generated inputs together. An interrupted write leaves only
            // this staging directory, which the next preparation can replace.
            let staging = directory.appending(path: ".staging", directoryHint: .isDirectory)
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: permissions)
            defer { try? files.removeItem(at: staging) }
            let invocation = try arguments(generated, staging)
            try files.moveItem(at: staging, to: generated)
            return (cache, invocation)
        }
    }

    static func prune(in root: URL, now: Date = .now, maximumBytes: Int64 = byteLimit,
                      maximumGroups: Int = groupLimit) throws {
        try withRootLock(in: root) {
            let files = FileManager.default
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            let groups = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).compactMap { directory in
                let name = directory.lastPathComponent
                guard name.count == 64, name.allSatisfy(\.isHexDigit),
                      let values = try? directory.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { return nil as Group? }
                let lastUse = (try? directory.appending(path: marker).resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return Group(directory: directory, lastUse: lastUse, bytes: allocatedSize(in: directory))
            }.sorted { $0.lastUse < $1.lastUse }

            var remaining = groups.count
            var bytes = groups.reduce(Int64(0)) { $0 + $1.bytes }
            for group in groups {
                let age = now.timeIntervalSince(group.lastUse)
                guard age >= releaseGrace,
                      age >= retention || remaining > maximumGroups || bytes > maximumBytes,
                      let descriptor = try? lock(group.directory.appending(path: marker), operation: LOCK_EX | LOCK_NB) else {
                    continue
                }
                defer { Darwin.close(descriptor) }
                do {
                    try files.removeItem(at: group.directory)
                    remaining -= 1
                    bytes -= group.bytes
                } catch {
                    // A failed deletion can be retried on the next sweep.
                }
            }
        }
    }

    private struct Group {
        let directory: URL
        let lastUse: Date
        let bytes: Int64
    }

    private static func allocatedSize(in directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let entry as URL in entries {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func touch(_ directory: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now],
                                               ofItemAtPath: directory.appending(path: marker).path)
    }

    private static func key(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func withRootLock<T>(in root: URL, _ body: () throws -> T) throws -> T {
        let descriptor = try lock(root.appending(path: "lock"), operation: LOCK_EX)
        defer { Darwin.close(descriptor) }
        return try body()
    }

    private static func lock(_ file: URL, operation: Int32) throws -> Int32 {
        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(descriptor, operation) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return descriptor
    }
}
