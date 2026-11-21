# Find and Replace

Search the current document, including unsaved text, in a native AppKit sidebar. The sidebar belongs to the window, extends behind the title bar beneath the traffic lights, and can be resized. The toolbar places the [sidebar menu](../sidebar-menu/spec.md) above the sidebar and the document title above the editor. Reversing an in-progress transition continues from the current divider position and animates the remaining distance. The editor keeps its selection and scroll position when the sidebar opens, closes, or resizes during a divider drag. It remembers the last query, replacement, options, width, and visibility across launches.

## Search

- Command-F shows the sidebar and focuses Find. A nonempty selection in the editor becomes the query. In regex mode, selected text is escaped so it matches literally. From within the sidebar, Command-F preserves the query.
- Option-Command-F expands Replace and focuses its input. Command-B toggles the sidebar and keeps editor focus when opening from the editor. Escape from either input hides the panel and returns focus to the editor.
- Find and Replace use compact, aligned fields. The Find field includes Case, Whole Word, and Regex toggles. One focus outline surrounds the active field and any toggles it contains. The buttons beside the fields expand replacement and apply Replace All. Both fields accept multiline input using Shift-Return or paste, grow while space is available, and scroll for longer text. Field undo is independent of document undo.
- Search lists one row per nonoverlapping match in document order, grouped under the filename and its icon. The fields and excerpts use the editor’s monospaced font at its default size. Excerpts highlight the matched text and truncate long lines on one row at the font’s regular character spacing. Hover and selection keep the excerpt width fixed. The reserved Dismiss button sits at the right edge, with a slot for Replace to its left when Replace is open. Case, Whole Word, and Regex options apply to the current buffer. Literal whole-word search treats Unicode letters, numbers, and underscore as part of a word. Regular expressions use Foundation's ICU matcher and accept Rust-style named groups.
- Search runs in the background. Old rows remain visible while fresh results are pending. Pending rows cannot edit the buffer. Results from earlier queries or document revisions are discarded. Invalid regex disables navigation and replacement.
- Command-G and Shift-Command-G move to the next or previous match and wrap, including when the panel is hidden. Return in Find moves forward. Selecting a result reveals and highlights that match in the editor. Only the active match uses the active highlight. Other visible matches, including the previously active one, retain the regular search highlight. Double-clicking a result focuses the editor, clears any replacement preview, and places a single caret after the match.
- Dismiss excludes one match from search navigation and replacement. An unrelated edit or replacement preserves valid dismissals. Refresh, changing the query or options, or replacing the document clears them.

## Replace

- Return in Replace focuses the first result and reveals its replacement preview. Moving through the results with Replace open previews each selected match in the editor using the old and proposed text on separate colored rows. The preview aligns with the surrounding text. It emphasizes the changed span within each line and temporarily reserves display space so the following source line remains visible. Clearing the preview restores the original spacing. It leaves file contents, dirty state, and undo history intact.
- Apply one result with its row button or Return on the focused row. After replacement, focus the next retained match beyond the inserted text if one exists. Replace All applies the retained matches in one undoable edit. An empty replacement removes the matched text.
- Regex replacements support numbered captures, named captures, and a doubled dollar for a literal dollar. Edits made with Find and Replace request the existing autosave.
- Escape on a result clears its selection and preview and focuses Find. Returning to the editor, collapsing Replace, refreshing, or hiding the panel also clears the preview.

Command Mode exposes refresh, option toggles, replacement, and result actions when the sidebar can perform them. Direct Command-B leaves an open Control palette available. Direct Command-F dismisses Control and focuses Find.

## Acceptance

- Search multiple matches on one line and across lines. Verify Unicode whole-word matching, named captures, and the invalid regex state.
- Dismiss one of three matches, replace one of the others, then Replace All. Confirm the dismissed text remains, Undo reverses each operation, and Refresh restores the dismissed occurrence.
- Select consecutive results in a syntax-colored file, then navigate to matches beyond the visible area and back. Confirm that the editor paints only the selected match with the active color. Double-click a result with Replace open and confirm that focus moves to the editor and the caret lands after the match. Verify that the preview and navigation leave the buffer unchanged and Command-G works with the panel hidden.
- With a long unwrapped line, open and close the sidebar and drag its divider. Repeat from the editor’s left edge and from a horizontally scrolled position. Verify the text keeps its position, long excerpts stay on one row at the narrowest sidebar width, and the next editor line remains visible during preview.
- Reopen the sidebar partway through closing, then close it partway through opening. The sidebar changes direction without jumping and reaches its previous width when reopened. Resize and reopen the sidebar, restart Edit, and verify that its query, options, replacement, visibility, and width are restored.
