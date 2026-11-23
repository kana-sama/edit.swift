import AppKit

@MainActor
enum OccurrenceCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = "Occurrence highlights: \(detail)" }
    }

    static func run(in app: Edit) async throws {
        let document = app.makeDocument()
        defer { document.window.close() }
        let editor = document.editor
        let source = "foo foo Foo food foo_bar\nf.o fxo f.o"
        let state = editor.occurrenceHighlighting
        editor.string = source
        editor.didChangeText()
        document.window.layoutIfNeeded()
        editor.setCaretSelections([NSRange(location: 1, length: 0)])
        try await waitFor("the whole words beside a single caret") {
            state.wordRanges == ranges([0, 4]) && state.selectionRanges.isEmpty
        }

        editor.setCaretSelections(ranges([0]))
        try await waitFor("both word and selected-text highlights using Edit's Find defaults") {
            state.wordRanges == ranges([0, 4]) && state.selectionRanges == ranges([4, 12, 17])
        }
        document.findSettings.options.caseSensitive = false
        try await waitFor("selected text using Match Case off") { state.selectionRanges == ranges([4, 8, 12, 17]) }
        document.findSettings.options.wholeWord = true
        try await waitFor("selected text using Whole Word") { state.selectionRanges == ranges([4, 8]) }

        document.performFind(.find)
        document.findSettings.query = "foo"
        try await waitFor("the active literal Find query to take precedence") { state.selectionRanges.isEmpty }
        document.toggleSidebarFocus(.scratches)
        try await waitFor("selection matches when Find is no longer visible") { state.selectionRanges == ranges([4, 8]) }
        document.performFind(.toggleSidebar)
        document.findSettings.options.wholeWord = false
        document.findSettings.options.regularExpression = true
        let literal = (source as NSString).range(of: "f.o")
        let lastLiteral = (source as NSString).range(of: "f.o", options: .backwards)
        editor.setCaretSelections([literal])
        try await waitFor("literal matches while Regex is enabled") {
            state.selectionRanges == [lastLiteral] && state.wordRanges.isEmpty
        }

        editor.setCaretSelections(ranges([0, 4]))
        try await waitFor("same-string multicaret selects exclude both active ranges") {
            state.selectionRanges == ranges([8, 12, 17])
        }
        editor.setCaretSelections([NSRange(location: 0, length: 3), NSRange(location: 13, length: 3)])
        try await waitFor("different selections suppress literal matching") { state.selectionRanges.isEmpty }

        editor.setCaretSelections([NSRange(location: 1, length: 0)])
        try await waitFor("word highlights return after collapsing the selection") { state.wordRanges == ranges([0, 4]) }
        document.window.makeFirstResponder(nil)
        guard state.wordRanges.isEmpty else { throw Failure("Word highlights remained after leaving the editor.") }
        document.focusContent()
        try await waitFor("word highlighting resumes on editor focus") { state.wordRanges == ranges([0, 4]) }
        try checkNativeDrawing(in: document)
        editor.insertText("x", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(90))
        guard state.wordRanges.isEmpty, state.selectionRanges.isEmpty, !document.window.isVisible,
              !NSApplication.shared.isActive else {
            throw Failure("Typing left stale matches or activated the verification window.")
        }
    }

    private static func checkNativeDrawing(in document: DocumentWindow) throws {
        let editor = document.editor
        let clip = document.scrollView.contentView
        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.occurrenceHighlighting.layout()
        guard let marked = clip.bitmapImageRepForCachingDisplay(in: clip.bounds),
              let cleared = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else {
            throw Failure("Could not capture the quiet editor.")
        }
        clip.cacheDisplay(in: clip.bounds, to: marked)
        editor.occurrenceHighlighting.reset()
        clip.cacheDisplay(in: clip.bounds, to: cleared)
        guard marked.tiffRepresentation != cleared.tiffRepresentation else {
            throw Failure("Word highlights did not change the rendered viewport.")
        }
        editor.occurrenceHighlighting.selectionChanged()
    }

    private static func ranges(_ starts: [Int]) -> [NSRange] {
        starts.map { NSRange(location: $0, length: 3) }
    }

    private static func waitFor(_ detail: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure("Timed out checking \(detail).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
