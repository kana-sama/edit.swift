import Foundation

@MainActor
final class DocumentActivity {
    private enum Replacement {
        case close
        case open([CheckedContinuation<Void, Never>])
    }

    private var replacement: Replacement?
    private var editabilityBeforeMutation: Bool?
    private(set) var isSaving = false
    private(set) var openGeneration: UInt64 = 0

    var isBusy: Bool { isSaving || replacement != nil || editabilityBeforeMutation != nil }

    var acceptsOpenRequest: Bool {
        if case .open = replacement { return true }
        return !isBusy
    }

    func beginOpenRequest() -> UInt64 {
        openGeneration &+= 1
        return openGeneration
    }

    func beginSave(duringWorkspaceMutation: Bool = false) -> Bool {
        guard !isSaving, duringWorkspaceMutation || editabilityBeforeMutation == nil else { return false }
        // The close sheet can save before completing its replacement.
        isSaving = true
        return true
    }

    func endSave() { isSaving = false }

    func beginClose(invalidateOpenRequests: Bool = false) {
        if invalidateOpenRequests { openGeneration &+= 1 }
        replacement = .close
    }

    func beginOpenReplacement() { replacement = .open([]) }

    func waitForOpenReplacement() async {
        guard case .open(var waiting) = replacement else { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            replacement = .open(waiting)
        }
    }

    func endReplacement() {
        let previous = replacement
        replacement = nil
        if case .open(let waiting) = previous {
            for waiter in waiting { waiter.resume() }
        }
    }

    func beginMutation(wasEditable: Bool) { editabilityBeforeMutation = wasEditable }

    func restoreEditabilityAfterMutation() {
        if editabilityBeforeMutation != nil { editabilityBeforeMutation = true }
    }

    func endMutation() -> Bool {
        let wasEditable = editabilityBeforeMutation ?? true
        editabilityBeforeMutation = nil
        return wasEditable
    }
}
