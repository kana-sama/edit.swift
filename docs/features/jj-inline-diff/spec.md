# Inline Jujutsu diff

Review a change in the editor where it was made. Inline diff uses the same comparison as [Jujutsu change indicators](../jj-change-indicators/spec.md), including unsaved text in the current buffer.

## Expand and review

- Click a gutter mark to expand that change. Click it again to collapse it. The collapsed mark retains its appearance. Give it a slightly wider and taller target in the editor margin. Use the pointing-hand cursor throughout the clickable area. The scrollbar marks continue to scroll to a change.
- A deletion shows the removed text on red rows at its old position. A replacement shows the red rows first, then the live green rows. An insertion colors the live rows green. Use a stronger shade on the changed spans in a replacement when the difference can be computed within its budget. Keep the code type size and line spacing in both appearances.
- Removed rows and live rows share a continuous caret and selection. Click a removed row to place a visible caret. Move or extend the selection with the keyboard, and drag across a boundary in either direction. Copy includes the entire displayed selection in order. Delete, cut, typing, and paste affect only the selected live text. Typing or pasting a replacement inserts at the start of that live part. A selection or caret entirely in removed text leaves the live buffer untouched. Save, Find, and undo use the live buffer.
- Several changes can stay open. Escape collapses them together before ordinary editor selection cancellation. When the native input method or a modal sheet handles Escape, it receives it first. Closing a change with focus in its removed text returns focus to the source editor.
- Keep the open hunks anchored to the diff baseline across refreshes of the same document. Keep a refreshed change open when its base range overlaps the previous open change, such as when editing the live line below a deletion turns it into a replacement. Remove an open hunk when its comparison disappears or when another document replaces the buffer. During a short pending refresh, keep the visible diff and disable hunk actions until a current result is ready. Follow the [asynchronous update rules](../../design.md#asynchronous-updates).

## Layout

The editor uses a single text view. Its TextKit layout reserves room for removed paragraphs, and native TextKit line fragments supply their glyphs and character geometry. Draw removed text and both change backgrounds in the editor's own document coordinates. Extend the change backgrounds across the exposed space during horizontal overscroll at either edge. The same layout supplies the removed caret, mouse hit testing, selection painting, and scrolling. Sidebars change the visible area of that document and clip all rows together. The live buffer remains the source for editing, saving, Jujutsu comparisons, and undo.

## Contextual actions

An open change shows compact AppKit actions when the latest caret is on one of its rows or the mouse is over one of its rows. When the caret and mouse are on different open changes, show their panels simultaneously. When both are on the same change, show one panel. Use a matte, opaque panel at the upper trailing edge of the change. Keep it reachable while the top of the block scrolls away. The panel overlays the text at the same position even when it covers part of a line. Moving onto a panel keeps it tied to its own change. Use native buttons for **Restore**, **Previous Change**, and **Next Change**, with tooltips and accessibility labels.

Next and Previous use the change that owns the pressed button as their starting point. Expand the adjacent change if needed and move the caret there. Wrap at the end or beginning of the file. Preserve any separately expanded changes.

Restore replaces the current content of that hunk with its base text as a single undoable buffer edit. Restore inserts back the text of a deletion and removes the text of an insertion. It validates the current range and content again before editing. It follows the normal file save flow and Focus edit boundaries. In a workspace that normalizes CRLF for comparisons, restored lines follow the document's preferred line ending.

A conflict marker or an ambiguous diff range can still provide status without offering an inline restore action.

## Verification

- Expand one deletion, replacement, and insertion from the gutter. Check that the pointer appears throughout the enlarged hit target, and that clicks and the regular text cursor work outside it.
- Select from the `2` in removed `line 2` through `li` in live `line 3`. Copy yields `2\nli`. Delete yields live `ne 3` and typing `X` yields live `Xne 3`. Check that the refreshed replacement stays open with all three original lines shown as removed. Repeat in the opposite selection direction, check a selection confined to removed rows, and undo the live edit.
- Place the caret on the second change, hover over the fourth, and click Previous on the fourth change's panel. Confirm the caret moves to the third change and opens it. With the same starting caret and hover, click Next and check the fifth change. Move the mouse onto the change containing the caret and confirm the shared change shows one panel. Check wrapping in both directions and collapse all with Escape.
- Restore individual insertions, deletions, and replacements and undo each one. Exercise the start and end of a document, an empty live buffer, mixed line endings, a protected Focus range, and a stale diff.
- Inspect an isolated native window in both appearances and while scrolling horizontally and vertically. Use a long line that runs under the matte panel and confirm the overlay leaves the line layout intact. Open and close the leading sidebar and trailing terminal while horizontally scrolled. Confirm removed and live glyphs stay aligned to the same document columns. Resize and zoom with several open changes, including a deleted block taller than the viewport. Check viewport and control placement, and leave neighboring text editable.

## References

Zed uses an expanded hunk to compose removed lines with the editable document. Its gutter toggles individual hunks, its controls follow hover or the newest selection, its arrows expand their destinations and wrap, and Escape collapses the expanded changes. [Zed gutter and hover](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/element/mouse.rs) · [Zed control layout](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/element.rs#L4827-L4947) · [Zed restore and navigation](https://github.com/zed-industries/zed/blob/f126950f9d3b62666f97437ae5d4ccac2272c4db/crates/editor/src/git.rs#L3130-L3216) · [Zed diff shortcuts](https://zed.dev/docs/git)

Xcode provides a native reference for the change bar's buttons, inline comparison, and change navigation. [Xcode source changes](https://developer.apple.com/documentation/xcode/tracking-code-changes-in-a-source-control-repository)
