import Foundation

/// The editor holds the editable snapshot and prefix-free reference rows. Keep the
/// canonical conflict so repository operations and session drafts use jj's representation.
struct JJConflictEdit: Sendable {
    struct SavedDraft: Codable, Sendable {
        let block: NSRange
        let payload: NSRange
        let originalPayload: String
        var appliedSides: Set<Int>? = nil
    }

    struct Projection {
        let rawOffsets: [Int]

        func visibleOffset(_ raw: Int) -> Int {
            raw - firstOffset { $0 >= raw }
        }

        func visibleRange(_ raw: NSRange) -> NSRange {
            let start = visibleOffset(raw.location)
            return NSRange(location: start, length: visibleOffset(NSMaxRange(raw)) - start)
        }

        func rawOffset(_ visible: Int) -> Int {
            var start = 0
            var end = rawOffsets.count
            while start < end {
                let middle = start + (end - start) / 2
                if rawOffsets[middle] - middle <= visible { start = middle + 1 }
                else { end = middle }
            }
            return visible + start
        }

        func removingPrefixes(from source: String, startingAt location: Int = 0) -> String {
            guard !rawOffsets.isEmpty else { return source }
            var visible: [UInt16] = []
            visible.reserveCapacity(source.utf16.count - rawOffsets.count)
            var nextPrefix = rawOffsets.startIndex
            for (offset, unit) in source.utf16.enumerated() {
                if nextPrefix < rawOffsets.endIndex, rawOffsets[nextPrefix] == location + offset {
                    nextPrefix += 1
                } else {
                    visible.append(unit)
                }
            }
            return String(decoding: visible, as: UTF16.self)
        }

        private func firstOffset(where matches: (Int) -> Bool) -> Int {
            var start = 0
            var end = rawOffsets.count
            while start < end {
                let middle = start + (end - start) / 2
                if matches(rawOffsets[middle]) { end = middle }
                else { start = middle + 1 }
            }
            return start
        }
    }

    let id = UUID()
    let original: JJConflict
    let projected: JJConflict
    var block: NSRange
    var result: NSRange?
    var hasSeparator: Bool
    var appliedSides: Set<Int> = []
    private let originalPayloadRange: NSRange?
    private let originalPayload: String

    init(_ conflict: JJConflict) {
        let separator = conflict.resultRange != nil && !conflict.resultNeedsSeparator
        original = conflict
        projected = conflict.projectingDiffRows()
        block = projected.range
        result = projected.resultRange
        hasSeparator = separator
        let source = conflict.source as NSString
        let separatorWidth = conflict.resultSeparator.utf16.count
        originalPayloadRange = conflict.resultRange.map {
            NSRange(location: $0.location - conflict.range.location,
                    length: $0.length + separatorWidth)
        }
        originalPayload = originalPayloadRange.map(source.substring(with:)) ?? ""
    }

    var payload: NSRange? {
        let separator = original.resultSeparator.isEmpty ? original.lineEnding : original.resultSeparator
        return result.map { NSRange(location: $0.location, length: $0.length + (hasSeparator ? separator.utf16.count : 0)) }
    }

    func relocated(to location: Int) -> Self {
        var moved = self
        moved.result?.location += location - block.location
        moved.block.location = location
        return moved
    }

    static func project(_ conflicts: [JJConflict], in source: String) -> (text: String, edits: [Self]) {
        guard !conflicts.isEmpty else { return (source, []) }
        let raw = source as NSString
        var projected: [Self] = []
        var removed = 0
        var previousEnd = 0
        for conflict in conflicts {
            guard conflict.range.location >= previousEnd, NSMaxRange(conflict.range) <= raw.length,
                  raw.substring(with: conflict.range).utf8.elementsEqual(conflict.source.utf8) else { continue }
            let edit = Self(conflict).relocated(to: conflict.range.location - removed)
            projected.append(edit)
            removed += conflict.range.length - edit.block.length
            previousEnd = NSMaxRange(conflict.range)
        }
        return (projection(for: projected).removingPrefixes(from: source), projected)
    }

    static func projection(for edits: [Self]) -> Projection {
        var offsets: [Int] = []
        for edit in edits {
            let before = edit.block.location - edit.projected.range.location
            let after = NSMaxRange(edit.block) - NSMaxRange(edit.projected.range)
            let boundary = edit.projected.resultRange.map(NSMaxRange) ?? Int.max
            for row in edit.projected.highlights where row.role != .marker {
                let location = row.range.location
                offsets.append(location + (location < boundary ? before : after) + offsets.count)
            }
        }
        return Projection(rawOffsets: offsets)
    }

    static func drafts(in source: String, edits: [Self]) -> [SavedDraft] {
        let visible = source as NSString
        let projection = projection(for: edits)
        return edits.compactMap { edit in
            guard let payload = edit.payload, NSMaxRange(payload) <= visible.length else { return nil }
            let isEdited = !visible.substring(with: payload).utf8.elementsEqual(edit.originalPayload.utf8)
            guard isEdited || !edit.appliedSides.isEmpty else { return nil }
            let rawStart = projection.rawOffset(edit.block.location)
            let rawEnd = projection.rawOffset(NSMaxRange(edit.block))
            return SavedDraft(block: NSRange(location: rawStart, length: rawEnd - rawStart),
                              payload: NSRange(location: projection.rawOffset(payload.location), length: payload.length),
                              originalPayload: edit.originalPayload, appliedSides: edit.appliedSides.isEmpty ? nil : edit.appliedSides)
        }
    }

    func displayed(in source: NSString) -> JJConflict? {
        guard let result, NSMaxRange(block) <= source.length else { return nil }
        return projected.displayingResult(in: source, blockRange: block, resultRange: result, hasSeparator: hasSeparator)
    }

    static func textForSaving(_ source: String, edits: [Self]) -> String {
        materializedText(source, edits: edits, keepingDrafts: false)
    }

    static func textWithDrafts(_ source: String, edits: [Self]) -> String {
        materializedText(source, edits: edits, keepingDrafts: true)
    }

    private static func materializedText(_ source: String, edits: [Self], keepingDrafts: Bool) -> String {
        guard !edits.isEmpty else { return source }
        let visible = source as NSString
        let text = NSMutableString(capacity: visible.length)
        var end = 0
        for edit in edits {
            text.append(visible.substring(with: NSRange(location: end, length: edit.block.location - end)))
            if keepingDrafts, let payload = edit.payload, let originalPayload = edit.originalPayloadRange {
                let raw = NSMutableString(string: edit.original.source)
                raw.replaceCharacters(in: originalPayload, with: visible.substring(with: payload))
                text.append(raw as String)
            } else {
                text.append(edit.original.source)
            }
            end = NSMaxRange(edit.block)
        }
        text.append(visible.substring(from: end))
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

    func withInitialResult(length: Int) -> Self {
        var updated = self
        updated.hasSeparator = true
        updated.block.length += length + original.lineEnding.utf16.count
        updated.result?.length = length
        return updated
    }

    @concurrent
    static func restore(_ drafts: [SavedDraft], in source: String) async -> (text: String, edits: [Self])? {
        let displayed = source as NSString
        func contains(_ range: NSRange, in length: Int) -> Bool {
            range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
        }
        var lastEnd = 0
        for draft in drafts {
            guard draft.block.location >= lastEnd, contains(draft.block, in: displayed.length),
                  contains(draft.payload, in: displayed.length), draft.payload.location >= draft.block.location,
                  NSMaxRange(draft.payload) <= NSMaxRange(draft.block) else { return nil }
            lastEnd = NSMaxRange(draft.block)
        }
        let original = NSMutableString(string: source)
        for draft in drafts.reversed() { original.replaceCharacters(in: draft.payload, with: draft.originalPayload) }
        let text = original as String
        let conflicts = JJLineDiff.analyze(base: nil, current: text, isConflicted: true, recordedConflict: text).conflicts
        var delta = 0
        var removed = 0
        var nextDraft = 0
        var restored: [Self] = []
        for conflict in conflicts {
            let blockLocation = conflict.range.location + delta
            var edit = Self(conflict).relocated(to: blockLocation - removed)
            removed += conflict.range.length - edit.block.length
            if nextDraft < drafts.count, drafts[nextDraft].block.location == blockLocation {
                let draft = drafts[nextDraft]
                let difference = draft.payload.length - draft.originalPayload.utf16.count
                guard conflict.range.length + difference == draft.block.length,
                      conflict.resultRange.map({ $0.location + delta }) == draft.payload.location else { return nil }
                let separator = conflict.resultSeparator.isEmpty ? conflict.lineEnding : conflict.resultSeparator
                let storedPayload = displayed.substring(with: draft.payload)
                let separatorLength = separator.utf16.count
                let applied = draft.appliedSides ?? []
                guard applied.isSubset(of: Set(conflict.segments.compactMap { $0.kind.diffSide })) else { return nil }
                let hasSeparator = !storedPayload.isEmpty
                if hasSeparator, !storedPayload.utf8.suffix(separator.utf8.count).elementsEqual(separator.utf8) { return nil }
                edit.block.length += difference
                edit.hasSeparator = hasSeparator
                edit.result?.length = draft.payload.length - (hasSeparator ? separatorLength : 0)
                edit.appliedSides = applied
                delta += difference
                nextDraft += 1
            }
            restored.append(edit)
        }
        guard nextDraft == drafts.count else { return nil }
        return (projection(for: restored).removingPrefixes(from: source), restored)
    }
}
