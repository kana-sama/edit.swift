# Line and Symbol Navigation

Use the [Control palette](../control/spec.md) to jump by line number or by symbol name. Open Control with Command-P and type a leading `:` for the current document or `#` for the workspace. Replace the prefix with its marker in the leading icon slot. Show **Go to Line or Symbol…** and **Go to Workspace Symbol…** in the Go menu and Command Mode. Press Backspace at the beginning of the field to return to file search.

## Go to Line or Symbol

Treat a decimal query as a one-based line number. Show the matching line as a single result. Return or a row click places the caret at its beginning. Show feedback for a number outside the document. Line navigation works in any text document, including untitled documents and documents without a language server.

For an empty or non-numeric query, request **Document Symbols** (`textDocument/documentSymbol`) when the active file has a compatible server. Show its symbols in source order for an empty query. Search by name and container with Control's case-insensitive matching. Show the symbol kind and its available container information.

## Go to Workspace Symbol

Request **Workspace Symbols** (`workspace/symbol`) from the language server for the active project when the query contains a symbol name. Show each result's kind and file path. Display paths relative to the open folder when possible. If the active project has a language server, this mode also works while a non-Zig file is open in that project.

With ZLS 0.17.0, refresh the workspace before the next search after leaving a Zig document. This keeps the file searchable when the server drops it from the index on close. Multiple closed documents share a single refresh. [ZLS document store](https://github.com/zigtools/zls/blob/0.17.0/src/DocumentStore.zig#L748-L770)

## Results and navigation

Use Control's native result rows, wrapping keyboard selection, Return and click activation, and Escape dismissal. Keep focus in the query while selecting a result. Opening a symbol in another file uses the current window and the usual save flow. Activation focuses the editor and records the source and destination in [Go Back and Go Forward](../navigation-history/spec.md).

Ignore out-of-date answers after editing the query, dismissing the palette, or changing the working context. Keep previous results inert while fetching newer results. Show the mode's empty or server-unavailable state when appropriate.

## Acceptance

- Open Control in a text file and enter `:2`. Press Return and verify the second line's beginning and editor focus. Try `:0` and a line beyond the end. Repeat in a document without LSP.
- In a Zig file, enter `:` to view its symbols. Find a symbol by part of its name and with different letter case. Activate it and verify the caret jumps to the symbol in the same document.
- In a Zig project, enter a symbol in `#` mode and verify its file path is visible. Choose a symbol in another file. Check the active file, editor focus, and caret. Go Back returns to the original file and caret. Repeat from a plain-text file in the same project.
- Type two queries in rapid succession and activate the latest result. Repeat while switching modes and while stopping the server. Use Escape to dismiss, and Backspace at the start of a prefixed query to switch back to file search.
