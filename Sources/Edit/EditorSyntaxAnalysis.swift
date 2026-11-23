import Foundation

@MainActor
final class EditorSyntaxAnalysis {
    struct Job {
        let task: Task<SyntaxAnalysis?, Never>
        let previews: AsyncStream<[SyntaxSpan]>
    }

    private var current: (source: String, language: SyntaxLanguage, job: Job)?

    deinit { current?.job.task.cancel() }

    func request(in source: String, language: SyntaxLanguage, visibleRange: NSRange? = nil,
                 publishesPreview: Bool = false) -> Job {
        if let current, current.language == language, current.source == source { return current.job }
        cancel()
        let (previews, continuation) = AsyncStream<[SyntaxSpan]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let publish: @Sendable ([SyntaxSpan]) -> Void = { preview in
            continuation.yield(preview)
        }
        let task = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return SyntaxEngine.analysis(in: source, language: language, visibleRange: visibleRange,
                                         onPreview: publishesPreview ? publish : nil)
        }
        let job = Job(task: task, previews: previews)
        current = (source, language, job)
        return job
    }

    func install(_ analysis: SyntaxAnalysis, in source: String, language: SyntaxLanguage) {
        cancel()
        let (previews, continuation) = AsyncStream<[SyntaxSpan]>.makeStream()
        continuation.finish()
        let job = Job(task: Task { analysis }, previews: previews)
        current = (source, language, job)
    }

    func cancelIfChanged(to source: String, language: SyntaxLanguage) {
        if let current, current.language != language || current.source != source { cancel() }
    }

    func cancel() {
        current?.job.task.cancel()
        current = nil
    }
}
