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
