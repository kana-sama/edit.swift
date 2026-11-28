import AppKit

@MainActor
final class JJInlineDiffInteraction {
    typealias Position = JJInlineDiffSelection.Position

    private struct Selection {
        let anchor: Position
        let head: Position

        func offsets(in projection: JJInlineDiffSelection) -> (anchor: Int, head: Int)? {
            guard let anchor = projection.displayOffset(for: anchor),
                  let head = projection.displayOffset(for: head) else { return nil }
            return (anchor, head)
        }
    }

    private weak var editor: EditorTextView?
    private let layout: JJInlineDiffLayout
    private var selection: Selection?
    private var navigationSelection: NSTextSelection?
    private weak var navigationManager: NSTextLayoutManager?
    private(set) var isMirroringProjectedSelection = false

    init(editor: EditorTextView, layout: JJInlineDiffLayout) {
        self.editor = editor
        self.layout = layout
    }

    var hasProjectedCaret: Bool {
        guard case .removed = selection?.head, let projection = layout.currentProjection() else { return false }
        return selectedRange(in: projection)?.length == 0
    }

    var head: Position? { selection?.head }

    var caretRect: NSRect? {
        guard hasProjectedCaret, case .removed(let key, let offset) = head else { return nil }
        return layout.removedCaretRect(key: key, offset: offset)
    }

    var projectedEditRange: NSRange? {
        guard selection != nil, let projection = layout.currentProjection(), let range = selectedRange(in: projection),
              let live = projection.liveRange(for: range), hasProjectedCaret || live.length < range.length else { return nil }
        return live
    }

    func sourceTextChanged() {
        clear()
        layout.sourceTextChanged()
    }

    func clear() {
        guard selection != nil else { return }
        selection = nil
        navigationSelection = nil
        updatePresentation()
        editor?.refreshCaretDecorations()
    }

    func selectionChanged() {
        guard selection != nil, !isMirroringProjectedSelection, let editor,
              let projection = layout.currentProjection(), let range = selectedRange(in: projection),
              projection.liveRange(for: range) != editor.selectedRange() || editor.hasSecondarySelections else { return }
        clear()
    }

    func updatePresentation() {
        let projection = layout.currentProjection()
        layout.showSelection(projection.flatMap { selectedRange(in: $0) }, in: projection)
    }

    @discardableResult
    func select(from anchor: Position, to head: Position) -> Bool {
        guard let editor, let projection = layout.currentProjection() else { return false }
        let next = Selection(anchor: anchor, head: head)
        guard let offsets = next.offsets(in: projection),
              let live = projection.liveRange(for: Self.range(offsets.anchor, offsets.head)),
              editor.focusAllowsEdits([live]) else { return false }
        if selection?.head != head { editor.multiCaret.restartBlink = true }
        selection = next
        navigationSelection = nil
        isMirroringProjectedSelection = true
        editor.setCaretSelections([live], record: false,
                                  primaryAffinity: offsets.head < offsets.anchor ? .upstream : .downstream)
        isMirroringProjectedSelection = false
        updatePresentation()
        editor.refreshCaretDecorations()
        return true
    }

    func copy(to pasteboard: NSPasteboard, cutting: Bool) -> Bool {
        guard let editor, let projection = layout.currentProjection(), var range = selectedRange(in: projection),
              let live = projectedEditRange else { return false }
        if range.length == 0, case .removed(let key, _) = selection?.head,
           let block = projection.displayRange(forRemoved: key) {
            let line = LineEditing.line(at: min(range.location, NSMaxRange(block) - 1), in: projection.string as NSString)
            range = NSIntersectionRange(block, NSRange(location: line.start, length: line.end - line.start))
        }
        guard let text = projection.text(in: range), !text.isEmpty else { return true }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        if cutting, live.length > 0, editor.isEditable, editor.focusAllowsEdits([live]) {
            clear()
            let edit = MultiCaretEditing.Replacement(range: live, text: "")
            editor.applyMultiEdits([edit], selections: [NSRange(location: live.location, length: 0)])
        }
        return true
    }

    func mouseDown(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard modifiers.isEmpty || modifiers == .shift,
              let editor, let window = editor.window, editor.isSelectable, !editor.hasMarkedText(),
              let projection = layout.currentProjection(), let hit = position(at: event, in: editor),
              let offset = projection.displayOffset(for: hit) else { return false }
        if modifiers.isEmpty, event.clickCount == 1, projectedEditRange == nil,
           case .live(let location) = hit, NSLocationInRange(location, editor.selectedRange()) {
            return false
        }
        guard window.makeFirstResponder(editor) else { return false }
        let previous = currentSelection(in: editor)

        let granularity: NSSelectionGranularity = event.clickCount >= 3 ? .selectByParagraph
            : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let wordText = granularity == .selectByWord ? layout.textLayout()?.text : nil
        let initial = wordText.map { EditorWordBoundary.clickSelection(at: offset, in: $0) }
            ?? selectionRange(at: offset, granularity: granularity, editor: editor)
        if modifiers == .shift {
            _ = select(from: previous.anchor, to: hit)
        } else if initial.length > 0, let start = projection.position(at: initial.location),
                  let end = projection.position(at: NSMaxRange(initial), preferPrevious: true) {
            _ = select(from: start, to: end)
        } else {
            _ = select(from: hit, to: hit)
        }
        let pressed = hit
        let revision = layout.projectionRevision
        var drag: NSEvent?
        window.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: 0.05, mode: .eventTracking) { event, stop in
            if event?.type == .leftMouseUp { stop.pointee = true }
            guard editor.window === window, self.layout.projectionRevision == revision else { stop.pointee = true; return }
            if event?.type == .leftMouseDragged { drag = event }
            guard drag != nil, let location = event ?? drag else { return }
            if editor.autoscroll(with: location) { self.layout.layout() }
            guard let hit = self.position(at: location, in: editor), let end = projection.displayOffset(for: hit) else { return }
            if modifiers == .shift {
                _ = self.select(from: previous.anchor, to: hit)
            } else if granularity == .selectByCharacter {
                _ = self.select(from: pressed, to: hit)
            } else {
                let anchor: Int
                let head: Int
                if let wordText {
                    (anchor, head) = EditorWordBoundary.dragSelection(from: initial, to: end, in: wordText)
                } else {
                    let range = self.selectionRange(at: end, granularity: granularity, editor: editor)
                    let backwards = end < initial.location
                    anchor = backwards ? initial.upperBound : initial.location
                    head = backwards ? range.location : range.upperBound
                }
                if let start = projection.position(at: anchor, preferPrevious: head < anchor),
                   let end = projection.position(at: head, preferPrevious: head >= anchor) {
                    _ = self.select(from: start, to: end)
                }
            }
        }
        return true
    }

    func handleSelectionCommand(_ command: Selector) -> Bool {
        guard let editor, editor.isSelectable, editor.focusSession == nil, !editor.hasSecondarySelections,
              !editor.hasMarkedText(), let projection = layout.currentProjection() else { return false }
        if command == #selector(NSResponder.selectAll(_:)) {
            guard let start = projection.position(at: 0), let end = projection.position(at: projection.length) else { return false }
            return select(from: start, to: end)
        }
        guard let movement = editor.selectionMovement(for: command) else { return false }
        let old = currentSelection(in: editor)
        guard let textLayout = layout.textLayout()?.manager,
              let offsets = old.offsets(in: projection),
              let textRange = editor.textRange(Self.range(offsets.anchor, offsets.head), in: textLayout) else { return false }
        textLayout.ensureLayout(for: textRange)
        var result = (navigationManager === textLayout ? navigationSelection : nil) ?? NSTextSelection(
            range: textRange, affinity: offsets.head < offsets.anchor ? .upstream : .downstream, granularity: .character
        )
        for _ in 0..<movement.steps {
            guard let next = textLayout.textSelectionNavigation.destinationSelection(
                for: result, direction: movement.direction, destination: movement.destination,
                extending: movement.extending, confined: false
            ) else { break }
            result = next
        }
        guard let first = result.textRanges.first, let last = result.textRanges.last else { return true }
        let range = NSUnionRange(editor.charRange(first, in: textLayout), editor.charRange(last, in: textLayout))
        let end = movement.extending && offsets.anchor == NSMaxRange(range) ? range.location : NSMaxRange(range)
        guard let head = projection.position(at: end) else { return false }
        if projectedEditRange == nil, case .live = head {
            let travel = Self.range(offsets.head, end)
            // Live-only movement can use the source editor's native selection history and geometry.
            if projection.liveRange(for: travel)?.length == travel.length { return false }
        }
        guard select(from: movement.extending ? old.anchor : head, to: head) else { return true }
        navigationSelection = result
        navigationManager = textLayout
        switch head {
        case .live(let offset): editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
        case .removed: layout.revealCaret(at: head)
        }
        return true
    }

    private func currentSelection(in editor: EditorTextView) -> Selection {
        if let selection { return selection }
        let live = editor.selectedRange()
        let head = editor.activeEnd(of: live)
        return Selection(anchor: .live(head == live.location ? NSMaxRange(live) : live.location), head: .live(head))
    }

    private func selectedRange(in projection: JJInlineDiffSelection) -> NSRange? {
        selection?.offsets(in: projection).map { Self.range($0.anchor, $0.head) }
    }

    private func position(at event: NSEvent, in editor: EditorTextView) -> Position? {
        let point = editor.convert(event.locationInWindow, from: nil)
        if let removed = layout.removedPosition(at: point) { return removed }
        let offset = editor.characterIndexForInsertion(at: point)
        guard offset != NSNotFound else { return nil }
        return .live(offset)
    }

    private func selectionRange(at offset: Int, granularity: NSSelectionGranularity, editor: EditorTextView) -> NSRange {
        let caret = NSRange(location: offset, length: 0)
        guard granularity == .selectByParagraph else { return caret }
        guard let layout = layout.textLayout()?.manager,
              let range = editor.textRange(caret, in: layout) else { return caret }
        let selection = NSTextSelection(range: range, affinity: .downstream, granularity: .character)
        let result = layout.textSelectionNavigation.textSelection(for: .paragraph, enclosing: selection)
        guard let first = result.textRanges.first, let last = result.textRanges.last else { return caret }
        return NSUnionRange(editor.charRange(first, in: layout), editor.charRange(last, in: layout))
    }

    private static func range(_ a: Int, _ b: Int) -> NSRange {
        NSRange(location: min(a, b), length: abs(a - b))
    }
}
