# Zig language server

Edit connects to ZLS to show symbol documentation and navigate Zig code. This slice covers **Go to Definition** (`textDocument/definition`), **Find All References** (`textDocument/references`), and **Hover** (`textDocument/hover`). [LSP checklist](../../lsp-checklist.md)

## Server discovery and session

- `zls` is the built-in server for named, editable Zig documents. Use Edit’s [language detection](../syntax-highlighting/spec.md), which recognizes `.zig` and `.zon`. Open an eligible document to start its server in the background.
- Find the first executable named `zls` in `PATH` order. For a Finder or Dock launch, resolve `PATH` from the user’s login shell on demand, with the inherited `PATH` as the fallback if the lookup fails. Pass the selected `PATH` to ZLS so it can find Zig. Search only the directories in that `PATH`. Show **Not on PATH** if the search finds no executable. [Zig and ZLS compatibility](https://zigtools.org/zls/install/#zig--zls-version-compatibility) · [VS Code shell environment](https://code.visualstudio.com/docs/supporting/faq#_resolving-shell-environment-fails)
- Use the nearest ancestor containing `build.zig` or `build.zig.zon` as the project root. If neither exists, use the window’s open folder when it contains the file, or the file’s parent directory otherwise. Initialize ZLS with that root in `workspaceFolders`.
- A session belongs to the current window and project root. Reuse it when navigating between Zig files in that root. Close the previous session when changing roots or closing its window. An explicit stop suppresses automatic starts for that window and root until **Start LSP** or **Restart LSP**, including when returning to the project during the same app session.
- Send the actual buffer text on open and keep it synchronized before requesting symbol information. Use ZLS’s advertised synchronization mode and negotiated position encoding, including UTF-16 by default. On a file switch or Save As, close the old document URI and open the new eligible URI. On restart, send the current buffer, including unsaved edits. [ZLS initialization and capabilities](https://github.com/zigtools/zls/blob/0.17.0/src/Server.zig#L320-L523)

## Header and controls

Show a status button in the document header when a language server matches the active document. Its label identifies the server and state, for example **ZLS · Ready**. Anchor a native popover to the button. List every matching server profile with its name, status, and individual controls, including a profile whose executable is missing. For this slice, the list contains one row for ZLS. [AppKit popover](https://developer.apple.com/documentation/appkit/nspopover)

Use **Starting**, **Ready**, **Stopping**, **Stopped**, **Not on PATH**, and **Failed** consistently in the header and popover. Show a concise reason for failure in the popover. Update both surfaces in place when the state changes.

- **Start LSP** starts a stopped server or retries a missing or failed server. Resolve the executable again for each attempt.
- **Stop LSP** cancels startup or ends a running session. Clear its pending editor interactions and show **Stopped** once shutdown finishes.
- **Restart LSP** ends the old session, resolves the executable again, and starts a fresh session. A restart from **Stopped** or **Failed** starts a fresh session directly.

Expose the same commands in [Control](../control-commands/spec.md) for the active editor window. While stopping, keep the status visible until the operation finishes. A failed launch or unexpected exit leaves the editor usable and the start and restart actions available. Escape dismisses the popover and returns focus to the triggering control.

## Cmd-hover and Cmd-click

Follow VS Code’s definition link gesture on macOS. When the pointer rests on a symbol with Command held, including when Command is pressed under a stationary pointer, probe with `textDocument/definition`. Once the current probe resolves to an actionable target, underline the source span, use the semantic link color, and show the pointing hand. Use `originSelectionRange` if the server returns it, or the word under the pointer otherwise. Release Command, leave the symbol, or change the document to clear the link. Plain clicks and drags use the normal editor selection behavior. [VS Code link gesture](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/gotoSymbol/browser/link/clickLinkGesture.ts) · [Definition link and probe](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/gotoSymbol/browser/link/goToDefinitionAtPosition.ts)

Cmd-click on the link sends a fresh `textDocument/definition` request at the clicked position. Accept both `Location` and `LocationLink`, using `targetSelectionRange` for a link’s destination. Treat the sole definition as the current location when it is in the same file and its selection range contains the clicked position. This also applies when the click is inside the name rather than at its first character. [VS Code navigation and fallback](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/gotoSymbol/browser/goToCommands.ts#L111-L201)

- A single definition elsewhere opens directly. Use the normal file-opening and save flow for a destination in another file. Place the caret at the start of the returned selection range and reveal the line if it is outside the viewport.
- A sole definition at the clicked location invokes **Find All References** if the server advertises it.
- Several distinct definitions offer a source-anchored **Peek Definition** choice, following VS Code. Open the selected destination using the same file-opening and caret rules.
- An empty response keeps the editor at the source and clears the link. A failed explicit navigation can show feedback without moving the caret.

Ignore pending lookups when their server session, source document, buffer version, or relevant pointer position changes. A delayed reply must not decorate a different symbol or open a file after the user has moved on to another document.

## References in the sidebar

Use VS Code’s compact reference lookup. Send `textDocument/references` with `includeDeclaration: true`. If the server returns exactly two locations, retry with `includeDeclaration: false` and use the retry if exactly one location remains. A single result opens directly at the start of its range. Zero results leave the editor at the source and briefly show **No references found**. Multiple results open **References** in the sidebar. [VS Code 1.147.0 compact lookup](https://github.com/microsoft/vscode/blob/1.147.0/src/vs/editor/contrib/gotoSymbol/browser/goToSymbol.ts#L67-L77)

- Generalize the existing [Search results](../find-replace/spec.md) file header and line rows into one grouped result component. Search supplies a single file group and its match ranges and actions. References supplies groups for all returned files and the exact reference ranges to highlight.
- Show the queried symbol and reference count in the panel. Group by file, with the file icon, basename, and containing path. Sort files by path and references by line and column. Use Search’s single-line excerpts and match styling, highlighting the span returned by the server even when another occurrence of the same text appears on that line.
- Reveal the nearest reference in the source file when the panel opens, if one exists. Start with its group expanded and leave the other groups collapsible. Arrow keys navigate the tree. Click a reference or press Return to open it at the start of its range and focus the editor. Keep the list available while opening results in the same window. [VS Code References tree](https://github.com/microsoft/vscode/blob/main/extensions/references-view/src/references/model.ts#L49-L155) · [Reference excerpts and opening](https://github.com/microsoft/vscode/blob/main/extensions/references-view/src/references/model.ts#L252-L296)
- Make References available from the [sidebar switcher](../sidebar-menu/spec.md) while the window has a result set. Command-F returns to Search with its own query and result state. A new reference lookup replaces the previous set together with its symbol and count.

## Hover

After the pointer rests on a symbol for 300 ms, request `textDocument/hover`. Show a nearby popover for a nonempty response, preferring space above the symbol and using space below when needed. Anchor it to the server’s hover range when supplied. Keep Command-link decoration independent of the documentation popover. [VS Code hover defaults](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/config/editorOptions.ts#L2304-L2313)

Render Markdown as selectable rich text with paragraphs, lists, links, inline code, and fenced code blocks. Use the editor’s code styling for recognized code fences, the system appearance for prose, and scrolling for content that exceeds the available space. Show plain-text responses as text. Keep the popover open while the pointer moves into it to read, select, copy, or follow a link. Dismiss it on Escape, typing, document changes, or after the pointer leaves both the symbol and the popover. [VS Code hover interaction](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/hover/browser/contentHoverController.ts) · [VS Code Markdown hover](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/hover/browser/markdownHoverParticipant.ts)

## Acceptance

- Open a Zig fixture with compatible Zig and ZLS on `PATH`. Verify the header and popover agree during open, start, stop, restart, and process failure. Switch files within the project after **Stop LSP** and check that it stays stopped. Switch to a separate fixture project and back to confirm the root and stop scope. Repeat with two candidate executables on `PATH` and with neither available.
- Hold Command over an imported symbol and then release it without moving the pointer. Verify the link color, underline, and pointing hand appear for the actionable span and clear on release. Check a non-symbol, a pending result that arrives after moving away, and clicks at the beginning and middle of the same symbol.
- Cmd-click a definition in the same file, one in a separate file, and a declaration with exactly one use. Verify the first two open the definition and the last opens the use directly. Add another use in a third file and verify References opens in the sidebar with grouped, highlighted excerpts and the correct count. Open results with the mouse and the keyboard.
- Run Find and Replace before and after opening References. Verify Search retains its query and row actions, both panels still highlight their own exact spans, and resizing the sidebar keeps excerpts on one line.
- Hover over a symbol with a signature, formatted documentation, and a fenced code block. Check light and dark appearances, click and copy inside the popover, then dismiss it with Escape. Repeat after editing the buffer or switching documents before the reply arrives and verify the stale popover stays closed.
- Place a multibyte character before a target and use a project path containing spaces. Rename or move a symbol in an unsaved buffer, restart ZLS, and verify that navigation and hover use the current text and correct ranges. Run the scenario against the locally available compatible Zig and ZLS versions in an [isolated agent instance](../../agent-testing.md).
