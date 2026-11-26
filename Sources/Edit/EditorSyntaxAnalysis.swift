import Foundation

@MainActor
final class EditorSyntaxAnalysis {
    struct Job {
        let task: Task<SyntaxAnalysis?, Never>
        let previews: AsyncStream<[SyntaxSpan]>
    }

    private var current: (source: String, language: SyntaxLanguage, job: Job)?
    private let incremental = IncrementalSyntaxSession()
#if EDIT_AGENT_CHECKS
    var treeReusesForCheck: Int { incremental.reuses }
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
        if SyntaxEngine.supportsIncremental(language) {
            task = Task { [incremental] in
                defer { continuation.finish() }
                guard let tree = await incremental.resolve(source, language: language), !Task.isCancelled else { return nil }
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

    func install(_ analysis: SyntaxAnalysis, in source: String, language: SyntaxLanguage, tree: SyntaxEngine.Tree?) {
        cancel()
        if let tree { incremental.install(tree) }
        let (previews, continuation) = AsyncStream<[SyntaxSpan]>.makeStream()
        continuation.finish()
        let job = Job(task: Task { analysis }, previews: previews)
        current = (source, language, job)
    }

    func cancelIfChanged(to source: String, language: SyntaxLanguage) {
        if let current, current.language != language || current.source != source { cancelJob() }
        incremental.resetIfLanguageChanged(to: language)
    }

    func recordEdit(_ range: NSRange, delta: Int, length: Int) {
        incremental.record(range, delta: delta, length: length)
    }

    func tree(in source: String, language: SyntaxLanguage) async -> SyntaxEngine.Tree? {
        await incremental.resolve(source, language: language)
    }

    func treeForEdit(in source: String, language: SyntaxLanguage, length: Int,
                     deadline: ContinuousClock.Instant) -> SyntaxEngine.Tree? {
        incremental.parseImmediately(source, language: language, length: length, deadline: deadline)
    }

    func projectedTree(in source: String, language: SyntaxLanguage, length: Int,
                       deadline: ContinuousClock.Instant) -> SyntaxEngine.Tree? {
        incremental.project(source, language: language, length: length, deadline: deadline)
    }

    func cancel() {
        cancelJob()
        incremental.reset()
    }

    private func cancelJob() {
        current?.job.task.cancel()
        current = nil
    }
}

@MainActor
private final class IncrementalSyntaxSession {
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
        let task: Task<SyntaxEngine.Tree?, Never>
        let reusedTree: Bool
        var laterEdits: EditBounds?
    }

    private var revision = 0
    private var workerID = 0
    private var language: SyntaxLanguage?
    private var length: Int?
    private var tree: SyntaxEngine.Tree?
    private var pending: EditBounds?
    private var projected: SyntaxEngine.Tree?
    private var projectedEdits: EditBounds?
    private var worker: Worker?
    private(set) var reuses = 0

    deinit { worker?.task.cancel() }

    func install(_ tree: SyntaxEngine.Tree) {
        self.tree = tree
        language = tree.language
        length = tree.length
        projected = nil
        projectedEdits = nil
    }

    func resetIfLanguageChanged(to language: SyntaxLanguage) {
        if self.language != language { reset() }
    }

    func reset() {
        guard length != nil || worker != nil else { return }
        revision &+= 1
        worker?.task.cancel()
        worker = nil
        language = nil
        length = nil
        tree = nil
        pending = nil
        projected = nil
        projectedEdits = nil
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
        if projected != nil { projectedEdits = projectedEdits?.combining(edit) ?? edit }
        if let previous = worker?.laterEdits { worker?.laterEdits = previous.combining(edit) }
        else { worker?.laterEdits = edit }
    }

    func project(_ source: String, language: SyntaxLanguage, length: Int,
                 deadline: ContinuousClock.Instant) -> SyntaxEngine.Tree? {
        guard self.language == language, self.length == length, let tree else { return nil }
        guard let pending else { return tree }
        let previous = projected ?? tree
        guard let bounds = projected == nil ? pending : projectedEdits else { return previous }
        guard let next = previous.projected(on: source, prefix: bounds.prefix, suffix: bounds.suffix, deadline: deadline) else {
            return nil
        }
        projected = next
        projectedEdits = nil
        return next
    }

    func parseImmediately(_ source: String, language: SyntaxLanguage, length: Int,
                          deadline: ContinuousClock.Instant) -> SyntaxEngine.Tree? {
        guard ContinuousClock.now < deadline else { return nil }
        let previous = tree?.language == language && self.length == length ? tree : nil
        if language == .zig {
            guard previous != nil, worker == nil, length <= 64 * 1_024 else { return nil }
        } else if previous == nil {
            // The first edit of an empty buffer has no tree to reuse.
            guard length <= 16 * 1_024 else { return nil }
        }
        if let previous, pending == nil { return previous }
        let parsed: SyntaxEngine.Tree?
        if language != .zig, previous != nil {
            parsed = project(source, language: language, length: length, deadline: deadline)?.reparsed(deadline: deadline)
        } else {
            parsed = SyntaxEngine.Tree(source: source, language: language, previous: previous,
                                       prefix: pending?.prefix ?? 0, suffix: pending?.suffix ?? 0, deadline: deadline)
        }
        guard let parsed else { return nil }
        worker?.task.cancel()
        worker = nil
        install(parsed)
        self.pending = nil
        if previous != nil { reuses += 1 }
        return parsed
    }

    func resolve(_ source: String, language: SyntaxLanguage) async -> SyntaxEngine.Tree? {
        guard !Task.isCancelled else { return nil }
        let count = source.utf16.count
        if self.language != language || length != count {
            reset()
            self.language = language
            length = count
        }
        guard count > 0 else { return nil }
        let requested = revision
        while !Task.isCancelled && revision == requested {
            if let tree, pending == nil { return tree }
            if worker == nil {
                let previous = tree
                let changes = pending
                let projected = projectedEdits == nil ? projected : nil
                let task = Task.detached(priority: .userInitiated) {
                    if let projected { return projected.reparsed(deadline: nil) }
                    return SyntaxEngine.Tree(source: source, language: language, previous: previous, prefix: changes?.prefix ?? 0,
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
                    if pending == nil {
                        projected = nil
                        projectedEdits = nil
                    }
                    if finished.reusedTree { reuses += 1 }
                } else if finished.revision == requested {
                    return nil
                }
            }
        }
        return nil
    }
}
