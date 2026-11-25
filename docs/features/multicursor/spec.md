# Multiple carets

Use multiple carets or selections to edit a document in one operation. TextKit supplies the primary selection and input. Single and multiple carets use the same thin bars, aligned to the display’s pixels. The first frame after inserting or deleting text shows each caret at its new position. Adjacent carets in the same column form a continuous line across their rows. All visible carets share one blink phase. Scrolling another caret into view preserves the phase. The system preference for a steady caret applies to the whole group. Selections use the system selection colors. The current-line highlight follows the primary selection.

## Commands

- Option-Command-Up and Option-Command-Down add a caret at the corresponding column on the previous or next line. Option-click adds one at the pointer.
- Option-Shift-I places carets at the ends of selected lines and at the selection endpoint. A selection ending at the start of the next line excludes that line.
- Command-D selects the current word or adds the next literal, case-sensitive occurrence. Command-K then Command-D replaces the newest selection with the next unselected occurrence. Shift-Command-L selects every nonoverlapping exact occurrence of the primary selection.
- Command-U and Shift-Command-U undo and redo selection changes for the current text. Escape keeps the primary selection when there are multiple carets and no expanded inline changes. The next Escape collapses that selection to its active end. An ordinary click resumes the native single selection.

These operations apply to every caret or selected range: text insertion, character and word deletion, moving the caret, indentation, line-boundary deletion, and moving or inserting lines. Line commands act once per affected line or contiguous block. Copy and Cut use the selected text, or each distinct line when every selection is empty. Whole-line Paste inserts above the target lines and keeps the clipboard content useful in other apps. Text changes from one multi-selection command are one undo step.

Arrow navigation applies to every selection, including Command-Left and Command-Right for the visual line edges and Shift to extend each selection from its own anchor. Word, paragraph, document, and page movement also retain separate carets or selections where their resulting ranges are distinct. Carets that reach the same boundary merge. Scroll-only commands leave the selections in place.

AppKit shows marked input at the primary selection. Confirming the composition inserts the finished text at all original selections as one Undo step. Cancelling restores the original text and selections.

## Verification

Run `./script/check` to verify selection commands and history, native key dispatch for caret movement and selection extension, Unicode edits and input-method composition, line edits, clipboard, and document Undo in an isolated, non-activating instance.
