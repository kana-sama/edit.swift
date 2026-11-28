import AppKit

@MainActor
enum JJInlineDiffCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "JJ inline diff: " + message }
    }

    static func run(in document: DocumentWindow, captureViewport: ((NSView) throws -> Void)? = nil) throws {
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
        guard let controller = editor.jjInlineDiff else {
            throw Failure("install inline change controls")
        }
        guard let gutter = scroll.hitTest(hitPoint), gutter !== unmarkedHit else {
            throw Failure("hit the gutter just outside its visible stripe before drawing")
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
        let firstRemoved = try require(controller.removedCaretRect(key: replacement.baseRange, offset: 0),
                                       "lay out the first removed caret in the editor")
        let nextRemoved = try require(controller.removedCaretRect(key: replacement.baseRange, offset: 1),
                                      "lay out the second removed caret in the editor")
        let firstRemovedLine = (replacement.removedText as NSString).lineRange(for: NSRange(location: 0, length: 0))
        let lastRemoved = try require(controller.removedCaretRect(key: replacement.baseRange,
                                                                 offset: NSMaxRange(firstRemovedLine)),
                                      "lay out the last removed row in the editor")
        guard block.contains(NSPoint(x: firstRemoved.minX, y: firstRemoved.midY)),
              lastRemoved.maxY <= sourceLine.minY + 2,
              descendant(of: editor, matching: { (view: NSTextView) in view !== editor }) == nil else {
            throw Failure("lay out removed and live rows in the same editor without a second text view")
        }
        let glyph = NSRect(x: firstRemoved.minX, y: firstRemoved.minY + 1,
                           width: nextRemoved.minX - firstRemoved.minX, height: firstRemoved.height - 2)
        let luminance = try renderedColors(in: glyph, of: editor).map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }
        guard let darkest = luminance.min(), let lightest = luminance.max(), lightest - darkest > 0.18 else {
            throw Failure("render the removed glyph in the editor's TextKit surface")
        }
        editor.setCaretSelections([NSRange(location: replacement.currentRange.location, length: 0)], record: false)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        guard window.firstResponder === editor, controller.hasProjectedCaret else {
            throw Failure("move the editor caret into removed rows")
        }
        let afterMode = (replacement.removedText as NSString).range(of: "let mode").upperBound
        let wordAnchor = JJInlineDiffSelection.Position.removed(key: replacement.baseRange, offset: afterMode)
        let wordClipboard = NSPasteboard.withUniqueName()
        defer { wordClipboard.releaseGlobally() }
        let platform = (replacement.removedText as NSString).range(of: "platform")
        let wordRect = try require(controller.removedCaretRect(key: replacement.baseRange, offset: platform.location + 3),
                                   "lay out a word in a removed row")
        let wordPoint = editor.convert(NSPoint(x: wordRect.minX, y: wordRect.midY), to: nil)
        NSApp.postEvent(try mouse(.leftMouseUp, at: wordPoint, in: window, clickCount: 2), atStart: true)
        editor.mouseDown(with: try mouse(.leftMouseDown, at: wordPoint, in: window, clickCount: 2))
        guard controller.copyProjectedSelection(to: wordClipboard, cutting: false),
              wordClipboard.string(forType: .string) == "platform" else {
            throw Failure("double-click selects only the word before a slash in a removed row")
        }
        guard controller.select(from: wordAnchor, to: wordAnchor) else {
            throw Failure("place a word-selection anchor in the removed text")
        }
        for expected in [" =", " = .legacy"] {
            editor.doCommand(by: #selector(NSResponder.moveWordRightAndModifySelection(_:)))
            guard controller.copyProjectedSelection(to: wordClipboard, cutting: false),
                  wordClipboard.string(forType: .string) == expected else {
                throw Failure("extend a word selection in a removed row through \(expected)")
            }
        }

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
        let hoverPoint = editor.convert(NSPoint(x: block.midX, y: firstRemoved.midY), to: nil)
        controller.mouseMoved(with: try mouse(.mouseMoved, at: hoverPoint, in: window))
        let initialPanel = try require(panels(in: scroll).first, "show a panel to find its button position")
        let initialRestore = try button("Edit.Diff.Restore", in: initialPanel)
        window.layoutIfNeeded()
        let restoreHover = initialRestore.convert(NSPoint(x: initialRestore.bounds.midX,
                                                         y: initialRestore.bounds.midY), to: nil)
        let hover = try mouse(.mouseMoved, at: restoreHover, in: window)
        controller.mouseExited(with: hover)
        guard panels(in: scroll).isEmpty else { throw Failure("hide the panel before approaching its position") }
        var cursorImages: [NSCursor] = []
        let tracking = EditApplication.ClickCursorTracking(currentCursor: { cursorImages.last ?? .iBeam },
                                                            setCursor: { cursorImages.append($0) })
        tracking.dispatch(hover.type, in: window, resolve: {
            EditApplication.clickCursor(in: window, at: restoreHover)
        }) {
            controller.mouseMoved(with: hover)
            window.layoutIfNeeded()
        }
        tracking.end(restoreImage: false)
        guard cursorImages == [.pointingHand] else {
            throw Failure("show the pointing hand on the same move that reveals the floating button")
        }
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

        let primary = NSRange(location: replacement.currentRange.location, length: 3)
        let carets = [NSRange(location: 0, length: 0), primary]
        editor.setCaretSelections(carets, record: false, primaryAffinity: .downstream)
        let escape = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53), "create an Escape key event")
        document.performFind(.find)
        let field = try require(window.firstResponder as? FindFieldTextView, "focus Search with the diff expanded")
        let app = try require(NSApp.delegate as? Edit, "find the window event monitor")
        let routedEscape = try require(app.routeWindowEvent(escape), "route Escape to Search")
        field.keyDown(with: routedEscape)
        guard controller.hasExpandedHunks, window.firstResponder === editor else {
            throw Failure("give Escape to the focused Search field before the diff")
        }
        document.performFind(.toggleSidebar)
        editor.setCaretSelections(carets, record: false, primaryAffinity: .downstream)
        func pressEscape() {
            if !editor.performKeyEquivalent(with: escape) { editor.keyDown(with: escape) }
        }
        pressEscape()
        guard !controller.hasExpandedHunks, editor.caretSelections == carets,
              editor.string == current, !undo.canUndo else {
            throw Failure("Escape closes all previews before clearing carets and leaves the buffer intact")
        }
        pressEscape()
        guard editor.caretSelections == [primary] else {
            throw Failure("the second Escape leaves the primary selection")
        }
        pressEscape()
        guard editor.caretSelections == [NSRange(location: primary.upperBound, length: 0)],
              editor.string == current, !undo.canUndo else {
            throw Failure("the third Escape collapses the primary selection without editing the buffer (\(editor.caretSelections))")
        }
        editor.setSelectedRange(primary, affinity: .upstream, stillSelecting: false)
        pressEscape()
        guard editor.caretSelections == [NSRange(location: primary.location, length: 0)] else {
            throw Failure("Escape collapses a backward selection to its active end")
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

        try checkRepeatedLineAlignment(in: document, controller: controller, undo: undo)
        try checkMouseNavigation(in: document, controller: controller)
        try checkMixedSelection(in: document, controller: controller, undo: undo)
        try checkWholeFileDeletion(in: document, controller: controller)
        do {
            try checkSidebarGeometry(in: document, controller: controller)
        } catch {
            try? captureViewport?(scroll)
            throw error
        }
        try captureViewport?(scroll)
    }

    private static func checkRepeatedLineAlignment(
        in document: DocumentWindow, controller: JJInlineDiff, undo: UndoManager
    ) throws {
        let editor = document.editor
        let header = "header\n\nbegin\n"
        let removed = (1...4).map { "deleted \($0)\n" }.joined()
        let prefix = (1...3).map { "before \($0)\n" }.joined()
        let row = "repeated\n"
        let middle = (1...5).map { "after \($0)\n" }.joined()
        let tail = (1...4).map { "tail \($0)\n" }.joined()
        let base = header + removed + prefix + row + middle + tail
        let repeated = header + prefix + String(repeating: row, count: 3) + middle
        let blank = "    \n"
        let expected = JJLineMark(kind: .insertion, lines: 7..<9)

        func refresh() throws -> JJDiffHunk {
            let analysis = JJLineDiff.analyze(base: base, current: editor.string, isConflicted: false, recordedConflict: nil)
            let hunk = try require(analysis.hunks.first { $0.mark == expected }, "mark the last two copies as added")
            editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
            return hunk
        }

        controller.collapseAll()
        undo.removeAllActions()
        defer { undo.removeAllActions() }
        editor.string = repeated + tail
        document.window.makeFirstResponder(editor)
        let original = try refresh()
        controller.toggle(original.mark)
        undo.beginUndoGrouping()
        editor.insertText(blank, replacementRange: NSRange(location: repeated.utf16.count, length: 0))
        undo.endUndoGrouping()
        guard editor.string == repeated + blank + tail else { throw Failure("insert a blank line after the copies") }
        let refreshed = try refresh()
        guard refreshed == original else { throw Failure("keep the repeated-line ranges after inserting a separate blank line") }
        editor.scrollRangeToVisible(refreshed.currentRange)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        controller.layout()
        guard controller.expandedRegion(for: refreshed.mark) != nil else {
            throw Failure("keep the repeated-line hunk expanded after a refresh")
        }

        editor.setCaretSelections([NSRange(location: refreshed.currentRange.location, length: 0)], record: false)
        controller.layout()
        let restore = try button("Edit.Diff.Restore", in: document.scrollView)
        undo.beginUndoGrouping()
        restore.performClick(nil)
        undo.endUndoGrouping()
        guard editor.string == header + prefix + row + middle + blank + tail else {
            throw Failure("restore the two added copies and keep the separate blank line")
        }
        undo.undo()
        guard editor.string == repeated + blank + tail else { throw Failure("undo the repeated-line Restore") }
    }

    private static func checkWholeFileDeletion(in document: DocumentWindow, controller: JJInlineDiff) throws {
        let editor = document.editor
        let first = "first\n"
        let base = first + "second\n"
        let analysis = JJLineDiff.analyze(base: base, current: "", isConflicted: false, recordedConflict: nil)
        let hunk = try require(analysis.hunks.first, "make a whole-file deletion")
        controller.collapseAll()
        editor.string = ""
        editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
        document.window.makeFirstResponder(editor)
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        controller.toggle(hunk.mark)

        let firstRow = try require(controller.removedCaretRect(key: hunk.baseRange, offset: 0),
                                   "lay out the first removed row over an empty source")
        let secondRow = try require(controller.removedCaretRect(key: hunk.baseRange, offset: first.utf16.count),
                                    "lay out the second removed row over an empty source")
        let start = JJInlineDiffSelection.Position.removed(key: hunk.baseRange, offset: 0)
        let end = JJInlineDiffSelection.Position.removed(key: hunk.baseRange, offset: base.utf16.count)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard firstRow.midY < secondRow.midY,
              controller.select(from: start, to: end),
              controller.copyProjectedSelection(to: pasteboard, cutting: false),
              pasteboard.string(forType: .string) == base,
              controller.projectedEditRange == NSRange(location: 0, length: 0), editor.string.isEmpty else {
            throw Failure("keep removed text selectable when it is the only text on screen")
        }
    }

    private static func checkSidebarGeometry(in document: DocumentWindow, controller: JJInlineDiff) throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        let prefix = "    let value = "
        let suffix = String(repeating: " wide text for scrolling", count: 12)
        let base = "header\n" + prefix + "old" + suffix + "\nfooter\n"
        let current = "header\n" + prefix + "new" + suffix + "\nfooter\n"
        let analysis = JJLineDiff.analyze(base: base, current: current, isConflicted: false, recordedConflict: nil)
        let hunk = try require(analysis.hunks.first, "make a long changed line")
        controller.collapseAll()
        editor.string = current
        window.makeFirstResponder(editor)
        editor.setCaretSelections([NSRange(location: 0, length: 0)], record: false)
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        controller.toggle(hunk.mark)

        func checkAlignment(_ state: String) throws {
            window.layoutIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let font = editor.font ?? EditorTextView.defaultFont
            let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            let offset = max(0, Int((scroll.visibleContentOrigin.x + 32 - editor.textContainerOrigin.x) / characterWidth))
            for phase in ["on resize", "after relayout"] {
                let oldGlyph = try require(controller.removedCaretRect(key: hunk.baseRange, offset: offset),
                                           "lay out the removed caret \(state) \(phase)")
                let newGlyph = try require(editor.lineBounds(at: hunk.currentRange.location + offset),
                                           "lay out the live caret \(state) \(phase)")
                guard oldGlyph.height > 0, newGlyph.height > 0, abs(oldGlyph.minX - newGlyph.minX) < 1,
                      oldGlyph.midY < newGlyph.midY else {
                    throw Failure("align red and live columns \(state) \(phase) (\(oldGlyph), \(newGlyph))")
                }
                if state == "after returning to the first column" && phase == "on resize" {
                    let exposed = scroll.documentVisibleRect.intersection(editor.bounds)
                    for x in [exposed.minX + 18, exposed.maxX - 24] {
                        let oldBand = NSRect(x: x, y: oldGlyph.minY + 1, width: 3, height: oldGlyph.height - 2)
                        let newBand = NSRect(x: x, y: newGlyph.minY + 1, width: 3, height: newGlyph.height - 2)
                        guard try renderedColors(in: oldBand, of: editor).contains(where: { $0.redComponent > $0.greenComponent + 0.025 }),
                              try renderedColors(in: newBand, of: editor).contains(where: { $0.greenComponent > $0.redComponent + 0.025 }) else {
                            throw Failure("paint both diff rows out to the exposed edges before relayout")
                        }
                    }
                }
                if phase == "on resize" {
                    try checkExpandedGutter(on: oldGlyph, editor: editor, scroll: scroll, window: window, state: state)
                    controller.layout()
                }
            }
        }

        try checkAlignment("before opening a sidebar")
        var position = scroll.visibleContentOrigin
        position.x += 100
        guard scroll.scrollToVisibleContentOrigin(position) else { throw Failure("scroll the long line horizontally") }
        try checkAlignment("after horizontal scrolling")

        let panel = TerminalPanelState(dock: .right, spaces: [], selectedSpace: nil, nextSpaceNumber: 1)
        document.restoreTerminal(DocumentTerminalState(panel: panel, sizes: TerminalDockSizes(),
                                                       isVisible: false, wasFocused: false))
        document.showTerminal()
        guard document.isTerminalDockedRight else { throw Failure("open the right terminal sidebar") }
        try checkAlignment("with the right terminal open")

        document.performFind(.toggleSidebar)
        try checkAlignment("with both sidebars open")
        document.performFind(.toggleSidebar)
        try checkAlignment("after closing the left sidebar")
        document.toggleTerminal()
        try checkAlignment("after closing the right terminal")

        position = scroll.visibleContentOrigin
        position.x = 0
        scroll.scrollToVisibleContentOrigin(position)
        try checkAlignment("after returning to the first column")
        try checkOverscrolledBackgrounds(base: base, current: current)
    }

    private static func checkOverscrolledBackgrounds(base: String, current: String) throws {
        let bounds = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = EditorFocusCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let (scroll, editor) = EditorTextView.scrollingEditor(in: bounds)
        window.contentView = scroll
        defer { window.close() }
        guard window.makeFirstResponder(editor), editor.hasBufferFocus else { throw Failure("focus the quiet editor fixture") }

        let analysis = JJLineDiff.analyze(base: base, current: current, isConflicted: false, recordedConflict: nil)
        let hunk = try require(analysis.hunks.first, "make a long changed line for overscroll")
        editor.string = current
        window.layoutIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
        let controller = try require(editor.jjInlineDiff, "attach the overscrolled diff")
        controller.toggle(hunk.mark)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()

        let clip = scroll.contentView
        let footer = (current as NSString).range(of: "footer")
        editor.setSelectedRange(NSRange(location: footer.location, length: 0))
        editor.refreshCurrentLine()

        let rows = try [
            require(editor.laidOutLineBounds(at: 0), "lay out an ordinary row"),
            require(controller.removedCaretRect(key: hunk.baseRange, offset: 0), "lay out a removed row"),
            require(editor.laidOutLineBounds(at: hunk.currentRange.location), "lay out an added row"),
            require(editor.laidOutLineBounds(at: footer.location), "lay out the active row"),
        ]
        for edge in ["left", "right"] {
            let documentFrame = editor.frame
            let x = edge == "left" ? documentFrame.minX - 24 : documentFrame.maxX + 24 - clip.bounds.width
            // Install an intermediate rubber-band position without sending input to the user's desktop.
            var viewport = clip.bounds
            viewport.origin.x = x
            clip.bounds = viewport
            scroll.reflectScrolledClipView(clip)

            let sampleX = edge == "left" ? clip.bounds.minX : clip.bounds.maxX - 1
            func color(_ row: NSRect) throws -> NSColor {
                let point = editor.convert(NSPoint(x: 0, y: row.midY), to: clip)
                let sample = NSRect(x: sampleX, y: point.y, width: 1, height: 1)
                guard clip.bounds.contains(sample), !editor.frame.intersects(sample) else {
                    throw Failure("expose space beyond the \(edge) document edge")
                }
                return try require(renderedColors(in: scroll.convert(sample, from: clip), of: scroll).first,
                                   "sample the \(edge) overscroll")
            }
            let ordinary = try color(rows[0])
            let removed = try color(rows[1])
            let added = try color(rows[2])
            let active = try color(rows[3])
            guard removed.redComponent > removed.greenComponent + 0.025,
                  added.greenComponent > added.redComponent + 0.025,
                  abs(active.redComponent - ordinary.redComponent) > 0.025 else {
                throw Failure("continue the active, removed, and added backgrounds into the \(edge) overscroll")
            }
            window.simulatedKeyStatus = false
            guard try color(rows[3]) == ordinary else {
                throw Failure("clear the active row into the \(edge) overscroll when the editor loses focus")
            }
            window.simulatedKeyStatus = true
            editor.refreshCurrentLine()
        }
    }

    private static func checkExpandedGutter(on row: NSRect, editor: EditorTextView, scroll: NSScrollView,
                                            window: NSWindow, state: String) throws {
        let parent = try require(scroll.superview, "find the scroll view's event parent")
        let edge = max(editor.convert(scroll.visibleContentOrigin, to: scroll).x, scroll.contentView.frame.minX)
        let y = scroll.convert(row, from: editor).midY
        let center = scroll.convert(NSPoint(x: edge + 8, y: y), to: nil)
        let target = scroll.hitTest(parent.convert(center, from: nil))
        guard target is ClickTarget else { throw Failure("find the expanded gutter \(state)") }
        // The split view's resize grip owns the seam with an open leading sidebar.
        let first: CGFloat = scroll.safeAreaRect.minX > scroll.bounds.minX ? 2.5 : 0.5
        for x in [first, 4, 8, 11.5] {
            let location = scroll.convert(NSPoint(x: edge + x, y: y), to: nil)
            guard scroll.hitTest(parent.convert(location, from: nil)) === target,
                  EditApplication.clickCursor(in: window, at: location) === NSCursor.pointingHand else {
                throw Failure("use the click target's cursor across the expanded gutter at x=\(x) \(state)")
            }
        }
        let outside = scroll.convert(NSPoint(x: edge + 12.5, y: y), to: nil)
        guard scroll.hitTest(parent.convert(outside, from: nil)) !== target,
              EditApplication.clickCursor(in: window, at: outside) == nil else {
            throw Failure("leave text navigation immediately beyond the expanded gutter \(state)")
        }
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
              replacement.removedText == base,
              controller.removedCaretRect(key: replacement.baseRange, offset: 14) != nil else {
            throw Failure("the updated open comparison contains all three original red lines")
        }

        deletion = try openExample()
        editor.setCaretSelections([NSRange(location: 2, length: 0)], record: false)
        for _ in 0..<4 { editor.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:))) }
        guard controller.projectedEditRange == editableRange else {
            throw Failure("extend the selection with Shift-Left from live text into the removed row")
        }
        try checkCopy("2\nli")

        let liveRect = try require(editor.lineBounds(at: 2), "lay out the live caret for a mouse drag")
        let redRect = try require(controller.removedCaretRect(key: deletion.baseRange, offset: 12),
                                  "lay out the removed caret for a mouse drag")
        let startPoint = editor.convert(NSPoint(x: liveRect.minX, y: liveRect.midY), to: nil)
        let endPoint = editor.convert(NSPoint(x: redRect.minX, y: redRect.midY), to: nil)
        for (start, end) in [(startPoint, endPoint), (endPoint, startPoint)] {
            NSApp.postEvent(try mouse(.leftMouseUp, at: end, in: window), atStart: true)
            NSApp.postEvent(try mouse(.leftMouseDragged, at: end, in: window), atStart: true)
            editor.mouseDown(with: try mouse(.leftMouseDown, at: start, in: window))
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

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                              clickCount: Int = 1) throws -> NSEvent {
        try require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: type == .mouseMoved ? 0 : clickCount,
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

    private static func renderedColors(in rect: NSRect, of view: NSView) throws -> [NSColor] {
        guard !rect.isEmpty, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw Failure("capture the inline diff pixels")
        }
        view.cacheDisplay(in: rect, to: bitmap)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
        }
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
