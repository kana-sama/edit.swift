# Focus

Focus lets the user edit selected lines of a document in place. The surrounding text stays visible for reference. Editing commands and search use the focused text as their working scope. The document owns the text, undo history, and file identity throughout the session.

## Start and exit

- Run **Focus Selection** from the Edit menu or [Control Command Mode](../control-commands/spec.md) in an editable buffer. The command uses the originating editor's selections and carets when Control owns keyboard focus.
- Focus every line touched by a selection and every line holding a caret. A selection ending exactly at the start of the next line leaves that line out. Combine adjacent lines into a block. Each block includes its internal line breaks and ends before the separator that leads into protected text.
- Keep empty carets at their columns. Collapse each nonempty selection to a caret at its active end, clamped to its last focused line if that end falls beyond the block. Merge coincident carets, keep the viewport in place, and leave the scope independent of later selections.
- **Exit Focus** is available in the Edit menu and Control while the mode is active. It returns the carets and selections to their locations in the full document and keeps all edits.
- Escape first goes to the control handling the current interaction, such as an input method, menu, sheet, palette, or Search field. In the editor it clears nonempty selections and extra carets first. With a single empty caret and no interaction to cancel, Escape exits Focus.
- A primary click on text outside the scope exits Focus and places the caret where clicked. A drag that starts inside extends the selection through focused text only. Hover, ordinary scrolling, and switching keyboard focus to Search or Control keep the mode active.

## Command scope

Each window can have one Focus session. Disconnected blocks are ordered by their position in the document and act as one editing scope. Navigation jumps over protected text. A logical line break separates disconnected ranges for navigation, clipboard presentation, and the occurrence selection commands. The separator exists only in the logical buffer. Document commands are available only when every edit can be confined to the active ranges. Validate the current scope again when invoking a command from Control, including a pinned entry.

| Action | In Focus |
| --- | --- |
| Select All and document start/end | Select only the focused characters, or move to the first or last active boundary. |
| Character, word, line, paragraph, and page movement | Land on positions in scope. Moving to the next or previous character across a gap jumps to the next or previous active boundary. Shift extends the selection through focused characters. |
| Multiple carets | Option-click and adding carets above or below work within the scope. Select Next Occurrence, Skip to Next Occurrence, and Select All Occurrences match the text across disconnected blocks using a logical line break at each boundary. An occurrence spanning a boundary is one selection with a visible piece on each side. Merge duplicate boundary carets. |
| Typing, IME, paste, deletion, and selection transforms | Apply edits immediately to the original document. Put inserted text at its caret or selection start. Apply each transformation to the source fragments in place. Deleting a selection across ranges preserves the gap. |
| Copy, Cut, and line commands | Copy selected focused text in document order, with a line break between disconnected pieces. With an empty selection, use the current line. Keep line insertion, indentation, and moves inside their range. A line move that would require protected text leaves the buffer intact. |
| Find and Replace | Search the focused text and wrap within it. Search results, excerpts, highlights, and replacements use original document positions. |
| Save, Save As, and autosave | Write the entire document using the existing [Files](../files/spec.md) and [Autosave](../autosave/spec.md) behavior. |

An insertion at either endpoint belongs to the block. Return at the end creates a new focused line and leaves the following text protected. Backspace at the first active position and forward delete at the last active position leave protected text intact. The same rule applies at each side of a gap. Deleting the entire contents of a range leaves an editable empty position. Edits move the active boundaries downstream as needed. Position calculation follows the editor's Unicode character boundaries, including composed characters and emoji.

[Find and Replace](../find-replace/spec.md) keeps its query and options when entering or leaving Focus and refreshes the results for the new scope. Apply whole-word tests, regex anchors, and lookaround to each contiguous active range as a text boundary. Literal and regex matches can contain real line breaks within a range. The gap between ranges is outside the searchable text. Replace All applies the matches from the active ranges as a single document edit. Discard async results computed with a scope that has since changed.

## History and document lifetime

A compound edit, including multiple carets or Replace All, forms one undo step. Undo and redo within Focus cover this session's edits and restore the text, selections, and range boundaries together. The first edit starts a fresh undo group. Entering and exiting without edits preserves the existing undo and redo history and dirty state. The full document history is available again on exit.

Save the focused blocks and their directional selections with the [buffer position](../files/spec.md). Restore them when returning to a recent file or restoring an open window or draft. Each restored window uses its own saved state, including when two windows show the same file. When the current text differs from the saved text, restore the ordinary position and selections and open in ordinary editing mode. Cancelling a save or close confirmation keeps the active session. Saving the document or changing its name through Save As keeps the scope.

## Appearance

Use the current text surface, syntax colors, window appearance, and system selection styling. A selected logical line break at a block boundary extends the selection fill to the right edge of the preceding line, just like a selected line break inside a block. Dim the text on protected lines. Mark the top and bottom of each focused block with thin horizontal rules in the system accent color, spanning the visible width of the editor. Include blank focused lines, including a new empty line after Return. The rules stay anchored to the block while the text selection and horizontal scroll position change. Keep the editor, sidebar, scrollbars, and title bar in their normal positions. Verify that the blocks remain discernible in light and dark appearances, with Increase Contrast or Reduce Transparency, while scrolling, and after zooming.

## Acceptance

- Select two words on each of four consecutive lines. Enter Focus and verify all four full lines are editable. Click beyond the original words on the first line, type and delete a character, then press Return at the end of the fourth line. The new line and caret are inside the block. The line below it stays protected. Repeat with carets in place of selections and with a final line at the end of the file.
- Focus two separate lines with protected text between them. Check caret navigation across the gap, Select All, Copy, typing, and multi-caret editing. Test backspace and forward delete at both ends of a block. Undo a compound edit and verify that the blocks and the gap return to their previous positions. Deleting all text in a block leaves an editable blank line.
- Focus two blocks with `B\nA` inside each and another `B\nA` across their boundary. Select the first occurrence and press Shift-Command-L. Verify three logical selections and four selected pieces. Command-D can select the split occurrence and use it to select the next one. Editing the selections preserves the protected lines between the blocks.
- With the same query inside and outside the scope, check the result count, Command-G and wrap, then Replace All. Check a regex that would only match by reading across a range boundary and a multiline query contained entirely within one range. Exit and verify that the full-document results are available again.
- Open Command Mode from a nonempty selection and invoke Focus Selection. Press Escape during IME composition, while Control or Search has focus, with selected text, with extra carets, and with one empty caret. Verify that the appropriate interaction handles each press. Drag out from inside a range and click outside it in separate trials.
- Edit a named file and verify both autosave and Save As preserve the protected text and line endings. Cancel a replacement of an edited untitled document and verify the scope and edits are still present. Exit Focus and undo a change made before entering the mode.
- Switch away from a focused file and reopen it. Verify its scope and a selection across two blocks are restored with the viewport. Restore a session with two windows showing that file in different scopes and an untitled draft in Focus. If a file changes on disk before reopening, verify its old scope is cleared.
- Inspect initial caret placement, both horizontal rules, scroll and zoom behavior, and appearance changes. Open the same file in a second window and verify the first window's scope belongs to its own view.

## Reference

The personal Lite XL checkout's change `kzmvusqxqzvlyzmnswwwttrmyynxnzxy` (`05beb72cf36a8da1bd935abeba750fddd1a34cc9`, **editor: narrow editing to selected fragments**) supplies the behavior. `data/plugins/selectioneditor.lua` registers Doc: Focus and Doc: Unfocus and handles the editor view and Escape. `data/core/doc/range.lua` maps scoped edits and undo to the source document. `tests/selection_editor.lua` covers boundary edits, disconnected ranges, search, undo, Save As, and IME.
