import AppKit

@MainActor
final class MultiCaretState {
    var selections: [NSRange] = []
    var undo: [[NSRange]] = []
    var redo: [[NSRange]] = []
    var isApplying = false
    var pendingSkip = false
    var navigation: [NSRange: NSTextSelection] = [:]
    var indicators: [NSTextInsertionIndicator] = []
    var highlights: [NSRect] = []

    func remember(_ selection: [NSRange]) {
        undo.append(selection)
        if undo.count > 100 { undo.removeFirst() }
        redo.removeAll()
    }
}

private final class SecondaryInsertionIndicator: NSTextInsertionIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension EditorTextView {
    var caretSelections: [NSRange] {
        multiCaret.selections.isEmpty ? [selectedRange()] : multiCaret.selections
    }

    var hasSecondarySelections: Bool { caretSelections.count > 1 }

    func setCaretSelections(
        _ ranges: [NSRange], record: Bool = true, navigation: [NSRange: NSTextSelection] = [:]
    ) {
        let selections = MultiCaretEditing.merged(ranges)
        guard let primary = selections.last else { return }
        let previous = caretSelections
        if record, previous != selections { multiCaret.remember(previous) }

        multiCaret.isApplying = true
        multiCaret.selections = selections
        multiCaret.navigation = navigation
        setSelectedRange(primary)
        multiCaret.isApplying = false
        requestLineRefresh()
    }

    func nativeSelectionChanged() {
        guard !multiCaret.isApplying else { return }
        let previous = multiCaret.selections
        let native = [selectedRange()]
        if !previous.isEmpty && previous != native {
            multiCaret.remember(previous)
        }
        multiCaret.selections = native
        multiCaret.navigation = [:]
    }

    func resetSelectionHistory() {
        multiCaret.undo.removeAll()
        multiCaret.redo.removeAll()
        multiCaret.pendingSkip = false
    }

    func resetMultiCarets() {
        resetSelectionHistory()
        multiCaret.selections = []
        multiCaret.navigation = [:]
        requestLineRefresh()
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(direction: .up) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(direction: .down) }

    private func addCaret(direction: NSTextSelectionNavigation.Direction) {
        let candidates = caretSelections
        let visualOrder = MultiCaretEditing.ordered(candidates)
        guard let edge = direction == .up ? visualOrder.first : visualOrder.last,
              let target = navigate(edge, direction: direction, destination: .character),
              target.location != edge.location else { return }
        let newCaret = NSRange(location: target.location, length: 0)
        setCaretSelections(candidates + [newCaret])
        scrollRangeToVisible(newCaret)
    }

    @objc func addCaretsAtLineEnds(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        let carets = caretSelections.flatMap { MultiCaretEditing.selectionEnds(in: $0, text: text) }
        setCaretSelections(carets)
        if let last = carets.last { scrollRangeToVisible(last) }
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        let skip = multiCaret.pendingSkip
        multiCaret.pendingSkip = false
        addNextOccurrence(skipping: skip)
    }

    @objc func skipNextOccurrence(_ sender: Any?) {
        multiCaret.pendingSkip = false
        addNextOccurrence(skipping: true)
    }

    private func addNextOccurrence(skipping: Bool) {
        guard let text = textStorage?.mutableString, let primary = caretSelections.last else { return }
        if primary.length == 0 {
            let word = selectionRange(forProposedRange: primary, granularity: .selectByWord)
            if word.length > 0 { setCaretSelections(caretSelections.dropLast() + [word]) }
            return
        }

        let needle = text.substring(with: primary)
        let selections = caretSelections
        let after = NSRange(location: NSMaxRange(primary), length: text.length - NSMaxRange(primary))
        let before = NSRange(location: 0, length: primary.location)
        for search in [after, before] {
            var start = search.location
            while start < NSMaxRange(search) {
                let result = text.range(of: needle, options: .literal,
                                        range: NSRange(location: start, length: NSMaxRange(search) - start))
                guard result.location != NSNotFound else { break }
                if !selections.contains(where: { NSIntersectionRange($0, result).length > 0 }) {
                    setCaretSelections((skipping ? Array(selections.dropLast()) : selections) + [result])
                    scrollRangeToVisible(result)
                    return
                }
                start = NSMaxRange(result)
            }
        }
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let text = textStorage?.mutableString,
              let primary = caretSelections.last, primary.length > 0 else { return }
        let needle = text.substring(with: primary)
        var start = 0
        var matches: [NSRange] = []
        while start < text.length {
            let range = text.range(of: needle, options: .literal, range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            if NSIntersectionRange(range, primary).length == 0 {
                matches.append(range)
                start = NSMaxRange(range)
            } else {
                start = NSMaxRange(primary)
            }
        }
        setCaretSelections(matches + [primary])
    }

    @objc func undoSelection(_ sender: Any?) {
        guard let previous = multiCaret.undo.popLast() else { return }
        multiCaret.redo.append(caretSelections)
        setCaretSelections(previous, record: false)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
    }

    @objc func redoSelection(_ sender: Any?) {
        guard let next = multiCaret.redo.popLast() else { return }
        multiCaret.undo.append(caretSelections)
        setCaretSelections(next, record: false)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
    }

    @objc func keepPrimarySelection(_ sender: Any?) {
        if let primary = caretSelections.last { setCaretSelections([primary]) }
    }

    func handleMultiCaretKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command && character == "k" && !hasMarkedText() {
            multiCaret.pendingSkip = true
            return true
        }
        if multiCaret.pendingSkip && modifiers == .command && character == "d" {
            skipNextOccurrence(nil)
            return true
        }
        multiCaret.pendingSkip = false
        if modifiers.isEmpty && character == "\u{1b}" && hasSecondarySelections && !hasMarkedText() {
            keepPrimarySelection(nil)
            return true
        }
        return false
    }

    func addCaret(at event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option,
              isSelectable, !hasMarkedText() else { return false }
        window?.makeFirstResponder(self)
        let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard location != NSNotFound, location <= (textStorage?.length ?? 0) else { return true }
        setCaretSelections(caretSelections + [NSRange(location: location, length: 0)])
        return true
    }

    func validateSelectionCommand(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(undoSelection(_:)): return !multiCaret.undo.isEmpty
        case #selector(redoSelection(_:)): return !multiCaret.redo.isEmpty
        case #selector(keepPrimarySelection(_:)): return hasSecondarySelections
        case #selector(selectAllOccurrences(_:)), #selector(addCaretsAtLineEnds(_:)):
            return isSelectable && !hasMarkedText() && (caretSelections.last?.length ?? 0) > 0
        case #selector(addCaretAbove(_:)), #selector(addCaretBelow(_:)),
             #selector(selectNextOccurrence(_:)), #selector(skipNextOccurrence(_:)):
            return isSelectable && !hasMarkedText() && (textStorage?.length ?? 0) > 0
        default: return nil
        }
    }

    func textRange(_ range: NSRange, in layout: NSTextLayoutManager) -> NSTextRange? {
        let start = layout.documentRange.location
        guard let lower = layout.location(start, offsetBy: range.location),
              let upper = layout.location(lower, offsetBy: range.length) else { return nil }
        return NSTextRange(location: lower, end: upper)
    }

    func charRange(_ range: NSTextRange, in layout: NSTextLayoutManager) -> NSRange {
        let start = layout.documentRange.location
        return NSRange(location: layout.offset(from: start, to: range.location),
                       length: layout.offset(from: range.location, to: range.endLocation))
    }

    private func navigate(
        _ range: NSRange,
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        extending: Bool = false
    ) -> NSRange? {
        navigationResult(range, direction: direction, destination: destination, extending: extending)?.range
    }

    private func navigationResult(
        _ range: NSRange,
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        extending: Bool
    ) -> (range: NSRange, selection: NSTextSelection)? {
        guard let layout = textLayoutManager, let textRange = textRange(range, in: layout) else { return nil }
        let selection = multiCaret.navigation[range] ?? NSTextSelection(
            range: textRange, affinity: .downstream, granularity: .character
        )
        guard let result = layout.textSelectionNavigation.destinationSelection(
            for: selection, direction: direction, destination: destination, extending: extending, confined: false
        ), let first = result.textRanges.first, let last = result.textRanges.last else { return nil }
        return (NSUnionRange(charRange(first, in: layout), charRange(last, in: layout)), result)
    }

    func moveSecondarySelections(command: Selector) -> Bool {
        guard hasSecondarySelections, !hasMarkedText() else { return false }
        typealias Direction = NSTextSelectionNavigation.Direction
        typealias Destination = NSTextSelectionNavigation.Destination
        let movement: (Direction, Destination, Bool)
        switch command {
        case #selector(moveBackward(_:)): movement = (.backward, .character, false)
        case #selector(moveForward(_:)): movement = (.forward, .character, false)
        case #selector(moveLeft(_:)): movement = (.left, .character, false)
        case #selector(moveRight(_:)): movement = (.right, .character, false)
        case #selector(moveUp(_:)): movement = (.up, .character, false)
        case #selector(moveDown(_:)): movement = (.down, .character, false)
        case #selector(moveWordBackward(_:)): movement = (.backward, .word, false)
        case #selector(moveWordForward(_:)): movement = (.forward, .word, false)
        case #selector(moveWordLeft(_:)): movement = (.left, .word, false)
        case #selector(moveWordRight(_:)): movement = (.right, .word, false)
        case #selector(moveToBeginningOfLine(_:)): movement = (.backward, .line, false)
        case #selector(moveToEndOfLine(_:)): movement = (.forward, .line, false)
        case #selector(moveToBeginningOfDocument(_:)): movement = (.backward, .document, false)
        case #selector(moveToEndOfDocument(_:)): movement = (.forward, .document, false)
        case #selector(moveBackwardAndModifySelection(_:)): movement = (.backward, .character, true)
        case #selector(moveForwardAndModifySelection(_:)): movement = (.forward, .character, true)
        case #selector(moveLeftAndModifySelection(_:)): movement = (.left, .character, true)
        case #selector(moveRightAndModifySelection(_:)): movement = (.right, .character, true)
        case #selector(moveUpAndModifySelection(_:)): movement = (.up, .character, true)
        case #selector(moveDownAndModifySelection(_:)): movement = (.down, .character, true)
        case #selector(moveWordBackwardAndModifySelection(_:)): movement = (.backward, .word, true)
        case #selector(moveWordForwardAndModifySelection(_:)): movement = (.forward, .word, true)
        case #selector(moveWordLeftAndModifySelection(_:)): movement = (.left, .word, true)
        case #selector(moveWordRightAndModifySelection(_:)): movement = (.right, .word, true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)): movement = (.backward, .line, true)
        case #selector(moveToEndOfLineAndModifySelection(_:)): movement = (.forward, .line, true)
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): movement = (.backward, .document, true)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): movement = (.forward, .document, true)
        default: return false
        }
        var navigation: [NSRange: NSTextSelection] = [:]
        let ranges = caretSelections.map { range in
            guard let result = navigationResult(range, direction: movement.0, destination: movement.1,
                                                extending: movement.2) else { return range }
            navigation[result.range] = result.selection
            return result.range
        }
        setCaretSelections(ranges, navigation: navigation)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
        return true
    }

    func refreshSecondarySelections() {
        let old = multiCaret.highlights
        var highlights: [NSRect] = []
        var carets: [NSRect] = []
        let secondary = caretSelections.dropLast()
        let showInsertionIndicators = window?.isKeyWindow == true
        if !secondary.isEmpty, let window, let layout = textLayoutManager,
           let viewport = layout.textViewportLayoutController.viewportRange {
            let visible = charRange(viewport, in: layout)
            let focus = window.firstResponder === self
            for range in secondary {
                if range.length == 0 {
                    guard focus, range.location >= visible.location, range.location <= NSMaxRange(visible) else { continue }
                    let caret = firstRect(forCharacterRange: range, actualRange: nil)
                    if caret.height > 0 {
                        carets.append(convert(window.convertFromScreen(caret), from: nil))
                    }
                } else {
                    let visibleSelection = NSIntersectionRange(range, visible)
                    guard visibleSelection.length > 0, let selected = textRange(visibleSelection, in: layout) else { continue }
                    layout.enumerateTextSegments(in: selected, type: .selection, options: .rangeNotRequired) {
                        _, frame, _, _ in
                        highlights.append(frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
                        return true
                    }
                }
            }
        }
        if old != highlights {
            multiCaret.highlights = highlights
            for rect in old + highlights { setNeedsDisplay(rect.intersection(visibleRect)) }
        }
        while multiCaret.indicators.count > carets.count {
            multiCaret.indicators.removeLast().removeFromSuperview()
        }
        for (index, frame) in carets.enumerated() {
            let target = NSRect(x: frame.minX, y: frame.minY, width: max(1, frame.width), height: frame.height)
            if index == multiCaret.indicators.count {
                let indicator = SecondaryInsertionIndicator(frame: target)
                indicator.color = insertionPointColor
                indicator.automaticModeOptions = []
                indicator.displayMode = showInsertionIndicators ? .automatic : .hidden
                addSubview(indicator)
                multiCaret.indicators.append(indicator)
            } else {
                let indicator = multiCaret.indicators[index]
                if indicator.frame != target { indicator.frame = target }
                let display: NSTextInsertionIndicator.DisplayMode = showInsertionIndicators ? .automatic : .hidden
                if indicator.displayMode != display { indicator.displayMode = display }
            }
        }
    }

    func drawSecondarySelections(in dirtyRect: NSRect) {
        guard !multiCaret.highlights.isEmpty else { return }
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        for highlight in multiCaret.highlights {
            highlight.intersection(dirtyRect).fill()
        }
    }

    func hideSecondaryCarets() {
        for indicator in multiCaret.indicators { indicator.removeFromSuperview() }
        multiCaret.indicators.removeAll()
        for rect in multiCaret.highlights { setNeedsDisplay(rect.intersection(visibleRect)) }
    }
}
