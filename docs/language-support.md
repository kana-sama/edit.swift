# Language support

Track highlighting quality separately for each bundled language mode. **✅** means confirmed, **❌** means missing or known to fail, and **❓** means unverified. In the last column, **❓** also covers modes with no LSP highlighting to compare against.

| Language mode | Tree-sitter highlighting | Tokenizer and flicker-free editing | Unclosed strings | LSP highlighting | Tree-sitter as a base for LSP |
| --- | :---: | :---: | :---: | :---: | :---: |
| Zig | ✅ | ✅ | ✅ | ✅ | ✅ |
| Odin | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ruby | ✅ | ✅ | ✅ | ❌ | ❓ |
| Swift | ✅ | ✅ | ❓ | ✅ | ❌ |
| Shell Script | ✅ | ✅ | ❓ | ❌ | ❓ |
| Solidity | ✅ | ✅ | ❓ | ❌ | ❓ |
| C | ✅ | ❓ | ❓ | ❓ | ❌ |
| C++ | ✅ | ❓ | ❓ | ❓ | ❌ |
| Clojure | ✅ | ❓ | ❓ | ❌ | ❓ |
| CSS | ✅ | ❓ | ❓ | ❌ | ❓ |
| Erlang | ✅ | ❓ | ❓ | ❌ | ❓ |
| Go | ✅ | ❓ | ❓ | ❌ | ❓ |
| HTML | ✅ | ❓ | ❓ | ❌ | ❓ |
| JavaScript | ✅ | ❓ | ❓ | ❌ | ❓ |
| JavaScript JSX | ✅ | ❓ | ❓ | ❌ | ❓ |
| JSON | ✅ | ❓ | ❓ | ❌ | ❓ |
| Lua | ✅ | ❓ | ❓ | ❌ | ❓ |
| Markdown | ✅ | ❓ | ❓ | ❌ | ❓ |
| Objective-C | ✅ | ❓ | ❓ | ❓ | ❌ |
| Objective-C++ | ✅ | ❓ | ❓ | ❓ | ❌ |
| Python | ✅ | ❓ | ❓ | ❌ | ❓ |
| Rust | ✅ | ❓ | ❓ | ❌ | ❓ |
| TOML | ✅ | ❓ | ❓ | ❌ | ❓ |
| TypeScript | ✅ | ❓ | ❓ | ❌ | ❓ |
| TypeScript JSX | ✅ | ❓ | ❓ | ❌ | ❓ |
| YAML | ✅ | ❓ | ❓ | ❌ | ❓ |

## What to verify

1. **Tree-sitter highlighting** requires a bundled grammar, an active highlight query, and a passing capture check. The [native syntax checks](../Sources/Edit/Checks/SyntaxCheck.swift) cover all listed modes.
2. **Tokenizer and flicker-free editing** requires language-aware token boundaries and responsive typing without intermediate color flashes. Verify the rendered frames with LSP off and the fresh parse held, per the [editing requirements](features/syntax-highlighting/spec.md#tokenization-during-editing). Odin, Ruby, Bash, Solidity, Swift, and Zig pass those checks. The [Odin fixtures](features/odin/spec.md) cover a Unicode procedure name, a hexadecimal number, a multiline raw string, and commenting out a declaration. Solidity cases cover typing and Backspace in line, NatSpec, block, and inline Yul comments, plus turning a function declaration into a comment. The Zig cases cover numbers, comments, quoted and multiline strings, editing a large file, and typing in ZON.
3. **Unclosed strings** requires string color from the opening delimiter while typing, through the boundary defined by the language, and a clean transition after closing the string. The native check covers Odin and Zig up to the line break and Ruby through EOF. Capture fixtures also cover Odin triple-quoted strings and ZON.
4. **LSP highlighting** requires Edit to render semantic tokens from the server. [Native LSP highlighting checks](../Sources/Edit/Checks/LSPSemanticHighlightCheck.swift) confirm this for Swift with SourceKit-LSP and Zig with ZLS. The [native OLS check](../Sources/Edit/Checks/OdinLSPCheck.swift) verifies Odin semantic colors with the Tree-sitter layer disabled. C, C++, Objective-C, and Objective-C++ route to SourceKit-LSP with clangd. Their current native test verifies [LSP integration](../Sources/Edit/Checks/SourceKitLSPCheck.swift), and semantic color rendering for those modes is still unverified. The [LSP feature checklist](lsp-checklist.md) tracks individual methods.
5. **Tree-sitter as a base for LSP** requires Tree-sitter to color roles the grammar can establish, leave ambiguous names to the server, and agree in color where both layers classify the same syntax. The native Zig test checks that division of responsibility. Known gaps include name-based type guesses in [Swift](../resources/syntax/queries/swift.scm#L155) and uppercase-constant guesses in the [shared C-family query](../resources/syntax/queries/c.scm#L3). See the [rules for both layers](features/syntax-highlighting/spec.md#tree-sitter-and-semantic-tokens).

The [native Odin comparison](../Sources/Edit/Checks/OdinLSPCheck.swift) checks all shared colors on a fixture with live OLS. It also checks that Tree-sitter leaves call targets, qualified member accesses, initializer and attribute values, and procedure headers without a parsed body to OLS.

Solidity uses Tree-sitter for syntax colors and [Solar](features/solidity-lsp/spec.md) for language services. The Forge 1.10.0 Solar server does not supply semantic colors.

Update the affected cells when adding a mode, changing highlighting, confirming a defect, or verifying a fix. Keep modes sorted by descending ✅ count, with alphabetical order for ties. Keep evidence beneath the table and leave ❓ until the relevant behavior is verified. The [bundled modes](../Sources/Edit/SyntaxLanguage.swift), [grammar inventory](../resources/syntax/README.md), and [server routing](../Sources/Edit/LanguageServer.swift) define the scope of the checklist.
