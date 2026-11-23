# Editor

A new untitled Edit window opens with a focused, empty plain-text buffer and one caret. [Files](../files/spec.md) defines how to open, save, and restore documents. The system supplies the window title bar, traffic lights, menus, scrollbars, caret, and selection appearance. AppKit and TextKit 2 handle text input and layout.

Use Menlo Regular at 12 points with an 18-point line height, matching the default editor typography in VS Code on macOS. Highlight the caret's current line across the viewport. Use a single text surface that follows macOS appearance. Lines can extend beyond the viewport and scroll horizontally without wrapping. Both axes use native macOS scrollbar preferences. Resizing the window or a split pane preserves the viewport relative to the exposed edge, within the available scroll range.

## Editing

- Type and select Unicode text with the keyboard, mouse, or macOS input methods. Use native character movement, page navigation, and editing key bindings. Word commands treat a dot as a separator. In `item.action`, Option-Right from the beginning reaches the end of `item` and then the end of `action`. Option-Left reaches the start of `action` and then the start of `item`. Shift extends from the current anchor, and Option-delete respects the same word boundary.
- Use the Edit menu or Command-X, C, V, A, Z, and Shift-Command-Z for Cut, Copy, Paste, Select All, Undo, and Redo. Copy and Cut with an empty selection act on the current line. Pasting a whole-line copy at a caret inserts it above that line. Selected text uses native clipboard behavior.
- Return inserts a line break with the leading spaces or tabs before the caret. Tab inserts four spaces at a caret or indents the selected lines. Shift-Tab outdents the affected lines.
- Option-Up and Option-Down move the current line or selected block up or down and keep the selection with the moved text. At the document boundary the block stays in place.
- Command-Return inserts below and Shift-Command-Return inserts above with matching indentation. Command-] and Command-[ indent or outdent each affected line. Outdent removes one leading tab or up to four leading spaces.
- Command-Delete deletes the prefix of a line, and Command-Forward Delete deletes the suffix. At the relevant line boundary these commands join adjacent lines.
- Command-= and Command-- change the text size by one point, from 6 to 72. Line height is 1.5 times the font size, rounded to a whole point. Command-0 and a fresh launch restore 12 points. Zoom keeps the same line at the top of the viewport. If the active line was visible and moves outside the viewport, scroll just enough to show it again. Keep the selection and leave offscreen carets in place.

The Edit menu has a Lines submenu with the six line commands. The View menu offers text sizing and native full screen. The Window menu offers Minimize, Zoom, and Close Window. The Help menu uses macOS command search.

## Acceptance

- Open a new untitled window and start typing. Select and replace Unicode text and use native undo and redo.
- Exercise indentation, inserting and moving lines, boundary deletion, and whole-line clipboard behavior. Undo each discrete line edit.
- Open a wide and tall sample within the scratch buffer. Confirm native horizontal and vertical scrolling and active-line highlighting. Shrink and enlarge the window with the caret outside the visible part of a long line. Check both axes from the left edge and after scrolling, with the sidebar open and closed. Scroll deep into the buffer and zoom out and in. Check that the viewport stays painted, the window keeps its size, and the top line stays in place. Select text near the lower edge, then zoom in enough to move that line outside the viewport. Verify the selection returns into view.
- Move the caret between rows before and after horizontal scrolling. Check that the highlight runs across the current row even when the caret is beyond the horizontal edge, and that previously highlighted rows stay clear as more of the document comes into view.
- Run `./script/check` to exercise native editing and render the implemented buffer without stealing focus.
