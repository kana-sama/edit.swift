import AppKit

@MainActor
enum JJInlineDiffCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "JJ inline diff: " + message }
    }

    static func run(in document: DocumentWindow) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        defer { window.close() }

        let base = """
            header
            let path = "platform/windows"
            let mode = .legacy
            first unchanged
            removed line
            second unchanged
            footer

            """
        let current = """
            header
            let path = "windows"
            let mode = .modern
            first unchanged
            second unchanged
            footer
            added line

            """
        let analysis = JJLineDiff.analyze(base: base, current: current, isConflicted: false, recordedConflict: nil)
        guard analysis.hunks.map(\.mark.kind) == [.replacement, .deletion, .insertion] else {
            throw Failure("provide one replacement, deletion, and insertion")
        }
        let replacement = analysis.hunks[0]
        let deletion = analysis.hunks[1]
        let insertion = analysis.hunks[2]
        guard let undo = editor.undoManager else { throw Failure("get the editor undo manager") }
        undo.groupsByEvent = false

        editor.string = current
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(editor)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        undo.removeAllActions()

        guard let parent = scroll.superview, let initialLine = editor.lineBounds(at: replacement.currentRange.location) else {
            throw Failure("lay out the source row")
        }
        let gutterX = max(editor.convert(scroll.visibleContentOrigin, to: scroll).x, scroll.contentView.frame.minX)
        let clickPoint = scroll.convert(NSPoint(x: gutterX + 8, y: scroll.convert(initialLine, from: editor).midY), to: nil)
        let hitPoint = parent.convert(clickPoint, from: nil)
        let unmarkedHit = scroll.hitTest(hitPoint)

        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        guard let controller = editor.jjInlineDiff,
              let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else {
            throw Failure("install and render the inline change controls")
        }
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        guard let gutter = scroll.hitTest(hitPoint), gutter !== unmarkedHit else {
            throw Failure("hit the gutter just outside its visible stripe")
        }
        gutter.mouseDown(with: try mouse(.leftMouseDown, at: clickPoint, in: window))

        guard controller.hasExpandedHunks,
              let block = controller.expandedRegion(for: replacement.mark),
              let sourceLine = editor.lineBounds(at: replacement.currentRange.location) else {
            throw Failure("expand the replacement using the widened gutter")
        }
        guard editor.string == current, !undo.canUndo, sourceLine.minY > initialLine.minY + 1 else {
            throw Failure("reserve display space without editing the buffer or its undo history")
        }
        let removed = try require(descendant(of: editor) { (view: NSTextView) in
            view.string == replacement.removedText && !view.isHiddenOrHasHiddenAncestor
        }, "show the removed text in its native text view")
        let removedFrame = removed.convert(removed.bounds, to: editor)
        guard block.intersects(removedFrame), removedFrame.maxY <= sourceLine.minY + 2,
              !removed.isEditable, removed.isSelectable else {
            throw Failure("show selectable, read-only removed text above the source line")
        }
        guard let highlight = replacement.removedHighlights.first,
              removed.textStorage?.attribute(.backgroundColor, at: highlight.location, effectiveRange: nil) != nil else {
            throw Failure("highlight the changed words in the removed text")
        }
        let removedSelection = NSRange(location: 1, length: 4)
        editor.setCaretSelections([NSRange(location: replacement.currentRange.location, length: 0)], record: false)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        guard window.firstResponder === removed else { throw Failure("navigate into the removed rows from the source") }
        guard window.makeFirstResponder(removed) else { throw Failure("focus the removed text") }
        removed.setSelectedRange(removedSelection)
        guard removed.selectedRange() == removedSelection else { throw Failure("select removed text") }
        let firstRemovedLine = (replacement.removedText as NSString).lineRange(for: NSRange(location: 0, length: 0))
        removed.setSelectedRange(NSRange(location: NSMaxRange(firstRemovedLine), length: 0))
        removed.moveDown(nil)
        guard window.firstResponder === editor, editor.selectedRange().location == replacement.currentRange.location else {
            throw Failure("navigate from the last removed row into the live source")
        }

        // Put the source caret outside the change so its controls require pointer hover.
        editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
        let removedInWindow = removed.convert(removed.bounds, to: nil)
        let hoverPoint = NSPoint(x: removedInWindow.midX, y: removedInWindow.midY)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: hoverPoint, in: window))
        let next = try button("Edit.Diff.Next", in: scroll)
        let previous = try button("Edit.Diff.Previous", in: scroll)
        _ = try button("Edit.Diff.Restore", in: scroll)
        next.performClick(nil)
        guard controller.expandedRegion(for: replacement.mark) != nil,
              controller.expandedRegion(for: deletion.mark) != nil else {
            throw Failure("Next opens the following deletion and keeps the replacement open")
        }
        next.performClick(nil)
        guard controller.expandedRegion(for: insertion.mark) != nil else {
            throw Failure("Next can open an addition with no removed rows")
        }
        previous.performClick(nil)
        guard editor.selectedRange().location == deletion.currentRange.location else {
            throw Failure("Previous selects the preceding deletion")
        }
        previous.performClick(nil)
        previous.performClick(nil)
        guard editor.selectedRange().location == insertion.currentRange.location else {
            throw Failure("Previous wraps to the last change")
        }
        next.performClick(nil)
        guard editor.selectedRange().location == replacement.currentRange.location else {
            throw Failure("Next wraps to the first change")
        }

        let carets = [NSRange(location: 0, length: 0), NSRange(location: replacement.currentRange.location, length: 0)]
        editor.setCaretSelections(carets, record: false)
        editor.cancelOperation(nil)
        guard !controller.hasExpandedHunks, editor.caretSelections == carets,
              editor.string == current, !undo.canUndo else {
            throw Failure("Escape closes all previews before clearing carets and leaves the buffer intact")
        }

        controller.toggle(replacement.mark)
        let restore = try button("Edit.Diff.Restore", in: scroll)
        editor.suspendJJMarkerNavigation()
        restore.performClick(nil)
        guard !restore.isEnabled, editor.string == current else { throw Failure("keep stale diff actions passive") }
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        let restored = (current as NSString).replacingCharacters(in: replacement.currentRange, with: replacement.removedText)
        undo.beginUndoGrouping()
        restore.performClick(nil)
        undo.endUndoGrouping()
        guard editor.string == restored, !controller.hasExpandedHunks, undo.canUndo else {
            throw Failure("restore only the selected hunk")
        }
        undo.undo()
        guard editor.string == current, !undo.canUndo else { throw Failure("undo Restore with one edit") }
        undo.redo()
        guard editor.string == restored else { throw Failure("redo Restore") }
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: type == .leftMouseDown ? 1 : 0, pressure: 0), "synthesize a mouse event")
    }

    private static func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try require(descendant(of: view) { (button: NSButton) in
            button.identifier?.rawValue == identifier && button.isEnabled && !button.isHiddenOrHasHiddenAncestor
        }, "show an enabled native button for \(identifier)")
    }

    private static func descendant<View: NSView>(of root: NSView, matching predicate: (View) -> Bool) -> View? {
        if let match = root as? View, predicate(match) { return match }
        for child in root.subviews {
            if let match = descendant(of: child, matching: predicate) { return match }
        }
        return nil
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw Failure(message) }
        return value
    }
}
