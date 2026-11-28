# Run Zig tests from CodeLens

In an editable Zig file, show **Run test** to the right of the code on the visual row containing the declaration's `test` keyword. For a multiline header, anchor the button to the keyword even when the name and opening brace are below it. Keep the button outside text layout so it leaves line heights, wrapping, and the gutter geometry intact. The action moves with its row during scrolling and zooming. When a wrapped row fills the available width, use **Run test** in that row's context menu. The button's tooltip and VoiceOver label include the test name.

## Discovery

Use the current buffer's incremental Zig syntax tree to identify top-level named tests, doctests, and unnamed blocks. This works with ZLS stopped and with syntax colors switched off. Match declarations by their syntax nodes to skip test-like text in comments and literals. Preserve the anchors of existing declarations as edits move them, and validate the clicked target against the current tree before running. Clear the previous file's actions as the next document is installed. [Asynchronous updates](../../design.md#asynchronous-updates)

The Zig extension for VS Code 0.6.17 identifies tests by regular expression in a throttled document scan. The syntax tree gives Edit the actual keyword position for a declaration, including Unicode text before it, multiline headers, and valid declarations before a syntax error. [VS Code Zig test discovery][vscode-zig-tests]

## Running a test

Save the current file using the normal save flow. Start Zig only after the save succeeds and the same document and source are still active. Resolve `zig` using the editor's toolchain PATH. Use `zig test` with the current file as the root module and the containing project as the working directory, or the file's directory when opened on its own. Projects that require explicit module arguments or a custom `build.zig` test step need their project test command.

Select the test by its full compiler name in the test runner. Zig's `--test-filter` matches substrings and unnamed blocks are included even when that filter is present. Keep other tests outside the run. [Zig test declarations][zig-tests]

Reveal live output and the exit status in the current window's **Tests** terminal space, while keeping keyboard focus in the editor. Clicking Run test while a test in that window is running reveals the current output. Control-C in the test terminal interrupts the process. Keep the transcript after the run and inherit the [terminal's folder and window lifecycle](../terminal/spec.md).

## Acceptance

Run `./script/check --only zig-test [screenshot-path]` with Zig on PATH. Verify that the multiline test's button follows its first display row after a UTF-16 edit and with word wrap. Click it with pending changes and check the saved file, precise selection, live output, and editor focus. Run the similarly named neighbor to verify failure output and reuse of the terminal. Hold a file switch and check the outgoing action until the new text appears. The optional screenshot shows the inline controls on the original fixture.

[vscode-zig-tests]: https://github.com/ziglang/vscode-zig/blob/master/src/zigTestRunnerProvider.ts#L65-L88
[zig-tests]: https://ziglang.org/documentation/0.17.1/#Zig-Test
