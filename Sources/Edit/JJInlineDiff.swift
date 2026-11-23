import AppKit

@MainActor
final class JJInlineDiff: NSResponder {
    private weak var editor: EditorTextView?
    private let display: JJInlineDiffLayout
    private var hunks: [JJDiffHunk] = []
    private var expandableMarks: Set<JJLineMark> = []
    private var expanded: Set<NSRange> = []
    private var visibleHunks: [JJDiffHunk] = []
    private var removedRows: [(line: Int, cumulative: Int)] = []
    private(set) var overviewRevision: UInt = 0
    private var normalizeCRLF = false
    private var current = true
    private var controlTarget: NSRange?
    private var navigationTarget: NSRange?
    private var pointer: NSPoint?
    private var pointerOnControls = false
    private var tracking: NSTrackingArea?
    private weak var trackedScroll: NSScrollView?

    private lazy var controls: JJInlineDiffControls = {
        let bar = JJInlineDiffControls(restore: { [weak self] in self?.restore() },
                                       previous: { [weak self] in self?.navigate(by: -1) },
                                       next: { [weak self] in self?.navigate(by: 1) })
        bar.onCancel = { [weak self] in self?.collapseAll() == true }
        bar.onHoverChange = { [weak self] inside in
            self?.pointerOnControls = inside
            self?.refreshControls()
        }
        return bar
    }()

    init(editor: EditorTextView) {
        self.editor = editor
        display = JJInlineDiffLayout(editor: editor)
        super.init()
        display.onSelectionChange = { [weak self] in
            guard let self, self.display.hunk(for: self.editor?.window?.firstResponder) != nil else { return }
            selectionChanged()
        }
        display.onCancel = { [weak self] in self?.collapseAll() == true }
    }

    required init?(coder: NSCoder) { fatalError("Inline diff is programmatically constructed") }

    var hasExpandedHunks: Bool { !expanded.isEmpty }

    func update(_ updated: [JJDiffHunk], normalizeCRLF: Bool) {
        let sameHunks = updated == hunks
        current = true
        self.normalizeCRLF = normalizeCRLF
        if !sameHunks {
            hunks = updated
            expandableMarks = Set(updated.map(\.mark))
            expanded.formIntersection(updated.map(\.baseRange))
            if let navigationTarget, !expanded.contains(navigationTarget) { self.navigationTarget = nil }
            applyExpansion()
        } else if hasExpandedHunks {
            refreshControls()
        }
    }

    func suspend() {
        guard current else { return }
        current = false
        if hasExpandedHunks { controls.setAvailability(restore: false, previous: false, next: false) }
    }

    func canToggle(_ mark: JJLineMark) -> Bool { current && expandableMarks.contains(mark) }

    func toggle(_ mark: JJLineMark) {
        guard current, let hunk = hunks.first(where: { $0.mark == mark }) else { return }
        navigationTarget = nil
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
        navigationTarget = nil
        applyExpansion()
        return true
    }

    func selectionChanged() {
        navigationTarget = nil
        editor?.requestLineRefresh()
    }

    func layout() {
        guard hasExpandedHunks else { return }
        display.layout()
        refreshControls()
    }

    func drawBackground(in rect: NSRect) {
        if hasExpandedHunks { display.drawBackground(in: rect) }
    }

    func moveFromSource(forward: Bool) -> Bool {
        hasExpandedHunks && display.moveFromSource(forward: forward)
    }

    func expandedRegion(for mark: JJLineMark) -> NSRect? {
        guard let hunk = visibleHunks.first(where: { $0.mark == mark }) else { return nil }
        return display.rect(for: hunk)
    }

    func revealExpanded(_ mark: JJLineMark) -> Bool {
        guard let hunk = visibleHunks.first(where: { $0.mark == mark }) else { return false }
        display.reveal(hunk)
        layout()
        return true
    }

    func overviewRows(for mark: JJLineMark) -> Range<Int> {
        let start = overviewRow(mark.lines.lowerBound, includingRemovedAtBoundary: false)
        let end = overviewRow(mark.lines.upperBound, includingRemovedAtBoundary: mark.lines.isEmpty)
        return start..<end
    }

    func overviewRow(_ line: Int, includingRemovedAtBoundary: Bool) -> Int {
        var low = 0
        var high = removedRows.count
        while low < high {
            let middle = (low + high) / 2
            let boundary = removedRows[middle].line
            if boundary < line || (includingRemovedAtBoundary && boundary == line) { low = middle + 1 }
            else { high = middle }
        }
        return line + (low > 0 ? removedRows[low - 1].cumulative : 0)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        pointer = event.locationInWindow
        if !pointerOnControls && !pointerIsOverControls { navigationTarget = nil }
        refreshControls()
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        pointerOnControls = false
        refreshControls()
    }

    private func applyExpansion() {
        let next = hunks.filter { expanded.contains($0.baseRange) }
        if next != visibleHunks {
            visibleHunks = next
            var total = 0
            removedRows = next.compactMap { hunk in
                guard !hunk.removedText.isEmpty else { return nil }
                hunk.removedText.enumerateLines { _, _ in total += 1 }
                return (hunk.mark.lines.lowerBound, total)
            }
            overviewRevision &+= 1
            display.display(next)
        }
        guard let scroll = editor?.enclosingScrollView else { return }
        if next.isEmpty {
            guard tracking != nil else { return }
            if let tracking { trackedScroll?.removeTrackingArea(tracking) }
            tracking = nil
            trackedScroll = nil
            pointer = nil
            pointerOnControls = false
            controlTarget = nil
            controls.removeFromSuperview()
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

    private var pointerIsOverControls: Bool {
        guard let pointer, !controls.isHidden, controls.superview != nil else { return false }
        return controls.bounds.contains(controls.convert(pointer, from: nil))
    }

    private func selectedHunk(in editor: EditorTextView) -> JJDiffHunk? {
        if let focused = display.hunk(for: editor.window?.firstResponder) { return focused }
        guard editor.window?.firstResponder === editor, let selection = editor.caretSelections.last else { return nil }
        let caret = editor.activeEnd(of: selection)
        return visibleHunks.first { hunk in
            let range = hunk.currentRange
            // EOF has no following line to take ownership of its caret.
            return NSLocationInRange(caret, range) ||
                (range.length == 0 && caret == range.location) ||
                (caret == NSMaxRange(range) && caret == editor.textStorage?.length)
        }
    }

    private func refreshControls() {
        guard hasExpandedHunks, let editor, let scroll = editor.enclosingScrollView else { return }
        var visible = scroll.contentView.frame
        let insets = scroll.contentInsets
        visible.origin.x += insets.left
        visible.origin.y += scroll.isFlipped ? insets.top : insets.bottom
        visible.size.width -= insets.left + insets.right
        visible.size.height -= insets.top + insets.bottom
        let target: JJDiffHunk?
        let staysOverControls = pointerOnControls || pointerIsOverControls ||
            (editor.window?.firstResponder as? NSView)?.isDescendant(of: controls) == true
        if let navigationTarget, let destination = visibleHunks.first(where: { $0.baseRange == navigationTarget }) {
            target = destination
        } else if staysOverControls, let controlTarget {
            target = visibleHunks.first { $0.baseRange == controlTarget }
        } else {
            let hovered = pointer.flatMap { point -> JJDiffHunk? in
                guard visible.contains(scroll.convert(point, from: nil)) else { return nil }
                let inEditor = editor.convert(point, from: nil)
                return visibleHunks.first { display.rect(for: $0)?.contains(inEditor) == true }
            }
            target = hovered ?? selectedHunk(in: editor)
        }
        guard let target, let block = display.rect(for: target).map({ scroll.convert($0, from: editor) }),
              !visible.intersection(block).isEmpty else {
            controls.isHidden = true
            controlTarget = nil
            pointerOnControls = false
            return
        }

        let scrollWidth = scroll.scrollerStyle == .overlay
            ? NSScroller.scrollerWidth(for: scroll.verticalScroller?.controlSize ?? .regular, scrollerStyle: .overlay)
            : 0
        let size = controls.fittingSize
        let x = max(visible.minX + 4, visible.maxX - size.width - scrollWidth - 6)
        let preferredY = scroll.isFlipped ? block.minY + 2 : block.maxY - size.height - 2
        let y = max(visible.minY + 2, min(preferredY, visible.maxY - size.height - 2))
        controlTarget = target.baseRange
        controls.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        controls.setAvailability(restore: current && canRestore(target, in: editor),
                                 previous: current && hunks.count > 1, next: current && hunks.count > 1)
        if controls.superview !== scroll { scroll.addSubview(controls, positioned: .above, relativeTo: nil) }
        controls.isHidden = false
    }

    private func navigate(by step: Int) {
        guard current, let editor, hunks.count > 1,
              let index = hunks.firstIndex(where: { $0.baseRange == controlTarget }) else { return }
        let target = hunks[(index + step + hunks.count) % hunks.count]
        expanded.insert(target.baseRange)
        let caret = NSRange(location: target.currentRange.location, length: 0)
        if editor.focusAllowsEdits([caret]) {
            editor.window?.makeFirstResponder(editor)
            editor.setCaretSelections([caret], record: false)
        }
        navigationTarget = target.baseRange
        applyExpansion()
        display.reveal(target)
        layout()
    }

    private func canRestore(_ hunk: JJDiffHunk, in editor: EditorTextView) -> Bool {
        editor.isEditable && !editor.hasMarkedText() && editor.focusAllowsEdits([hunk.currentRange])
    }

    private func restore() {
        guard current, let editor, let hunk = visibleHunks.first(where: { $0.baseRange == controlTarget }),
              canRestore(hunk, in: editor), let source = editor.textStorage?.mutableString else { return }
        let range = hunk.currentRange
        guard range.location <= source.length, range.length <= source.length - range.location,
              source.substring(with: range).utf8.elementsEqual(hunk.insertedText.utf8) else {
            suspend()
            return
        }
        editor.window?.makeFirstResponder(editor)
        let restored = normalizeCRLF
            ? hunk.removedText.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
                .replacingOccurrences(of: "\n", with: editor.preferredLineEnding, options: .literal)
            : hunk.removedText
        let edit = MultiCaretEditing.Replacement(range: range, text: restored)
        let caret = NSRange(location: range.location, length: 0)
        guard editor.applyMultiEdits([edit], selections: [caret]) else { return }
        editor.undoManager?.setActionName("Restore Change")
        expanded.remove(hunk.baseRange)
        navigationTarget = nil
        applyExpansion()
    }
}
