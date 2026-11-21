# Multiple carets

Use multiple carets or selections to edit a document in one operation. TextKit supplies the primary selection and input. Secondary carets use the system insertion indicator and selection colors. The current-line highlight follows the primary selection.

## Commands

- Option-Command-Up and Option-Command-Down add a caret at the corresponding column on the previous or next line. Option-click adds one at the pointer.
- Option-Shift-I places carets at the ends of selected lines and at the selection endpoint. A selection ending at the start of the next line excludes that line.
- Command-D selects the current word or adds the next literal, case-sensitive occurrence. Command-K then Command-D replaces the newest selection with the next unselected occurrence. Shift-Command-L selects every nonoverlapping exact occurrence of the primary selection.
- Command-U and Shift-Command-U undo and redo selection changes for the current text. Escape keeps the primary selection. An ordinary click resumes the native single selection.

These operations apply to every caret or selected range: text insertion, character and word deletion, moving the caret, indentation, line-boundary deletion, and moving or inserting lines. Line commands act once per affected line or contiguous block. Copy and Cut use the selected text, or each distinct line when every selection is empty. Whole-line Paste inserts above the target lines and keeps the clipboard content useful in other apps. Text changes from one multi-selection command are one undo step.

The document keeps one native input-method composition. Starting a composition preserves the primary selection.

## Verification

Run `./script/check` to verify selection commands and history, Unicode edits, line edits, clipboard, and document Undo in an isolated, non-activating instance.
