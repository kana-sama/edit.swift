# Toggle Line Comments

Press Command-/ or choose Edit > Lines > Toggle Line Comments to comment the line at each caret and every line touched by a selection. A selection ending at the start of a line excludes that line. Multiple carets on the same line edit it once.

Use the document’s active syntax language, including a manual choice. Decide whether to add or remove comments for each selection independently. Skip empty lines and lines containing only spaces or tabs when the selection also covers nonblank lines. When all nonblank lines start with the comment prefix after indentation, remove the prefix and up to one following space. Otherwise, insert the prefix and one space on each nonblank line. A selection covering only blank lines receives comments on those lines.

When adding comments, use the shallowest participating indentation rounded down to a stop at the editor’s indentation width. Place the prefix before any tab that crosses that column. Preserve the original indentation and line separators so toggling a mixed selection twice restores the original text.

The command is available in editable buffers whose active language has a line comment prefix. Keep carets and selections with the edited text. Toggling a selection keeps the viewport in place within the available scroll range. One Undo or Redo applies the whole command and also keeps the viewport in place for selection edits.

## Acceptance

- In a Swift buffer, press Command-/ with a caret on an indented line, then press it again. Verify the resulting text, caret, and indentation.
- Select commented Zig code with blank and whitespace-only lines in the middle. Press Command-/ once to remove the `//` markers. Undo to restore the code and selection.
- Select across two lines in a buffer with horizontal overflow. Toggle comments on and off and use Undo and Redo. Check the horizontal position both at the left edge and after scrolling.
- In a Python buffer, select a mix of commented and uncommented lines with spaces and tabs for indentation, ending at the start of the next line. Verify the alignment and use of `#`, toggle again, and undo the command. With carets on separate lines, verify that one can add a comment while another removes one.
- Verify that the menu command is disabled in plain text and in read-only buffers.

The line toggle follows the default behavior of [VS Code’s Toggle Line Comment command](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/comment/browser/lineCommentCommand.ts).
