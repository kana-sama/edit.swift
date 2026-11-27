# Solidity language server

Edit uses Solar from Foundry for named, editable Solidity files. Find `forge` on the same PATH as the other language servers and launch `forge lsp --stdio` from the project root. Discover projects from `foundry.toml`, `remappings.txt`, and loose `.sol` files. Search parent directories when opening a file on its own. Use the opened Foundry project as the root when navigating into its vendored libraries. Solar reads the project configuration, remappings, and active Foundry profile. An older Forge with no `lsp` subcommand reports a process failure in the existing Language Servers popover. [Foundry editor integration](https://github.com/foundry-rs/foundry/blob/v1.10.0/editors/README.md)

Use the existing per-window sessions, workspace-scoped Start, Stop and Restart, definition links, references, occurrence highlighting, document and workspace symbols, and Rename Symbol. Display Markdown hover with syntax-colored Solidity fences. Send the unsaved buffer with UTF-16 positions and notify Solar of saved files and relevant file changes. Show published errors in the source editor and Worktree. Solar in Forge 1.10.0 does not advertise semantic tokens. Syntax colors use the bundled Solidity Tree-sitter grammar.

Solar provides the shared [completion, signature help, and formatting commands](../lsp-editing/spec.md). Formatting uses the Foundry project's format configuration.

## NatSpec hover

Use the [Zig hover section layout](../lsp/spec.md#hover). Put the syntax-colored signature in a rounded code block, then show the description and developer notes. Below the shared divider, use left-hand **Parameters** and **Returns** labels beside their documentation. Show each documented value on a separate line, with its name in inline code when given. Show only the labels that have content. Preserve Markdown links, emphasis, and code examples. Display inherited documentation when Solar includes it in the response. [Solidity NatSpec format](https://docs.soliditylang.org/en/stable/natspec-format.html)

Remove the block-comment margins that Solar can include in Markdown and restore blank lines between paragraphs. Retain the meaning of Markdown lists, emphasis, and asterisks in code examples.

## Acceptance

Run `./script/check --only lsp-solidity` with a compatible Forge on PATH. Check the discovered root, remapped library navigation and held source/destination frames, hover and symbols, cross-file rename, errors during unsaved edits, keyboard completion, active parameter highlighting, format and Undo, and Stop and Restart. Use `EDIT_SOLIDITY_CHECK_PROJECT` to exercise the same integration on a disposable copy of BarterLend.

Hover a documented call and check the summary, notes, and Markdown links above the divider and the parameter and return rows below it. With the BarterLend fixture, hover `getStalePriceWindow` in `LeverageRouter.sol` and check the single **Returns** row. Hover `forceApprove` and check that the ERC-7674 note begins a separate paragraph.
