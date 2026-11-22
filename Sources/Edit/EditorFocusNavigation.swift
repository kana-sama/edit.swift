import AppKit

struct FocusNavigationSelection: Equatable {
    let anchor: Int
    let head: Int

    var extent: NSRange {
        NSRange(location: min(anchor, head), length: abs(head - anchor))
    }

    func pieces(in scope: [NSRange]) -> [NSRange] {
        let parts = scope.map { NSIntersectionRange($0, extent) }.filter { $0.length > 0 }
        return parts.isEmpty ? [NSRange(location: head, length: 0)] : parts
    }
}

extension EditorTextView {
    var focusedSelectionGroups: [[NSRange]]? {
        guard let scope = focusRanges else { return nil }
        return focusedSelections(in: scope).map { $0.pieces(in: scope) }
    }

    func activeEnd(of range: NSRange) -> Int {
        if let group = multiCaret.focusNavigation?.last(where: { $0.extent == range }) {
            return group.head
        }
        if let group = multiCaret.focusNavigation?.last,
           range == selectedRange(),
           group.head >= range.location, group.head <= range.upperBound {
            return group.head
        }
        if let selection = multiCaret.navigation[range] {
            return selection.affinity == .upstream ? range.location : range.upperBound
        }
        if range == selectedRange(), selectionAffinity == .upstream {
            return range.location
        }
        return range.upperBound
    }

    @discardableResult
    func selectFocusedText() -> Bool {
        guard let scope = focusRanges, let first = scope.first, let last = scope.last else { return false }
        setFocusedSelections([FocusNavigationSelection(anchor: first.location, head: last.upperBound)], in: scope)
        return true
    }

    func restoreFocusedSelectionGroups(_ groups: [[NSRange]], primary: NSRange? = nil,
                                       activeEnd: Int? = nil) {
        guard let scope = focusRanges else { return }
        var selections = groups.compactMap { pieces -> FocusNavigationSelection? in
            guard let first = pieces.first, let last = pieces.last else { return nil }
            return FocusNavigationSelection(anchor: first.location, head: last.upperBound)
        }
        if let last = selections.last, let primary {
            let head = activeEnd ?? primary.upperBound
            let backward = head <= last.anchor ||
                (primary.location == last.anchor && primary.upperBound < last.head)
            selections[selections.count - 1] = FocusNavigationSelection(
                anchor: backward ? last.head : last.anchor, head: head
            )
        }
        setFocusedSelections(selections, in: scope, record: false)
    }

    func constrainNativeFocusSelection() -> Bool {
        guard let scope = focusRanges else { return false }
        let range = selectedRange()
        guard range.location != NSNotFound else { return true }
        let head = selectionAffinity == .upstream ? range.location : range.upperBound
        let anchor = head == range.location ? range.upperBound : range.location
        let selection = FocusNavigationSelection(anchor: nearestFocusPosition(anchor, in: scope),
                                                head: nearestFocusPosition(head, in: scope))
        if selection.pieces(in: scope) == [range], multiCaret.selections == [range] {
            multiCaret.focusNavigation = [selection]
            return true
        }
        setFocusedSelections([selection], in: scope)
        return true
    }

    func focusedPosition(
        from position: Int, direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination, in scope: [NSRange],
        nativePosition: (Int) -> Int?
    ) -> Int {
        guard let first = scope.first, let last = scope.last else { return position }
        let backward = direction == .backward || direction == .left || direction == .up
        if destination == .document { return backward ? first.location : last.upperBound }

        let position = nearestFocusPosition(position, in: scope)
        guard let index = scope.firstIndex(where: { $0.location <= position && position <= $0.upperBound }) else {
            return position
        }
        let span = scope[index]
        let adjacent = index + (backward ? -1 : 1)
        let native = nativePosition(position) ?? position

        if direction == .up || direction == .down {
            guard let text = textStorage?.mutableString else { return position }
            let currentLine = LineEditing.line(at: position, in: text)
            let candidateLine = LineEditing.line(at: native, in: text)
            let candidateStart = max(candidateLine.start, span.location)
            let candidateEnd = min(candidateLine.contentEnd, span.upperBound)
            if currentLine.start != candidateLine.start, candidateStart <= candidateEnd {
                return min(max(native, candidateStart), candidateEnd)
            }
            let candidateInside = span.location <= native && native <= span.upperBound
            if candidateInside && native != position { return native }
            guard scope.indices.contains(adjacent) else {
                return backward ? span.location : span.upperBound
            }
            let next = scope[adjacent]
            let nextLine = LineEditing.line(at: backward ? next.upperBound : next.location, in: text)
            let column = position - max(currentLine.start, span.location)
            let firstColumn = max(next.location, nextLine.start)
            let lastColumn = max(firstColumn, min(next.upperBound, nextLine.contentEnd))
            let target = min(firstColumn + column, lastColumn)
            if target == lastColumn { return target }
            return max(firstColumn, text.rangeOfComposedCharacterSequence(at: target).location)
        }

        if destination == .line || destination == .paragraph {
            return min(max(native, span.location), span.upperBound)
        }
        if (backward ? position == span.location : position == span.upperBound),
           scope.indices.contains(adjacent) {
            return backward ? scope[adjacent].upperBound : scope[adjacent].location
        }
        return min(max(native, span.location), span.upperBound)
    }

    func moveFocusedSelections(
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination, extending: Bool, steps: Int,
        nativePosition: (Int) -> Int?
    ) {
        guard let scope = focusRanges else { return }
        let backward = direction == .backward || direction == .left || direction == .up
        let vertical = direction == .up || direction == .down
        let selections = focusedSelections(in: scope).map { selection in
            if !extending, !vertical, destination == .character, selection.extent.length > 0 {
                let end = backward ? selection.extent.location : selection.extent.upperBound
                return FocusNavigationSelection(anchor: end, head: end)
            }
            var head = selection.head
            for _ in 0..<steps {
                let next = focusedPosition(from: head, direction: direction, destination: destination,
                                           in: scope, nativePosition: nativePosition)
                if next == head { break }
                head = next
            }
            return FocusNavigationSelection(anchor: extending ? selection.anchor : head, head: head)
        }
        setFocusedSelections(selections, in: scope)
        if let head = selections.last?.head { scrollRangeToVisible(NSRange(location: head, length: 0)) }
    }

    private func focusedSelections(in scope: [NSRange]) -> [FocusNavigationSelection] {
        if let selections = multiCaret.focusNavigation { return selections }
        return caretSelections.filter { $0.location != NSNotFound }.map { range in
            let head = activeEnd(of: range)
            let anchor = head == range.location ? range.upperBound : range.location
            return FocusNavigationSelection(anchor: nearestFocusPosition(anchor, in: scope),
                                            head: nearestFocusPosition(head, in: scope))
        }
    }

    private func setFocusedSelections(_ ranges: [FocusNavigationSelection], in scope: [NSRange], record: Bool = true) {
        // Merge selections and carets in logical space, preserving the active end of the newest one.
        let merged = MultiCaretEditing.merged(ranges.map(\.extent))
        let groups = merged.count == ranges.count ? ranges : merged.compactMap { extent -> FocusNavigationSelection? in
            guard let latest = ranges.last(where: {
                extent.location <= $0.extent.location && $0.extent.upperBound <= extent.upperBound
            }) else { return nil }
            return latest.head >= latest.anchor
                ? FocusNavigationSelection(anchor: extent.location, head: extent.upperBound)
                : FocusNavigationSelection(anchor: extent.upperBound, head: extent.location)
        }
        let parts = groups.flatMap { group -> [NSRange] in
            var regions = group.pieces(in: scope)
            if let primary = regions.firstIndex(where: { $0.location <= group.head && group.head <= $0.upperBound }) {
                let active = regions.remove(at: primary)
                regions.append(active)
            } else {
                regions.append(NSRange(location: group.head, length: 0))
            }
            return regions
        }
        setCaretSelections(parts, record: record, focusNavigation: groups)
    }

    private func nearestFocusPosition(_ position: Int, in scope: [NSRange]) -> Int {
        guard let first = scope.first, let last = scope.last else { return position }
        if position < first.location { return first.location }
        var previous = first
        for span in scope {
            if position < span.location {
                return position - previous.upperBound <= span.location - position ? previous.upperBound : span.location
            }
            if position <= span.upperBound { return position }
            previous = span
        }
        return last.upperBound
    }
}
