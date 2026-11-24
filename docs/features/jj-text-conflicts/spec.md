# Jujutsu text conflicts

Show materialized conflicts where the user is already editing or inspecting a file. Confirm each block against the recorded Jujutsu file so that marker-like text in ordinary files keeps its ordinary meaning. Support `diff`, `snapshot`, and jj's `git` markers, long delimiters, conflicts with any number of sides, and files with no terminating newline. Show supported blocks even when another block has incomplete markers. [Jujutsu conflict formats](https://docs.jj-vcs.dev/latest/conflicts/#conflict-markers)

Use purple text on structural markers. Tint added diff rows green and removed diff rows red, with stronger tints on the changed words. Use the inline diff palette and comparison. Preserve ordinary syntax colors elsewhere and keep the [gutter and scrollbar conflict marks](../jj-change-indicators/spec.md).

The strip below the native toolbar has 12-point side insets, the current block and total count, previous and next controls, and Diff and Snapshot segments. Keep navigation and both segments reachable in narrow windows. Float direct actions at the trailing edge of their marker rows using the same treatment as inline diff actions. A historical preview offers highlighting, navigation, and format switching.

Verify working-copy conflicts against the recorded file before presenting a new buffer. Include the conflict strip and its scroll inset in the first frame. Preserve the text position when the live repository observer supplies its analysis.

- **Accept Snapshot** on a snapshot or Git side replaces only that conflict block with the displayed side. Ancestor rows provide context.
- **Apply Diff** on a Diff segment incorporates its changes into a draft starting with the displayed snapshot. Independent word edits can be combined on the same line. Apply multiple diffs in the desired order. **Undo Diff** on the latest applied segment returns to the preceding draft. The closing marker offers **Use Result** once a diff has been applied.
- **Edit Result…** at the closing marker opens a code editor seeded with the current draft or the first displayed side. When an overlapping diff cannot be safely applied, open the same editor with the current draft and explain the overlap. **Use Result** applies the edited text to the block. Cancel closes the editor and keeps any staged diffs. [KDiff3 merge output editor](https://docs.kde.org/stable_kf6/en/kdiff3/kdiff3/merging.html)

Drafts are local to the open buffer and stay with their unchanged marker block. Only accepting a side or result edits the buffer. The replacement follows normal save and Undo behavior. Suspend actions while analysis is stale and verify the exact marker text before applying a replacement.

A format change prepares the new marker text and highlight ranges together before replacing the visible block. It rewrites confirmed blocks as one undoable buffer edit, preserving their sides, bases, surrounding text, and final newlines. Preview format changes are in memory. Neither operation changes the repository configuration.

## Acceptance

- Open a real three-sided merge with two conflicts from a regular file. Check that the first frame reserves the strip and that the first line stays in place when the live analysis arrives. Check marker glyph colors, diff row colors, word highlights, strip insets, and floating buttons in both appearances. Navigate to the next conflict and switch format from the top strip. Check that the first Snapshot frame repaints every marker and clears the previous colors from ordinary text.
- Resolve one block using the third snapshot. Resolve from the result editor when a diff overlaps the starting snapshot. In the other block, apply both diffs with independent word edits out of order, undo the most recent one, reapply it, and use the result. Check that the other block survives and editor Undo restores the resolved block.
- Snapshot a format-only edit with jj and verify that it preserves the recorded conflict, including sides with different final line endings.
- Open the same conflict in another revision. Switch its format and verify the preview remains read-only and the working file stays unchanged.
