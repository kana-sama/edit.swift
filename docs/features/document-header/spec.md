# Document header

The [native glass header](../../design.md#document-header) shows the file icon, directory path, filename, and caret position in a single row. The path is secondary text before the filename. In a folder window, show the parent directory relative to the open folder and omit the prefix for files at its root. For standalone files and files outside the open folder, use the absolute directory, abbreviated with `~` under the home directory. The filename and path tooltips show the full file path. Untitled documents and scratches have no path prefix.

Show the active end of the primary selection as `line:column` in secondary text after the filename. Both numbers start at 1. Count logical lines and user-perceived characters, with each tab counting as one character. Keep the position current during editing and navigation, including when restoring a selection or using multiple carets. Show it on text surfaces, including read-only source, and hide it in rendered Markdown and other file previews.

Keep the filename readable as the window or its sidebars resize. Cap the path width, truncate its beginning to preserve the directories closest to the file, and hide it when too little of it fits. Keep the coordinate pair whole while space allows. The path and coordinates yield before the filename and existing header controls. Keep outgoing metadata with its content during a document switch, and show the incoming metadata with the new presentation and its restored selection.

## Acceptance

- Open a nested file in a folder window, a file at its root, and a file outside it. Check their directory prefixes and the full path on hover. Resize the editor pane in both directions while a long path is visible.
- Move the primary caret through multiple lines, select backward across characters, and add a second caret. Check a line with a tab and composed characters, the empty line after a final newline, and the position after an insertion. Toggle Markdown Preview and check the position on return to the source.
- Hold a switch between two documents with different paths and positions. Verify that the outgoing path, filename, and position match the visible buffer while the destination is pending and that the destination metadata matches its restored position on the first frame.
