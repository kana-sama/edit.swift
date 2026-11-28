import AppKit

@MainActor
enum MarkdownCheck {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(in app: Edit, screenshot: String? = nil) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = """
        # Markdown in Edit

        - [ ] A task

        > [!WARNING]
        > Keep this visible.

        | Command | Value |
        | :--- | ---: |
        | `swift` | one |

        <details>
        <summary>More</summary>

        A footnote[^one] and another reference[^one].

        </details>

        [Other](Other.md#target)
        [Web](https://example.invalid/guide?q=preview#overview)

        ```swift
        func example() -> Int { 1 }
        ```

        Math $x^2$ and :rocket:.

        ```mermaid
        graph TD
            A --> B
        ```

        ![Remote](https://example.invalid/remote.png)

        [^one]: A note.

        """
        let file = folder.appending(path: "Main.md")
        let other = folder.appending(path: "Other.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let otherText = "# Elsewhere\n\n## Target\n\nDestination\n\n" + String(repeating: "A paragraph after the destination.\n\n", count: 40)
        try otherText.write(to: other, atomically: true, encoding: .utf8)
        let document = app.makeDocument()
        defer { document.window.close() }
        guard try await app.openFile(file, in: document) === document else { throw Failure("Could not open Markdown fixture.") }
        let text = document.editor
        let tableCaret = (text.string as NSString).range(of: "`swift`").location + 1
        text.setSelectedRange(NSRange(location: tableCaret, length: 0))
        guard let table = document.currentMarkdownTable else { throw Failure("Missing table command at the body cell.") }
        let formatted = table.edit(.format).text
        let inserted = table.edit(.columnRight).text
        let borderless = table.edit(.toggleBorders).text
        guard formatted.contains("`swift`"), formatted.contains(":---"), inserted.contains("`swift`"),
              borderless.hasPrefix("Command | Value"), borderless.contains("`swift` | one"),
              MarkdownTable(source: borderless, caret: (borderless as NSString).range(of: "`swift`").location) != nil,
              MarkdownTable(source: "```md\n\(formatted)\n```", caret: 18) == nil else {
            throw Failure("Formatting a Markdown table lost content, alignment, or valid table syntax.")
        }
        let originalPosition = text.selectedRange()
        if let command = ControlCommand.markdownTableCommands(for: document).first {
            command.run(in: document)
            guard text.string.contains(formatted) else { throw Failure("Control did not format the table.") }
            text.undoManager?.undo()
            guard text.string == source, text.selectedRange() == originalPosition else { throw Failure("Undo did not restore the table source.") }
        }
        document.toggleMarkdownPreview()
        guard let preview = document.markdownPreviewForCheck else { throw Failure("Could not enter Markdown preview.") }
        try await wait("formatted document, Mermaid, and math") {
            try await preview.evaluateForCheck("!!document.querySelector('.alert.warning') && !!document.querySelector('.diagram svg') && !!document.querySelector('.katex')") as? Bool == true
        }
        try checkGlassEdge(preview, in: document.window)
        guard try await preview.evaluateForCheck("scrollY === 0 && document.querySelector('h1').getBoundingClientRect().top > 0") as? Bool == true else {
            throw Failure("The first Markdown heading starts under the scroll edge.")
        }
        guard try await preview.evaluateForCheck("""
            (() => {
                const heading = document.querySelector('h1');
                window.scrollTo(0, heading.getBoundingClientRect().top + 8);
                const position = heading.getBoundingClientRect();
                return position.top < 0 && position.bottom > 0;
            })()
            """) as? Bool == true else {
            throw Failure("The Markdown heading cannot scroll through the top edge.")
        }
        _ = try await preview.evaluateForCheck("window.scrollTo(0, 0)")
        guard try await preview.evaluateForCheck("document.querySelectorAll('a[data-footnote-ref]').length === 2 && !!document.querySelector('[data-load-image]') && !!document.querySelector('.syntax-function')") as? Bool == true else {
            throw Failure("The preview is missing footnotes, the image control, or code colors.")
        }
        document.performFind(.find)
        guard let find = document.window.firstResponder as? NSTextView, let undo = find.undoManager,
              undo !== text.undoManager else {
            throw Failure("Preview Find has no input focus or Undo history.")
        }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        find.insertText("initial", replacementRange: find.selectedRange())
        find.breakUndoCoalescing()
        undo.endUndoGrouping()
        undo.groupsByEvent = true
        document.performFind(.find)
        guard document.window.firstResponder === find, find.selectedRange() == NSRange(location: 0, length: 7) else {
            throw Failure("Repeating Command-F did not select the whole preview query.")
        }
        guard preview.isFinding, document.handleMarkdownEscape(), document.isShowingMarkdownPreview else {
            throw Failure("Escape did not dismiss preview Find before leaving preview.")
        }
        _ = try await preview.evaluateForCheck("getSelection().selectAllChildren(document.querySelector('h1'))")
        let heading = try await preview.evaluateForCheck("getSelection().toString()") as? String
        document.performFind(.find)
        try await wait("preview Find seeds the rendered selection") {
            heading?.isEmpty == false && find.string == heading &&
                find.selectedRange() == NSRange(location: 0, length: find.string.utf16.count)
        }
        let didUndo = find.tryToPerform(Selector(("undo:")), with: nil)
        guard didUndo, find.string == "initial" else {
            throw Failure("Undo in preview Find should restore the previous query; got \(find.string.debugDescription), handled: \(didUndo), redo: \(undo.canRedo).")
        }
        guard document.handleMarkdownEscape(), document.isShowingMarkdownPreview else {
            throw Failure("Escape did not return to the preview after Undo.")
        }
        _ = try await preview.evaluateForCheck("document.querySelector('[data-task]').click(); document.querySelector('details').open = true;")
        try await wait("source task edit") { text.string.contains("- [x] A task") }
        text.undoManager?.undo()
        try await wait("task undo") { text.string.contains("- [ ] A task") }
        try await wait("rerendered task after Undo") {
            try await preview.evaluateForCheck("document.querySelector('[data-task]')?.checked === false") as? Bool == true
        }
        guard text.selectedRange() == originalPosition else { throw Failure("A preview edit moved the editor selection.") }
        guard try await preview.evaluateForCheck("""
            document.querySelector('a[data-target="Other.md#target"]').title === 'Other.md#target' &&
            document.querySelector('a[data-target^="https://"]').title === 'https://example.invalid/guide?q=preview#overview' &&
            document.querySelector('a[data-footnote-ref]').title === 'Footnote 1'
            """) as? Bool == true else {
            throw Failure("Markdown preview tooltips do not name their destinations.")
        }
        if let screenshot { try await preview.captureForCheck(to: screenshot) }
        var exposedEditor = false
        text.observeEditorUnhideForCheck { exposedEditor = true }
        let originTitle = document.window.title
        let (presentation, release) = AsyncStream<Void>.makeStream()
        var stagedPreview: MarkdownPreviewView?
        document.beforePresentMarkdownForCheck = { incoming in
            stagedPreview = incoming
            for await _ in presentation { break }
        }
        defer { release.finish() }
        _ = try await preview.evaluateForCheck("document.querySelector('a[data-target=\"Other.md#target\"]').click(); true")
        try await wait("prepared destination frame behind current Markdown preview") { stagedPreview != nil }
        guard document.window.title == originTitle, document.markdownPreviewForCheck === preview,
              document.fileURL == FileBuffer.canonicalURL(file), document.scrollView.isHidden,
              let prepared = stagedPreview,
              try await prepared.evaluateForCheck("Math.abs(document.querySelector('#target').getBoundingClientRect().top) < 2") as? Bool == true else {
            throw Failure("The originating title and preview must stay together until the destination frame is ready at its fragment.")
        }
        try checkGlassEdge(preview, in: document.window)
        try checkGlassEdge(prepared, in: document.window)
        if let screenshot {
            let path = URL(fileURLWithPath: screenshot).deletingPathExtension().path
            try await preview.captureForCheck(to: path + "-pending.png")
            try await stagedPreview?.captureForCheck(to: path + "-destination.png")
        }
        document.beforePresentMarkdownForCheck = nil
        release.finish()
        try await wait("clicked local destination in preview") {
            guard document.fileURL == FileBuffer.canonicalURL(other), let destination = document.markdownPreviewForCheck,
                  destination === stagedPreview, destination.hasCurrentDocument else { return false }
            return try await destination.evaluateForCheck("Math.abs(document.querySelector('#target').getBoundingClientRect().top) < 2") as? Bool == true
        }
        text.observeEditorUnhideForCheck(nil)
        guard !exposedEditor, document.window.title == "Other.md", document.scrollView.isHidden else {
            throw Failure("The destination title and preview did not replace the origin without exposing the editor.")
        }
        try checkGlassEdge(prepared, in: document.window)
        guard try await app.openFile(file, in: document) === document, document.isShowingMarkdownPreview,
              let reopened = document.markdownPreviewForCheck else { throw Failure("A reopened file lost its preview mode.") }
        try await wait("stored disclosure") { try await reopened.evaluateForCheck("document.querySelector('details')?.open === true") as? Bool == true }
        document.toggleMarkdownPreview()
        text.scrollRangeToVisible((text.string as NSString).range(of: "[Other]"))
        try await wait("native source link tooltip") { text.markdownToolTipsForCheck.contains("Other.md#target") }
        await document.followMarkdownForCheck("Other.md#target")
        guard !document.isShowingMarkdownPreview, document.fileURL == FileBuffer.canonicalURL(other),
              document.editor.selectedRange().location == 13 else { throw Failure("A source link did not reveal its heading in source mode.") }
        let draft = app.makeDocument()
        defer { draft.window.close() }
        draft.editor.string = "# Draft"
        draft.setSyntaxLanguage(.markdown)
        draft.toggleMarkdownPreview()
        guard draft.sessionDocument().editorPosition?.markdown?.showsPreview == true else {
            throw Failure("The untitled Markdown buffer did not save its preview mode in session state.")
        }
        try await checkHistory(in: app, project: folder.appending(path: "Project"))
    }

    private static func checkHistory(in app: Edit, project: URL) async throws {
        guard let executable = JJRepository.executable else { return }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let result = try await JJCommand.run(executable, arguments: ["git", "init", "--colocate"], in: project,
                                             limit: 16_384, timeout: 12)
        guard result.status == 0, let workspace = await JJRepository.discover(at: project) else {
            throw Failure("Could not create the Markdown history fixture.")
        }
        let main = project.appending(path: "Main.md")
        let other = project.appending(path: "Other.md")
        try "# Recorded\n\n- [ ] Task\n\n[Other](/Other.md)\n".write(to: main, atomically: true, encoding: .utf8)
        try "# Recorded destination\n".write(to: other, atomically: true, encoding: .utf8)
        _ = try await JJRepository.command(["describe", "-m", "Markdown revision"], in: workspace)
        _ = try await JJRepository.command(["new", "-m", "Working copy"], in: workspace)
        try "# Different working destination\n".write(to: other, atomically: true, encoding: .utf8)
        _ = try await JJRepository.command(["util", "snapshot"], in: workspace)
        let graph = try await JJSourceControlRepository.graph(in: workspace, revset: "@ | @-")
        guard let revision = graph.revisions.first(where: { $0.subject == "Markdown revision" }) else {
            throw Failure("The fixture's Markdown revision was not recorded.")
        }
        let file = try await JJSourceControlRepository.linkedFile("Main.md", in: revision, workspace: workspace, at: graph.operationID)
        let document = app.makeDocument()
        defer { document.window.close() }
        document.setFolder(project)
        guard await document.openSourceControlFile(file, in: revision, workspace: workspace, operationID: graph.operationID, while: { true }) else {
            throw Failure("Could not open recorded Markdown.")
        }
        document.toggleMarkdownPreview()
        guard let preview = document.markdownPreviewForCheck else { throw Failure("Recorded Markdown cannot enter preview.") }
        try await wait("disabled task in a recorded revision") {
            try await preview.evaluateForCheck("document.querySelector('[data-task]')?.disabled === true") as? Bool == true
        }
        try checkGlassEdge(preview, in: document.window)
        var exposedEditor = false
        document.editor.observeEditorUnhideForCheck { exposedEditor = true }
        await document.followMarkdownForCheck("/Other.md")
        document.editor.observeEditorUnhideForCheck(nil)
        guard document.editor.string.contains("Recorded destination"), document.isShowingMarkdownPreview,
              !exposedEditor, document.markdownPreviewForCheck?.hasCurrentDocument == true,
              let recorded = document.sessionDocument().markdownRevision else {
            throw Failure("A historical link opened the working copy or exposed the editor between previews.")
        }
        let restored = app.makeDocument()
        defer { restored.window.close() }
        let loaded = try await recorded.load()
        restored.restoreMarkdownRevision(loaded)
        restored.restoreEditorPosition(document.sessionDocument().editorPosition)
        guard restored.isShowingMarkdownPreview, restored.editor.string == document.editor.string else {
            throw Failure("A restored historical window lost its revision or mode.")
        }
    }

    private static func wait(_ description: String, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        throw Failure("Timed out waiting for \(description).")
    }

    private static func checkGlassEdge(_ preview: MarkdownPreviewView, in window: NSWindow) throws {
        window.layoutIfNeeded()
        let webView = preview.responder
        let webTop = webView.convert(webView.bounds, to: nil).maxY
        let overlap = webTop - window.contentLayoutRect.maxY
        let inset = preview.topContentInsetForCheck
        guard overlap > 8, abs(inset - overlap) < 2 else {
            throw Failure("Markdown must fill the glass header and inset its content (overlap \(overlap), inset \(inset)).")
        }
    }
}
