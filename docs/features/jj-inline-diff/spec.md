# Inline Jujutsu diff

Review a change in the editor where it was made. Inline diff uses the same comparison as [Jujutsu change indicators](../jj-change-indicators/spec.md), including unsaved text in the current buffer.

## Expand and review

- Click a gutter mark to expand that change. Click it again to collapse it. The collapsed mark retains its appearance. Give it a slightly wider and taller target in the editor margin. Use the pointing-hand cursor throughout the clickable area. The scrollbar marks continue to scroll to a change.
- A deletion shows the removed text on red rows at its old position. A replacement shows the red rows first, then the live green rows. An insertion colors the live rows green. Use a stronger shade on the changed spans in a replacement when the difference can be computed within its budget. Keep the code type size and line spacing in both appearances.
- Removed text is selectable and read-only. Click it to place a caret, move with the keyboard, select, and copy it within the block. Up and Down can carry a single caret between live and removed rows. Live green rows support the ordinary editor commands. Save, Find, and the document's editing and undo operations use the live buffer.
- Several changes can stay open. Escape collapses them together before ordinary editor selection cancellation. When the native input method or a modal sheet handles Escape, it receives it first. Closing a change with focus in its removed text returns focus to the source editor.
- Keep the open hunks anchored to the diff baseline across refreshes of the same document when they still exist. Remove an open hunk when its comparison disappears or when another document replaces the buffer. During a short pending refresh, keep the visible diff and disable hunk actions until a current result is ready. Follow the [asynchronous update rules](../../design.md#asynchronous-updates).

## Contextual actions

An open change shows compact AppKit actions when the latest caret is on one of its rows or the mouse is over one of its rows. When the caret and mouse are on different open changes, show their panels simultaneously. When both are on the same change, show one panel. Place each panel at the upper trailing edge of its change and keep it reachable while the top of the block scrolls away. Moving onto a panel keeps it tied to its own change. Use native buttons for **Restore**, **Next Change**, and **Previous Change**, with tooltips and accessibility labels.

Next and Previous move to the adjacent change in the document and expand it if needed. Wrap at the end or beginning of the file. The destination becomes the active change. Preserve any separately expanded changes.

Restore replaces the current content of that hunk with its base text as a single undoable buffer edit. Restore inserts back the text of a deletion and removes the text of an insertion. It validates the current range and content again before editing. It follows the normal file save flow and Focus edit boundaries. In a workspace that normalizes CRLF for comparisons, restored lines follow the document's preferred line ending.

A conflict marker or an ambiguous diff range can still provide status without offering an inline restore action.

## Verification

- Expand one deletion, replacement, and insertion from the gutter. Check that the pointer appears throughout the enlarged hit target, and that clicks and the regular text cursor work outside it.
- Select removed text and try navigating, copying, and changing it. Verify the live buffer and its saved text include only the current version. Type in a green row, undo, and check the refreshed diff.
- Place the primary caret in one open change and hover over another. Confirm two panels appear and each acts on its own change. Move the mouse onto a panel and then onto the change containing the caret. Confirm the shared change shows one panel. Navigate to a closed change, wrap in both directions, and collapse all with Escape.
- Restore individual insertions, deletions, and replacements and undo each one. Exercise the start and end of a document, an empty live buffer, mixed line endings, a protected Focus range, and a stale diff.
- Inspect an isolated native window in both appearances and while scrolling horizontally and vertically. Resize and zoom with several open changes, including a deleted block taller than the viewport. Check viewport and control placement, and leave neighboring text editable.

## References

Zed uses an expanded hunk to compose removed lines with the editable document. Its gutter toggles individual hunks, its controls follow hover or the newest selection, its arrows expand their destinations and wrap, and Escape collapses the expanded changes. [Zed gutter and hover](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/element/mouse.rs) · [Zed control layout](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/element.rs#L4827-L4947) · [Zed restore and navigation](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/git.rs#L3130-L3216) · [Zed diff shortcuts](https://zed.dev/docs/git)

Use AppKit controls and materials for Edit's contextual actions. Xcode provides a native reference for a change bar with contextual actions, inline comparison, and change navigation. [Xcode source changes](https://developer.apple.com/documentation/xcode/tracking-code-changes-in-a-source-control-repository)
