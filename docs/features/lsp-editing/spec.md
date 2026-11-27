# LSP editing commands

Completion, signature help, and document formatting are shared Edit features. Use the same commands and interaction for Solar, ZLS, OLS, and SourceKit-LSP, including the C-family modes that SourceKit-LSP serves through clangd. Offer each command when the language server is ready and advertises its capability for the active source.

## Completion

**Complete** (Control-Space) asks the server for suggestions at a single caret. Also request suggestions as an identifier is typed and on the server's trigger characters. Match the server's filter text, with identifier prefixes ahead of subsequence matches. When the server has no matching prefix for an unqualified identifier, offer matching words from the current buffer with their source excerpts and a plain replacement of the typed prefix. This keeps identifiers such as `Operation` available when Solar's analysis of an unfinished `Ope` statement reports a parse error and loses access to its symbols.

When Solar cannot complete a member after an unfinished `Enum.` access, offer the members of the visible enum declaration in the current contract or source unit. Use the current syntax tree to find the declaration and insert only the chosen member name.

Place the list to the right of the caret and below its line when space permits. Fit it on the active screen, shifting to the other side or above the caret line when needed. Use a rounded panel with a list and a documentation column on its right. Render the selected item's Markdown or plaintext documentation and resolve it when available. Show brief detail or a source excerpt when that is what the candidate provides. Keep the caret in the editor and pair the documentation with the selected row as requests finish.

Use Up and Down to move the selection, Return or Tab to accept, and Escape to dismiss. Clicking a row accepts it. Apply the initial server edit and additional edits together as one undoable operation. Validate the current document, revision, and caret before inserting. Keep matching rows from the previous response briefly visible during a compatible refresh and suspend acceptance until the current response arrives.

## Signature help and formatting

**Show Signature Help** (Control-Shift-Space) opens a card at a single caret. Also request help on the server's trigger characters and update it as the user edits the call. Emphasize the active parameter using the returned UTF-16 label offsets or the ordered parameter labels. Dismiss it with Escape, on caret navigation, or when the editor loses focus.

**Format Document** (Option-Shift-F) formats the current buffer using the language server's formatter and project settings. Apply the response as one Undo action and retain caret positions across whitespace changes. Discard replies superseded by a buffer change, server restart, or file switch. Offer document formatting outside Focus so the server can edit the whole document. Use the ordinary save flow for disk writes.

The commands appear in Edit and Control. Capabilities and results follow the currently installed language server. [LSP checklist](../../lsp-checklist.md)

## Acceptance

Run `./script/check --only lsp-editing` with compatible ZLS, OLS, and SourceKit-LSP toolchains. Complete a prefix, view the item documentation, select the second parameter, format, and undo in Zig, Odin, Swift, and C. Run `./script/check --only lsp-solidity` with Forge for those interactions and Solar's incomplete-statement recovery. With a disposable BarterLend copy in `EDIT_SOLIDITY_CHECK_PROJECT`, type `Ope` before the `return` in `LeverageRouter.sol`, wait for the error and completion, then dismiss and reopen the list. Accept `Operation`. Try `Operation.` before the same `return` with and without a semicolon. Verify that both list the enum values and that accepting a value completes only the member access.
