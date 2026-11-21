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
        let manager = try require(editor.textLayoutManager, "Find uses the editor's TextKit layout")
        for (row, location) in [(0, 0), (1, 4)] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            var activeMatches: [Int] = []
            let start = manager.documentRange.location
            manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
                if let color = attributes[.backgroundColor] as? NSColor, color.alphaComponent > 0.5 {
                    activeMatches.append(manager.offset(from: start, to: range.location))
                }
                return true
            }
            try expect(activeMatches == [location], "the active editor highlight follows the selected result")
        }

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

        document.performFind(.refresh)
        try await waitUntil("dismissed match restored by refresh") { table.numberOfRows == 3 }
        document.performFind(.toggleSidebar)
        try expect(window.firstResponder === editor, "hiding Find restores editor focus")
        document.performFind(.next)
        try expect(editor.string == "cat cat\ncat", "finding with the sidebar hidden preserves text")
        try await checkSidebarLayout(in: app.makeDocument())
        try expect(NSApplication.shared.activationPolicy() == .prohibited &&
                   !NSApplication.shared.isActive && !window.isVisible, "Find stays in the isolated hidden window")
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
        let origin = clip.bounds.origin
        document.performFind(.find)
        try await Task.sleep(for: .milliseconds(30))
        try expect(abs(clip.bounds.origin.x - origin.x) < 1 && abs(clip.bounds.origin.y - origin.y) < 1,
                   "opening the sidebar preserves editor scroll position (\(origin) to \(clip.bounds.origin))")
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
        let icon = FileIcons.image(for: url, appearance: window.effectiveAppearance)
        try expect(icon != nil && window.standardWindowButton(.documentIconButton)?.image === icon,
                   "the title proxy retains its Seti icon with the sidebar toolbar installed")

        let query = try require(window.firstResponder as? NSTextView, "Find focuses its input")
        query.insertText("checksum", replacementRange: NSRange(location: 0, length: query.string.utf16.count))
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
            let cell = try require(table.view(atColumn: 0, row: 4, makeIfNecessary: true), "a visible match has a row")
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
        let firstCharacter = NSRange(location: 0, length: 0)
        editor.setSelectedRange(firstCharacter)
        let drags: [(NSPoint, CGFloat)] = [
            (NSPoint(x: 0, y: -scroll.contentInsets.top), 9),
            (NSPoint(x: 140, y: 40), -6),
        ]
        for (position, distance) in drags {
            clip.scroll(to: position)
            scroll.reflectScrolledClipView(clip)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let beforeDrag = clip.bounds.origin
            try expect(abs(beforeDrag.x - position.x) < 1 && abs(beforeDrag.y - position.y) < 1,
                       "the editor is scrolled to the starting position for the divider drag")
            let width = sidebar.frame.width
            try dragDivider(split.splitView, sidebar: sidebar, in: window, by: distance)
            window.layoutIfNeeded()
            await Task.yield()
            try expect(abs(sidebar.frame.width - width - distance) < 1,
                       "dragging the native divider changes the sidebar width")
            let afterDrag = clip.bounds.origin
            try expect(abs(afterDrag.x - beforeDrag.x) < 1 && abs(afterDrag.y - beforeDrag.y) < 1,
                       "dragging the sidebar divider preserves the editor scroll position (\(beforeDrag) to \(afterDrag))")
            try expect(editor.selectedRange() == firstCharacter, "dragging the sidebar divider preserves selection")
        }

        document.performFind(.toggleSidebar)
        await Task.yield()
        clip.scroll(to: NSPoint(x: 140, y: 40))
        document.scrollView.reflectScrolledClipView(clip)
        let scrolled = clip.bounds.origin
        document.performFind(.toggleSidebar)
        await Task.yield()
        try expect(abs(clip.bounds.origin.x - scrolled.x) < 1,
                   "reopening the sidebar preserves a nonzero horizontal scroll offset")
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
