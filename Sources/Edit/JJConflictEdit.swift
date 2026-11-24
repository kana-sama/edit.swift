import Foundation

/// The editable snapshot is part of the document buffer. Keep its original materialized
/// payload so saves can write a valid unresolved conflict until the user marks it resolved.
struct JJConflictEdit: Sendable {
    struct SavedDraft: Codable, Sendable {
        let block: NSRange
        let payload: NSRange
        let originalPayload: String
    }

    let original: JJConflict
    var block: NSRange
    var result: NSRange?
    var hasSeparator: Bool
    private let originalPayload: String

    init(_ conflict: JJConflict) {
        let separator = conflict.resultRange != nil && !conflict.resultNeedsSeparator
        original = conflict
        block = conflict.range
        result = conflict.resultRange
        hasSeparator = separator
        let source = conflict.source as NSString
        let separatorWidth = conflict.resultSeparator.utf16.count
        let payload = conflict.resultRange.map {
            NSRange(location: $0.location - conflict.range.location,
                    length: $0.length + separatorWidth)
        }
        originalPayload = payload.map(source.substring(with:)) ?? ""
    }

    var payload: NSRange? {
        let separator = original.resultSeparator.isEmpty ? original.lineEnding : original.resultSeparator
        return result.map { NSRange(location: $0.location, length: $0.length + (hasSeparator ? separator.utf16.count : 0)) }
    }

    func draft(in source: NSString) -> SavedDraft? {
        guard let payload, NSMaxRange(payload) <= source.length,
              !source.substring(with: payload).utf8.elementsEqual(originalPayload.utf8) else { return nil }
        return SavedDraft(block: block, payload: payload, originalPayload: originalPayload)
    }

    func displayed(in source: NSString) -> JJConflict? {
        guard let result, NSMaxRange(block) <= source.length else { return nil }
        return original.displayingResult(in: source, blockRange: block, resultRange: result, hasSeparator: hasSeparator)
    }

    static func textForSaving(_ source: String, edits: [Self]) -> String {
        guard !edits.isEmpty else { return source }
        let drafts = edits.compactMap { $0.draft(in: source as NSString) }
        guard !drafts.isEmpty else { return source }
        let text = NSMutableString(string: source)
        for draft in drafts.reversed() { text.replaceCharacters(in: draft.payload, with: draft.originalPayload) }
        return text as String
    }

    func allows(_ edit: NSRange, replacement: String, in source: NSString) -> Bool {
        if NSMaxRange(edit) == block.location {
            if replacement.utf8.last == 10 { return true }
            return replacement.isEmpty && (edit.location == 0 || source.character(at: edit.location - 1) == 10)
        }
        if edit.location == NSMaxRange(block), original.source.utf8.last != 10 { return replacement.isEmpty }
        if NSMaxRange(edit) < block.location || edit.location >= NSMaxRange(block) { return true }
        guard let result, hasSeparator else { return false }
        return edit.location >= result.location && NSMaxRange(edit) <= NSMaxRange(result)
    }

    func remapped(after edits: [EditorTextEdit]) -> Self? {
        var shifted = self
        for edit in edits.reversed() {
            let delta = edit.text.utf16.count - edit.range.length
            if NSMaxRange(edit.range) <= shifted.block.location {
                shifted.block.location += delta
                shifted.result?.location += delta
            } else if edit.range.location < NSMaxRange(shifted.block) {
                guard let result = shifted.result,
                      edit.range.location >= result.location, NSMaxRange(edit.range) <= NSMaxRange(result) else { return nil }
                shifted.block.length += delta
                shifted.result?.length += delta
            }
        }
        return shifted
    }

    func withInsertedSeparator() -> Self {
        var updated = self
        updated.hasSeparator = true
        updated.block.length += original.lineEnding.utf16.count
        return updated
    }

    @concurrent
    static func restore(_ drafts: [SavedDraft], in source: String) async -> [Self] {
        let displayed = source as NSString
        func contains(_ range: NSRange, in length: Int) -> Bool {
            range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
        }
        var lastEnd = 0
        for draft in drafts {
            guard draft.block.location >= lastEnd, contains(draft.block, in: displayed.length),
                  contains(draft.payload, in: displayed.length), draft.payload.location >= draft.block.location,
                  NSMaxRange(draft.payload) <= NSMaxRange(draft.block) else { return [] }
            lastEnd = NSMaxRange(draft.block)
        }
        let original = NSMutableString(string: source)
        for draft in drafts.reversed() { original.replaceCharacters(in: draft.payload, with: draft.originalPayload) }
        let text = original as String
        let conflicts = JJLineDiff.analyze(base: nil, current: text, isConflicted: true, recordedConflict: text).conflicts
        var delta = 0
        var nextDraft = 0
        var restored: [Self] = []
        for conflict in conflicts {
            var edit = Self(conflict)
            edit.block.location += delta
            edit.result?.location += delta
            if nextDraft < drafts.count, drafts[nextDraft].block.location == edit.block.location {
                let draft = drafts[nextDraft]
                let difference = draft.payload.length - draft.originalPayload.utf16.count
                guard edit.block.length + difference == draft.block.length,
                      edit.result?.location == draft.payload.location else { return [] }
                let separator = conflict.resultSeparator.isEmpty ? conflict.lineEnding : conflict.resultSeparator
                let storedPayload = displayed.substring(with: draft.payload)
                let separatorLength = separator.utf16.count
                guard storedPayload.utf8.suffix(separator.utf8.count).elementsEqual(separator.utf8) else { return [] }
                edit.block = draft.block
                edit.hasSeparator = true
                edit.result?.length = draft.payload.length - separatorLength
                delta += difference
                nextDraft += 1
            }
            restored.append(edit)
        }
        return nextDraft == drafts.count ? restored : []
    }
}
