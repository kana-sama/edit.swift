# Jujutsu text conflicts

Show materialized conflicts where the user is already editing or inspecting a file. Confirm each block against the recorded Jujutsu file so that marker-like text in ordinary files keeps its ordinary meaning. Support `diff`, `snapshot`, and jj's `git` markers, long delimiters, conflicts with any number of sides, and files with no terminating newline. Show supported blocks even when another block has incomplete markers. [Jujutsu conflict formats](https://docs.jj-vcs.dev/latest/conflicts/#conflict-markers)

Color structural markers purple, added diff lines green, and removed diff lines red. Preserve ordinary syntax colors on snapshot text and diff context. Keep the existing [gutter and scrollbar conflict marks](../jj-change-indicators/spec.md) for navigation.

Show a panel above the editor with the current block and total count, previous and next controls, and a choice of Diff or Snapshot. The Resolve menu offers every side by number and, when available, its subject. It also lets the user focus the markers for manual editing. When space is tight, retain the format picker and the actions menu, including navigation. A historical preview has the same highlighting and format and navigation controls, with resolution reserved for the editable working file.

Accepting a side replaces only the selected block with that side's text. A format change rewrites confirmed blocks as one undoable buffer edit, preserving their sides, bases, surrounding text, and final newlines. Preview format changes are in memory. Both operations leave repository configuration unchanged and follow normal buffer save and Undo behavior. Suspend actions while analysis is stale, and validate the current marker text before replacing a range.

## Acceptance

- Open a real three-sided merge with two conflicts. Check status icons, markers, diff colors, and the panel in both appearances. Navigate between the blocks and switch the editable text between Diff and Snapshot.
- Snapshot a format-only edit with jj and verify that it preserves the recorded conflict, including when the sides have different final line endings. Resolve one block with the third side and check that the other remains intact. Undo the resolution and the format change.
- Open the same conflict in another revision. Switch its format and verify the preview remains read-only and the working file stays unchanged.
