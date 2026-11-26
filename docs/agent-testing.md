# Agent Testing and Builds

Read this before building or launching for agent checks or changing the build and test scripts.

## Commands

- `./script/build` builds the development app incrementally. Use `./script/build release` for an optimized build.
- `./script/run` launches the interactive app for owner use and review.
- `./script/check [screenshot-path]` runs the general native suite without activating the app. Pass a path to capture the window. Live language-server scenarios have separate `--only` commands below.
- `./script/install [directory]` installs the release app bundle and leaves bundles with unrelated identifiers untouched.

SwiftPM builds and links the Edit executable and the pinned SwiftTerm dependency. The build script packages the resulting product and resources in the signed application bundle. The pinned Tree-sitter runtime and grammars build into a native library cached per SDK, compiler and target. The same C header defines the entry point used by the library and the editor. The build reuses SwiftPM checkouts and products and the syntax library in `.local/swift-sdk`, and reuses the signed bundle when its inputs match. Use the default debug build during development and an optimized build when measuring runtime or launch performance.

`./script/check` enables `EDIT_AGENT_CHECKS` and includes the native check sources from `Sources/Edit/Checks` in the separate `Edit Agent.app`. The normal Edit executable excludes that directory and the check runner.

Building or installing a replacement keeps the previous bundle on disk so macOS can validate any processes still using it. Subsequent builds or installs remove retained bundles whose executables are no longer running.

Use separate fresh directories via `EDIT_BUILD_DIR` and `EDIT_SDK_CACHE_DIR` to measure a fully cold build. Setting just `EDIT_BUILD_DIR` to a fresh directory measures rebuilding the project with the existing SDK cache. Report incremental build times separately. For cold launch, measure first launch to the first usable window and record the machine, OS, and cache conditions.

## Focused checks

- `./script/check --only editor [screenshot-path]` checks editing, multiple carets, viewport resizing, zoom, word wrap, and active-line painting. The optional PNG captures the initial editor fixture. The `-word-wrap.png` and `-word-wrap-sidebar.png` captures show the wrapped buffer at two widths.
- `./script/check --only syntax` checks bundled grammars, first-frame drawing, and Tree-sitter-only editing while a background result is held.
- `./script/check --only inline-diff [screenshot-path]` checks the inline diff, Escape priority, sidebar geometry, and overscroll. The optional PNG captures the viewport at the final right overscroll position, or the viewport where the geometry check failed.
- `./script/check --only files [screenshot-path]` checks file and folder opening, Close Workspace, saves, autosave, session restoration, and previews. The optional `-pending.png` and `-standalone.png` captures show both sides of the Close Workspace transition.
- `./script/check --only markdown [screenshot-path]` exercises Markdown table edits, rendering, task undo, link tooltips, navigation, and preview state. With a screenshot path, it captures the original preview, the original preview while the transition is held, and the prepared destination at its anchor.
- `./script/check --only results [screenshot-path]` checks Search and References, including result geometry, dismissals, focus, and both Tree Mode settings. The optional `-list.png` and `-tree.png` captures show References in both layouts.
- `./script/check --only workspace-search [screenshot-path]` checks Search field geometry across focus changes, the native scope control, a held scope switch and a cached return to Workspace, glob and ignore rules, folder context action, tree layout, a held cross-file transition, and partial replacement with Undo. The optional captures show the four fields, the pending and ready scope states, Workspace Search at minimum width, its tree, and both frames of the file transition.
- `./script/check --only control [screenshot-path]` checks file and workspace-symbol ranking, project isolation in Go to File and Open Recent, and history migration. The optional PNG captures the ranked README results.
- `./script/check --only jj [screenshot-path]` checks recorded and live Jujutsu indicators, inline diff, and command completion. The optional PNG captures the editor and Worktree with recorded changes.
- `./script/check --only source-control [screenshot-path]` checks the Jujutsu shortcut, graph, changed-file outline, revision preview, and repository Undo and Redo. The optional PNG captures the Jujutsu sidebar beside a changed file.
- `./script/check --only lsp [screenshot-path]` uses compatible `zig` and `zls` executables from `PATH` to check server controls, definition navigation, hover, and single and grouped references. The optional PNG captures the References sidebar. The `-hover.png` capture shows a live linked type, and `-hover-sections.png` and `-hover-sections-light.png` show the same four-row hover in the current and light appearances. The `-hover-short.png` and `-hover-code.png` captures show the generic hover layout. The `-servers.png` and `-servers-stopped.png` captures show the server controls.
- `./script/check --only lsp-progress [screenshot-path]` checks ZLS initialization and build configuration progress. With a screenshot path, it captures the server popover during both phases and the spinner in the header.
- `./script/check --only lsp-state [screenshot-path]` checks workspace-scoped Stop, Start, and Restart across two app launches using one disposable profile. The optional PNG shows local coloring in a C header with SourceKit-LSP stopped.
- `./script/check --only lsp-highlight [screenshot-path]` checks both highlighting layers, their priority, workspace preferences, Command Mode switches, and ZLS viewport and whole-file results. The optional captures show the switches and the editor with a held semantic update.
- `./script/check --only lsp-diagnostics [screenshot-path]` checks live error publications for Zig, Swift, C, and Odin, including the underline, selection, overscroll, buffer transitions, edits, and server controls. The optional PNG shows a Zig error with semantic colors disabled. The `-hover.png` capture shows the diagnostic list.
- `./script/check --only lsp-swift [screenshot-path]` uses the installed SourceKit-LSP toolchain to check Swift navigation, hover, highlights, symbol search, rename, indexing progress, and independent controls in a mixed Swift and Zig folder.
- `./script/check --only lsp-odin [screenshot-path]` checks project discovery, navigation, symbol queries, rename, semantic paint, Tree-sitter and OLS color agreement, and server lifecycle with OLS from PATH. The optional PNG captures the native `core:fmt` hover. The `-runtime.png` and `-runtime-table.png` captures show the opening and scrolled views of the `base:runtime` hover.
- `./script/check --only lsp-c-family [screenshot-path]` uses SourceKit-LSP and a compilation database to check definitions, hover, and symbols in C, C++, Objective-C, and Objective-C++. It also checks inline C rename and changing an open file’s language mode within the same server session. The optional PNG shows the first Objective-C++ frame, and `-pending.png` shows the Objective-C file while the transition is held.
- `./script/check --only worktree` checks the outline and its file operations, including Undo and Redo.

Select a command using [verification and completion](workflow.md#verification-and-completion). Each command builds or reuses the hidden agent app and runs with a disposable profile. Reuse the build directory across runs. On a timing-sensitive regression, capture the failing state during the relevant check.

## Quiet agent checks

Prefer process or model checks when a window is unnecessary. Test the real implementation through its ordinary entry points where practical. When startup, layout, or drawing requires AppKit, use a dedicated test instance and disposable data with an identity separate from the owner's app.

- Prevent activation before launch and window creation. Keep the test instance in the background throughout the check.
- Create editor test windows fully transparent and non-interactive. Keep them unordered for bitmap captures and close each fixture when its check ends. Checks that require a live window backing layer can order a transparent window offscreen for that check.
- Exercise source-control popover contents in an unordered test window. AppKit positions the native popover separately from its anchor, so a transparent offscreen anchor does not isolate it.
- Suppress Dock attention, interactive alerts, restoration, and other owner-facing effects for that test instance. Collect diagnostics through the runner.
- Use synthetic files and a disposable profile. Identify the exact test instance before controlling it or closing it.
- Verify quiet behavior without changing global macOS settings or interacting with the owner's running editor.

Use temporary captures of the running test UI under the same isolation rules when they help investigate a visual issue. If an operation would interrupt the owner, stop that operation and report the specific blocker.
