import Foundation

@MainActor
final class EditorSyntaxAnalysis {
    struct Job {
        let task: Task<SyntaxAnalysis?, Never>
        let previews: AsyncStream<[SyntaxSpan]>
    }

    private var current: (source: String, language: SyntaxLanguage, job: Job)?
    private let zig = ZigSyntaxSession()
#if EDIT_AGENT_CHECKS
    var zigReusesForCheck: Int { zig.reuses }
#endif

    deinit { current?.job.task.cancel() }

    func request(in source: String, language: SyntaxLanguage, visibleRange: NSRange? = nil,
                 publishesPreview: Bool = false) -> Job {
        if let current, current.language == language, current.source == source { return current.job }
        cancelJob()
        let (previews, continuation) = AsyncStream<[SyntaxSpan]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let publish: @Sendable ([SyntaxSpan]) -> Void = { preview in
            continuation.yield(preview)
        }
        let task: Task<SyntaxAnalysis?, Never>
        if language == .zig && SyntaxEngine.supportsIncrementalZig {
            task = Task { [zig] in
                defer { continuation.finish() }
                guard let tree = await zig.resolve(source), !Task.isCancelled else { return nil }
                let work = Task.detached(priority: .userInitiated) { tree.bracketContext() }
                let brackets = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                return brackets.map { SyntaxAnalysis(spans: [], brackets: $0) }
            }
        } else {
            task = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                return SyntaxEngine.analysis(in: source, language: language, visibleRange: visibleRange,
                                             onPreview: publishesPreview ? publish : nil)
            }
        }
        let job = Job(task: task, previews: previews)
        current = (source, language, job)
        return job
    }

    func install(_ analysis: SyntaxAnalysis, in source: String, language: SyntaxLanguage, zigTree: SyntaxEngine.ZigTree?) {
        cancel()
        if let zigTree { zig.install(zigTree) }
        let (previews, continuation) = AsyncStream<[SyntaxSpan]>.makeStream()
        continuation.finish()
        let job = Job(task: Task { analysis }, previews: previews)
        current = (source, language, job)
    }

    func cancelIfChanged(to source: String, language: SyntaxLanguage) {
        if let current, current.language != language || current.source != source { cancelJob() }
        if language != .zig { zig.reset() }
    }

    func recordZigEdit(_ range: NSRange, delta: Int, length: Int) {
        zig.record(range, delta: delta, length: length)
    }

    func zigTree(in source: String) async -> SyntaxEngine.ZigTree? { await zig.resolve(source) }

    func zigTreeForEdit(in source: String, deadline: ContinuousClock.Instant) -> SyntaxEngine.ZigTree? {
        zig.parseImmediately(source, deadline: deadline)
    }

    func cancel() {
        cancelJob()
        zig.reset()
    }

    private func cancelJob() {
        current?.job.task.cancel()
        current = nil
    }
}

@MainActor
private final class ZigSyntaxSession {
    // Across revisions only the common untouched prefix and suffix can be reused.
    private struct EditBounds {
        var prefix: Int
        var suffix: Int

        func combining(_ edit: EditBounds) -> EditBounds {
            EditBounds(prefix: min(prefix, edit.prefix), suffix: min(suffix, edit.suffix))
        }
    }

    private struct Worker {
        let id: Int
        let revision: Int
        let task: Task<SyntaxEngine.ZigTree?, Never>
        let reusedTree: Bool
        var laterEdits: EditBounds?
    }

    private var revision = 0
    private var workerID = 0
    private var length: Int?
    private var tree: SyntaxEngine.ZigTree?
    private var pending: EditBounds?
    private var worker: Worker?
    private(set) var reuses = 0

    deinit { worker?.task.cancel() }

    func install(_ tree: SyntaxEngine.ZigTree) {
        self.tree = tree
        length = tree.length
    }

    func reset() {
        guard length != nil || worker != nil else { return }
        revision &+= 1
        worker?.task.cancel()
        worker = nil
        length = nil
        tree = nil
        pending = nil
    }

    func record(_ edited: NSRange, delta: Int, length: Int) {
        guard let oldLength = self.length else { return }
        guard oldLength == length - delta, edited.location >= 0, edited.location <= length,
              edited.length >= delta, edited.length <= length - edited.location else {
            reset()
            return
        }
        revision &+= 1
        self.length = length
        let edit = EditBounds(prefix: edited.location, suffix: length - edited.upperBound)
        if tree != nil { pending = pending?.combining(edit) ?? edit }
        if let previous = worker?.laterEdits { worker?.laterEdits = previous.combining(edit) }
        else { worker?.laterEdits = edit }
    }

    func parseImmediately(_ source: String, deadline: ContinuousClock.Instant) -> SyntaxEngine.ZigTree? {
        guard worker == nil, let tree, let length, length <= 64 * 1_024 else { return nil }
        guard let pending else { return tree }
        guard let parsed = SyntaxEngine.ZigTree(source: source, previous: tree, prefix: pending.prefix,
                                                suffix: pending.suffix, deadline: deadline) else { return nil }
        install(parsed)
        self.pending = nil
        reuses += 1
        return parsed
    }

    func resolve(_ source: String) async -> SyntaxEngine.ZigTree? {
        guard !Task.isCancelled else { return nil }
        let count = source.utf16.count
        if length != count {
            reset()
            length = count
        }
        guard count > 0 else { return nil }
        let requested = revision
        while !Task.isCancelled && revision == requested {
            if let tree, pending == nil { return tree }
            if worker == nil {
                let previous = tree
                let changes = pending
                let task = Task.detached(priority: .userInitiated) {
                    SyntaxEngine.ZigTree(source: source, previous: previous, prefix: changes?.prefix ?? 0,
                                         suffix: changes?.suffix ?? 0)
                }
                workerID &+= 1
                worker = Worker(id: workerID, revision: revision, task: task, reusedTree: previous != nil)
            }
            guard let active = worker else { return nil }
            let parsed = await active.task.value
            // Keep the finished tree as the base for the next edit, even if this waiter was superseded.
            if let finished = worker, finished.id == active.id {
                worker = nil
                if let parsed {
                    tree = parsed
                    pending = finished.laterEdits
                    if finished.reusedTree { reuses += 1 }
                }
            }
            if parsed == nil && active.revision == requested { return nil }
        }
        return nil
    }
}
