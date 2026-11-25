# Markdown table commands

Expose the following commands in [Control Command Mode](../control-commands/spec.md) when the primary caret is in a valid GFM table in a writable buffer whose effective syntax is Markdown. Resolve the table, row, and column from the originating editor when the command runs. Apply the operation to that table as one undoable edit and leave the result in source editing. When a [Focus](../focus/spec.md) scope is active, offer the operation only if its changes fit inside the scope. [GFM tables](https://github.github.com/gfm/#tables-extension-)

| Command | Result |
| --- | --- |
| **Markdown: format table** | Align the source column separators with spaces, using the widest cell that belongs to each column. Preserve the separator row's alignment markers and the table's outer-pipe style. |
| **Markdown: insert table row below** | Insert one empty body row below the current row. From the header or separator, insert the first body row. Place the caret in the new row in the current column. |
| **Markdown: insert table column left** | Insert an empty column before the current column in every row, including the header. Add a neutral separator for it and place the caret in the new cell on the current row. |
| **Markdown: insert table column right** | Insert an empty column after the current column using the same rules. |
| **Markdown: toggle table borders** | Switch the whole table between rows with both outer `\|` markers and rows without them. Keep all inner column separators. An inconsistent table gets outer markers on every row. A single-column table keeps enough pipe syntax to remain a GFM table. |

Use the table syntax to identify separators. Preserve escaped pipes, inline code, other cell markup, row prefixes and indentation, and existing line endings. An extra cell in a body row stays in the source even where GFM omits it in preview. Align newly inserted cells with the surrounding table. On formatting or toggling, keep the caret in its logical cell and as close as possible to its original offset within the cell. Preserve the surrounding document and retain it through undo and redo.

## Acceptance

- Format a table containing uneven padding, left, center, and right alignment markers, Unicode, escaped pipes, and inline code. Verify that separators align in the editor and the table keeps its rendered cell content and alignment. Undo and redo the operation.
- Insert a row from the header, separator, middle, and last body row. Insert a column at each edge and in the middle. Verify that the table remains valid and the caret lands in the inserted row or column.
- Toggle borders twice on tables with and without outer pipes. Try mixed outer pipes and a single-column table. Check that escaped pipes and surrounding paragraphs stay intact and that the result remains a valid table.
- Recheck availability with the caret outside the table, inside a fenced example, in a malformed table, in a read-only revision, and with a Focus scope that prevents the full edit. Verify source commands from Control act on the editor that opened it.
