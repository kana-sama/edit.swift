# LSP error highlighting

Underline errors published by the active file's language server with a red wave in the editor. Draw the wave under the reported text, across each visible wrapped line. For a point diagnostic, draw a short wave at the reported position. Preserve syntax colors, selection, and text geometry. The LSP Highlighting switch controls semantic colors independently of these marks.

Tint the last visual row of a source line with errors. Show the messages in reading order in a stronger tint after the code on that row. Use the available horizontal space and truncate the summary when it reaches the viewport edge. Keep the summary outside the buffer and text layout so it cannot change wrapping, editing, or horizontal scroll bounds.

Hover the row with the summary or an underlined row to read the full messages in a selectable card. Anchor its arrow to the summary or the underlined text. On those rows, plain hover shows errors and Command-hover keeps symbol documentation and navigation available. Clear obsolete cards with their diagnostics.

Use [`textDocument/publishDiagnostics`][publish] for named, editable files. Render Error diagnostics and entries without a severity, which the protocol leaves to the client. Warnings, information, and hints are outside this feature's scope. Map UTF-16 positions against the synchronized document and discard invalid ranges. Each report replaces the previous marks, including reports with an empty list.

Apply versioned reports only when their URI and version match the active synchronized document. For servers that omit the version, associate the report with the synchronized revision at receipt. Discard queued updates if the buffer changes before display. Clear marks when text changes, when the replacement document is installed, or when the server stops, restarts, or fails. While another file is opening, keep the outgoing marks with its text and title.

## Acceptance

Run `./script/check --only lsp-diagnostics` with ZLS, SourceKit-LSP, and OLS available. The isolated native check verifies live diagnostics for Zig, Swift, C, and Odin. It checks UTF-16 offsets, underline and message pixels, full text on row hover, recovery after edits and server controls, and the outgoing and incoming presentations of a held file transition. Protocol fixtures cover empty, filtered, stale, unversioned, and unrelated reports.

[publish]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics
