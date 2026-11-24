# Document Highlights

**Document Highlights** (`textDocument/documentHighlight`) mark occurrences of the symbol under the caret in the current file. Edit uses the ranges supplied by a ready language server that advertises document highlights. For example, two independent Zig functions can each declare `value`, and moving the caret between them switches the highlight to that function’s declaration and uses.

- Use the primary caret or a primary selection within one identifier. Render the results with the existing word highlight style. The highlights do not modify the selection or text.
- An empty result clears the word highlights. When no server with this feature is available, use the existing whole-word highlighting. Selected-text highlights and Find keep their existing literal behavior.
- Debounce caret movement and discard results after editing, switching files, moving focus away, or restarting the server. In Focus, show only the ranges inside the visible blocks.

## Acceptance

- In a Zig file, place the caret on a use of a local variable that shares its spelling with another function’s local variable. Verify that the declaration and use in the first function are highlighted. Move to the second function and verify that the highlights follow it.
- Stop ZLS and verify that placing the caret on the variable highlights all matching words again. Restart ZLS and verify that semantic highlighting resumes. Repeat after moving focus away and returning to the editor.

[ZLS 0.17.0 document highlight handler](https://github.com/zigtools/zls/blob/0.17.0/src/features/references.zig#L23-L26)
