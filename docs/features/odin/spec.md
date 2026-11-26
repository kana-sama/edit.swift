# Odin support

Edit detects `.odin` files regardless of extension case. Users can also select Odin in the language picker or return to Auto Detect.

The bundled Tree-sitter grammar colors keywords, control flow, procedure declarations and calls, types, fields, literals, and comments. It does not infer identifier roles from capitalization. Odin code fences use the same captures in Markdown source. No Odin compiler, language server, or network connection is needed.

Odin follows the [shared editing requirements](../syntax-highlighting/spec.md#tokenization-during-editing). The native syntax check opens an Odin file with LSP off and checks the first frame and the frames during and after a held parse for typing, Backspace, and turning a procedure declaration into a comment. Fixtures exercise a Unicode identifier, a hexadecimal literal, and a multiline raw string. Separate captures cover nested comments, string offsets across Unicode, and Odin inside a Markdown code fence.

A double quote after `proc` takes the calling convention color from the opening delimiter. Other double quotes take the string color, and single quotes open rune literals with the same color. Escaped delimiters stay inside the literal. An unfinished ordinary string, rune, or calling convention ends at the line break. Triple-quoted and raw strings can span lines. Quotes inside comments and other literals retain the enclosing color.

The native check verifies the opening delimiter, the literal body, and the closing delimiter with the foreground parse budget expired and the background result held.
