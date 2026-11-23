import Foundation

struct DraftRecoveryRevision: Codable, Sendable, Equatable {
    let id: UUID
    let version: UInt64
}

struct DraftCheckpoint: Codable, Sendable {
    let revision: DraftRecoveryRevision
    let text: String?
    var folderPath: String? = nil
    var placement: WindowPlacement? = nil
}

final class DraftRecoveryStore: Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "Edit.DraftRecovery", qos: .utility)

    init(directory: URL) { self.directory = directory }

    func write(_ checkpoint: DraftCheckpoint, onError: @escaping @MainActor @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                try SessionStore.writePrivate(JSONEncoder().encode(checkpoint), to: url(for: checkpoint.revision.id))
            } catch {
                let detail = error.localizedDescription
                Task { @MainActor in onError(detail) }
            }
        }
    }

    func read() async throws -> (checkpoints: [DraftCheckpoint], unreadable: Int) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try readCheckpoints() }) }
        }
    }

    func removeSaved(in session: EditorSession) async {
        let saved = Set(session.documents.compactMap { $0.draftRecovery?.id })
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume(returning: ()) }
                guard let result = try? readCheckpoints() else { return }
                for checkpoint in result.checkpoints where checkpoint.text == nil || saved.contains(checkpoint.revision.id) {
                    try? FileManager.default.removeItem(at: url(for: checkpoint.revision.id))
                }
            }
        }
    }

    private func readCheckpoints() throws -> (checkpoints: [DraftCheckpoint], unreadable: Int) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return ([], 0)
        }
        var checkpoints: [DraftCheckpoint] = []
        var unreadable = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let checkpoint = try JSONDecoder().decode(DraftCheckpoint.self, from: Data(contentsOf: file))
                if id == checkpoint.revision.id && (checkpoint.text == nil || checkpoint.placement != nil) {
                    checkpoints.append(checkpoint)
                } else {
                    unreadable += 1
                }
            } catch {
                unreadable += 1
            }
        }
        return (checkpoints, unreadable)
    }

    private func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }
}

extension EditorSession {
    static func recovering(_ checkpoints: [DraftCheckpoint], into saved: EditorSession?) -> EditorSession? {
        guard !checkpoints.isEmpty else { return saved }
        var pending: [UUID: DraftCheckpoint] = [:]
        for checkpoint in checkpoints { pending[checkpoint.revision.id] = checkpoint }
        var restored: [SessionDocument] = []
        var active: Int?
        for (index, original) in (saved?.documents ?? []).enumerated() {
            var record = original
            if let revision = record.draftRecovery,
               let checkpoint = pending.removeValue(forKey: revision.id), checkpoint.revision.version > revision.version {
                guard let text = checkpoint.text else { continue }
                record.draft = text
                record.folderPath = checkpoint.folderPath
                if let placement = checkpoint.placement { record.placement = placement }
                record.editorPosition = nil
                record.draftRecovery = checkpoint.revision
            }
            if index == saved?.activeIndex { active = restored.count }
            restored.append(record)
        }
        for checkpoint in checkpoints {
            guard pending.removeValue(forKey: checkpoint.revision.id) != nil,
                  let text = checkpoint.text, let placement = checkpoint.placement else { continue }
            restored.append(SessionDocument(draft: text, placement: placement, folderPath: checkpoint.folderPath,
                                            draftRecovery: checkpoint.revision))
        }
        if saved == nil && restored.isEmpty { return nil }
        return EditorSession(documents: restored, activeIndex: active, lastWindow: saved?.lastWindow)
    }
}
