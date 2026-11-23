import Foundation

@MainActor
final class DocumentAutosave {
    private struct Request {
        let generation: UInt
        let text: String
    }

    private struct Failure {
        let generation: UInt
        let detail: String
        var reported = false
    }

    enum WriteError: LocalizedError {
        case inUse

        var errorDescription: String? { "The file is in use by another window." }
    }

    private unowned let document: DocumentWindow
    private var idle: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: Request?
    private var writingGeneration: UInt?
    private var failure: Failure?
    private(set) var generation: UInt = 0

    init(document: DocumentWindow) { self.document = document }

    var hasWorker: Bool { worker != nil }

    func noteEdit() { generation &+= 1 }

    func request() {
        guard document.canScheduleAutosave else { return }
        if document.editor.hasMarkedText() {
            scheduleIdle()
            return
        }
        guard pending?.generation != generation, writingGeneration != generation,
              failure?.generation != generation else { return }
        pending = Request(generation: generation, text: document.editor.string)
        resume()
    }

    func resume() {
        guard pending != nil, worker == nil, document.canRunAutosave else { return }
        worker = Task { [document] in
            while let request = pending, document.canRunAutosave {
                pending = nil
                if document.editor.hasMarkedText() {
                    scheduleIdle()
                    break
                }
                await write(request)
            }
            worker = nil
            document.reportAutosaveFailure()
        }
    }

    func waitForWrite() async { await worker?.value }

    func flush() async {
        cancelIdle()
        await waitForWrite()
        pending = nil
        if document.window.isDocumentEdited {
            await write(Request(generation: generation, text: document.editor.string), retryFailed: true)
        }
    }

    func didSave(through generation: UInt) {
        if let pending, pending.generation <= generation { self.pending = nil }
        if document.window.isDocumentEdited { scheduleIdle() }
    }

    func scheduleIdle() {
        cancelIdle()
        guard document.canScheduleAutosave else { return }
        idle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            idle = nil
            request()
        }
    }

    func cancelIdle() {
        idle?.cancel()
        idle = nil
    }

    func reset() {
        cancelIdle()
        pending = nil
        failure = nil
    }

    func clearFailure() { failure = nil }

    func takeFailure(includingReported: Bool = false) -> String? {
        guard let failure, includingReported || !failure.reported else { return nil }
        self.failure?.reported = true
        return failure.detail
    }

    private func write(_ request: Request, retryFailed: Bool = false) async {
        guard retryFailed || failure?.generation != request.generation else { return }
        writingGeneration = request.generation
        defer { writingGeneration = nil }
        do {
            try await document.writeAutosave(request.text)
        } catch FileBufferError.changedOnDisk {
            failure = Failure(generation: request.generation,
                              detail: "The file changed on disk. Use Save to review whether to replace it.")
        } catch {
            failure = Failure(generation: request.generation, detail: error.localizedDescription)
        }
    }
}
