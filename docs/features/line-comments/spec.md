# Toggle Line Comments

Press Command-/ or choose Edit > Lines > Toggle Line Comments to comment the line at each caret and every line touched by a selection. A selection ending at the start of a line excludes that line. Multiple carets on the same line edit it once.

Use the document’s active syntax language, including a manual choice. Insert its line comment prefix and one space after each line’s indentation. When every affected line already starts with the prefix after indentation, remove the prefix and up to one following space from each line. In a mixed selection, add a prefix to every affected line so toggling twice restores the original text.

The command is available in editable buffers whose active language has a line comment prefix. Keep carets and selections with the edited text. One Undo or Redo applies the whole command.

## Acceptance

- In a Swift buffer, press Command-/ with a caret on an indented line, then press it again. Verify the resulting text, caret, and indentation.
- In a Python buffer, select a mix of commented and uncommented lines ending at the start of the next line. Verify the use of `#`, toggle again, and undo the command. Repeat with carets on separate lines and two carets on one line.
- Verify that the menu command is disabled in plain text and in read-only buffers.

The shortcut follows [Xcode’s Toggle Comments command](https://developer.apple.com/videos/play/wwdc2026/8013/).
