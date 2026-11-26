# Language support

This matrix tracks the language modes shipped in Edit. Each row records the quality of Tree-sitter highlighting when editing and whether Edit integrates a language server for that mode. Plain Text is outside the matrix.

- **Supported** means the mode meets the [Tree-sitter editing requirements](features/syntax-highlighting/spec.md#tokenization-during-editing) and has a passing native check with LSP off. Link the check in the row.
- **Partial verification** means existing checks cover some of the editing requirements. The mode has yet to qualify as Supported.
- **Unverified** means a grammar and highlight query ship, and flicker-free editing still needs acceptance coverage.
- **Failing** means a known editing defect prevents the mode from qualifying as Supported.

The LSP column names the server integrated in Edit. A dash means Edit has no server integration for that mode. Whether a particular capability works depends on the server and project. The [LSP checklist](lsp-checklist.md) tracks individual capabilities.

Initial inventory as of November 26, 2026, based on the bundled modes, server routing, and existing checks. Update the affected rows when adding a mode, changing integration, finding a regression, or verifying a fix.

| Language mode | Tree-sitter highlighting | LSP in Edit | Evidence or known gap |
| --- | --- | --- | --- |
| C | Unverified | SourceKit-LSP (clangd) | |
| C++ | Unverified | SourceKit-LSP (clangd) | |
| Clojure | Unverified | — | Includes EDN. |
| CSS | Unverified | — | |
| Erlang | Unverified | — | |
| Go | Unverified | — | |
| HTML | Unverified | — | Includes embedded JavaScript and CSS. |
| JavaScript | Unverified | — | |
| JavaScript JSX | Unverified | — | |
| JSON | Unverified | — | Includes JSONC. |
| Lua | Unverified | — | |
| Markdown | Unverified | — | Includes inline and fenced code. |
| Objective-C | Unverified | SourceKit-LSP (clangd) | |
| Objective-C++ | Unverified | SourceKit-LSP (clangd) | |
| Python | Unverified | — | |
| Ruby | Supported | — | The native typing check covers `Brewfile`, an empty file, and Backspace in a method ending in `?`. |
| Rust | Unverified | — | Existing first-frame check covers opening a file. |
| Shell Script | Supported | — | The native typing check covers Bash commands, comments, and a multiline heredoc. |
| Solidity | Unverified | — | |
| Swift | Supported | SourceKit-LSP | Native checks cover opening, Unicode function names, and edits in a large file. |
| TOML | Unverified | — | |
| TypeScript | Unverified | — | |
| TypeScript JSX | Unverified | — | |
| YAML | Unverified | — | |
| Zig | Partial verification | ZLS | The [native highlight check](../Sources/Edit/Checks/LSPSemanticHighlightCheck.swift) covers typing and Backspace with held results and includes a Tree-sitter-only typing case. Full Tree-sitter-only editing coverage, including ZON, is pending. |

The [native typing check](../Sources/Edit/Checks/SyntaxCheck.swift) runs with `./script/check --only syntax`. For Ruby, Bash, and Swift it holds the background result with LSP off. It covers regular typing, a forced foreground parse timeout, and a timeout of both the foreground parse and the query of the previous tree. It checks every glyph in the edited token before, during, and after the held result, including when a token changes color.

Inventory sources: [bundled modes](../Sources/Edit/SyntaxLanguage.swift), [bundled grammar versions](../resources/syntax/README.md), and [server routing](../Sources/Edit/LanguageServer.swift).
