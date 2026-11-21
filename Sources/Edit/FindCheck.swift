import AppKit

@MainActor
enum FindCheck {
    static func run(in app: Edit) async throws {
        try checkMatcher()

        let document = app.makeDocument()
        let window = document.window
        let editor = document.editor
        defer { window.close() }

        editor.string = "cat cat\ncat"
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        document.performFind(.find)
        let table = try require(
            descendant(of: window.contentView, type: FindResultsTable.self),
            "Find installs a native result table"
        )
        try await waitUntil("initial matches") { table.numberOfRows == 3 }
        try expect(editor.selectedRange() == NSRange(location: 0, length: 3), "opening Find preserves selection")
        document.performFind(.replace)
        let replacement = try require(
            window.firstResponder as? NSTextView, "Replace focuses its native input"
        )
        replacement.insertText("dog", replacementRange: NSRange(location: 0, length: replacement.string.utf16.count))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await Task.yield()
        try expect(editor.subviews.contains { !$0.isHidden && $0.accessibilityLabel()?.hasPrefix("Replace ") == true },
                   "inline preview is visible")
        try expect(editor.string == "cat cat\ncat", "preview never edits the document")
        document.performFind(.dismissSelected)
        try expect(table.numberOfRows == 2, "dismiss removes only the chosen occurrence")
        let undo = try require(editor.undoManager, "Find uses the document undo manager")
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        document.performFind(.replaceSelected)
        undo.endUndoGrouping()
        try await waitUntil("remaining match after single replacement; text=\(editor.string)") { table.numberOfRows == 1 }
        try expect(editor.string == "cat dog\ncat", "replace selected leaves a dismissed match unchanged")

        undo.beginUndoGrouping()
        document.performFind(.replaceAll)
        undo.endUndoGrouping()
        try await waitUntil("all retained matches replaced; text=\(editor.string)") { document.canPerformFind(.next) && table.numberOfRows == 0 }
        try expect(editor.string == "cat dog\ndog", "replace all applies only retained matches")
        undo.undo()
        try expect(editor.string == "cat dog\ncat", "one Undo restores Replace All")
        undo.undo()
        try expect(editor.string == "cat cat\ncat", "a second Undo restores Replace Selected")
        try await waitUntil("matches restored by undo; text=\(editor.string)") { table.numberOfRows == 2 }

        let menu = try sidebarMenu(in: window).menu
        let refreshIndex = menu.indexOfItem(withTitle: "Refresh Search")
        try expect(refreshIndex >= 0, "Refresh Search is in the sidebar menu")
        menu.performActionForItem(at: refreshIndex)
        try await waitUntil("dismissed match restored by the Refresh Search menu item") { table.numberOfRows == 3 }
        document.performFind(.toggleSidebar)
        try expect(window.firstResponder === editor, "hiding Find restores editor focus")
        document.performFind(.next)
        try expect(editor.string == "cat cat\ncat", "finding with the sidebar hidden preserves text")
        try await checkReturnNavigation(in: app.makeDocument())
        try await checkRenderedHighlights(in: app.makeDocument())
        try await checkSidebarLayout(in: app.makeDocument())
        try await checkSidebarReversal(in: app.makeDocument())
        try await checkWindowSession(in: app)
        try expect(NSApplication.shared.activationPolicy() == .prohibited &&
                   !NSApplication.shared.isActive && !window.isVisible, "Find stays in the isolated hidden window")
    }

    private static func checkWindowSession(in app: Edit) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "find-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Sample.txt")
        try Data("alpha ALPHA\nBeta Bota\n".utf8).write(to: file)
        let first = app.makeDocument()
        let second = app.makeDocument()
        let untouched = app.makeDocument()

        func type(_ value: String, command: FindCommand, in document: DocumentWindow) throws {
            document.performFind(command)
            let field = try require(document.window.firstResponder as? FindFieldTextView, "search session input")
            field.insertText(value, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        }

        func setWidth(_ width: CGFloat, in document: DocumentWindow) throws {
            let split = try require(document.window.contentViewController as? NSSplitViewController, "search session split view")
            split.splitView.setPosition(width, ofDividerAt: 0)
            document.window.layoutIfNeeded()
        }

        _ = try await app.openFile(file, in: first)
        _ = try await app.openFile(file, in: second)
        try type("alpha", command: .find, in: first)
        first.performFind(.toggleCase)
        try type("first replacement", command: .replace, in: first)
        try setWidth(240, in: first)
        try type("B.ta", command: .find, in: second)
        second.performFind(.toggleRegex)
        try type("second replacement", command: .replace, in: second)
        second.performFind(.toggleReplace)
        try setWidth(325, in: second)
        second.performFind(.toggleSidebar)

        let all = app.sessionSnapshot()
        let snapshot = EditorSession(documents: Array(all.documents.suffix(3)), activeIndex: 0, lastWindow: nil)
        let store = SessionStore(url: directory.appending(path: "session.json"))
        try store.write(snapshot)
        let saved = try require(try store.read(), "read back window search sessions")
        let firstSettings = try require(saved.documents[0].findSettings, "snapshot of first window's search")
        let secondSettings = try require(saved.documents[1].findSettings, "snapshot of second window's search")
        try expect(firstSettings.query == "alpha" && secondSettings.query == "B.ta" && saved.documents[2].findSettings == nil,
                   "search state is saved per window even for two views of the same file")
        try expect(firstSettings.width != secondSettings.width, "the windows keep independent sidebar widths")

        [first, second, untouched].forEach { $0.window.close() }
        let placeholder = app.makeDocument()
        await app.restore(saved, reusing: placeholder)
        let restored = Array(app.documents.suffix(3))
        defer { restored.forEach { $0.window.close() } }
        try expect(restored.first === placeholder, "restoring search keeps the associated editor windows")
        try expect(restored[0].sessionDocument().findSettings == firstSettings &&
                   restored[1].sessionDocument().findSettings == secondSettings,
                   "each window restores its own replacement, options, width, and visibility")

        let firstTable = try require(descendant(of: restored[0].window.contentView, type: FindResultsTable.self),
                                     "the first sidebar reopens visibly")
        try await waitUntil("the first window reruns its case-insensitive query") { firstTable.numberOfRows == 2 }
        try expect(restored[1].window.contentViewController as? NSSplitViewController == nil && restored[1].canPerformFind(.next),
                   "the second sidebar stays hidden and still has its own query")
        restored[1].performFind(.find)
        let secondField = try require(restored[1].window.firstResponder as? FindFieldTextView, "the restored second query field")
        let secondTable = try require(descendant(of: restored[1].window.contentView, type: FindResultsTable.self),
                                      "the second sidebar opens on demand")
        try expect(secondField.string == "B.ta", "opening hidden Find preserves its saved query")
        try await waitUntil("the second window reruns its regex") { secondTable.numberOfRows == 2 }

        let fresh = app.makeDocument()
        defer { fresh.window.close() }
        for document in [restored[2], fresh] {
            document.performFind(.find)
            let field = try require(document.window.firstResponder as? FindFieldTextView, "empty search field")
            try expect(field.string.isEmpty, "windows without saved search state start with an empty query")
        }
    }

    private static func checkReturnNavigation(in document: DocumentWindow) async throws {
        let window = document.window
        let editor = document.editor
        editor.string = "cat cat\ncat"
        document.performFind(.find)
        let find = try require(window.firstResponder as? FindFieldTextView, "Return check Find field")
        let table = try require(descendant(of: window.contentView, type: FindResultsTable.self), "Return check results")
        let pressReturn = try require(
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "\r",
                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
            "plain Return key event"
        )

        find.keyDown(with: pressReturn)
        try expect(window.firstResponder === find, "Find keeps focus when there are no matches")
        find.insertText("cat", replacementRange: NSRange(location: 0, length: 0))
        find.keyDown(with: pressReturn)
        try await waitUntil("Return focuses the first result when the pending search completes") {
            window.firstResponder === table && table.selectedRow == 0
        }
        table.keyDown(with: pressReturn)
        try expect(window.firstResponder === editor && editor.selectedRange() == NSRange(location: 3, length: 0) &&
                   editor.string == "cat cat\ncat", "Return in a search result focuses the editor after the match")

        document.performFind(.replace)
        let replace = try require(window.firstResponder as? FindFieldTextView, "Return check Replace field")
        replace.insertText("dog", replacementRange: NSRange(location: 0, length: 0))
        document.performFind(.find)
        find.keyDown(with: pressReturn)
        try expect(window.firstResponder === replace, "Return in Find moves to Replace when it is open")
        replace.keyDown(with: pressReturn)
        try expect(window.firstResponder === table && table.selectedRow == 0, "Return in Replace focuses the first result")
        table.keyDown(with: pressReturn)
        try await waitUntil("Return on a result applies one replacement and advances") {
            editor.string == "dog cat\ncat" && table.numberOfRows == 2 && window.firstResponder === table &&
                table.selectedRow == 0
        }

        document.performFind(.find)
        find.insertText("missing", replacementRange: NSRange(location: 0, length: find.string.utf16.count))
        find.keyDown(with: pressReturn)
        try expect(window.firstResponder === replace, "Return in Find moves to Replace with no results")
        replace.keyDown(with: pressReturn)
        try await waitUntil("the unmatched query finishes without moving focus out of Replace") {
            table.numberOfRows == 0 && window.firstResponder === replace
        }

        document.performFind(.toggleReplace)
        find.insertText("cat", replacementRange: NSRange(location: 0, length: find.string.utf16.count))
        find.keyDown(with: pressReturn)
        document.performFind(.find)
        try await waitUntil("reopening Find cancels deferred focus of results") {
            table.numberOfRows == 2 && window.firstResponder === find
        }
    }

    private static func checkRenderedHighlights(in document: DocumentWindow) async throws {
        let window = document.window
        let editor = document.editor
        let clip = document.scrollView.contentView
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let text = "use first::Item;\n\nuse second::Item;\n" +
            String(repeating: "fn example() {}\n", count: 70) + "use third::Item;\nuse fourth::Item;\n"
        editor.string = text
        document.setSyntaxLanguage(.rust)
        document.performFind(.find)
        let input = try require(window.firstResponder as? FindFieldTextView, "Find input for the render check")
        let table = try require(descendant(of: window.contentView, type: FindResultsTable.self), "render check result table")
        let manager = try require(editor.textLayoutManager, "TextKit 2 for the render check")
        input.insertText("us", replacementRange: NSRange(location: 0, length: 0))
        // Use the backing layer of a non-interactive, transparent window without repainting for the capture.
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try expect(window.isVisible && !NSApp.isActive && window.alphaValue == 0, "quiet search render check")
        try await waitUntil("the Rust sample has syntax colors and search results") {
            var hasSyntax = false
            manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attrs, _ in
                hasSyntax = attrs[.foregroundColor] is NSColor
                return !hasSyntax
            }
            return table.numberOfRows == 4 && hasSyntax
        }

        let wordStarts = ["use first", "use second", "use third", "use fourth"].map {
            (text as NSString).range(of: $0).location
        }
        func hasPaint(active: Int, other: Int) -> Bool {
            let bounds = clip.bounds
            guard let layer = clip.layer,
                  let bitmap = clip.bitmapImageRepForCachingDisplay(in: bounds),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
            let rendered = layer.presentation() ?? layer
            let context = graphics.cgContext
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -rendered.bounds.minX, y: -rendered.bounds.minY)
            rendered.render(in: context)

            func sample(_ index: Int) -> NSColor? {
                let range = NSRange(location: wordStarts[index], length: 2)
                let screenRect = editor.firstRect(forCharacterRange: range, actualRange: nil)
                let rect = clip.convert(window.convertFromScreen(screenRect), from: nil)
                let point = NSPoint(x: rect.minX + 1, y: rect.minY + 1)
                guard bounds.contains(point) else { return nil }
                let x = Int((point.x - bounds.minX) * CGFloat(bitmap.pixelsWide) / bounds.width)
                let y = Int((point.y - bounds.minY) * CGFloat(bitmap.pixelsHigh) / bounds.height)
                return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            }
            guard let current = sample(active), let passive = sample(other) else { return false }
            return current.redComponent - current.greenComponent > 0.12 &&
                passive.redComponent - passive.greenComponent < 0.12 &&
                passive.redComponent - passive.blueComponent > 0.12
        }

        document.performFind(.next)
        try await waitUntil("the first selected result is orange and the second is yellow") { hasPaint(active: 0, other: 1) }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntil("the painted highlight moves to the selected row") { hasPaint(active: 1, other: 0) }

        document.performFind(.previous)
        let viewport = try require(manager.textViewportLayoutController.viewportRange, "visible Rust text")
        manager.invalidateRenderingAttributes(for: viewport)
        manager.textViewportLayoutController.layoutViewport()
        try await waitUntil("the painted highlights survive a reset of TextKit's rendering attributes") {
            hasPaint(active: 0, other: 1)
        }

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await waitUntil("the editor scrolls to and paints the distant result") { hasPaint(active: 2, other: 3) }
        document.performFind(.next)
        try await waitUntil("the painted highlight follows forward navigation") { hasPaint(active: 3, other: 2) }
        document.performFind(.next)
        try await waitUntil("navigation wraps and paints the first result again") { hasPaint(active: 0, other: 1) }
    }

    private static func checkSidebarLayout(in document: DocumentWindow) async throws {
        let window = document.window
        let editor = document.editor
        let scroll = document.scrollView
        let clip = scroll.contentView
        let lines = (0..<100).map { index in
            "checksum = \"" + String(index) + String(repeating: "abcdef0123456789", count: 12) + "\""
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Search layout.toml")
        let text = lines.joined(separator: "\n")
        try Data(text.utf8).write(to: url)
        document.load(try FileBuffer.read(url))
        let caret = NSRange(location: lines[0].utf16.count, length: 0)
        editor.setSelectedRange(caret)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let documentToolbar = try require(window.toolbar, "document toolbar")
        try expect(documentToolbar.displayMode == .iconOnly && !documentToolbar.allowsDisplayModeCustomization,
                   "the document toolbar uses fixed icon display")
        let titlebarBottom = window.contentLayoutRect.maxY
        let titlebarInset = scroll.contentInsets.top
        let initialFrame = scroll.convert(scroll.bounds, to: nil)
        try expect(window.styleMask.contains(.fullSizeContentView) && window.toolbar?.isVisible == true &&
                   !window.titlebarAppearsTransparent && scroll.automaticallyAdjustsContentInsets &&
                   initialFrame.maxY > titlebarBottom && titlebarInset > 0,
                   "the native titlebar overlaps the editor's scroll view before Search opens")
        func firstLineFrame() -> NSRect {
            let bounds = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            return window.convertFromScreen(bounds)
        }
        let firstAtTop = firstLineFrame()
        try expect(firstAtTop.height > 0 && firstAtTop.maxY <= titlebarBottom,
                   "the system inset keeps the first line below the titlebar at the top")
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let firstUnderTitlebar = firstLineFrame()
        try expect(firstUnderTitlebar.height > 0 && firstUnderTitlebar.minY >= titlebarBottom &&
                   firstUnderTitlebar.maxY <= initialFrame.maxY,
                   "the first line scrolls up under the native titlebar")
        editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count - 1, length: 1))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        clip.scroll(to: NSPoint(x: 0, y: 40))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        document.scrollView.reflectScrolledClipView(clip)
        let origin = scroll.visibleContentOrigin
        document.performFind(.find)
        try await Task.sleep(for: .milliseconds(30))
        let openedOrigin = scroll.visibleContentOrigin
        try expect(abs(openedOrigin.x - origin.x) < 1 && abs(openedOrigin.y - origin.y) < 1,
                   "opening the sidebar preserves editor scroll position (\(origin) to \(openedOrigin))")
        try expect(editor.selectedRange() == caret, "sidebar layout preserves the editor selection")

        let split = try require(window.contentViewController as? NSSplitViewController, "Find uses a native split view")
        let sidebar = split.splitViewItems[0].viewController.view
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        try expect(sidebarFrame.maxY > window.contentLayoutRect.maxY && sidebarFrame.minY <= window.contentLayoutRect.minY,
                   "sidebar spans the window including titlebar (\(sidebarFrame), content \(window.contentLayoutRect))")
        let editorFrame = scroll.convert(scroll.bounds, to: nil)
        try expect(editorFrame.maxY > window.contentLayoutRect.maxY && abs(editorFrame.maxY - sidebarFrame.maxY) < 1 &&
                   abs(scroll.contentInsets.top - titlebarInset) < 1,
                   "the editor still scrolls under the same titlebar when the sidebar opens")
        try expect(abs(editorFrame.minX - initialFrame.minX) < 1 && scroll.contentInsets.left > 0 &&
                   abs(editorFrame.minX + scroll.contentInsets.left - sidebarFrame.maxX) < 2,
                   "the full-width editor is inset only at the native sidebar's exposed edge")
        let sampleLocation = (text as NSString).range(of: lines[6]).location
        func sampleFrame() -> NSRect {
            let screen = editor.firstRect(forCharacterRange: NSRange(location: sampleLocation, length: 1), actualRange: nil)
            return window.convertFromScreen(screen)
        }
        let glyphAtRest = sampleFrame()
        try expect(glyphAtRest.height > 0 && glyphAtRest.minX >= sidebarFrame.maxX,
                   "the first column stays clear of the sidebar at the leftmost scroll position")
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 140, y: origin.y))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let glyphBehindSidebar = sampleFrame()
        try expect(glyphBehindSidebar.height > 0 && glyphBehindSidebar.minX > sidebarFrame.minX &&
                   glyphBehindSidebar.maxX < sidebarFrame.maxX && abs(glyphAtRest.minX - glyphBehindSidebar.minX - 140) < 2,
                   "horizontal scrolling carries the same text underneath the sidebar")
        let scroller = try require(scroll.horizontalScroller, "the native editor horizontal scroller")
        try expect(scroller.convert(scroller.bounds, to: nil).minX >= sidebarFrame.maxX - 1,
                   "the horizontal scroller starts at the exposed edge of the editor")
        let bitmap = try require(clip.bitmapImageRepForCachingDisplay(in: clip.bounds), "editor underlay bitmap")
        clip.cacheDisplay(in: clip.bounds, to: bitmap)
        let glyphInClip = clip.convert(glyphBehindSidebar, from: nil)
        let scale = CGFloat(bitmap.pixelsWide) / clip.bounds.width
        let from = max(0, Int((glyphInClip.minX - clip.bounds.minX) * scale))
        let to = min(bitmap.pixelsWide, Int((glyphInClip.maxX - clip.bounds.minX) * scale) + 1)
        let paintsBehindSidebar = stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 3).contains { y in
            guard let background = bitmap.colorAt(x: 8, y: y)?.usingColorSpace(.sRGB) else { return false }
            return (from..<max(from, to)).contains { x in
                guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return max(abs(ink.redComponent - background.redComponent),
                           abs(ink.greenComponent - background.greenComponent),
                           abs(ink.blueComponent - background.blueComponent)) > 0.08
            }
        }
        try expect(paintsBehindSidebar, "TextKit paints glyphs in the editor region underneath the sidebar")
        editor.scrollRangeToVisible(NSRange(location: sampleLocation, length: 1))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try expect(sampleFrame().minX >= sidebarFrame.maxX,
                   "revealing a text range brings it back into the exposed editor")
        scroll.scrollToVisibleContentOrigin(origin)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let icon = FileIcons.image(for: url, appearance: window.effectiveAppearance)
        try expect(icon != nil && HeaderCheck.fileIcon(in: document)?.image === icon,
                   "the title bar retains its Seti icon with the sidebar toolbar installed")

        let query = try require(window.firstResponder as? NSTextView, "Find focuses its input")
        query.insertText("checksum", replacementRange: NSRange(location: 0, length: query.string.utf16.count))
        let sidebarToolbar = try require(window.toolbar, "sidebar toolbar")
        try expect(sidebarToolbar.displayMode == .iconOnly && !sidebarToolbar.allowsDisplayModeCustomization &&
                   !sidebarToolbar.items.contains { $0.itemIdentifier.rawValue == "Search.Refresh" },
                   "the sidebar toolbar uses fixed icons without a separate Refresh button")
        let picker = try sidebarMenu(in: window)
        let items = picker.menu.items
        try expect(!picker.isHidden && items.count == 3 && items[0].title == "Search" && items[0].state == .on &&
                   items[1].isSeparatorItem && items[2].title == "Refresh Search",
                   "the sidebar menu lists the active sidebar before the Refresh Search command")
        window.makeFirstResponder(editor)
        picker.menu.performActionForItem(at: 0)
        try expect(window.firstResponder === query && query.string == "checksum",
                   "selecting Search focuses Find and preserves the query")
        document.performFind(.replace)
        let replacement = try require(window.firstResponder as? NSTextView, "Replace focuses its input")
        replacement.insertText("digest", replacementRange: NSRange(location: 0, length: replacement.string.utf16.count))
        let table = try require(descendant(of: sidebar, type: FindResultsTable.self), "Find has a native results table")
        try await waitUntil("one result per long source line") { table.numberOfRows == lines.count }
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        for width in [280.0, 185.0] {
            split.splitView.setPosition(width, ofDividerAt: 0)
            window.layoutIfNeeded()
            let cell = try require(table.view(atColumn: 0, row: 4, makeIfNecessary: true) as? FindResultCell,
                                   "a visible match has a result row")
            cell.layoutSubtreeIfNeeded()
            let field = try require(descendant(of: cell, type: NSTextField.self), "result has an excerpt")
            try expect(field.stringValue.hasPrefix("checksum ="), "long excerpts keep their matching prefix")
            try expect(field.frame.height <= cell.bounds.height && field.maximumNumberOfLines == 1,
                       "long excerpts are one line and fit at sidebar width \(width)")
            let font = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try expect(font == editor.font, "result excerpts use the editor font")
            let dismiss = try require(
                cell.subviews.first { $0.accessibilityLabel() == "Dismiss This Match" }, "the row has a Dismiss button"
            )
            try expect(!dismiss.isHidden && abs(dismiss.frame.maxX - (cell.bounds.maxX - 4)) < 1,
                       "Dismiss stays at the right edge of the result row")
            let style = field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            try expect(style?.tighteningFactorForTruncation == 0, "truncating excerpts preserves character spacing")
            func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
                try require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, trackingNumber: 0, userData: nil),
                            "search row hover event")
            }
            let selectedFrame = field.frame
            cell.updateSelection(false)
            cell.layoutSubtreeIfNeeded()
            try expect(dismiss.isHidden && field.frame == selectedFrame,
                       "the result excerpt keeps its width when selection changes (\(selectedFrame) to \(field.frame))")
            cell.mouseEntered(with: try hoverEvent(.mouseEntered))
            cell.layoutSubtreeIfNeeded()
            try expect(!dismiss.isHidden && field.frame == selectedFrame,
                       "the result excerpt keeps its width when row buttons appear on hover")
            cell.mouseExited(with: try hoverEvent(.mouseExited))
            cell.updateSelection(true)
        }
        let fourthLine = lines.prefix(4).reduce(0) { $0 + $1.utf16.count + 1 }
        let followingLine = fourthLine + lines[4].utf16.count + 1
        func lineRect(_ location: Int) -> NSRect {
            editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        }
        let previewDistance = abs(lineRect(fourthLine).minY - lineRect(followingLine).minY)
        try expect(previewDistance > lineRect(fourthLine).height * 1.75,
                   "the next document line remains visible below the replacement preview")
        try expect(editor.string == lines.joined(separator: "\n"), "the preview leaves the source buffer unchanged")
        document.performFind(.clearSelection)
        let plainDistance = abs(lineRect(fourthLine).minY - lineRect(followingLine).minY)
        try expect(plainDistance < previewDistance, "clearing preview restores the original line spacing")

        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: sampleLocation, length: 0))
        scroll.scrollToVisibleContentOrigin(NSPoint(x: 140, y: origin.y))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        try expect(editor.selectedRange().location == sampleLocation + 1, "keyboard navigation moves the caret")
        let exposedEdge = sidebar.convert(sidebar.bounds, to: nil).maxX
        try await waitUntil("keyboard navigation reveals a caret behind the resized sidebar") {
            let range = NSRange(location: editor.selectedRange().location, length: 1)
            let rect = editor.firstRect(forCharacterRange: range, actualRange: nil)
            return rect.height > 0 && window.convertFromScreen(rect).minX >= exposedEdge
        }

        scroll.scrollToVisibleContentOrigin(NSPoint(x: 140, y: origin.y))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let insertion = editor.selectedRange()
        editor.insertText("x", replacementRange: insertion)
        try expect(editor.selectedRange().location == insertion.location + 1, "typing keeps the insertion caret")
        try await waitUntil("typing reveals the insertion point behind the sidebar") {
            let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            return rect.height > 0 && window.convertFromScreen(rect).minX >= exposedEdge
        }

        let firstCharacter = NSRange(location: 0, length: 0)
        editor.setSelectedRange(firstCharacter)
        let drags: [(NSPoint, CGFloat)] = [
            (NSPoint(x: 0, y: 0), 9),
            (NSPoint(x: 140, y: 80), -6),
        ]
        for (position, distance) in drags {
            scroll.scrollToVisibleContentOrigin(position)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let beforeDrag = scroll.visibleContentOrigin
            try expect(abs(beforeDrag.x - position.x) < 1 && abs(beforeDrag.y - position.y) < 1,
                       "the editor is scrolled to the starting position for the divider drag")
            let width = sidebar.frame.width
            try dragDivider(split.splitView, sidebar: sidebar, in: window, by: distance)
            window.layoutIfNeeded()
            await Task.yield()
            try expect(abs(sidebar.frame.width - width - distance) < 1,
                       "dragging the native divider changes the sidebar width")
            let afterDrag = scroll.visibleContentOrigin
            try expect(abs(afterDrag.x - beforeDrag.x) < 1 && abs(afterDrag.y - beforeDrag.y) < 1,
                       "dragging the sidebar divider preserves the editor scroll position (\(beforeDrag) to \(afterDrag))")
            try expect(editor.selectedRange() == firstCharacter, "dragging the sidebar divider preserves selection")
        }

        document.performFind(.toggleSidebar)
        await Task.yield()
        try expect(picker.isHidden, "the menu is hidden with the sidebar")
        clip.scroll(to: NSPoint(x: 140, y: 40))
        document.scrollView.reflectScrolledClipView(clip)
        let scrolled = scroll.visibleContentOrigin
        document.performFind(.toggleSidebar)
        await Task.yield()
        try expect(abs(scroll.visibleContentOrigin.x - scrolled.x) < 1,
                   "reopening the sidebar preserves a nonzero horizontal scroll offset")
        try expect(!picker.isHidden, "reopening the sidebar restores its menu")
    }

    private static func checkSidebarReversal(in document: DocumentWindow) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let window = document.window
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        // AppKit animates an ordered window. Keep this one invisible and non-interactive.
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try expect(window.isVisible && !NSApp.isActive && window.alphaValue == 0,
                   "live sidebar animation runs without interrupting the user")

        document.performFind(.toggleSidebar)
        let split = try require(window.contentViewController as? NSSplitViewController, "native animated split view")
        let sidebar = split.splitViewItems[0]
        let picker = try sidebarMenu(in: window)
        func divider() -> CGFloat {
            if sidebar.isCollapsed { return 0 }
            let view = sidebar.viewController.view
            return view.convert(view.bounds, to: split.splitView).maxX
        }
        func reverse(with command: FindCommand) throws {
            let position = divider()
            let origin = document.scrollView.visibleContentOrigin
            document.performFind(command)
            try expect(abs(divider() - position) < 1 && abs(document.scrollView.visibleContentOrigin.x - origin.x) < 1,
                       "reversing preserves the divider position and the horizontal scroll offset")
            try expect(picker.isHidden, "the menu button stays hidden until the sidebar settles")
        }

        try await waitUntil("sidebar fully opens") { !picker.isHidden }
        let openPosition = divider()
        document.performFind(.toggleSidebar)
        try await waitUntil("sidebar is partway closed") { divider() > 0 && divider() < openPosition * 0.8 }
        try reverse(with: .find)
        try expect(window.firstResponder is FindFieldTextView, "reopening with Command-F focuses Find")
        try await waitUntil("reversed sidebar finishes opening") { !picker.isHidden }
        try expect(abs(divider() - openPosition) < 1, "reopening preserves the sidebar width")

        document.performFind(.toggleSidebar)
        try await waitUntil("sidebar fully closes") { sidebar.isCollapsed }
        document.performFind(.toggleSidebar)
        try await waitUntil("sidebar is partway open") { divider() > openPosition * 0.2 && divider() < openPosition }
        try reverse(with: .toggleSidebar)
        try await waitUntil("reversed sidebar finishes closing") { sidebar.isCollapsed }
        try expect(divider() < 1 && window.firstResponder === document.editor,
                   "closing leaves the editor focused")

        document.performFind(.toggleSidebar)
        document.performFind(.toggleSidebar)
        document.performFind(.find)
        try await waitUntil("rapid toggles leave the sidebar open") { !picker.isHidden }
        try expect(abs(divider() - openPosition) < 1 && window.firstResponder is FindFieldTextView,
                   "superseded animations leave the latest width and focus")
    }

    private static func sidebarMenu(in window: NSWindow) throws -> NSMenuToolbarItem {
        try require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "Edit.SidebarMenu" } as? NSMenuToolbarItem,
                    "the sidebar header contains a native menu")
    }

    private static func dragDivider(_ splitView: NSSplitView, sidebar: NSView, in window: NSWindow, by distance: CGFloat) throws {
        let divider = splitView.convert(
            NSPoint(x: sidebar.frame.maxX + splitView.dividerThickness / 2, y: splitView.bounds.midY), to: nil
        )
        func mouse(_ type: NSEvent.EventType, offset: CGFloat) throws -> NSEvent {
            try require(NSEvent.mouseEvent(with: type, location: NSPoint(x: divider.x + offset, y: divider.y),
                                         modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                        "native divider event")
        }
        let down = try mouse(.leftMouseDown, offset: 0)
        for offset in [distance / 3, 2 * distance / 3, distance] {
            NSApplication.shared.postEvent(try mouse(.leftMouseDragged, offset: offset), atStart: false)
        }
        NSApplication.shared.postEvent(try mouse(.leftMouseUp, offset: distance), atStart: false)
        splitView.mouseDown(with: down)
    }

    private static func checkMatcher() throws {
        let original = "ID:24 ID:51"
        let options = FindOptions(regularExpression: true)
        guard case .matches(let hits) = FindSearch.match("(?P<key>[A-Z]+):(\\d+)", in: original, options: options) else {
            throw Failure("match regex")
        }
        try expect(hits.count == 2, "separate matches on the same line")
        let captures = "$2/$0/" + "$" + "{key}/$$/" + "$" + "{absent}"
        let replacement = hits.first?.replacement(using: captures, in: original as NSString, isRegex: true)
        try expect(replacement == "24/ID:24/ID/$/", "numbered and named regex captures")
        guard case .invalidExpression = FindSearch.match("[", in: original, options: options) else {
            throw Failure("invalid regex is reported")
        }
        guard case .matches(let words) = FindSearch.match("кот", in: "Кот котик _кот кошка-кот",
                                                         options: FindOptions(caseSensitive: false, wholeWord: true)) else {
            throw Failure("whole-word search")
        }
        try expect(words.count == 2, "Unicode whole-word search is case insensitive")
    }

    private static func descendant<T: NSView>(of root: NSView?, type: T.Type) -> T? {
        guard let root else { return nil }
        if let view = root as? T { return view }
        for child in root.subviews {
            if let view = descendant(of: child, type: type) { return view }
        }
        return nil
    }

    private static func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(condition(), description)
    }

    private static func expect(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure(description) }
    }

    private static func require<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw Failure(description) }
        return value
    }

    private struct Failure: LocalizedError {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { "Failed Find check for \(description)." }
    }
}
