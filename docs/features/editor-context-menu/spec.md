# Editor context menu

Secondary-click or Control-click in the editor to open a native context menu with **Cut**, **Copy**, and **Paste**. These items use the same selection, whole-line clipboard behavior, and availability as the editor’s [Edit commands](../editor/spec.md#editing).

When the pointer is over a Zig symbol and ZLS is ready, add a separator and show the supported symbol commands.

- **Go to Declaration** requests `textDocument/declaration` and navigates to the returned location. Go Back returns to the clicked symbol. [ZLS capabilities](https://github.com/zigtools/zls/tree/0.17.0)
- **Find References** runs the [reference lookup](../lsp/spec.md#references-in-the-sidebar) directly.
- **Rename…** opens the [inline symbol name field](../lsp-rename/spec.md) also available with F2. Return submits the new name and Escape cancels.

Symbol commands use the pointer position. Opening the menu leaves the editor’s selection intact. Ignore a menu’s symbol commands if the document or language-server session changes before they run.

## Acceptance

- Open the menu in a plain-text file, over whitespace in a Zig file, and over a symbol after stopping ZLS. Check that each menu contains the three clipboard commands.
- Open the menu over a Zig symbol while the caret is elsewhere. Check the six command titles and run each symbol command. Confirm that the declaration, references, and rename field refer to the clicked symbol.
