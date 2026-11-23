import AppKit

@MainActor
enum JJInlineDiffCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "JJ inline diff: " + message }
    }

    static func run(in document: DocumentWindow) throws {
        guard NSApp is EditApplication else { throw Failure("launch with the shared click cursor handler") }
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
        let gutterY = scroll.convert(initialLine, from: editor).midY
        for x in [0.5, 4.0, 8.0, 11.5] {
            let location = scroll.convert(NSPoint(x: gutterX + x, y: gutterY), to: nil)
            guard scroll.hitTest(parent.convert(location, from: nil)) === gutter,
                  EditApplication.clickCursor(in: window, at: location) === NSCursor.pointingHand else {
                throw Failure("use the pointing hand across the clickable gutter at x=\(x)")
            }
        }
        let outsideGutter = scroll.convert(NSPoint(x: gutterX + 12.5, y: gutterY), to: nil)
        guard scroll.hitTest(parent.convert(outsideGutter, from: nil)) !== gutter,
              EditApplication.clickCursor(in: window, at: outsideGutter) == nil else {
            throw Failure("leave the text cursor outside the hit area")
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
        editor.setCaretSelections([NSRange(location: replacement.currentRange.location, length: 0)], record: false)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        guard window.firstResponder === editor, controller.hasProjectedCaret else {
            throw Failure("move the editor caret into removed rows")
        }
        let firstRemovedLine = (replacement.removedText as NSString).lineRange(for: NSRange(location: 0, length: 0))
        let lastRemovedStart = JJInlineDiffSelection.Position.removed(key: replacement.baseRange,
                                                                      offset: NSMaxRange(firstRemovedLine))
        guard controller.select(from: lastRemovedStart, to: lastRemovedStart) else {
            throw Failure("place the caret in the last removed row")
        }
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        guard window.firstResponder === editor, editor.selectedRange().location == replacement.currentRange.location else {
            throw Failure("navigate from the last removed row into the live source")
        }

        // Put the source caret outside the change so its controls require pointer hover.
        editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
        let removedInWindow = removed.convert(removed.bounds, to: nil)
        let hoverPoint = NSPoint(x: removedInWindow.midX, y: removedInWindow.midY)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: hoverPoint, in: window))
        let hoverPanel = try require(panels(in: scroll).first, "show a panel on mouse hover")
        let next = try button("Edit.Diff.Next", in: hoverPanel)
        let previous = try button("Edit.Diff.Previous", in: hoverPanel)
        let hoverRestore = try button("Edit.Diff.Restore", in: hoverPanel)
        window.layoutIfNeeded()
        for control in [hoverRestore, next, previous] {
            for x in [control.bounds.minX + 1, control.bounds.midX, control.bounds.maxX - 1] {
                let location = control.convert(NSPoint(x: x, y: control.bounds.midY), to: nil)
                guard EditApplication.clickCursor(in: window, at: location) === NSCursor.pointingHand else {
                    throw Failure("use the pointing hand across the floating button \(control.identifier?.rawValue ?? "")")
                }
            }
        }
        guard EditApplication.clickCursor(in: window, at: hoverPoint) == nil else {
            throw Failure("keep the text cursor over removed text beside the floating buttons")
        }
        next.performClick(nil)
        guard controller.expandedRegion(for: replacement.mark) != nil,
              controller.expandedRegion(for: deletion.mark) != nil else {
            throw Failure("Next opens the following deletion and keeps the replacement open")
        }
        let mousePanelRect = hoverPanel.convert(hoverPanel.bounds, to: nil)
        let mousePanelCenter = NSPoint(x: mousePanelRect.midX, y: mousePanelRect.midY)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: mousePanelCenter, in: window))
        func caretPanel() throws -> JJInlineDiffControls {
            let visible = panels(in: scroll)
            guard visible.count == 2, let panel = visible.first(where: { $0 !== hoverPanel }),
                  !panel.frame.intersects(hoverPanel.frame) else {
                throw Failure("keep a separate panel for the mouse and the caret")
            }
            return panel
        }
        try button("Edit.Diff.Next", in: caretPanel()).performClick(nil)
        guard controller.expandedRegion(for: insertion.mark) != nil else {
            throw Failure("Next can open an addition with no removed rows")
        }
        try button("Edit.Diff.Previous", in: caretPanel()).performClick(nil)
        guard editor.selectedRange().location == deletion.currentRange.location else {
            throw Failure("Previous selects the preceding deletion")
        }
        try button("Edit.Diff.Previous", in: caretPanel()).performClick(nil)
        guard panels(in: scroll).count == 1, panels(in: scroll).first === hoverPanel else {
            throw Failure("show one panel when the mouse and caret share a change")
        }
        previous.performClick(nil)
        guard editor.selectedRange().location == insertion.currentRange.location else {
            throw Failure("Previous wraps to the last change")
        }
        try button("Edit.Diff.Next", in: caretPanel()).performClick(nil)
        guard editor.selectedRange().location == replacement.currentRange.location else {
            throw Failure("Next wraps to the first change")
        }
        let deleted = try require(controller.expandedRegion(for: deletion.mark), "lay out the expanded deletion")
        let deletionHover = editor.convert(NSPoint(x: deleted.midX, y: deleted.midY), to: nil)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: deletionHover, in: window))
        _ = try caretPanel()
        let green = try require(editor.lineBounds(at: replacement.currentRange.location), "lay out the live changed row")
        let liveHover = editor.convert(NSPoint(x: green.midX, y: green.midY), to: nil)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: liveHover, in: window))
        guard panels(in: scroll).count == 1, panels(in: scroll).first === hoverPanel else {
            throw Failure("keep only the caret panel when the mouse moves onto its live rows")
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
        window.layoutIfNeeded()
        let restorePoint = restore.convert(NSPoint(x: restore.bounds.midX, y: restore.bounds.midY), to: nil)
        guard !restore.isEnabled, editor.string == current,
              EditApplication.clickCursor(in: window, at: restorePoint) === NSCursor.arrow else {
            throw Failure("keep stale diff actions passive with an arrow cursor")
        }
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

        try checkMouseNavigation(in: document, controller: controller)
        try checkMixedSelection(in: document, controller: controller, undo: undo)
    }

    private static func checkMixedSelection(in document: DocumentWindow, controller: JJInlineDiff, undo: UndoManager) throws {
        let window = document.window
        let editor = document.editor
        let base = "line 1\nline 2\nline 3\n"
        let current = "line 3\n"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        func refresh(_ text: String) throws -> JJDiffHunk {
            let analysis = JJLineDiff.analyze(base: base, current: text, isConflicted: false, recordedConflict: nil)
            guard analysis.hunks.count == 1, let hunk = analysis.hunks.first else {
                throw Failure("make a single diff hunk for the mixed selection example")
            }
            editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
            return hunk
        }

        func openExample() throws -> JJDiffHunk {
            controller.collapseAll()
            editor.string = current
            window.makeFirstResponder(editor)
            editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
            let hunk = try refresh(current)
            controller.toggle(hunk.mark)
            return hunk
        }

        func checkCopy(_ expected: String) throws {
            pasteboard.clearContents()
            guard controller.copyProjectedSelection(to: pasteboard, cutting: false),
                  pasteboard.string(forType: .string) == expected else {
                throw Failure("copy the mixed selection in visual order")
            }
        }

        var deletion = try openExample()
        let live = JJInlineDiffSelection.Position.live(2)
        let editableRange = NSRange(location: 0, length: 2)
        var removed = JJInlineDiffSelection.Position.removed(key: deletion.baseRange, offset: 12)
        guard controller.select(from: removed, to: live), controller.projectedEditRange == editableRange else {
            throw Failure("select from the removed second line to the live third line")
        }
        try checkCopy("2\nli")
        undo.beginUndoGrouping()
        editor.deleteBackward(nil)
        undo.endUndoGrouping()
        guard editor.string == "ne 3\n" else { throw Failure("Delete only removes the selected live characters") }
        undo.undo()
        guard editor.string == current else { throw Failure("undo a mixed selection edit in one step") }

        deletion = try openExample()
        removed = .removed(key: deletion.baseRange, offset: 12)
        guard controller.select(from: live, to: removed), controller.projectedEditRange == editableRange else {
            throw Failure("select from the live third line to the removed second line")
        }
        try checkCopy("2\nli")
        undo.beginUndoGrouping()
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        guard editor.string == "Xne 3\n" else { throw Failure("typing replaces only the selected live characters") }
        let replacement = try refresh(editor.string)
        guard replacement.mark.kind == .replacement, controller.expandedRegion(for: replacement.mark) != nil,
              descendant(of: editor, matching: { (view: NSTextView) in
                  view.string == base && !view.isHiddenOrHasHiddenAncestor && !view.isEditable
              }) != nil else {
            throw Failure("the updated open comparison contains all three original red lines")
        }

        deletion = try openExample()
        editor.setCaretSelections([NSRange(location: 2, length: 0)], record: false)
        for _ in 0..<4 { editor.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:))) }
        guard controller.projectedEditRange == editableRange else {
            throw Failure("extend the selection with Shift-Left from live text into the removed row")
        }
        try checkCopy("2\nli")

        let redView = try require(descendant(of: editor) { (view: NSTextView) in
            view.string == deletion.removedText && !view.isHiddenOrHasHiddenAncestor
        }, "lay out the removed rows for a mouse drag")
        func caretPoint(in view: NSTextView, at offset: Int) throws -> NSPoint {
            let rect = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
            guard rect.height > 0 else { throw Failure("locate the text caret for a mouse drag") }
            return window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.midY))
        }
        let startPoint = try caretPoint(in: editor, at: 2)
        let endPoint = try caretPoint(in: redView, at: 12)
        for (view, start, end) in [(editor as NSTextView, startPoint, endPoint), (redView, endPoint, startPoint)] {
            NSApp.postEvent(try mouse(.leftMouseUp, at: end, in: window), atStart: true)
            NSApp.postEvent(try mouse(.leftMouseDragged, at: end, in: window), atStart: true)
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: window))
            guard controller.projectedEditRange == editableRange else {
                throw Failure("drag across the live and removed rows as one selection in both directions")
            }
            try checkCopy("2\nli")
        }
        editor.selectAll(nil)
        try checkCopy(base)

        let redCaret = JJInlineDiffSelection.Position.removed(key: deletion.baseRange, offset: 12)
        guard controller.select(from: redCaret, to: redCaret), controller.hasProjectedCaret else {
            throw Failure("place the projected caret inside a read-only row")
        }
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.deleteBackward(nil)
        guard editor.string == current, controller.hasProjectedCaret else {
            throw Failure("typing and Delete leave a caret in a read-only row and leave the live text intact")
        }

        let finalLine = JJLineDiff.analyze(base: "old", current: "new", isConflicted: false, recordedConflict: nil)
        let projection = JJInlineDiffSelection(source: "new", hunks: finalLine.hunks)
        guard projection.string == "old\nnew", projection.liveRange(for: NSRange(location: 2, length: 4)) ==
                NSRange(location: 0, length: 2) else {
            throw Failure("keep an unterminated removed line visually separate from its live replacement")
        }
    }

    private static func checkMouseNavigation(in document: DocumentWindow, controller: JJInlineDiff) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        let longLine = String(repeating: " code under the panel", count: 14)
        func fixture(_ prefix: String) -> String {
            (1...5).map { index in
                "\(prefix) \(index)\(index == 4 ? longLine : "")\ncontext \(index)\n"
            }.joined()
        }
        let current = fixture("new")
        let analysis = JJLineDiff.analyze(base: fixture("old"), current: current, isConflicted: false, recordedConflict: nil)
        guard analysis.hunks.count == 5 else { throw Failure("lay out five independent changes for mouse navigation") }
        let second = analysis.hunks[1]
        let fourth = analysis.hunks[3]
        editor.string = current
        window.makeFirstResponder(editor)
        editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        controller.toggle(second.mark)
        controller.toggle(fourth.mark)

        for (identifier, destination) in [("Edit.Diff.Previous", analysis.hunks[2]), ("Edit.Diff.Next", analysis.hunks[4])] {
            editor.setCaretSelections([NSRange(location: second.currentRange.location, length: 0)], record: false)
            controller.layout()
            let fourthRegion = try require(controller.expandedRegion(for: fourth.mark), "lay out the fourth change")
            let line = try require(editor.lineBounds(at: fourth.currentRange.location), "lay out the long changed line")
            let hover = editor.convert(NSPoint(x: fourthRegion.midX, y: fourthRegion.midY), to: nil)
            controller.mouseMoved(with: try mouse(.mouseMoved, at: hover, in: window))
            let controls = panels(in: scroll)
            guard controls.count == 2, let panel = controls.first(where: { $0.hunkKey == fourth.baseRange }),
                  controls.contains(where: { $0.hunkKey == second.baseRange }),
                  panel.frame.intersects(scroll.convert(fourthRegion, from: editor)),
                  editor.lineBounds(at: fourth.currentRange.location) == line else {
                throw Failure("overlay the fourth change without shifting its text or the caret's panel")
            }
            let arrow = try button(identifier, in: panel)
            window.layoutIfNeeded()
            let point = arrow.convert(NSPoint(x: arrow.bounds.midX, y: arrow.bounds.midY), to: nil)
            controller.mouseMoved(with: try mouse(.mouseMoved, at: point, in: window))
            let windowFrame = try require(window.contentView?.superview, "find the window's hit testing view")
            let hit = try require(windowFrame.hitTest(windowFrame.superview?.convert(point, from: nil) ?? point),
                                  "hit the arrow on the hovered panel")
            guard hit === arrow, editor.selectedRange().location == second.currentRange.location,
                  controller.expandedRegion(for: destination.mark) == nil else {
                throw Failure("start a native arrow click on the fourth change with the caret on the second")
            }
            // Dispatch the action of the hit-tested button in the non-interactive test window.
            guard let action = arrow.action, NSApp.sendAction(action, to: arrow.target, from: arrow),
                  editor.selectedRange().location == destination.currentRange.location,
                  controller.expandedRegion(for: destination.mark) != nil else {
                throw Failure("move the caret and expand the change adjacent to the clicked panel")
            }
        }
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1,
                                      pressure: type == .leftMouseUp ? 0 : 1), "synthesize a mouse event")
    }

    private static func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try require(descendant(of: view) { (button: NSButton) in
            button.identifier?.rawValue == identifier && button.isEnabled && !button.isHiddenOrHasHiddenAncestor
        }, "show an enabled native button for \(identifier)")
    }

    private static func panels(in scroll: NSScrollView) -> [JJInlineDiffControls] {
        scroll.subviews.compactMap { $0 as? JJInlineDiffControls }.filter { !$0.isHiddenOrHasHiddenAncestor }
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
