# Editor

A new untitled Edit window opens with a focused, empty plain-text buffer and one caret. [Files](../files/spec.md) defines how to open, save, and restore documents. The system supplies the window title bar, traffic lights, menus, scrollbars, caret, and selection appearance. AppKit and TextKit 2 handle text input and layout.

Use the system monospaced font at 13 points initially and highlight the caret's current line across the viewport. Use a single text surface that follows macOS appearance. Lines can extend beyond the viewport and scroll horizontally without wrapping. Both axes use native macOS scrollbar preferences.

## Editing

- Type and select Unicode text with the keyboard, mouse, or macOS input methods. Use native character and word movement, page navigation, and editing key bindings.
- Use the Edit menu or Command-X, C, V, A, Z, and Shift-Command-Z for Cut, Copy, Paste, Select All, Undo, and Redo. Copy and Cut with an empty selection act on the current line. Pasting a whole-line copy at a caret inserts it above that line. Selected text uses native clipboard behavior.
- Return inserts a line break with the leading spaces or tabs before the caret. Tab inserts four spaces at a caret or indents the selected lines. Shift-Tab outdents the affected lines.
- Option-Up and Option-Down move the current line or selected block up or down and keep the selection with the moved text. At the document boundary the block stays in place.
- Command-Return inserts below and Shift-Command-Return inserts above with matching indentation. Command-] and Command-[ indent or outdent each affected line. Outdent removes one leading tab or up to four leading spaces.
- Command-Delete deletes the prefix of a line, and Command-Forward Delete deletes the suffix. At the relevant line boundary these commands join adjacent lines.
- Command-= and Command-- change the text size by one point, from 6 to 72. Command-0 and a fresh launch restore 13 points.

The Edit menu has a Lines submenu with the six line commands. The View menu offers text sizing and native full screen. The Window menu offers Minimize, Zoom, and Close Window. The Help menu uses macOS command search.

## Acceptance

- Open a new untitled window and start typing. Select and replace Unicode text and use native undo and redo.
- Exercise indentation, inserting and moving lines, boundary deletion, and whole-line clipboard behavior. Undo each discrete line edit.
- Open a wide and tall sample within the scratch buffer. Confirm native horizontal and vertical scrolling, active-line highlighting, and a text-size change without a change to the window size.
- Run `./script/check` to exercise native editing and render the implemented buffer without stealing focus.
