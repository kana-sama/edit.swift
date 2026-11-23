import Accessibility
import AppKit

@MainActor
final class MultiCaretState {
    var selections: [NSRange] = []
    struct Snapshot {
        let ranges: [NSRange]
        let focusNavigation: [FocusNavigationSelection]?
    }

    var undo: [Snapshot] = []
    var redo: [Snapshot] = []
    var isApplying = false
    var pendingSkip = false
    var navigation: [NSRange: NSTextSelection] = [:]
    var focusNavigation: [FocusNavigationSelection]?
    var indicatorGroup: CaretIndicatorGroup?
    var nativeCaretColor: NSColor?
    var restartBlink = true
    var highlights: [NSRect] = []

    func remember(_ selection: [NSRange]) {
        undo.append(Snapshot(ranges: selection, focusNavigation: focusNavigation))
        if undo.count > 100 { undo.removeFirst() }
        redo.removeAll()
    }
}

final class CaretIndicatorGroup: NSView {
    static let blinkKey = "caretBlink"
    private(set) var caretRects: [NSRect] = []
    private var caretColor = NSColor.textColor

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        caretColor.setFill()
        for caret in caretRects where caret.intersects(dirtyRect) { caret.fill() }
    }

    func update(_ carets: [NSRect], viewport: NSRect, color: NSColor, restartBlink: Bool) {
        if frame != viewport { frame = viewport }
        let width = max(1, floor(convertToBacking(NSSize(width: 1.5, height: 0)).width))
        let rects = carets.map { caret in
            let backing = convertToBacking(caret.offsetBy(dx: -viewport.minX, dy: -viewport.minY))
            // Adjacent lines share the same pixel at the boundary between their carets.
            let top = backing.minY.rounded()
            return convertFromBacking(NSRect(x: (backing.midX - width / 2).rounded(), y: top,
                                             width: width, height: backing.maxY.rounded() - top))
        }
        if caretRects != rects || caretColor != color {
            caretRects = rects
            caretColor = color
            needsDisplay = true
        }

        guard let layer else { return }
        if AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator {
            layer.removeAnimation(forKey: Self.blinkKey)
        } else if restartBlink || layer.animation(forKey: Self.blinkKey) == nil {
            // Keep still after an edit, then blink the whole group on one timeline.
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 1, 0, 0, 1]
            blink.keyTimes = [0, 0.45, 0.5, 0.95, 1]
            blink.duration = 1.2
            blink.repeatCount = .infinity
            blink.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.add(blink, forKey: Self.blinkKey)
        }
    }
}

extension EditorTextView {
    var caretSelections: [NSRange] {
        multiCaret.selections.isEmpty ? [selectedRange()] : multiCaret.selections
    }

    var hasSecondarySelections: Bool { caretSelections.count > 1 }

    func setCaretSelections(
        _ ranges: [NSRange], record: Bool = true, navigation: [NSRange: NSTextSelection] = [:],
        focusNavigation: [FocusNavigationSelection]? = nil, primaryAffinity: NSSelectionAffinity? = nil,
        occurrenceSession: OccurrenceHighlighting.Session? = nil
    ) {
        let selections = MultiCaretEditing.merged(ranges)
        guard let primary = selections.last else { return }
        if let diff = jjInlineDiff, !diff.isMirroringProjectedSelection { diff.clearProjectedSelection() }
        let previous = caretSelections
        if record, previous != selections { multiCaret.remember(previous) }

        if previous != selections { multiCaret.restartBlink = true }
        multiCaret.isApplying = true
        multiCaret.selections = selections
        multiCaret.navigation = navigation
        multiCaret.focusNavigation = focusNavigation
        if let primaryAffinity {
            setSelectedRange(primary, affinity: primaryAffinity, stillSelecting: false)
        } else {
            setSelectedRange(primary)
        }
        multiCaret.isApplying = false
        occurrenceHighlighting.selectionChanged(occurrenceSession: occurrenceSession)
        requestLineRefresh()
    }

    func nativeSelectionChanged() {
        guard !multiCaret.isApplying, !constrainNativeFocusSelection() else { return }
        let previous = multiCaret.selections
        let native = [selectedRange()]
        if previous != native {
            multiCaret.restartBlink = true
            if !previous.isEmpty { multiCaret.remember(previous) }
        }
        multiCaret.selections = native
        multiCaret.navigation = [:]
        multiCaret.focusNavigation = nil
    }

    func resetSelectionHistory() {
        multiCaret.undo.removeAll()
        multiCaret.redo.removeAll()
        multiCaret.pendingSkip = false
    }

    func resetMultiCarets() {
        discardMultiCaretComposition()
        resetSelectionHistory()
        multiCaret.selections = []
        multiCaret.navigation = [:]
        multiCaret.focusNavigation = nil
        requestLineRefresh()
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(direction: .up) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(direction: .down) }

    private func addCaret(direction: NSTextSelectionNavigation.Direction) {
        let candidates = caretSelections
        let visualOrder = MultiCaretEditing.ordered(candidates)
        guard let edge = direction == .up ? visualOrder.first : visualOrder.last else { return }
        let target: Int?
        if let scope = focusRanges {
            target = focusedPosition(from: edge.location, direction: direction, destination: .character, in: scope) {
                navigate(NSRange(location: $0, length: 0), direction: direction, destination: .character)?.location
            }
        } else {
            target = navigate(edge, direction: direction, destination: .character)?.location
        }
        guard let target, target != edge.location else { return }
        let newCaret = NSRange(location: target, length: 0)
        setCaretSelections(candidates + [newCaret])
        scrollRangeToVisible(newCaret)
    }

    @objc func addCaretsAtLineEnds(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        let carets = caretSelections.flatMap { selection in
            let ends = MultiCaretEditing.selectionEnds(in: selection, text: text)
            guard focusRanges != nil else { return ends }
            return ends.map { NSRange(location: max(selection.location, $0.location), length: 0) }
        }
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
        if selectFocusedOccurrences(skipping ? .skip : .next, in: text) { return }
        if primary.length == 0 {
            var word = selectionRange(forProposedRange: primary, granularity: .selectByWord)
            if let scope = focusRanges {
                guard let range = scope.first(where: { $0.location <= primary.location && primary.location <= $0.upperBound })
                else { return }
                word = NSIntersectionRange(word, range)
            }
            if word.length > 0 {
                setCaretSelections(caretSelections.dropLast() + [word],
                                   occurrenceSession: .init(query: text.substring(with: word)))
            }
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
                    setCaretSelections((skipping ? Array(selections.dropLast()) : selections) + [result],
                                       occurrenceSession: .init(query: needle))
                    scrollRangeToVisible(result)
                    return
                }
                start = NSMaxRange(result)
            }
        }
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        if selectFocusedOccurrences(.all, in: text) { return }
        guard let primary = caretSelections.last, primary.length > 0 else { return }
        let needle = text.substring(with: primary)
        var matches: [NSRange] = []
        var start = 0
        while start < text.length {
            let range = text.range(of: needle, options: .literal,
                                   range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            if NSIntersectionRange(range, primary).length == 0 {
                matches.append(range)
                start = range.upperBound
            } else {
                start = primary.upperBound
            }
        }
        setCaretSelections(matches + [primary], occurrenceSession: .init(query: needle))
    }

    @objc func undoSelection(_ sender: Any?) {
        guard let previous = multiCaret.undo.popLast() else { return }
        multiCaret.redo.append(.init(ranges: caretSelections, focusNavigation: multiCaret.focusNavigation))
        setCaretSelections(previous.ranges, record: false, focusNavigation: previous.focusNavigation)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
    }

    @objc func redoSelection(_ sender: Any?) {
        guard let next = multiCaret.redo.popLast() else { return }
        multiCaret.undo.append(.init(ranges: caretSelections, focusNavigation: multiCaret.focusNavigation))
        setCaretSelections(next.ranges, record: false, focusNavigation: next.focusNavigation)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
    }

    @objc func keepPrimarySelection(_ sender: Any?) {
        guard let primary = caretSelections.last else { return }
        let navigation = multiCaret.navigation[primary].map { [primary: $0] } ?? [:]
        setCaretSelections([primary], navigation: navigation, primaryAffinity: selectionAffinity)
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
        return false
    }

    func addCaret(at event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option,
              isSelectable, !hasMarkedText() else { return false }
        window?.makeFirstResponder(self)
        let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard location != NSNotFound, location <= (textStorage?.length ?? 0),
              focusRanges?.contains(where: { $0.location <= location && location <= $0.upperBound }) ?? true else { return true }
        setCaretSelections(caretSelections + [NSRange(location: location, length: 0)])
        return true
    }

    func validateSelectionCommand(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(goToBracket(_:)), #selector(selectToBracket(_:)): return canNavigateBrackets
        case #selector(undoSelection(_:)): return !multiCaret.undo.isEmpty
        case #selector(redoSelection(_:)): return !multiCaret.redo.isEmpty
        case #selector(keepPrimarySelection(_:)): return hasSecondarySelections
        case #selector(selectAllOccurrences(_:)):
            let focusedLength = focusRanges == nil ? nil : multiCaret.focusNavigation?.last?.extent.length
            return isSelectable && !hasMarkedText() && (focusedLength ?? caretSelections.last?.length ?? 0) > 0
        case #selector(addCaretsAtLineEnds(_:)):
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
        extending: Bool,
        steps: Int = 1
    ) -> (range: NSRange, selection: NSTextSelection)? {
        guard let layout = textLayoutManager, let textRange = textRange(range, in: layout) else { return nil }
        var selection = multiCaret.navigation[range] ?? NSTextSelection(
            range: textRange, affinity: .downstream, granularity: .character
        )
        for _ in 0..<steps {
            guard let next = layout.textSelectionNavigation.destinationSelection(
                for: selection, direction: direction, destination: destination, extending: extending, confined: false
            ) else { break }
            selection = next
        }
        guard let first = selection.textRanges.first, let last = selection.textRanges.last else { return nil }
        return (NSUnionRange(charRange(first, in: layout), charRange(last, in: layout)), selection)
    }

    func selectionMovement(for command: Selector) -> (direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination, extending: Bool, steps: Int)? {
        typealias Direction = NSTextSelectionNavigation.Direction
        typealias Destination = NSTextSelectionNavigation.Destination
        let movement: (Direction, Destination, Bool)
        let steps: Int
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
        case #selector(moveToLeftEndOfLine(_:)): movement = (.left, .line, false)
        case #selector(moveToRightEndOfLine(_:)): movement = (.right, .line, false)
        case #selector(moveToBeginningOfLine(_:)): movement = (.backward, .line, false)
        case #selector(moveToEndOfLine(_:)): movement = (.forward, .line, false)
        case #selector(moveToBeginningOfParagraph(_:)): movement = (.backward, .paragraph, false)
        case #selector(moveToEndOfParagraph(_:)): movement = (.forward, .paragraph, false)
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
        case #selector(moveToLeftEndOfLineAndModifySelection(_:)): movement = (.left, .line, true)
        case #selector(moveToRightEndOfLineAndModifySelection(_:)): movement = (.right, .line, true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)): movement = (.backward, .line, true)
        case #selector(moveToEndOfLineAndModifySelection(_:)): movement = (.forward, .line, true)
        case #selector(moveToBeginningOfParagraphAndModifySelection(_:)),
             #selector(moveParagraphBackwardAndModifySelection(_:)): movement = (.backward, .paragraph, true)
        case #selector(moveToEndOfParagraphAndModifySelection(_:)),
             #selector(moveParagraphForwardAndModifySelection(_:)): movement = (.forward, .paragraph, true)
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): movement = (.backward, .document, true)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): movement = (.forward, .document, true)
        case #selector(pageUp(_:)): movement = (.up, .character, false)
        case #selector(pageDown(_:)): movement = (.down, .character, false)
        case #selector(pageUpAndModifySelection(_:)): movement = (.up, .character, true)
        case #selector(pageDownAndModifySelection(_:)): movement = (.down, .character, true)
        default: return nil
        }
        switch command {
        case #selector(pageUp(_:)), #selector(pageDown(_:)),
             #selector(pageUpAndModifySelection(_:)), #selector(pageDownAndModifySelection(_:)):
            let lineHeight = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 1
            steps = max(1, Int(visibleRect.height / max(1, lineHeight)) - 1)
        default:
            steps = 1
        }
        return (movement.0, movement.1, movement.2, steps)
    }

    func moveSecondarySelections(command: Selector) -> Bool {
        let primary = selectedRange()
        let hasBackwardSelection = primary.length > 0 && multiCaret.navigation[primary]?.affinity == .upstream
        guard (hasSecondarySelections || focusRanges != nil || hasBackwardSelection), !hasMarkedText(),
              let movement = selectionMovement(for: command) else { return false }
        if focusRanges != nil {
            moveFocusedSelections(direction: movement.direction, destination: movement.destination,
                                  extending: movement.extending, steps: movement.steps) {
                navigate(NSRange(location: $0, length: 0), direction: movement.direction,
                         destination: movement.destination)?.location
            }
            return true
        }
        var navigation: [NSRange: NSTextSelection] = [:]
        let ranges = caretSelections.map { range in
            guard let result = navigationResult(range, direction: movement.direction, destination: movement.destination,
                                                extending: movement.extending, steps: movement.steps) else { return range }
            navigation[result.range] = result.selection
            return result.range
        }
        setCaretSelections(ranges, navigation: navigation)
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }
        return true
    }

    func refreshCaretDecorations() {
        let selections = caretSelections
        let hidesLiveCaret = jjInlineDiff?.projectedEditRange?.length == 0
        let projectedCaret = hidesLiveCaret ? jjInlineDiff?.projectedCaretRect : nil
        let showCarets = (hidesLiveCaret ? projectedCaret != nil && isSelectable : isEditable)
            && !hasMarkedText() && window?.isKeyWindow == true && window?.firstResponder === self
        let old = multiCaret.highlights
        var highlights: [NSRect] = []
        var carets: [NSRect] = []
        let viewportRect = visibleRect
        let focusedGroups = focusRanges == nil ? [] : (multiCaret.focusNavigation ?? [])
        if showCarets || selections.count > 1 || !focusedGroups.isEmpty, let window, let layout = textLayoutManager {
            let visible = layout.textViewportLayoutController.viewportRange.map { charRange($0, in: layout) }
                ?? NSRange(location: 0, length: 0)
            var drawnRanges = Array(selections.dropLast())
            if let scope = focusRanges, !focusedGroups.isEmpty, let text = textStorage?.mutableString {
                for (block, next) in zip(scope, scope.dropFirst()) where
                    visible.location <= block.upperBound && block.upperBound < visible.upperBound {
                    if focusedGroups.contains(where: {
                        $0.extent.location <= block.upperBound && next.location <= $0.extent.upperBound
                    }) {
                        // Borrow the real separator's geometry for the virtual newline.
                        // It stays outside the editor's actual selections.
                        drawnRanges.append(LineEditing.line(at: block.upperBound, in: text).separatorRange)
                    }
                }
            }
            for range in drawnRanges {
                let visibleSelection = NSIntersectionRange(range, visible)
                guard visibleSelection.length > 0, let selected = textRange(visibleSelection, in: layout) else { continue }
                layout.enumerateTextSegments(in: selected, type: .selection, options: .rangeNotRequired) {
                    _, frame, _, _ in
                    highlights.append(frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
                    return true
                }
            }
            if showCarets, let projectedCaret {
                if projectedCaret.insetBy(dx: -1, dy: 0).intersects(viewportRect) { carets.append(projectedCaret) }
            } else if showCarets {
                for range in selections where range.length == 0 &&
                    visible.location <= range.location && range.location <= visible.upperBound {
                    let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
                    let caret = convert(window.convertFromScreen(screenRect), from: nil)
                    // TextKit can return a zero-width rectangle for a caret.
                    if caret.height > 0, caret.insetBy(dx: -1, dy: 0).intersects(viewportRect) { carets.append(caret) }
                }
            }
        }
        if old != highlights {
            multiCaret.highlights = highlights
            for rect in old + highlights { setNeedsDisplay(rect.intersection(visibleRect)) }
        }
        guard showCarets, selections.contains(where: { $0.length == 0 }),
              !carets.isEmpty || multiCaret.indicatorGroup != nil else {
            hideSharedCarets(restoringNativeCaret: !hidesLiveCaret)
            if hidesLiveCaret { hideNativeCaret() }
            return
        }
        let group = multiCaret.indicatorGroup ?? CaretIndicatorGroup()
        if multiCaret.indicatorGroup == nil {
            multiCaret.indicatorGroup = group
            group.wantsLayer = true
            group.clipsToBounds = true
            addSubview(group)
        }
        hideNativeCaret()
        group.update(carets, viewport: viewportRect, color: multiCaret.nativeCaretColor ?? .textColor,
                     restartBlink: multiCaret.restartBlink)
        multiCaret.restartBlink = false
    }

    func drawSecondarySelections(in dirtyRect: NSRect) {
        guard !multiCaret.highlights.isEmpty else { return }
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        for highlight in multiCaret.highlights {
            highlight.intersection(dirtyRect).fill()
        }
    }

    func hideCaretDecorations() {
        hideSharedCarets()
        for rect in multiCaret.highlights { setNeedsDisplay(rect.intersection(visibleRect)) }
    }

    private func hideNativeCaret() {
        if multiCaret.nativeCaretColor == nil {
            // TextKit still owns text input and selection. The editor draws the caret.
            multiCaret.nativeCaretColor = insertionPointColor
            insertionPointColor = .clear
        }
    }

    private func hideSharedCarets(restoringNativeCaret: Bool = true) {
        if restoringNativeCaret, let color = multiCaret.nativeCaretColor {
            insertionPointColor = color
            multiCaret.nativeCaretColor = nil
        }
        guard let group = multiCaret.indicatorGroup else { return }
        group.layer?.removeAnimation(forKey: CaretIndicatorGroup.blinkKey)
        group.removeFromSuperview()
        multiCaret.indicatorGroup = nil
        multiCaret.restartBlink = true
    }
}
