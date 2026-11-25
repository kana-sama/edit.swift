import AppKit

@MainActor
final class JJInlineDiff: NSResponder {
    private weak var editor: EditorTextView?
    private let display: JJInlineDiffLayout
    private let interaction: JJInlineDiffInteraction
    private var hunks: [JJDiffHunk] = []
    private var expandableMarks: Set<JJLineMark> = []
    private var expanded: Set<NSRange> = []
    private var visibleHunks: [JJDiffHunk] = []
    private var normalizeCRLF = false
    private var current = true
    private var panels: [NSRange: JJInlineDiffControls] = [:]
    private weak var lastTextResponder: NSResponder?
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?
    private weak var trackedScroll: NSScrollView?

    init(editor: EditorTextView) {
        self.editor = editor
        let display = JJInlineDiffLayout(editor: editor)
        self.display = display
        interaction = JJInlineDiffInteraction(editor: editor, layout: display)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Inline diff is programmatically constructed") }

    var hasExpandedHunks: Bool { !expanded.isEmpty }
    var projectedEditRange: NSRange? { interaction.projectedEditRange }
    var hasProjectedCaret: Bool { interaction.hasProjectedCaret }
    var projectedCaretRect: NSRect? { interaction.caretRect }
    var isMirroringProjectedSelection: Bool { interaction.isMirroringProjectedSelection }

    func handleMouseDown(_ event: NSEvent) -> Bool { interaction.mouseDown(with: event) }
    func handleSelectionCommand(_ selector: Selector) -> Bool { interaction.handleSelectionCommand(selector) }
    func clearProjectedSelection() { interaction.clear() }
    func sourceTextChanged() { interaction.sourceTextChanged() }

    func copyProjectedSelection(to pasteboard: NSPasteboard, cutting: Bool) -> Bool {
        interaction.copy(to: pasteboard, cutting: cutting)
    }

    @discardableResult
    func select(from anchor: JJInlineDiffSelection.Position, to head: JJInlineDiffSelection.Position) -> Bool {
        interaction.select(from: anchor, to: head)
    }

    func update(_ updated: [JJDiffHunk], normalizeCRLF: Bool) {
        let sameHunks = updated == hunks
        current = true
        self.normalizeCRLF = normalizeCRLF
        if !sameHunks {
            hunks = updated
            expandableMarks = Set(updated.map(\.mark))
            let previouslyExpanded = expanded
            expanded = Set(updated.lazy.map(\.baseRange).filter { range in
                previouslyExpanded.contains(range) || previouslyExpanded.contains { previous in
                    if previous.length == 0 { return NSLocationInRange(previous.location, range) }
                    if range.length == 0 { return NSLocationInRange(range.location, previous) }
                    return NSIntersectionRange(previous, range).length > 0
                }
            })
            applyExpansion()
        } else if hasExpandedHunks {
            refreshControls()
        }
    }

    func suspend() {
        guard current else { return }
        current = false
        for panel in panels.values { panel.setAvailability(restore: false, previous: false, next: false) }
    }

    func canToggle(_ mark: JJLineMark) -> Bool { current && expandableMarks.contains(mark) }

    func toggle(_ mark: JJLineMark) {
        guard current, let hunk = hunks.first(where: { $0.mark == mark }) else { return }
        let opening = expanded.remove(hunk.baseRange) == nil
        if opening { expanded.insert(hunk.baseRange) }
        applyExpansion()
        if opening {
            display.reveal(hunk)
            layout()
        }
    }

    @discardableResult
    func collapseAll() -> Bool {
        guard hasExpandedHunks else { return false }
        expanded.removeAll()
        applyExpansion()
        return true
    }

    @discardableResult
    func expandAll() -> Bool {
        guard current, !hunks.isEmpty else { return false }
        let everything = Set(hunks.map(\.baseRange))
        guard everything != expanded else { return true }
        expanded = everything
        applyExpansion()
        return true
    }

    func selectionChanged() {
        interaction.selectionChanged()
        editor?.requestLineRefresh()
    }

    func layout() {
        guard hasExpandedHunks else { return }
        display.layout()
        interaction.updatePresentation()
        if interaction.hasProjectedCaret { editor?.refreshCaretDecorations() }
        refreshControls()
    }

    func drawBackground(in rect: NSRect, includesText: Bool = true) {
        if hasExpandedHunks { display.drawBackground(in: rect, includesText: includesText) }
    }

    func expandedRegion(for mark: JJLineMark) -> NSRect? {
        guard let hunk = visibleHunks.first(where: { $0.mark == mark }) else { return nil }
        return display.rect(for: hunk)
    }

    func removedCaretRect(key: NSRange, offset: Int) -> NSRect? {
        display.removedCaretRect(key: key, offset: offset)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        pointer = event.locationInWindow
        refreshControls()
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        refreshControls()
    }

    private func applyExpansion() {
        let next = hunks.filter { expanded.contains($0.baseRange) }
        if next != visibleHunks {
            visibleHunks = next
            interaction.clear()
            display.display(next)
        }
        guard let scroll = editor?.enclosingScrollView else { return }
        if next.isEmpty {
            guard tracking != nil else { return }
            if let tracking { trackedScroll?.removeTrackingArea(tracking) }
            tracking = nil
            trackedScroll = nil
            lastTextResponder = nil
            pointer = nil
            removePanels(except: [])
        } else {
            if tracking == nil || trackedScroll !== scroll {
                if let tracking { trackedScroll?.removeTrackingArea(tracking) }
                let area = NSTrackingArea(rect: .zero,
                                          options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                          owner: self)
                scroll.addTrackingArea(area)
                tracking = area
                trackedScroll = scroll
                pointer = scroll.window?.mouseLocationOutsideOfEventStream
            }
            layout()
        }
        editor?.requestLineRefresh()
    }

    private func selectedHunk(in editor: EditorTextView) -> JJDiffHunk? {
        var responder = editor.window?.firstResponder
        if let view = responder as? NSView, panels.values.contains(where: { view.isDescendant(of: $0) }) {
            responder = lastTextResponder
        }
        guard responder === editor, let selection = editor.caretSelections.last else { return nil }
        lastTextResponder = editor
        if case .removed(let key, _) = interaction.head {
            return visibleHunks.first { $0.baseRange == key }
        }
        let caret = editor.activeEnd(of: selection)
        return visibleHunks.first { hunk in
            let range = hunk.currentRange
            // EOF has no following line to take ownership of its caret.
            return NSLocationInRange(caret, range) ||
                (range.length == 0 && caret == range.location) ||
                (caret == NSMaxRange(range) && caret == editor.textStorage?.length)
        }
    }

    private func hoveredHunk(in editor: EditorTextView, scroll: NSScrollView, visible: NSRect) -> JJDiffHunk? {
        guard let pointer, visible.contains(scroll.convert(pointer, from: nil)) else { return nil }
        var hit = scroll.hitTest(scroll.superview?.convert(pointer, from: nil) ?? pointer)
        while let view = hit, view !== scroll {
            if let panel = view as? JJInlineDiffControls {
                return visibleHunks.first { $0.baseRange == panel.hunkKey }
            }
            hit = view.superview
        }
        let inEditor = editor.convert(pointer, from: nil)
        return visibleHunks.first { display.rect(for: $0)?.contains(inEditor) == true }
    }

    private func refreshControls() {
        guard hasExpandedHunks, let editor, let scroll = editor.enclosingScrollView else { return }
        let visible = JJEditorActionBar.viewport(in: scroll)
        let targets = Set([selectedHunk(in: editor), hoveredHunk(in: editor, scroll: scroll, visible: visible)]
            .compactMap { $0?.baseRange })
        var placements: [(key: NSRange, panel: JJInlineDiffControls, frame: NSRect)] = []
        for target in visibleHunks where targets.contains(target.baseRange) {
            guard let region = display.rect(for: target) else { continue }
            let block = scroll.convert(region, from: editor)
            guard !visible.intersection(block).isEmpty else { continue }
            let panel = panel(for: target.baseRange)
            panel.setAvailability(restore: current && canRestore(target, in: editor),
                                  previous: current && hunks.count > 1, next: current && hunks.count > 1)
            placements.append((target.baseRange, panel, panel.frame(over: block, in: visible, scroll: scroll)))
        }
        removePanels(except: Set(placements.map(\.key)))
        placements.sort { $0.frame.minY < $1.frame.minY }
        if placements.count == 2 && placements[0].frame.maxY + 2 > placements[1].frame.minY {
            let lastY = visible.maxY - placements[1].frame.height - 2
            placements[1].frame.origin.y = min(lastY, placements[0].frame.maxY + 2)
            placements[0].frame.origin.y = max(visible.minY + 2,
                                              placements[1].frame.minY - placements[0].frame.height - 2)
        }
        for (_, panel, frame) in placements {
            panel.frame = frame
            if panel.superview !== scroll { scroll.addSubview(panel, positioned: .above, relativeTo: nil) }
        }
    }

    private func panel(for key: NSRange) -> JJInlineDiffControls {
        if let panel = panels[key] { return panel }
        let panel = JJInlineDiffControls(hunkKey: key, restore: { [weak self] key in self?.restore(key) },
                                         navigate: { [weak self] key, step in self?.navigate(from: key, by: step) })
        panel.onCancel = { [weak self] in self?.collapseAll() == true }
        panel.onPointerChange = { [weak self] event in self?.mouseMoved(with: event) }
        panels[key] = panel
        return panel
    }

    private func removePanels(except keys: Set<NSRange>) {
        for key in Set(panels.keys).subtracting(keys) {
            panels.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func navigate(from key: NSRange, by step: Int) {
        guard current, let editor, hunks.count > 1,
              let index = hunks.firstIndex(where: { $0.baseRange == key }) else { return }
        let target = hunks[(index + step + hunks.count) % hunks.count]
        expanded.insert(target.baseRange)
        applyExpansion()
        display.reveal(target)
        let caret = NSRange(location: target.currentRange.location, length: 0)
        if editor.focusAllowsEdits([caret]), editor.window?.makeFirstResponder(editor) == true {
            editor.setCaretSelections([caret], record: false)
        }
        layout()
    }

    private func canRestore(_ hunk: JJDiffHunk, in editor: EditorTextView) -> Bool {
        editor.isEditable && !editor.hasMarkedText() && editor.focusAllowsEdits([hunk.currentRange])
    }

    private func restore(_ key: NSRange) {
        guard current, let editor, let hunk = visibleHunks.first(where: { $0.baseRange == key }),
              canRestore(hunk, in: editor), let source = editor.textStorage?.mutableString else { return }
        let range = hunk.currentRange
        guard range.location <= source.length, range.length <= source.length - range.location,
              source.substring(with: range).utf8.elementsEqual(hunk.insertedText.utf8) else {
            suspend()
            return
        }
        editor.window?.makeFirstResponder(editor)
        interaction.clear()
        let restored = normalizeCRLF
            ? hunk.removedText.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
                .replacingOccurrences(of: "\n", with: editor.preferredLineEnding, options: .literal)
            : hunk.removedText
        let edit = MultiCaretEditing.Replacement(range: range, text: restored)
        let caret = NSRange(location: range.location, length: 0)
        guard editor.applyMultiEdits([edit], selections: [caret]) else { return }
        editor.undoManager?.setActionName("Restore Change")
        expanded.remove(hunk.baseRange)
        applyExpansion()
    }
}
