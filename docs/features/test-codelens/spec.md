# Run Zig tests from CodeLens

In an editable Zig file, show **Run test** to the right of the code on the visual row containing the declaration's `test` keyword. Use a gray label and center its visible text vertically within the row. For a multiline header, anchor the button to the keyword even when the name and opening brace are below it. Keep the button outside text layout so it leaves line heights, wrapping, and the gutter geometry intact. The action moves with its row during scrolling and zooming. When a wrapped row fills the available width, use **Run test** in that row's context menu. The button's tooltip and VoiceOver label include the test name.

## Discovery

Use the current buffer's incremental Zig syntax tree to identify top-level named tests, doctests, and unnamed blocks. This works with ZLS stopped and with syntax colors switched off. Match declarations by their syntax nodes to skip test-like text in comments and literals. Preserve the anchors of existing declarations as edits move them, and validate the clicked target against the current tree before running. Clear the previous file's actions as the next document is installed. [Asynchronous updates](../../design.md#asynchronous-updates)

The Zig extension for VS Code 0.6.17 identifies tests by regular expression in a throttled document scan. The syntax tree gives Edit the actual keyword position for a declaration, including Unicode text before it, multiline headers, and valid declarations before a syntax error. [VS Code Zig test discovery][vscode-zig-tests]

## Running a test

Save the current file using the normal save flow. Start Zig only after the save succeeds and the same document and source are still active. Resolve `zig` on PATH and use the containing project as the working directory, or the file's directory for a loose file. Use the interactive login shell's exports when Edit was launched from the Dock or Finder.

With Zig 0.17, use the project's `zig build` configuration when its `test` step runs a host test artifact rooted at the current file. Reuse the artifact's modules and generated dependencies, and run the selected test through an isolated build step. The project's build script stays on disk as written. A loose file, or a file outside the project test artifact, uses `zig test` with the file as the root module. Custom test runners and multiple matching host test artifacts require the project's own invocation.

Select the test by its full compiler name in the test runner. Zig's `--test-filter` matches substrings and unnamed blocks are included even when that filter is present. Keep other tests outside the run. [Zig test declarations][zig-tests]

Reuse generated runner and build configuration files at stable paths for the same inputs. Tests in a project share Edit's local and global Zig caches for the selected toolchain. Zig validates the cached binary against the project's current sources. Each click executes the selected test, and the build summary reports whether Zig reused its binary.

Store these files in Edit's own cache. After a run, expire groups unused for 14 days and remove the least recently used groups until the cache fits within 1 GiB and 24 project and toolchain groups. Active runs and groups just released by a terminal are skipped during cleanup.

Print the working directory and the actual Zig executable and arguments before launching. Reveal live output and the exit status in the current window's **Tests** terminal space, while keeping keyboard focus in the editor. Clicking Run test while a test in that window is running reveals the current output. Control-C in the test terminal interrupts the process. Keep the transcript after the run and inherit the [terminal's folder and window lifecycle](../terminal/spec.md).

## Acceptance

Run `./script/check --only zig-test [screenshot-path]` with Zig on PATH. Verify that the multiline test's button follows its first display row after a UTF-16 edit and with word wrap. Click it with pending changes and check the saved file, precise selection, live output, and editor focus. Run the similarly named neighbor to verify failure output and reuse of the terminal. Verify the printed command for loose-file and project runs. In a project test with an injected module, check that two unchanged clicks execute the selected test with the same command and that the second compile step is cached. Change the module and check that Zig rebuilds and runs the updated test. Verify that cleanup skips active groups and trims inactive groups by age, count, and disk usage. Hold a file switch and check the outgoing action until the new text appears. The optional screenshot shows the inline controls on the original fixture.

[vscode-zig-tests]: https://github.com/ziglang/vscode-zig/blob/master/src/zigTestRunnerProvider.ts#L65-L88
[zig-tests]: https://ziglang.org/documentation/0.17.1/#Zig-Test
