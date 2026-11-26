# Odin support

Edit detects `.odin` files regardless of extension case. Users can also select Odin in the language picker or return to Auto Detect.

The bundled Tree-sitter grammar colors keywords, control flow, declarations with bodies, explicit type declarations, fields, enum members, literals, and comments. A procedure declaration with a body or a foreign placeholder uses the function color. An explicit `#type proc` binding uses the type color. Keys in named initializers and attribute names use the property color. OLS classifies call targets, qualified member accesses, value identifiers in initializers and attributes, and bare procedure headers. Odin code fences use the same Tree-sitter captures in Markdown source. Tree-sitter highlighting runs offline. [Odin Language Server](../odin-lsp/spec.md) adds semantic services.

Odin follows the [shared editing requirements](../syntax-highlighting/spec.md#tokenization-during-editing). The native syntax check opens an Odin file with LSP off and checks the first frame and the frames during and after a held parse for typing, Backspace, and turning a procedure declaration into a comment. Fixtures exercise a Unicode identifier, a hexadecimal literal, and a multiline raw string. Separate captures cover nested comments, string offsets across Unicode, and Odin inside a Markdown code fence.

A double quote after `proc` takes the calling convention color from the opening delimiter. Other double quotes take the string color, and single quotes open rune literals with the same color. Escaped delimiters stay inside the literal. An unfinished ordinary string, rune, or calling convention ends at the line break. Triple-quoted and raw strings can span lines. Quotes inside comments and other literals retain the enclosing color.

The native check verifies the opening delimiter, the literal body, and the closing delimiter with the foreground parse budget expired and the background result held.

`./script/check --only lsp-odin` compares the two highlighting layers on an open Odin file. It checks explicit procedure types, declarations and named keys, conversions, calls through fields and variables, attribute values, and a procedure with an unfinished body.
