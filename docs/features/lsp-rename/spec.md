# Rename Symbol

Use **Rename Symbol** (`textDocument/prepareRename`, `textDocument/rename`) to change a Zig declaration and its references to a new name. The command is available in editable Zig buffers when ZLS is ready.

## Interaction

- Press F2 with the caret on a symbol. Use the range and name returned by ZLS to position a native single-line field over the symbol. Select the entire name and move keyboard focus to the field. Keep the buffer unchanged while the name is being edited.
- Press Escape to discard the typed name and return focus to the original editor selection. Clicking away cancels the field. An active input method handles Return and Escape before the rename field does.
- Press Return to submit the new name. An unchanged name dismisses the field. An empty name leaves the field active. ZLS returns the spelling to insert, including any Zig identifier quoting needed for the new name.
- Discard the operation if the source buffer, server, or open request changes while the rename is pending. Report an unsuccessful request at the symbol when the source is still current.

## Applying the rename

Check the returned edits across the active project before changing any file. Each range must resolve to the old name in the relevant text, with editable open buffers and non-overlapping edits. The initiating buffer uses the snapshot synchronized with ZLS, including unsaved text. Edits to an already open secondary buffer use its loaded text when it matches the on-disk snapshot. Report conflicting unsaved changes before applying any of the rename.

Apply open-buffer changes through the editor's normal edit and autosave path, preserving selection positions and providing one **Undo Rename Symbol** action in each changed buffer. Write edits to closed files using their existing encoding and checked disk revision. Restore preceding closed-file writes when an apply fails and the published revision is still current. Undo applies to the active buffer's change.

## Acceptance

- Open a project with a function used in the current buffer, a second open buffer, and a closed file. Place a multibyte character before the symbol. Press F2 and verify that the original name is selected. Type a different name and press Escape. Verify that editor focus and all three files are unchanged.
- Press F2 again and submit a replacement with Return. Verify the declaration and references are updated, a similarly named symbol in another scope is unchanged, and the originating editor regains focus. Check **Undo Rename Symbol** in the changed editor.
- Rename with unsaved changes in the origin, then repeat with conflicting unsaved changes in a secondary buffer. Verify that the first uses the live text and the second reports the conflict without edits.

[ZLS rename implementation](https://github.com/zigtools/zls/blob/0.17.0/src/features/references.zig#L737-L755) · [AppKit text field delegate](https://developer.apple.com/documentation/appkit/nstextfielddelegate)
