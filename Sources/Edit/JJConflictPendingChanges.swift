import Foundation

@MainActor
final class JJConflictPendingChanges {
    struct Input: Equatable, Sendable {
        let id: UUID
        let original: JJConflict
        let result: String

        static func == (left: Self, right: Self) -> Bool {
            left.id == right.id && left.original == right.original && left.result.utf8.elementsEqual(right.result.utf8)
        }
    }

    private struct Review: Sendable {
        let input: Input
        let rows: [Int: [NSRange]]
    }

    private var inputs: [Input] = []
    private var reviews: [UUID: Review] = [:]
    private var task: Task<Void, Never>?
    private var expiry: Task<Void, Never>?

    func confirmedRows(for id: UUID) -> [Int: [NSRange]] { reviews[id]?.rows ?? [:] }

    func update(_ inputs: [Input], onUpdate: @escaping @MainActor () -> Void) {
        guard self.inputs != inputs else { return }
        self.inputs = inputs
        task?.cancel()
        task = nil
        let current = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        reviews = reviews.filter { current[$0.key]?.original == $0.value.input.original }
        let needed = inputs.filter { reviews[$0.id]?.input != $0 }
        guard !needed.isEmpty else {
            expiry?.cancel()
            expiry = nil
            return
        }

        if expiry == nil {
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                guard let self else { return }
                let current = Dictionary(uniqueKeysWithValues: self.inputs.map { ($0.id, $0) })
                reviews = reviews.filter { current[$0.key] == $0.value.input }
                onUpdate()
            }
        }
        task = Task { [weak self] in
            let updated = await Self.review(needed)
            guard let self, !Task.isCancelled else { return }
            for review in updated { reviews[review.input.id] = review }
            expiry?.cancel()
            expiry = nil
            task = nil
            onUpdate()
        }
    }

    @concurrent
    private static func review(_ inputs: [Input]) async -> [Review] {
        var budget = JJLineDiff.Budget(deadline: ContinuousClock.now + .milliseconds(100))
        return inputs.map { input in
            let rows = (try? input.original.confirmedChanges(in: input.result, budget: &budget)) ?? [:]
            return Review(input: input, rows: rows)
        }
    }
}
