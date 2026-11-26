# Syntax resources

Edit compiles the pinned generated C parser sources in this directory with Apple Command Line Tools. The resulting Tree-sitter library and its highlight queries are shipped inside the application and work offline. The embedded library is opened on the first syntax request.

The source archive contains Tree-sitter 0.25.10 and the generated parser and scanner sources for the following releases. Runtime and grammar license notices are in `licenses/`.

| Grammar | Version or commit |
| --- | --- |
| Tree-sitter runtime | 0.25.10 |
| C | 0.23.4 |
| C++ | `5cb9b693cfd7bfacab1d9ff4acac1a4150700609` |
| Clojure | 0.1.0 |
| CSS | 0.23.2 |
| Erlang | 0.19.0 |
| Go | 0.23.4 |
| HTML | 0.23.2 |
| JSON | 0.24.8 |
| Lua | 0.5.0 |
| Markdown and inline Markdown | `9a23c1a96c0513d8fc6520972beedd419a973539` |
| Objective-C and Objective-C++ | [tree-sitter-objcpp `f744aa49e05971a2177f9b993f81a494744df7f5`](https://tangled.org/dunkirk.sh/dots/commit/f744aa49e05971a2177f9b993f81a494744df7f5) |
| Odin | [tree-sitter-odin `d2ca8efb4487e156a60d5bd6db2598b872629403`](https://github.com/tree-sitter-grammars/tree-sitter-odin/commit/d2ca8efb4487e156a60d5bd6db2598b872629403) |
| Python | 0.25.0 |
| Ruby | 0.23.1 |
| Rust | 0.24.0 |
| Shell Script | Bash 0.25.0 |
| Solidity | 1.2.13 |
| Swift | 0.7.4 |
| TOML | tree-sitter-toml-ng 0.7.0 |
| TypeScript and TSX | `e2c53597d6a5d9cf7bbe8dccde576fe1e46c5899` |
| YAML | `baff0b51c64ef6a1fb1f8390f3ad6015b83ec13a` |
| Zig | `6479aa13f32f701c383083d8b28360ebd682fb7d` with Edit's ZON extension |

JavaScript and JSX use the TSX grammar. Queries start from the grammar distributions for supported capture names. Edit supplies its own JavaScript queries and retains the original Edit queries for Clojure, Erlang, Solidity, TOML, and Zig. TSX and TypeScript share the JavaScript rules and add TypeScript-specific rules. Objective-C and Objective-C++ share a grammar and use the C and C++ captures with additional Objective-C rules.

The build applies [local grammar patches](patches/) after extracting the archive. The Ruby scanner retains an unterminated ordinary or percent string's body at EOF so the parser can report a missing delimiter and keep the literal as a syntax node.

Tree-sitter is distributed under the [MIT License](https://github.com/tree-sitter/tree-sitter/blob/v0.25.10/LICENSE). Each parser retains its respective license.
