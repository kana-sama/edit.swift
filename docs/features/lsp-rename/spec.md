# Rename Symbol

Use **Rename Symbol** (`textDocument/prepareRename`, `textDocument/rename`) to change a Zig declaration and its references to a new name. The command is available in editable Zig buffers when ZLS is ready.

## Interaction

- Press F2 with the caret on a symbol. Select the name returned by ZLS in the editor. The name keeps its normal background within a slightly rounded opening that follows its exact text bounds. Dim the surrounding code. As the name grows or shrinks, the rest of the line follows its normal layout and the opening follows the name.
- Keep keyboard focus, selection, and the insertion point in the editor. Show the normal editor caret when the selection collapses, including at the edge of the shaded region. Limit draft edits to the name. Saves, language requests, and the document's undo history continue to use the original text until Rename Symbol applies the result.
- Press Escape to discard the draft and restore the original selection. Clicking outside the name or leaving the editor also cancels the draft. An active input method handles Return and Escape before the rename command does.
- Press Return to submit the new name. Keep the draft visible while ZLS responds, and keep the caret at the position it held in the name when Return was pressed. Follow that position through any quoting or escaping ZLS adds. An unchanged name ends the session with the caret at that position. An empty name leaves the session active.
- Discard the operation if the source buffer, server, or open request changes while the rename is pending. Report an unsuccessful request at the symbol when the source is still current.

## Applying the rename

Check the returned edits across the active project before changing any file. Each range must resolve to the old name in the relevant text, with editable open buffers and non-overlapping edits. The initiating buffer uses the snapshot synchronized with ZLS, including unsaved text. Edits to an already open secondary buffer use its loaded text when it matches the on-disk snapshot. Report conflicting unsaved changes before applying any of the rename.

Apply open-buffer changes through the editor's normal edit and autosave path, preserving selection positions and providing one **Undo Rename Symbol** action in each changed buffer. Write edits to closed files using their existing encoding and checked disk revision. Restore preceding closed-file writes when an apply fails and the published revision is still current. Undo applies to the active buffer's change.

## Acceptance

- Open a project with a function used in the current buffer, a second open buffer, and a closed file. Place a multibyte character before the symbol. Press F2 and verify that the editor selects the name and only the surrounding code is dimmed. Type a longer name and check that the text and opening move together. Press Escape and verify that the original text and selection return and all three files are unchanged.
- Press F2 again and submit a replacement with Return. Verify the declaration and references are updated, a similarly named symbol in another scope is unchanged, and the originating editor regains focus. Check **Undo Rename Symbol** in the changed editor.
- Submit a longer name with the caret at its end. Repeat with the caret inside the name, including a name that requires Zig quoting. Verify that Return keeps the caret at the corresponding position.
- Collapse the selected name with an arrow and verify the caret is visible. After Escape, Return with the same name, and a completed rename, move Down from a long line to a closing brace and Up again. Verify that the caret returns to the column on the long line.
- Rename with unsaved changes in the origin, then repeat with conflicting unsaved changes in a secondary buffer. Verify that the first uses the live text and the second reports the conflict without edits.

[ZLS rename implementation](https://github.com/zigtools/zls/blob/0.17.0/src/features/references.zig#L737-L755)
