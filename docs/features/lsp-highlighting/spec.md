# LSP highlighting

Edit uses semantic tokens to color named source files served by an active language server with semantic-token support. The [Tree-sitter highlighter](../syntax-highlighting/spec.md) provides the opening colors and the fallback while a server is unavailable, disabled, or slow. Files outside a supported server's scope, read-only previews, and buffers with projected conflict edits use Tree-sitter. Plain Text stays uncolored.

**Toggle LSP Highlight** in [Command Mode](../control-commands/spec.md) and in the View menu is on by default. It changes the setting immediately in all open windows for that folder and remembers it across launches. Standalone windows share a separate setting. Other language-server features stay available.

Prefer whole-document tokens for smooth scrolling. Use deltas when the server advertises them and supplies a result ID, and use a full result when a delta fails. For a range-only server, request the document range. Handle server refresh requests and coalesce edits before requesting updated colors. Decode tokens off the UI thread. Use the current document revision and server generation to discard obsolete results. Keep the current colors visible while replacement colors are pending and start Tree-sitter if semantic colors are still pending after a short deadline.

Map server token types and supported modifiers to the existing Edit theme. A server determines which regions it classifies. Request syntactic tokens from SourceKit-LSP for Swift as well. Tree-sitter remains available to bracket navigation.

## Acceptance

Open a Zig or Swift file in an eligible folder. Verify that live server tokens color identifiers and that a change updates the colors without moving the text, viewport, or title. Switch to a file without a language server and verify Tree-sitter colors. Turn LSP highlighting off in one window and verify that other windows for the same folder use Tree-sitter and that independent workspaces keep their setting. Reopen the workspace and verify the saved choice. Use `./script/check --only lsp-highlight` for the native check.
