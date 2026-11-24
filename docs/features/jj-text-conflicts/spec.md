# Jujutsu text conflicts

Show materialized conflicts where the user is already editing or inspecting a file. Confirm each block against the recorded Jujutsu file so that marker-like text in ordinary files keeps its ordinary meaning. Support `diff`, `snapshot`, and jj's `git` markers, long delimiters, conflicts with any number of sides, and files with no terminating newline. Show supported blocks even when another block has incomplete markers. [Jujutsu conflict formats](https://docs.jj-vcs.dev/latest/conflicts/#conflict-markers)

Use purple text on structural markers. Tint added diff rows green and removed diff rows red, with stronger tints on the changed words. Use the inline diff palette and comparison. Preserve ordinary syntax colors elsewhere and keep the [gutter and scrollbar conflict marks](../jj-change-indicators/spec.md).

The strip below the native toolbar has 12-point side insets, the current block and total count, previous and next controls, and Diff and Snapshot segments. Keep navigation and both segments reachable in narrow windows. Float direct actions at the trailing edge of their marker rows using the same treatment as inline diff actions. A historical preview offers highlighting, navigation, and format switching.

Verify working-copy conflicts against the recorded file before presenting a new buffer. Include the conflict strip and its scroll inset in the first frame. Preserve the text position when the live repository observer supplies its analysis.

- Keep marker lines, their structural line endings, and reference sections selectable and copyable. Reject edits that touch them, including selections that cross from editable text into protected text. Ordinary files with literal markers retain regular editing.
- **Accept Snapshot** on a snapshot or Git side replaces just that conflict block with the displayed side. The first full snapshot in the block serves as the editable result. **Edit Snapshot** moves the caret there in the existing editor. Materialize a blank editable line when the selected snapshot is empty.
- In Diff mode, **Apply Diff** updates the editable snapshot in place. Apply multiple diffs in the desired order and use ordinary editor Undo to reverse an application. When a diff overlaps the current result, focus the snapshot and offer **Merge Manually** on that diff. Keep the source alternatives visible for comparison.
- **Mark Resolved** replaces the entire block with the current snapshot and leaves other conflicts intact. Undo restores the protected block and its inline result.

Save and autosave write ordinary edits and resolved blocks while preserving the original materialized payload of each unfinished conflict. Recover unfinished inline results with the session. Keep the current representation while an inline draft is edited so its starting snapshot and reference diffs stay together. Suspend actions while analysis is stale and verify the exact protected block before replacing a range.

A format change prepares the new marker text and highlight ranges together before replacing the visible block. It rewrites confirmed blocks as one undoable buffer edit, preserving their sides, bases, surrounding text, and final newlines. Preview format changes are in memory. Neither operation changes the repository configuration.

## Acceptance

- Open a real three-sided merge with two conflicts from a regular file. Check that the first frame reserves the strip and that the first line stays in place when the live analysis arrives. Check marker glyph colors, diff row colors, word highlights, strip insets, and floating buttons in both appearances. Navigate to the next conflict and switch format from the top strip. Check that the first Snapshot frame repaints every marker and clears the previous colors from ordinary text.
- Reject typing, multiline replacement and input composition across a confirmed marker. Apply an overlapping diff and edit the snapshot in the same editor. Save while resolving and confirm jj still sees the original conflict. Apply both independent diffs in the other block and reverse one with editor Undo. Accept the third snapshot or mark the edited result resolved and check that Undo restores the original protected block and its draft.
- Snapshot a format-only edit with jj and verify that it preserves the recorded conflict, including sides with different final line endings.
- Open the same conflict in another revision. Switch its format and verify the preview remains read-only and the working file stays unchanged.
