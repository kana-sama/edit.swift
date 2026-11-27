# Solidity language server

Edit uses Solar from Foundry for named, editable Solidity files. Find `forge` on the same PATH as the other language servers and launch `forge lsp --stdio` from the project root. Discover projects from `foundry.toml`, `remappings.txt`, and loose `.sol` files. Search parent directories when opening a file on its own. Use the opened Foundry project as the root when navigating into its vendored libraries. Solar reads the project configuration, remappings, and active Foundry profile. An older Forge with no `lsp` subcommand reports a process failure in the existing Language Servers popover. [Foundry editor integration](https://github.com/foundry-rs/foundry/blob/v1.10.0/editors/README.md)

Use the existing per-window sessions, workspace-scoped Start, Stop and Restart, definition links, references, occurrence highlighting, document and workspace symbols, and Rename Symbol. Display Markdown hover with syntax-colored Solidity fences. Send the unsaved buffer with UTF-16 positions and notify Solar of saved files and relevant file changes. Show published errors in the source editor and Worktree. Solar in Forge 1.10.0 does not advertise semantic tokens. Syntax colors use the bundled Solidity Tree-sitter grammar.

Solar provides the shared [completion, signature help, and formatting commands](../lsp-editing/spec.md). Formatting uses the Foundry project's format configuration.

## NatSpec hover

Use the shared code block and divider from the [Zig hover section layout](../lsp/spec.md#hover). Put the syntax-colored signature in a rounded code block, then show `@notice` as the description. When both tags are present, show `@dev` below the description with an accent rule beside the text. When the author supplies only `@dev`, show it directly as the description. Below the divider, put **Parameters** and **Returns** headings above their respective lists at the left edge. Leave a larger gap between these sections. Use right-aligned, secondary labels for names and a common left-aligned description column for named parameters and returns, including wrapped text. On narrow layouts, place the label above its description if the columns cannot fit. Let unnamed returns start at the left edge. Show headings for documented groups. Preserve Markdown links, emphasis, and code examples. [Solidity NatSpec format](https://docs.soliditylang.org/en/stable/natspec-format.html)

Read local NatSpec from the declaration to keep wrapped comment lines with their tags. In the active file, read the unsaved buffer. Use the server documentation for inherited comments and when the declaration cannot be read. Remove block-comment margins left in Solar Markdown and restore blank lines between paragraphs.

## Acceptance

Run `./script/check --only lsp-solidity` with a compatible Forge on PATH. Check the discovered root, remapped library navigation and held source/destination frames, hover and symbols, cross-file rename, errors during unsaved edits, keyboard completion, active parameter highlighting, format and Undo, and Stop and Restart. Use `EDIT_SOLIDITY_CHECK_PROJECT` to exercise the same integration on a disposable copy of BarterLend.

Hover a documented call and check the description and developer note above the divider, with the parameter and return rows below it. With the BarterLend fixture, check the single return row for `getStalePriceWindow` and the second paragraph for `forceApprove`. Hover `previewProvideExactIn` in `ICreditPool.sol` to verify that the continuation lines appear in their corresponding fields.
