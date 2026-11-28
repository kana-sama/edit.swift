# Smart Typing

- Typing either member of `()`, `[]`, `{}`, `""`, or `''` around a selection wraps its contents and keeps those contents selected. Multiline selections preserve their text and line endings.
- Typing an auto-inserted closer at its position moves the caret past it. At the end of a line or before whitespace or `)]},;:`, typing an opener inserts the pair and puts the caret between the two characters. Elsewhere it inserts one character. A quote following an odd number of backslashes is literal. An opening quote immediately after a word character inserts just the typed quote. Paste and input-method composition retain their literal text.
- Return copies the current line's indentation before the caret. If the character before the caret is `(`, `[`, or `{` after ignoring spaces and tabs, Return adds one level of four spaces. When the matching closer immediately follows the caret, Return puts it on a separate line at the original indentation and leaves the caret on the indented line between them. Use the document's line ending for each inserted break.
- At an empty caret, Tab inserts enough spaces to reach the next multiple of four logical columns from the start of the line. An existing tab advances to the next stop. With a selection, Tab indents affected lines by one level.
- Apply these rules to each editable caret or selection, including in Focus. A single keystroke edits the buffer as one Undo step. Undo and Redo restore the text and caret locations for wrapping and splitting a pair.

## Acceptance

- In `fn () `, type `{` then Return. Check that the caret sits on a blank line four spaces in and that `}` sits on the following line. Undo and redo both steps, then type past the generated closer.
- Wrap multiline Unicode text with a quote or bracket and undo the wrap. Include a single keystroke that wraps a selection and inserts a pair at another caret.
- Use Tab at different starting columns on lines with spaces, tabs, and Unicode text. Split pairs across two Focus blocks in a CRLF buffer and undo both edits together.
