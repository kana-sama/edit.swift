# LSP highlighting

Edit renders semantic tokens over the [Tree-sitter colors](../syntax-highlighting/spec.md) in named source files served by an active language server. When both layers are enabled, the semantic token wins at each overlap and the underlying colors fill gaps in the server's coverage. Tree-sitter supplies the opening and editing colors independently of the server. Files outside a supported server's scope, read-only previews, and buffers with projected conflict edits can use the Tree-sitter layer. Plain Text stays uncolored.

**Toggle Tree-sitter Highlight** and **Toggle LSP Highlight** in [Command Mode](../control-commands/spec.md) and the View menu control the layers independently. Both default to on. Each setting applies immediately to open windows for that folder and is saved across launches. Standalone windows share a separate pair of settings. Other language-server features and Tree-sitter bracket analysis stay available.

Request whole-document tokens as soon as a server is ready for the open file. When ZLS supports both modes, a file is at least 64 KiB, and the viewport covers a small part of it, also request the visible lines. Apply the range result when it arrives first and replace it with the whole-file result for scrolling. SourceKit-LSP performs file-wide semantic analysis for a range request, so request the whole file once. Use deltas when the server supplies a result ID and supports them. For a range-only server, request the document range.

Coalesce edits before asking for fresh tokens. Keep remapped overlay colors over the local layer while the replacement is pending, up to a fixed deadline. Clear the overlay when switching files or losing the semantic provider. Decode tokens off the UI thread and discard results from an old revision or connection.

Map server token types and supported modifiers to the existing Edit theme. A server determines which regions it classifies. Request syntactic tokens from SourceKit-LSP for Swift as well. Tree-sitter remains available to bracket navigation.

## Acceptance

Open a Zig or Swift file in an eligible folder. Verify that the semantic color wins at an overlap while Tree-sitter colors remain available elsewhere. Independently toggle each layer in Command Mode and verify all four combinations, propagation to windows for the same folder, and saved settings. Hold the full result for a large Zig file and verify that visible semantic tokens arrive before offscreen tokens. During a held update or file switch, verify the visible text, title, and colors in the pending and ready frames. Use `./script/check --only lsp-highlight` for the native check.
