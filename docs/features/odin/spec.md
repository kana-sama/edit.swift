# Odin support

Edit detects `.odin` files regardless of extension case. Users can also select Odin in the language picker or return to Auto Detect.

The bundled Tree-sitter grammar colors keywords, control flow, procedure declarations and calls, types, fields, literals, and comments. It does not infer identifier roles from capitalization. Odin code fences use the same captures in Markdown source. No Odin compiler, language server, or network connection is needed.

Odin follows the [shared editing requirements](../syntax-highlighting/spec.md#tokenization-during-editing). The native syntax check opens an Odin file with LSP off and checks the first frame and the frames during and after a held parse for typing, Backspace, and turning a procedure declaration into a comment. Fixtures exercise a Unicode identifier, a hexadecimal literal, and a multiline raw string. Separate captures cover nested comments, string offsets across Unicode, and Odin inside a Markdown code fence.

This feature does not provide LSP, formatting, build integration, or special recovery for unfinished strings.
