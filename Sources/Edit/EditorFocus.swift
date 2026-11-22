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
        self.ranges = MultiCaretEditing.merged(ranges)
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
        isEditable && focusSession == nil && !hasMarkedText() && caretSelections.contains { $0.length > 0 }
    }

    func beginFocus() {
        guard canFocusSelection else { return }
        let ranges = caretSelections.filter { $0.length > 0 }
        let carets = ranges.map { NSRange(location: activeEnd(of: $0), length: 0) }
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
        guard let focusRanges, let layout = textLayoutManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let visible = visibleRect
        guard !visible.isEmpty else { return }
        let viewportCharacters = charRange(viewport, in: layout)
        let origin = textContainerOrigin
        let active = CGMutablePath()
        for range in focusRanges where range.location <= NSMaxRange(viewportCharacters)
            && NSMaxRange(range) >= viewportCharacters.location {
            let footprint = range.length == 0 ? range : NSIntersectionRange(range, viewportCharacters)
            guard (range.length == 0 || footprint.length > 0), let text = textRange(footprint, in: layout) else { continue }
            layout.enumerateTextSegments(in: text, type: .selection, options: .rangeNotRequired) { _, rect, _, _ in
                let area = rect.offsetBy(dx: origin.x - visible.minX, dy: origin.y - visible.minY)
                let clipped = area.insetBy(dx: -1, dy: 0)
                    .intersection(NSRect(origin: .zero, size: visible.size).insetBy(dx: -2, dy: -2))
                if !clipped.isEmpty { active.addRect(clipped) }
                return true
            }
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
        decoration.active = active.normalized()
    }
}

@MainActor
final class FocusDecoration: NSView {
    var active = CGPath(rect: .zero, transform: nil) {
        didSet { if active != oldValue { needsDisplay = true } }
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
        let outside = CGPath(rect: bounds, transform: nil).subtracting(active)
        context.addPath(outside)
        NSColor.textBackgroundColor.withAlphaComponent(contrast ? 0.48 : 0.72).setFill()
        context.fillPath()
        context.addPath(active)
        NSColor.controlAccentColor.setStroke()
        context.setLineWidth(1)
        context.strokePath()
    }
}
