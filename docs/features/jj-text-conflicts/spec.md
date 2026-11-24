# Jujutsu text conflicts

Show materialized conflicts where the user is already editing or inspecting a file. Confirm each block against the recorded Jujutsu file so that marker-like text in ordinary files keeps its ordinary meaning. Support `diff`, `snapshot`, and jj's `git` markers, long delimiters, conflicts with any number of sides, and files with no terminating newline. Show supported blocks even when another block has incomplete markers. [Jujutsu conflict formats](https://docs.jj-vcs.dev/latest/conflicts/#conflict-markers)

Tint the full width of structural marker rows purple, added diff rows green, and removed diff rows red. Use stronger tints on changed words within added and removed rows, with the same diff palette and comparison as inline diffs. Preserve ordinary syntax colors on the text. Keep the existing [gutter and scrollbar conflict marks](../jj-change-indicators/spec.md) for navigation.

Show a panel above the editor with the current block and total count, previous and next controls, and a two-segment Diff and Snapshot control. Keep navigation and both segments reachable when space is tight. Position the Resolve action at the trailing edge of the active visible block using the same floating treatment as inline diff actions. Its menu offers every side by number and, when available, its subject. It also lets the user focus the markers for manual editing. A historical preview provides the highlighting, format switch, and navigation.

Accepting a side replaces only the selected block with that side's text. A format change rewrites confirmed blocks as one undoable buffer edit, preserving their sides, bases, surrounding text, and final newlines. Preview format changes are in memory. Both operations leave repository configuration unchanged and follow normal buffer save and Undo behavior. Suspend actions while analysis is stale, and validate the current marker text before replacing a range.

## Acceptance

- Open a real three-sided merge with two conflicts. Check full-row colors, word-level differences, and the panels in both appearances. Navigate between the blocks and verify that the floating action follows the active block. Switch the editable text between Diff and Snapshot using the top control.
- Snapshot a format-only edit with jj and verify that it preserves the recorded conflict, including when the sides have different final line endings. Resolve one block with the third side and check that the other remains intact. Undo the resolution and the format change.
- Open the same conflict in another revision. Switch its format and verify the preview remains read-only and the working file stays unchanged.
