import CryptoKit
import Darwin
import Foundation

struct FileFormat: Codable, Sendable, Equatable {
    var hasBOM: Bool = false
    var lineEnding: String = "\n"
}

enum FileRevision: Codable, Sendable, Equatable {
    case missing
    case contents(Data)

    fileprivate init(bytes: Data) {
        self = .contents(Data(SHA256.hash(data: bytes)))
    }
}

enum FileBufferError: LocalizedError {
    case changedOnDisk
    case invalidPath(URL)
    case notRegularFile(URL)
    case notDirectory(URL)
    case invalidUTF8(URL)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            "The file changed on disk."
        case .invalidPath(let url):
            "The path “\(url.path)” could not be used."
        case .notRegularFile(let url):
            "“\(url.lastPathComponent)” is not a regular file."
        case .notDirectory(let url):
            "“\(url.lastPathComponent)” is not a directory."
        case .invalidUTF8(let url):
            "“\(url.lastPathComponent)” is not a UTF-8 text file."
        }
    }
}

struct FileBuffer: Sendable {
    let url: URL
    let text: String
    let format: FileFormat
    let revision: FileRevision

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func canonicalURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        if let resolved = resolvedURL(url) {
            return resolved
        }

        // A new file can still have a symlink anywhere in its parent path.
        let parent = url.deletingLastPathComponent()
        if let resolvedParent = resolvedURL(parent) {
            return resolvedParent.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        }
        return url.standardizedFileURL
    }

    static func read(_ url: URL, allowMissing: Bool = false) throws -> FileBuffer {
        guard url.isFileURL else { throw FileBufferError.invalidPath(url) }
        let url = canonicalURL(url)
        guard let data = try diskContents(at: url) else {
            guard allowMissing else { throw fileError(ENOENT, url) }
            try requireDirectory(url.deletingLastPathComponent())
            return FileBuffer(url: url, text: "", format: FileFormat(), revision: .missing)
        }

        let hasBOM = data.starts(with: bom)
        let contents = hasBOM ? data.dropFirst(bom.count) : data
        guard let text = String(validating: contents, as: UTF8.self) else {
            throw FileBufferError.invalidUTF8(url)
        }

        let format = FileFormat(hasBOM: hasBOM, lineEnding: dominantLineEnding(in: text) ?? "\n")
        return FileBuffer(url: url, text: text, format: format, revision: FileRevision(bytes: data))
    }

    static func save(
        _ text: String,
        to url: URL,
        format: FileFormat,
        expected: FileRevision?
    ) throws -> FileBuffer {
        guard url.isFileURL else { throw FileBufferError.invalidPath(url) }
        let url = canonicalURL(url)
        let parent = url.deletingLastPathComponent()

        var bytes = format.hasBOM ? Data(bom) : Data()
        bytes.append(contentsOf: text.utf8)
        let revision = FileRevision(bytes: bytes)
        let temporary = parent.appendingPathComponent(".edit-\(UUID().uuidString).tmp", isDirectory: false)
        let descriptor = try withPath(temporary) { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666) }
        guard descriptor >= 0 else { throw fileError(errno, temporary) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            _ = try? withPath(temporary) { unlink($0) }
        }
        try handle.write(contentsOf: bytes)

        let status = try fileStatus(at: url)
        if status != nil && expected != .missing { try requireWritableFile(url) }
        if let status, fchmod(descriptor, status.st_mode & 0o777) != 0 {
            throw fileError(errno, temporary)
        }
        try handle.synchronize()
        try handle.close()

        // Compare again after staging so a long write cannot overwrite a change
        // that happened while the replacement was being prepared.
        if let expected {
            if expected == .missing {
                guard try fileStatus(at: url) == nil else { throw FileBufferError.changedOnDisk }
            } else {
                guard let current = try diskContents(at: url), FileRevision(bytes: current) == expected else {
                    throw FileBufferError.changedOnDisk
                }
            }
        }
        try withPath(temporary) { source in
            try withPath(url) { destination in
                if expected == .missing {
                    guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                        let code = errno
                        if code == EEXIST { throw FileBufferError.changedOnDisk }
                        throw fileError(code, url)
                    }
                } else if rename(source, destination) != 0 {
                    throw fileError(errno, url)
                }
            }
        }

        let savedFormat = FileFormat(
            hasBOM: format.hasBOM, lineEnding: dominantLineEnding(in: text) ?? format.lineEnding
        )
        return FileBuffer(url: url, text: text, format: savedFormat, revision: revision)
    }

    private static func resolvedURL(_ url: URL) -> URL? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: false, relativeTo: nil)
        }
    }

    private static func diskContents(at url: URL) throws -> Data? {
        guard try fileStatus(at: url) != nil else { return nil }

        // Nonblocking open keeps a concurrent replacement with a FIFO from blocking.
        let descriptor = try withPath(url) { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw fileError(code, url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw fileError(errno, url) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw FileBufferError.notRegularFile(url) }
        let data = try handle.readToEnd() ?? Data()

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw fileError(errno, url) }
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileBufferError.changedOnDisk
        }
        return data
    }

    private static func fileStatus(at url: URL) throws -> stat? {
        var status = stat()
        let result = try withPath(url) { lstat($0, &status) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw fileError(code, url)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw FileBufferError.notRegularFile(url) }
        return status
    }

    private static func requireWritableFile(_ url: URL) throws {
        // A rename can replace a read-only file when the directory is writable.
        let descriptor = try withPath(url) { open($0, O_WRONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw fileError(errno, url) }
        close(descriptor)
    }

    private static func requireDirectory(_ url: URL) throws {
        var status = stat()
        let result = try withPath(url) { stat($0, &status) }
        guard result == 0 else { throw fileError(errno, url) }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw FileBufferError.notDirectory(url) }
    }

    private static func withPath<Result>(
        _ url: URL,
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) throws -> Result {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw FileBufferError.invalidPath(url) }
            return try body(path)
        }
    }

    private static func fileError(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func dominantLineEnding(in text: String) -> String? {
        var counts: [String: Int] = [:]
        var separators: [String] = []
        var iterator = text.unicodeScalars.makeIterator()
        var next = iterator.next()

        while let current = next {
            next = iterator.next()
            let separator: String
            switch current.value {
            case 0x0D where next?.value == 0x0A:
                separator = "\r\n"
                next = iterator.next()
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                separator = String(current)
            default:
                continue
            }

            if counts[separator] == nil {
                separators.append(separator)
            }
            counts[separator, default: 0] += 1
        }
        return separators.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }
}
