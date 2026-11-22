import AppKit

@MainActor
final class EditorFocusSession {
    struct Snapshot {
        let session: UUID
        fileprivate let ranges: [NSRange]
    }

    private let id = UUID()
    private(set) var ranges: [NSRange]

    init(_ ranges: [NSRange]) {
        self.ranges = ranges
    }

    var snapshot: Snapshot { Snapshot(session: id, ranges: ranges) }

    func contains(_ range: NSRange) -> Bool {
        range.location >= 0 && range.length >= 0 && ranges.contains {
            range.location >= $0.location && range.location <= NSMaxRange($0) &&
                range.length <= NSMaxRange($0) - range.location
        }
    }

    @discardableResult
    func restore(_ snapshot: Snapshot) -> Bool {
        guard snapshot.session == id else { return false }
        ranges = snapshot.ranges
        return true
    }

    func resizeMarkedRange(_ original: NSRange, to length: Int) {
        guard let index = ranges.firstIndex(where: { original.location >= $0.location && NSMaxRange(original) <= NSMaxRange($0) })
        else { return }
        let delta = length - original.length
        ranges[index].length += delta
        for following in ranges.indices.dropFirst(index + 1) { ranges[following].location += delta }
    }

    func apply(_ replacements: [MultiCaretEditing.Replacement]) {
        // Each edit belongs to one original range. Edits before that range move
        // both endpoints, and edits inside it move its end.
        var offset = 0
        var firstEdit = 0
        for index in ranges.indices {
            let range = ranges[index]
            var inside = 0
            while firstEdit < replacements.count {
                let edit = replacements[firstEdit]
                guard edit.range.location <= NSMaxRange(range) else { break }
                inside += edit.text.utf16.count - edit.range.length
                firstEdit += 1
            }
            ranges[index] = NSRange(location: range.location + offset, length: range.length + inside)
            offset += inside
        }
    }
}

@MainActor
final class EditorUndoManager: UndoManager {
    private var focusFloor: Int?
    private var restoreGroupsByEvent = true
    var hasFocusedEdits = false

    override var canUndo: Bool {
        super.canUndo && (focusFloor.map { undoCount > $0 } ?? true)
    }

    override var canRedo: Bool {
        (focusFloor == nil || hasFocusedEdits) && super.canRedo
    }

    override func undo() {
        if canUndo { super.undo() }
    }

    override func redo() {
        if canRedo { super.redo() }
    }

    func beginFocus() {
        restoreGroupsByEvent = groupsByEvent
        // Finish any open event group before setting the floor.
        while groupingLevel > 0 { endUndoGrouping() }
        groupsByEvent = false
        hasFocusedEdits = false
        focusFloor = undoCount
    }

    func endFocus() {
        guard focusFloor != nil else { return }
        focusFloor = nil
        groupsByEvent = restoreGroupsByEvent
    }
}

extension EditorTextView {
    var focusRanges: [NSRange]? { focusSession?.ranges }

    var canFocusSelection: Bool {
        isEditable && focusSession == nil && !hasMarkedText()
    }

    func beginFocus() {
        guard canFocusSelection, let text = textStorage?.mutableString else { return }
        let selections = caretSelections
        // Each block owns its internal line breaks. The break leading into
        // protected text stays outside, so Return at the end can add a line.
        let ranges = MultiCaretEditing.lineBlocks(in: text, for: selections).map(\.line.contentRange)
        guard !ranges.isEmpty else { return }
        let carets = selections.compactMap { selection -> NSRange? in
            guard let lines = LineEditing.affectedLines(in: text, selection: selection) else { return nil }
            return NSRange(location: min(activeEnd(of: selection), lines.contentEnd), length: 0)
        }
        let origin = enclosingScrollView?.visibleContentOrigin
        breakUndoCoalescing()
        editorUndoManager.beginFocus()
        focusSession = EditorFocusSession(ranges)
        resetSelectionHistory()
        setCaretSelections(carets, record: false)
        if let origin { enclosingScrollView?.scrollToVisibleContentOrigin(origin) }
        requestLineRefresh()
        onFocusScopeChange?()
    }

    func exitFocus(notify: Bool = true) {
        guard focusSession != nil else { return }
        if hasMarkedText() { unmarkText() }
        focusSession = nil
        focusDecoration?.removeFromSuperview()
        focusDecoration = nil
        resetSelectionHistory()
        breakUndoCoalescing()
        editorUndoManager.endFocus()
        requestLineRefresh()
        if notify { onFocusScopeChange?() }
    }

    func focusAllowsEdits(_ ranges: [NSRange]) -> Bool {
        guard let focusSession else { return true }
        return ranges.allSatisfy(focusSession.contains)
    }

    func withFocusEditsAllowed<T>(_ change: () -> T) -> T {
        let wasAllowed = focusEditsAllowed
        focusEditsAllowed = true
        defer { focusEditsAllowed = wasAllowed }
        return change()
    }

    func captureFocusSnapshot() -> EditorFocusSession.Snapshot? {
        focusSession?.snapshot
    }

    @discardableResult
    func updateFocus(
        after replacements: [MultiCaretEditing.Replacement], restoring snapshot: EditorFocusSession.Snapshot?
    ) -> Bool {
        guard let focusSession else { return false }
        if let snapshot {
            guard focusSession.restore(snapshot) else { return false }
        } else {
            focusSession.apply(replacements)
            editorUndoManager.hasFocusedEdits = true
        }
        requestLineRefresh()
        return true
    }

    func refreshFocusDecoration() {
        guard let focusRanges, let layout = textLayoutManager, let storage = textStorage else { return }
        let visible = visibleRect
        guard !visible.isEmpty else { return }
        let viewport = layout.textViewportLayoutController.viewportRange.map { charRange($0, in: layout) }
        guard let viewportCharacters = viewport ?? (storage.length == 0 ? NSRange(location: 0, length: 0) : nil)
        else { return }
        var activeBands: [CGRect] = []
        for range in focusRanges where range.location <= viewportCharacters.upperBound
            && range.upperBound >= viewportCharacters.location {
            let top: CGFloat
            if range.location < viewportCharacters.location {
                top = visible.minY - 1
            } else if let first = lineBounds(at: range.location) {
                top = first.minY
            } else if storage.length == 0 {
                top = textContainerOrigin.y
            } else {
                continue
            }

            let bottom: CGFloat
            if range.upperBound > viewportCharacters.upperBound {
                bottom = visible.maxY + 1
            } else if let last = lineBounds(at: range.upperBound) {
                bottom = last.maxY
            } else if storage.length == 0, let paragraph = defaultParagraphStyle {
                bottom = top + paragraph.minimumLineHeight
            } else {
                continue
            }

            guard top <= visible.maxY, bottom >= visible.minY, bottom > top else { continue }
            activeBands.append(CGRect(x: 0, y: top - visible.minY, width: visible.width, height: bottom - top))
        }

        let decoration: FocusDecoration
        if let focusDecoration {
            decoration = focusDecoration
        } else {
            decoration = FocusDecoration()
            decoration.setAccessibilityElement(false)
            decoration.wantsLayer = true
            decoration.layer?.zPosition = 1
            addSubview(decoration)
            focusDecoration = decoration
        }
        if decoration.frame != visible { decoration.frame = visible }
        decoration.activeBands = activeBands
    }
}

@MainActor
final class FocusDecoration: NSView {
    var activeBands: [CGRect] = [] {
        didSet { if activeBands != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        context.addRect(bounds)
        for band in activeBands {
            context.addRect(band.intersection(bounds))
        }
        NSColor.textBackgroundColor.withAlphaComponent(contrast ? 0.48 : 0.72).setFill()
        context.fillPath(using: .evenOdd)
        for band in activeBands {
            for y in [band.minY, band.maxY] where bounds.minY <= y && y <= bounds.maxY {
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
        }
        NSColor.controlAccentColor.setStroke()
        context.setLineWidth(1)
        context.strokePath()
    }
}
