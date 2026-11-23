import Darwin
import Foundation

struct ScratchFile: Codable, Sendable, Equatable {
    let id: UUID
    let storedName: String
    var name: String
    var folderPath: String?
    var openedAt: Date?

    init(id: UUID = UUID(), name: String, folderPath: String?, openedAt: Date? = nil) {
        self.id = id
        storedName = name
        self.name = name
        self.folderPath = folderPath
        self.openedAt = openedAt
    }

    var folderLabel: String {
        guard let folderPath else { return "Global" }
        let name = URL(filePath: folderPath, directoryHint: .isDirectory).lastPathComponent
        return name.isEmpty ? folderPath : name
    }
}

struct TrashedScratch: Sendable {
    let file: ScratchFile
    let trashedURL: URL
}

actor ScratchStore {
    private let root: URL
    private let trashDirectoryForChecks: URL?

    init(root: URL, trashDirectoryForChecks: URL? = nil) {
        self.root = root
        self.trashDirectoryForChecks = trashDirectoryForChecks
    }

    nonisolated static func folderPath(for folder: URL?) -> String? {
        folder.map { WorktreeFileOperations.path(FileBuffer.canonicalURL($0)) }
    }

    nonisolated func url(for file: ScratchFile) -> URL {
        root.appending(path: file.id.uuidString, directoryHint: .isDirectory)
            .appending(path: file.storedName, directoryHint: .notDirectory)
    }

    nonisolated func identifiesScratch(at url: URL) -> Bool {
        scratchID(at: url) != nil
    }

    private nonisolated func scratchID(at url: URL) -> UUID? {
        let directory = url.deletingLastPathComponent()
        guard WorktreeFileOperations.path(directory.deletingLastPathComponent()) == WorktreeFileOperations.path(root) else {
            return nil
        }
        return UUID(uuidString: directory.lastPathComponent)
    }

    func file(at url: URL) throws -> ScratchFile? {
        guard let id = scratchID(at: url) else { return nil }
        let file = try files().first { $0.id == id }
        guard file?.storedName == url.lastPathComponent else { return nil }
        return file
    }

    private var indexURL: URL { root.appending(path: "index.json", directoryHint: .notDirectory) }

    func files() throws -> [ScratchFile] {
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        let files = try JSONDecoder().decode([ScratchFile].self, from: data)
        guard files.allSatisfy({ Self.isFilename($0.name) && Self.isFilename($0.storedName) }),
              Set(files.map(\.id)).count == files.count else { throw Failure.invalidIndex }
        return files
    }

    func create(name: String, text: String, format: FileFormat, in folder: URL?, openedAt: Date? = nil) throws -> (ScratchFile, FileBuffer) {
        guard Self.isFilename(name) else { throw Failure.invalidName }
        var files = try files()
        let path = Self.folderPath(for: folder)
        let name = availableName(name, avoiding: names(in: path, files: files))
        let file = ScratchFile(name: name, folderPath: path, openedAt: openedAt)
        let buffer = try write(file, text: text, format: format)
        do {
            files.append(file)
            try save(files)
            return (file, buffer)
        } catch {
            removeUnpublishedFile(file)
            throw error
        }
    }

    func recordOpen(_ id: UUID, at timestamp: Date) throws -> ScratchFile? {
        var files = try files()
        guard let index = files.firstIndex(where: { $0.id == id }) else { return nil }
        if (files[index].openedAt ?? .distantPast) < timestamp {
            files[index].openedAt = timestamp
            try save(files)
        }
        return files[index]
    }

    private func write(_ file: ScratchFile, text: String, format: FileFormat) throws -> FileBuffer {
        let target = url(for: file)
        let directory = target.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            return try FileBuffer.save(text, to: target, format: format, expected: .missing).file
        } catch {
            removeUnpublishedFile(file)
            throw error
        }
    }

    private func removeUnpublishedFile(_ file: ScratchFile) {
        try? FileManager.default.removeItem(at: url(for: file).deletingLastPathComponent())
    }

    func move(_ id: UUID, to folderPath: String?) throws -> ScratchFile? {
        try move([id], to: folderPath).first
    }

    func move(_ ids: [UUID], to folderPath: String?) throws -> [ScratchFile] {
        var files = try files()
        let moving = try indices(for: ids, in: files).filter { files[$0].folderPath != folderPath }
        guard !moving.isEmpty else { return [] }
        var reserved = names(in: folderPath, files: files)
        // Keep the backing URL stable for open buffers, autosaves and session restoration.
        for index in moving {
            let name = availableName(files[index].name, avoiding: reserved)
            reserved.insert(Self.nameKey(name))
            files[index].name = name
            files[index].folderPath = folderPath
        }
        try save(files)
        return moving.map { files[$0] }
    }

    func rename(_ id: UUID, to name: String) throws -> ScratchFile {
        guard Self.isFilename(name) else { throw Failure.invalidName }
        var files = try files()
        guard let index = files.firstIndex(where: { $0.id == id }) else { throw Failure.missingScratch }
        guard files[index].name != name else { return files[index] }
        let others = files.filter { $0.id != id }
        guard !names(in: files[index].folderPath, files: others).contains(Self.nameKey(name)) else {
            throw Failure.nameConflict(name)
        }
        files[index].name = name
        try save(files)
        return files[index]
    }

    func restoreMetadata(_ records: [ScratchFile]) throws -> [ScratchFile] {
        guard !records.isEmpty else { return [] }
        var files = try files()
        let selected = try indices(for: records.map(\.id), in: files)
        let previous = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reserved = Set(files.filter { previous[$0.id] == nil }.map(NameSlot.init))
        for index in selected {
            guard let record = previous[files[index].id], Self.isFilename(record.name) else { throw Failure.invalidName }
            guard reserved.insert(NameSlot(record)).inserted else { throw Failure.nameConflict(record.name) }
            files[index].name = record.name
            files[index].folderPath = record.folderPath
        }
        try save(files)
        return selected.map { files[$0] }
    }

    func importFiles(_ urls: [URL], into folderPath: String?) throws -> [ScratchFile] {
        var files = try files()
        let indexed = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var visited: Set<String> = []
        let inputs = try urls.compactMap { url -> (String, FileBuffer)? in
            let source = FileBuffer.canonicalURL(url)
            guard visited.insert(WorktreeFileOperations.path(source)).inserted else { return nil }
            let name: String
            if let id = scratchID(at: source), let file = indexed[id], file.storedName == source.lastPathComponent {
                name = file.name
            } else {
                name = url.lastPathComponent
            }
            guard Self.isFilename(name) else { throw Failure.invalidName }
            return (name, try FileBuffer.read(source))
        }
        guard !inputs.isEmpty else { return [] }

        var reserved = names(in: folderPath, files: files)
        var imported: [ScratchFile] = []
        do {
            for (sourceName, buffer) in inputs {
                let name = availableName(sourceName, avoiding: reserved)
                let file = ScratchFile(name: name, folderPath: folderPath)
                _ = try write(file, text: buffer.text, format: buffer.format)
                imported.append(file)
                reserved.insert(Self.nameKey(name))
            }
            files.append(contentsOf: imported)
            try save(files)
            return imported
        } catch {
            for file in imported { removeUnpublishedFile(file) }
            throw error
        }
    }

    func trash(_ ids: [UUID]) throws -> [TrashedScratch] {
        var files = try files()
        let selected = try indices(for: ids, in: files).map { files[$0] }
        guard !selected.isEmpty else { return [] }
        let removed = Set(selected.map(\.id))
        var trashed: [TrashedScratch] = []
        do {
            for file in selected {
                let destination = try recycle(url(for: file))
                trashed.append(TrashedScratch(file: file, trashedURL: destination))
            }
            files.removeAll { removed.contains($0.id) }
            try save(files)
            for file in selected {
                // Do not unlink unrecognized items that may have appeared in the directory.
                let directory = url(for: file).deletingLastPathComponent()
                _ = directory.withUnsafeFileSystemRepresentation { $0.map(rmdir) }
            }
            return trashed
        } catch {
            try rollBack(trashed.map { (from: $0.trashedURL, to: url(for: $0.file)) }, after: error)
        }
    }

    func restore(_ records: [TrashedScratch]) throws -> [ScratchFile] {
        guard !records.isEmpty else { return [] }
        var files = try files()
        var ids = Set(files.map(\.id))
        var reserved = Set(files.map(NameSlot.init))
        for record in records {
            guard Self.isFilename(record.file.name), Self.isFilename(record.file.storedName) else { throw Failure.invalidName }
            guard ids.insert(record.file.id).inserted else { throw Failure.alreadyRestored }
            guard reserved.insert(NameSlot(record.file)).inserted else { throw Failure.nameConflict(record.file.name) }
        }

        let manager = FileManager.default
        var restored: [TrashedScratch] = []
        do {
            for record in records {
                let target = url(for: record.file)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: record.trashedURL, to: target)
                restored.append(record)
            }
            let recovered = restored.map(\.file)
            files.append(contentsOf: recovered)
            try save(files)
            return recovered
        } catch {
            try rollBack(restored.map { (from: url(for: $0.file), to: $0.trashedURL) }, after: error)
        }
    }

    private func recycle(_ source: URL) throws -> URL {
        let manager = FileManager.default
        if let trashDirectoryForChecks {
            let directory = trashDirectoryForChecks.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            try manager.moveItem(at: source, to: target)
            return target
        }
        var result: NSURL?
        try manager.trashItem(at: source, resultingItemURL: &result)
        guard let result else { throw Failure.missingTrashLocation }
        return result as URL
    }

    private func rollBack(_ moves: [(from: URL, to: URL)], after error: Error) throws -> Never {
        var retained: [URL] = []
        for move in moves.reversed() {
            do {
                try FileManager.default.moveItem(at: move.from, to: move.to)
            } catch {
                retained.append(move.from)
            }
        }
        if retained.isEmpty { throw error }
        throw Failure.rollback(error.localizedDescription, retained)
    }

    private func indices(for ids: [UUID], in files: [ScratchFile]) throws -> [Int] {
        let byID = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.element.id, $0.offset) })
        var visited: Set<UUID> = []
        return try ids.compactMap { id in
            guard visited.insert(id).inserted else { return nil }
            guard let index = byID[id] else { throw Failure.missingScratch }
            return index
        }
    }

    private func save(_ files: [ScratchFile]) throws {
        try JSONEncoder().encode(files).write(to: indexURL, options: .atomic)
    }

    private static func isFilename(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private struct NameSlot: Hashable {
        let folderPath: String?
        let name: String

        init(_ file: ScratchFile) {
            folderPath = file.folderPath
            name = ScratchStore.nameKey(file.name)
        }
    }

    private func names(in folderPath: String?, files: [ScratchFile]) -> Set<String> {
        Set(files.lazy.filter { $0.folderPath == folderPath }.map { Self.nameKey($0.name) })
    }

    private func availableName(_ name: String, avoiding usedNames: Set<String>) -> String {
        guard usedNames.contains(Self.nameKey(name)) else { return name }
        let path = name as NSString
        let ext = path.pathExtension
        let base = path.deletingPathExtension
        var number = 2
        while true {
            let stem = "\(base) \(number)"
            let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
            if !usedNames.contains(Self.nameKey(candidate)) { return candidate }
            number += 1
        }
    }

    private enum Failure: LocalizedError {
        case invalidName, invalidIndex, missingScratch, alreadyRestored, missingTrashLocation
        case nameConflict(String)
        case rollback(String, [URL])

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a valid scratch filename."
            case .invalidIndex: "The scratch index could not be read."
            case .missingScratch: "This scratch is no longer in the list."
            case .alreadyRestored: "This scratch is already in the list."
            case .missingTrashLocation: "The Trash did not return the location of the scratch."
            case .nameConflict(let name): "A scratch named “\(name)” already exists in this category."
            case .rollback(let detail, let retained):
                "\(detail) Some files could not be moved back. Their current locations are \(retained.map(\.path).joined(separator: ", "))."
            }
        }
    }
}
