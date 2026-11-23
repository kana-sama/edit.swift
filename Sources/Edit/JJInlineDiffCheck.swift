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
        try require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: type == .leftMouseDown ? 1 : 0, pressure: 0), "synthesize a mouse event")
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
