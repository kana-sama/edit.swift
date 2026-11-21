# Control · Go to File

File → Go to File… (⌘P) opens a centered native palette of recent named files. The empty query shows the most recent first. Type case-insensitive fuzzy terms against the names and directories. Each term must match, terms may appear in any order, and a backslash can escape a literal space. Prefer a matching filename to a matching directory. Highlight the matching characters. Resolve queries off the UI thread and keep outdated rows inert until the latest results arrive.

Up and Down wrap through results. Return and row clicks open a document or focus its existing window. Esc and repeated ⌘P restore the original focus. Clicking outside dismisses the palette and still performs the click. The trailing dismiss control of an active row removes it from the shared [recent history](../recent-files/spec.md). An opening error keeps the query and shows the reason.

Swift Edit uses [autosave](../autosave/spec.md) when Control takes focus and when it opens a file. A scratch buffer without a path remains available in its window.

## Acceptance

Open documents, close one, and open Control. Filter by name and path, navigate in both directions, and open an entry with Return. Check that an already-open file preserves its window and text, and that recently deleted paths can be removed. Escape returns to the previous focus.
