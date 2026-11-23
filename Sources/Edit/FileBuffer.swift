import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum FileTextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8, utf16LE, utf16BE, utf32LE, utf32BE
    case macOSRoman, windowsCP1251, windowsCP1252, isoLatin1, shiftJIS

    private static let unicodeBOMs: [Self] = [.utf32LE, .utf32BE, .utf8, .utf16LE, .utf16BE]

    var foundation: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .utf32LE: .utf32LittleEndian
        case .utf32BE: .utf32BigEndian
        case .macOSRoman: .macOSRoman
        case .windowsCP1251: .windowsCP1251
        case .windowsCP1252: .windowsCP1252
        case .isoLatin1: .isoLatin1
        case .shiftJIS: .shiftJIS
        }
    }

    var title: String { NSString.localizedName(of: foundation.rawValue) }

    var bom: [UInt8] {
        switch self {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LE: [0xFF, 0xFE]
        case .utf16BE: [0xFE, 0xFF]
        case .utf32LE: [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BE: [0x00, 0x00, 0xFE, 0xFF]
        default: []
        }
    }

    static func fromBOM(in data: Data) -> Self? {
        unicodeBOMs.first { data.starts(with: $0.bom) }
    }

    private var coreFoundation: CFStringEncoding {
        CFStringConvertNSStringEncodingToEncoding(foundation.rawValue)
    }

    var attributeValue: String {
        let name = CFStringConvertEncodingToIANACharSetName(coreFoundation) as String? ?? ""
        return "\(name);\(coreFoundation)"
    }

    static func fromAttribute(_ attribute: String) -> Self? {
        let fields = attribute.split(separator: ";", omittingEmptySubsequences: false)
        if fields.count > 1, let value = UInt32(fields[1].prefix(while: { $0.isNumber })),
           let encoding = allCases.first(where: { $0.coreFoundation == value }) {
            return encoding
        }
        guard let name = fields.first, !name.isEmpty else { return nil }
        let value = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        return allCases.first { $0.coreFoundation == value }
    }
}

struct FileFormat: Codable, Sendable, Equatable {
    var hasBOM: Bool = false
    var lineEnding: String = "\n"
    // A missing encoding in older session drafts represents UTF-8.
    var storedEncoding: FileTextEncoding?
    var encoding: FileTextEncoding { storedEncoding ?? .utf8 }

    func using(_ newEncoding: FileTextEncoding) -> Self {
        guard newEncoding != encoding else { return self }
        return Self(hasBOM: newEncoding != .utf8 && !newEncoding.bom.isEmpty, lineEnding: lineEnding,
                    storedEncoding: newEncoding == .utf8 ? nil : newEncoding)
    }
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
    case multipleHardLinks
    case invalidPath(URL)
    case notRegularFile(URL)
    case notDirectory(URL)
    case invalidText(URL, FileTextEncoding)
    case unrepresentableText(FileTextEncoding)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            "The file changed on disk."
        case .multipleHardLinks:
            "This file has multiple hard links. Use Save As with a different name to keep the linked file intact."
        case .invalidPath(let url):
            "The path “\(url.path)” could not be used."
        case .notRegularFile(let url):
            "“\(url.lastPathComponent)” is not a regular file."
        case .notDirectory(let url):
            "“\(url.lastPathComponent)” is not a directory."
        case .invalidText(let url, let encoding):
            "“\(url.lastPathComponent)” could not be read as \(encoding.title)."
        case .unrepresentableText(let encoding):
            "Some characters cannot be saved as \(encoding.title). Choose an encoding that supports them."
        }
    }
}

struct FileBuffer: Sendable {
    struct SaveResult: Sendable {
        let file: FileBuffer
        let replacedIdentity: FileIdentity?
    }

    struct DiskStamp: Equatable, Sendable {
        let identity: FileIdentity
        private let size: off_t
        private let links: nlink_t
        private let modifiedSeconds: Int
        private let modifiedNanoseconds: Int
        private let changedSeconds: Int
        private let changedNanoseconds: Int

        fileprivate init(_ status: stat) {
            identity = FileIdentity(status)
            size = status.st_size
            links = status.st_nlink
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    private struct DiskFile {
        let handle: FileHandle
        let status: stat
    }

    let url: URL
    let text: String
    let format: FileFormat
    let revision: FileRevision
    let diskStamp: DiskStamp?
    var identity: FileIdentity? { diskStamp?.identity }

    private static let encodingAttribute = "com.apple.TextEncoding"

    static func revision(at url: URL) throws -> FileRevision {
        guard let contents = try diskContents(at: url) else { return .missing }
        return FileRevision(bytes: contents.bytes)
    }

    static func readIfChanged(_ url: URL, since stamp: DiskStamp?) throws -> FileBuffer? {
        guard let status = try fileStatus(at: url), DiskStamp(status) != stamp else { return nil }
        return try read(url)
    }

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
        guard let disk = try diskContents(at: url, readEncoding: true) else {
            guard allowMissing else { throw fileError(ENOENT, url) }
            try requireDirectory(url.deletingLastPathComponent())
            return FileBuffer(url: url, text: "", format: FileFormat(), revision: .missing, diskStamp: nil)
        }

        let taggedBOM = disk.encoding.flatMap { encoding in
            !encoding.bom.isEmpty && disk.bytes.starts(with: encoding.bom) ? encoding : nil
        }
        let bomEncoding = taggedBOM ?? FileTextEncoding.fromBOM(in: disk.bytes)
        let encoding = bomEncoding ?? disk.encoding ?? .utf8
        let contents = disk.bytes.dropFirst(bomEncoding?.bom.count ?? 0)
        let decoded = encoding == .utf8
            ? String(validating: contents, as: UTF8.self)
            : String(data: contents, encoding: encoding.foundation)
        guard let text = decoded else { throw FileBufferError.invalidText(url, encoding) }

        let format = FileFormat(hasBOM: bomEncoding != nil, lineEnding: dominantLineEnding(in: text) ?? "\n",
                                storedEncoding: encoding == .utf8 ? nil : encoding)
        return FileBuffer(url: url, text: text, format: format, revision: FileRevision(bytes: disk.bytes), diskStamp: disk.stamp)
    }

    static func save(
        _ text: String,
        to url: URL,
        format: FileFormat,
        expected: FileRevision?
    ) throws -> SaveResult {
        guard url.isFileURL else { throw FileBufferError.invalidPath(url) }
        let url = canonicalURL(url)
        let encoding = format.encoding
        var bytes = format.hasBOM ? Data(encoding.bom) : Data()
        if encoding == .utf8 {
            bytes.append(contentsOf: text.utf8)
        } else {
            guard let encoded = text.data(using: encoding.foundation, allowLossyConversion: false),
                  let roundTrip = String(data: encoded, encoding: encoding.foundation),
                  roundTrip.utf16.elementsEqual(text.utf16) else {
                throw FileBufferError.unrepresentableText(encoding)
            }
            bytes.append(encoded)
        }

        if try expected == .missing || (expected == nil && fileStatus(at: url) == nil) {
            return try publish(bytes, text: text, to: url, format: format, expected: .missing)
        }

        // Keep version validation and replacement in the same coordinator access. The
        // revision check also protects against earlier changes by uncoordinated writers.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var outcome: Result<SaveResult, Error>?
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            outcome = Result { try publish(bytes, text: text, to: target, format: format, expected: expected) }
        }
        if let outcome { return try outcome.get() }
        if let coordinationError { throw coordinationError }
        throw CocoaError(.fileWriteUnknown)
    }

    private static func publish(
        _ bytes: Data, text: String, to url: URL, format: FileFormat, expected: FileRevision?
    ) throws -> SaveResult {
        let parent = url.deletingLastPathComponent()
        let encoding = format.encoding
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

        let original: DiskFile?
        if expected == .missing {
            original = nil
            guard try fileStatus(at: url) == nil else { throw FileBufferError.changedOnDisk }
        } else {
            original = try openFile(at: url, access: expected == nil ? O_WRONLY : O_RDWR)
        }
        defer { try? original?.handle.close() }
        if let original {
            guard original.status.st_nlink == 1 else { throw FileBufferError.multipleHardLinks }
            if let expected {
                let current = try original.handle.readToEnd() ?? Data()
                guard FileRevision(bytes: current) == expected else { throw FileBufferError.changedOnDisk }
            }
            guard fcopyfile(original.handle.fileDescriptor, descriptor, nil, UInt32(COPYFILE_XATTR)) == 0 else {
                throw fileError(errno, url)
            }
        } else if expected != nil && expected != .missing {
            throw FileBufferError.changedOnDisk
        }

        let ambiguousBOM = encoding == .utf16LE && bytes.starts(with: FileTextEncoding.utf32LE.bom)
        if encoding != .utf8 && (!format.hasBOM || ambiguousBOM) {
            // The macOS encoding hint lets ambiguous text reopen without guessing.
            let metadata = Data(encoding.attributeValue.utf8)
            let result = metadata.withUnsafeBytes {
                fsetxattr(descriptor, encodingAttribute, $0.baseAddress, $0.count, 0, 0)
            }
            if result != 0 { throw fileError(errno, url) }
        } else if fremovexattr(descriptor, encodingAttribute, 0) != 0, errno != ENOATTR, errno != ENOTSUP {
            throw fileError(errno, url)
        }

        if let original {
            guard fchmod(descriptor, original.status.st_mode & 0o777) == 0,
                  fcopyfile(original.handle.fileDescriptor, descriptor, nil, UInt32(COPYFILE_ACL)) == 0 else {
                throw fileError(errno, temporary)
            }
        }
        var outputStatus = stat()
        guard fstat(descriptor, &outputStatus) == 0 else { throw fileError(errno, temporary) }
        try handle.synchronize()
        try handle.close()

        try withPath(temporary) { source in
            try withPath(url) { destination in
                if let original {
                    // Check that the name still points to the file whose bytes and metadata were staged.
                    guard let current = try fileStatus(at: url), sameVersion(original.status, current) else {
                        throw FileBufferError.changedOnDisk
                    }
                    guard rename(source, destination) == 0 else { throw fileError(errno, url) }
                } else {
                    guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
                        let code = errno
                        if code == EEXIST { throw FileBufferError.changedOnDisk }
                        throw fileError(code, url)
                    }
                }
            }
        }

        var savedFormat = format
        savedFormat.lineEnding = dominantLineEnding(in: text) ?? format.lineEnding
        let file = FileBuffer(url: url, text: text, format: savedFormat, revision: revision, diskStamp: DiskStamp(outputStatus))
        return SaveResult(file: file, replacedIdentity: original.map { FileIdentity($0.status) })
    }

    private static func resolvedURL(_ url: URL) -> URL? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: false, relativeTo: nil)
        }
    }

    private static func diskContents(
        at url: URL, readEncoding: Bool = false
    ) throws -> (bytes: Data, encoding: FileTextEncoding?, stamp: DiskStamp)? {
        guard let file = try openFile(at: url, access: O_RDONLY) else { return nil }
        let handle = file.handle
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        let encoding = readEncoding ? encodingHint(from: handle.fileDescriptor) : nil

        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0 else { throw fileError(errno, url) }
        guard sameVersion(file.status, after) else { throw FileBufferError.changedOnDisk }
        return (data, encoding, DiskStamp(after))
    }

    private static func openFile(at url: URL, access: Int32) throws -> DiskFile? {
        guard try fileStatus(at: url) != nil else { return nil }

        // Nonblocking open keeps a concurrent replacement with a FIFO from blocking.
        let descriptor = try withPath(url) { open($0, access | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw fileError(code, url)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw fileError(code, url)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw FileBufferError.notRegularFile(url)
        }
        return DiskFile(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), status: status)
    }

    private static func sameVersion(_ before: stat, _ after: stat) -> Bool {
        DiskStamp(before) == DiskStamp(after)
    }

    private static func encodingHint(from descriptor: Int32) -> FileTextEncoding? {
        let length = fgetxattr(descriptor, encodingAttribute, nil, 0, 0, 0)
        guard length > 0, length <= 4096 else { return nil }
        var bytes = Data(count: length)
        let count = bytes.withUnsafeMutableBytes {
            fgetxattr(descriptor, encodingAttribute, $0.baseAddress, $0.count, 0, 0)
        }
        guard count == length, let attribute = String(data: bytes, encoding: .utf8) else { return nil }
        return FileTextEncoding.fromAttribute(attribute)
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
