import AppKit

@MainActor
enum BracketCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = "Brackets: \(detail)" }
    }

    static func run(in app: Edit) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        guard let menu = NSApplication.shared.mainMenu else { throw Failure("Missing command menu.") }
        let commands = ControlCommand.fromMenu(menu)
        guard let go = commands.first(where: { $0.item.action == #selector(EditorTextView.goToBracket(_:)) }),
              let select = commands.first(where: { $0.item.action == #selector(EditorTextView.selectToBracket(_:)) }),
              go.item.keyEquivalent.isEmpty, select.item.keyEquivalent.isEmpty else {
            throw Failure("Both commands should be available without shortcuts.")
        }

        let editor = document.editor
        let source = "let data = [ value ]\nlet text = \"[ never ]\"\nlet tail = last"
        let text = source as NSString
        let opener = text.range(of: "[")
        let closer = text.range(of: "]")
        let value = text.range(of: "value")
        let tail = text.range(of: "last")
        editor.string = source
        editor.didChangeText()
        document.setSyntaxLanguage(.swift)
        editor.setSelectedRange(caret(value.location + 2))

        guard go.isAvailable(in: document, focus: editor) else { throw Failure("Go to Bracket missing from Control.") }
        go.run(in: document)
        try await waitFor("Go to Bracket from inside the pair") { editor.selectedRange() == caret(closer.location) }

        guard editor.tryToPerform(#selector(EditorTextView.selectToBracket(_:)), with: select.item) else {
            throw Failure("Select to Bracket is not on the editor responder chain.")
        }
        let pair = NSUnionRange(opener, closer)
        try await waitFor("the inclusive backward selection") {
            editor.selectedRange() == pair && editor.activeEnd(of: pair) == opener.location
        }
        editor.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
        let extended = NSRange(location: pair.location - 1, length: pair.length + 1)
        guard editor.selectedRange() == extended else { throw Failure("Shift-Left did not extend the backward selection.") }

        editor.setCaretSelections([caret(value.location + 2), caret(tail.location)])
        select.run(in: document)
        guard editor.caretSelections == [pair] else { throw Failure("An unsuccessful selection result was retained.") }

        let quoted = text.range(of: "never")
        editor.setCaretSelections([caret(quoted.location + 2)])
        go.run(in: document)
        guard editor.selectedRange() == caret(quoted.location + 2), editor.string == source else {
            throw Failure("A quoted bracket changed navigation or text.")
        }
        document.setSyntaxLanguage(.plainText)
        go.run(in: document)
        try await waitFor("Plain Text includes brackets inside quotes") {
            editor.selectedRange() == caret(text.range(of: "]", options: .backwards).location)
        }
        try await checkHighlights()
        try await checkDecorationsWhileTyping()
    }

    private static func checkHighlights() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 380, height: 140)
        let window = BracketCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }
        let (scroll, editor) = EditorTextView.scrollingEditor(in: bounds)
        window.contentView = scroll
        window.makeFirstResponder(editor)
        editor.string = "( left ) [ right ]"
        editor.didChangeText()
        editor.setCaretSelections([caret(14)])
        let expected = [NSRange(location: 9, length: 1), NSRange(location: 17, length: 1)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.layoutIfNeeded()
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            editor.bracketNavigation.refresh()
            do {
                try await waitFor("both bracket frames in \(appearance.rawValue)") {
                    editor.bracketNavigation.highlightRanges == expected && editor.bracketNavigation.highlightFrames.count == 2
                }
            } catch {
                let ranges = editor.bracketNavigation.highlightRanges
                let frames = editor.bracketNavigation.highlightFrames
                throw Failure("\(appearance.rawValue) drew \(frames) for \(ranges), selection \(editor.caretSelections), "
                              + "editor focus \(window.firstResponder === editor).")
            }
            let visible = editor.visibleRect
            guard let marked = editor.bitmapImageRepForCachingDisplay(in: visible),
                  let cleared = editor.bitmapImageRepForCachingDisplay(in: visible) else {
                throw Failure("Could not capture the quiet bracket fixture.")
            }
            editor.cacheDisplay(in: visible, to: marked)
            editor.bracketNavigation.clearHighlights()
            editor.cacheDisplay(in: visible, to: cleared)
            guard marked.tiffRepresentation != cleared.tiffRepresentation else {
                throw Failure("No pixels changed when removing the bracket highlights.")
            }
            editor.requestLineRefresh()
        }
        editor.setSelectedRange(NSRange(location: 12, length: 3))
        try await waitFor("a nonempty selection removes the highlights") { editor.bracketNavigation.highlightRanges.isEmpty }
        editor.setSelectedRange(caret(14))
        try await waitFor("the restored caret highlights brackets") { editor.bracketNavigation.highlightRanges == expected }
        window.makeFirstResponder(nil)
        guard editor.bracketNavigation.highlightRanges.isEmpty, !window.isVisible, !NSApplication.shared.isActive else {
            throw Failure("The quiet fixture did not clear the bracket highlight on blur.")
        }
    }

    private static func checkDecorationsWhileTyping() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 420, height: 160)
        let window = BracketCheckWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let (scroll, editor) = EditorTextView.scrollingEditor(in: bounds)
        window.contentView = scroll
        window.makeFirstResponder(editor)

        let source = "test \"typing\" {\n    return error.Hello;\n    return error;\n    return error.Hello\n}\n"
        let text = source as NSString
        let opening = text.range(of: "{")
        let closing = text.range(of: "}")
        editor.string = source
        editor.bracketNavigation.setLanguage(.zig)
        editor.setCaretSelections([caret(text.range(of: ";").upperBound)])
        window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.bracketNavigation.refresh()
        try await waitFor("the original pair before editing") {
            editor.bracketNavigation.highlightRanges == [opening, closing] && editor.bracketNavigation.highlightFrames.count == 2
        }

        func showCurrentMarks() -> [JJLineMark] {
            let result = JJLineDiff.analyze(base: "", current: editor.string, isConflicted: false, recordedConflict: nil)
            editor.setJJLineMarks(result.marks, lineStarts: result.lineStarts)
            return result.marks
        }
        let marks = showCurrentMarks()
        let gutterX = editor.convert(NSPoint(x: scroll.contentView.frame.minX + 3, y: 0), from: scroll).x
        func decorationAreas(closing: NSRange, phase: String) throws -> [NSRect] {
            let brackets = editor.highlightRects(for: [opening, closing])
            guard brackets.count == 2 else {
                let manager = editor.textLayoutManager
                let viewport = manager?.textViewportLayoutController.viewportRange.flatMap { viewport in
                    manager.map { editor.charRange(viewport, in: $0) }
                }
                throw Failure("Lay out both delimiters \(phase). Closing \(closing), frames \(brackets), viewport \(String(describing: viewport)).")
            }
            // A fallback font can move the closing row, so sample its current position.
            return brackets + [NSRect(x: gutterX, y: brackets[1].midY, width: 1, height: 1)]
        }

        func capture(_ area: NSRect) throws -> NSBitmapImageRep {
            guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: area) else {
                throw Failure("Capture the bracket and gutter pixels in the unordered editor window.")
            }
            editor.cacheDisplay(in: area, to: bitmap)
            return bitmap
        }
        let areas = try decorationAreas(closing: closing, phase: "before any edit")
        let painted = try areas.map { try capture($0).tiffRepresentation }
        let stripe = areas[2]
        guard let green = try capture(stripe).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB),
              green.greenComponent > green.redComponent + 0.2,
              marks.contains(.init(kind: .insertion, lines: 0..<5)), !window.isVisible, !NSApp.isActive else {
            throw Failure("The added closing brace must have a green gutter mark in the isolated fixture.")
        }

        var hold = false
        var waiting = false
        editor.bracketNavigation.beforeInstallIndexForCheck = {
            waiting = true
            defer { waiting = false }
            while hold && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        defer { hold = false; editor.bracketNavigation.beforeInstallIndexForCheck = nil }

        let secondReturn = text.range(of: "return error;")
        let edits = [("ы", text.range(of: ";").upperBound),
                     (" ", secondReturn.location + "return".utf16.count),
                     (".", secondReturn.upperBound - 1),
                     (";", text.range(of: "Hello", options: .backwards).upperBound),
                     ("+", secondReturn.upperBound - 1),
                     (",", secondReturn.upperBound - 1),
                     ("🦊", secondReturn.upperBound - 1),
                     (";", text.range(of: ";").upperBound)]
        for (character, position) in edits {
            editor.setCaretSelections([caret(position)])
            editor.bracketNavigation.refresh()
            for insert in [true, false] {
                hold = true
                if insert {
                    editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    editor.deleteBackward(nil)
                }
                let moved = NSRange(location: closing.location + (insert ? character.utf16.count : 0), length: closing.length)
                func checkFrame(_ phase: String) throws {
                    editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    let actual = editor.bracketNavigation.highlightRanges
                    guard actual == [opening, moved] else {
                        throw Failure("Match \([opening, moved]) \(phase) when editing \(character.debugDescription). Found \(actual) at \(editor.selectedRange()).")
                    }
                    let pixels = try decorationAreas(closing: moved, phase: "\(phase) for \(character.debugDescription)")
                        .map { try capture($0).tiffRepresentation }
                    guard pixels == painted else {
                        throw Failure("Keep both bracket outlines and the closing row's gutter painted \(phase) when editing \(character.debugDescription).")
                    }
                }
                guard editor.jjLineMarks == marks else { throw Failure("The old gutter comparison stays pending.") }
                try checkFrame("on the first frame")
                try await waitFor("a held bracket index") { waiting }
                try checkFrame("while both analyses are pending")
                hold = false
                try await waitFor("the replacement bracket index") { !waiting }
                guard showCurrentMarks() == marks else { throw Failure("Typing within an added line keeps the same changed rows.") }
                try checkFrame("after both analyses finish")
            }
        }

        editor.setCaretSelections([caret(closing.upperBound)])
        editor.bracketNavigation.refresh()
        editor.insertText("+", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard editor.bracketNavigation.highlightRanges.isEmpty else {
            throw Failure("Typing beyond the closing delimiter moves the caret outside the previous pair.")
        }
        editor.deleteBackward(nil)
        try await waitFor("the brace pair after returning to the closing delimiter") {
            editor.bracketNavigation.highlightRanges == [opening, closing]
        }
        editor.deleteBackward(nil)
        guard editor.bracketNavigation.highlightRanges.isEmpty else {
            throw Failure("Deleting the closing delimiter removes the previous highlight immediately.")
        }

        let commentSource = "test \"typing\" { / }\n" as NSString
        editor.string = commentSource as String
        let commentOpener = commentSource.range(of: "{")
        let commentCloser = commentSource.range(of: "}")
        editor.setCaretSelections([caret(commentSource.range(of: "/").upperBound)])
        editor.bracketNavigation.refresh()
        try await waitFor("the brace pair before starting a comment") {
            editor.bracketNavigation.highlightRanges == [commentOpener, commentCloser]
        }

        hold = true
        editor.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        let commentedCloser = NSRange(location: commentCloser.location + 1, length: commentCloser.length)
        try await waitFor("the held index after starting a comment") { waiting }
        guard editor.bracketNavigation.highlightRanges == [commentOpener, commentedCloser] else {
            throw Failure("Keep the existing pair until analysis sees the closing brace inside a comment.")
        }
        hold = false
        try await waitFor("the comment to invalidate that pair") { editor.bracketNavigation.highlightRanges.isEmpty }

        // Focus draws a viewport overlay and needs a live clip rect.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        defer { editor.exitFocus(); window.orderOut(nil) }
        guard window.isVisible, !NSApp.isActive, window.alphaValue == 0, !editor.visibleRect.isInfinite else {
            throw Failure("Use a quiet offscreen viewport for the Focus check.")
        }
        editor.string = source
        editor.setCaretSelections([NSRange(location: 0, length: closing.upperBound)])
        editor.beginFocus()
        editor.setCaretSelections([caret(secondReturn.upperBound - 1)])
        editor.bracketNavigation.refresh()
        try await waitFor("the brace pair before an indexing delay") {
            editor.bracketNavigation.highlightRanges == [opening, closing]
        }
        hold = true
        editor.insertText("+", replacementRange: NSRange(location: NSNotFound, length: 0))
        let focusedClosing = NSRange(location: closing.location + 1, length: closing.length)
        guard editor.focusRanges?.first?.upperBound == focusedClosing.upperBound,
              editor.bracketNavigation.highlightRanges == [opening, focusedClosing] else {
            throw Failure("Keep the outlines when an edit resizes their Focus block.")
        }
        try await waitFor("the held index before the retention deadline") { waiting }
        guard !editor.bracketNavigation.highlightRanges.isEmpty else {
            throw Failure("Keep the outlines at the start of an indexing delay.")
        }
        try await waitFor("the last valid pair to expire while its replacement is still pending") {
            waiting && editor.bracketNavigation.highlightRanges.isEmpty
        }
    }

    private static func caret(_ position: Int) -> NSRange { NSRange(location: position, length: 0) }

    private static func waitFor(_ detail: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure("Timed out checking \(detail).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// The AppKit fixture remains unordered while exercising the focused paint path.
private final class BracketCheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
