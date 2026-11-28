# Format on Save

Turn on **Edit → Format on Save** to format the active document when using Save (Command-S) or Save As. In Command Mode, search for **Toggle Format on Save**. The switch starts off. Edit remembers the setting for each workspace across launches and uses a separate setting for windows without an open folder.

Use the current document's [Format Document](../lsp-editing/spec.md) provider and its project settings. Save requests formatting even when [autosave](../autosave/spec.md) has already written the current text. Background saves and the write before Run Test preserve the user's text.

Choose **File → Save Without Format** or search for **Save Without Format** in Command Mode to save the current text as written. This skips the formatter for that save and keeps the workspace setting for future saves. For an untitled document, the command opens the usual save panel.

After a Save As destination is confirmed, or when saving in place, apply the formatter's edits to the buffer as one Undo action, map the current selections, and save the resulting text through the ordinary writer. An untitled buffer becomes eligible for language-server formatting once it has a path and an active provider. When the formatter is unavailable or the editor is in Focus, save the current text.

Keep the editor responsive while formatting. If the text changes, the server restarts, the formatter fails, or its one-second deadline expires, discard the result and save the current text. A late reply must leave the saved and displayed text alone. Save retains the normal encoding and disk-change checks.

## Acceptance

Run `./script/check --only lsp-editing` with ZLS, OLS, and SourceKit-LSP. Check the persisted workspace switch, the saved bytes with the switch off and on, one-step Undo, and explicit Save after autosave. With Format on Save enabled, run Save Without Format from Command Mode and check the text in the buffer and on disk. Follow it with Save and check that the formatter runs. Hold a ZLS reply during Save, type more text, and check that the current text reaches disk.
