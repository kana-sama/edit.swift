# Control · Go to File

File → Go to File… (⌘P) opens a centered native palette of recent named files and files in the [active folder](../folders/spec.md). The empty query shows [pinned files](../control-pins/spec.md), followed by a single newest-first list of recent files that includes eligible [scratches](../scratch-files/spec.md#go-to-file). Show directories relative to the active folder for its files, including recent ones. Exclude `.DS_Store` from every file query. Type case-insensitive fuzzy terms against the names and directories. Each term must match, terms may appear in any order, and a backslash can escape a literal space. Prefer a matching filename to a matching directory. Highlight the matching characters. Resolve queries off the UI thread and keep outdated rows inert until the latest results arrive. Use the system menu material and one borderless search row with a leading magnifier, text field, and a trailing clear button when a query is present. A thin separator divides the search row from compact results. Inset the rounded system-accent selection and keep the row and shortcut padding balanced across modes. The results area reaches the panel edge and fits whole rows up to the height limit. Match the space after the last row to the inset above the first row. Scroll longer lists without a visible scrollbar.

Up and Down wrap through results. Unmodified Return and row clicks open the selected file in the current window. Escape, ⌘W, and repeated ⌘P dismiss the palette and restore the original focus. While Control has focus, text navigation, clipboard commands, and undo operate on its search field. Document shortcuts such as ⌘Return, ⌘N, and ⌘S have no effect. ⌘F and ⌥⌘F dismiss the palette and focus Find or Replace, and ⌘Q still quits Edit. Clicking outside dismisses the palette and still performs the click. The trailing dismiss control of an active recent row removes it from the shared [recent history](../recent-files/spec.md). An opening error keeps the query and shows the reason.

Swift Edit uses [autosave](../autosave/spec.md) when Control takes focus and when it opens a file. An edited untitled draft gets the save or discard prompt before replacement. Cancel returns to the current buffer.

Control supports [search in both keyboard layouts](../control-keyboard-layouts/spec.md).

For nonempty queries, give results within the search folder a small relevance bonus, greatest at the root and decreasing with depth. The root of an explicit directory query is that directory. Prefer a closer result when text matches are comparable, before considering recency; a clearly better text match can still win. Apply the same ranking to indexed and recent files. Opening a recent alias must not hide a better-ranked path for the same file.

The empty query and file searches use only the [recent files visible in the current project](../recent-files/spec.md), plus existing pins and eligible scratches. Without a folder, search the shared history instead.

## Folder search

The recursive search skips directories whose names start with a dot, plus `node_modules`, `bower_components`, `venv`, `__pycache__`, `DerivedData`, and `zig-out`. Skip `target` next to a `Cargo.toml`. Package contents and symbolic directory links are skipped during the recursive walk.

Apply `.gitignore` patterns to directories, including scoped rules, glob patterns, and exceptions in nested ignore files. When the active folder sits inside a Git repository, use ancestor ignore files up to the repository root. An ignored directory is never traversed by the recursive search. Individual files that match ignore patterns are still searchable if their parent directories are included. The same directory exclusions apply to recent files inside the active folder, including with an empty query.

Type a literal path from the active folder followed by a slash to search within that subfolder. For an ordinary folder, include its searchable descendants. For an excluded folder, show only its direct files and type the next path component followed by a slash to descend. Text after the last slash filters the files in the requested scope.

## Acceptance

Open documents, close one, and open Control. Filter by name and path, navigate in both directions, and open an entry with Return. Check that the file opens in the current window, even if another window has the same path, and that recently deleted paths can be removed. With two results, select the second row and verify that both fit without scrolling. Scroll a long list, then narrow it to two results and check that the list returns to the top. Escape returns to the previous focus. With Control open, verify that ⌘Return does not insert a line, ⌘W closes the palette, and ⌘A and ⌘Z operate on the query.


In a folder containing `a/b`, `a/e/g`, `c`, and `d`, put `a` and `c` in `.gitignore`. Only `c` and `d` are eligible in a recursive search. `a/` shows `b`, and `a/e/` shows `g`. Repeat with a dot directory and with a recent file in an excluded directory.

Create `Sources/Edit/FindCheck.swift` and `Sources/.DS_Store`. Search for `Sources/` and confirm that it lists FindCheck with `Sources/Edit` as its directory. Open FindCheck, then repeat with the empty query and the filename query. The relative directory is the same each time.

With `README.md` at the project root, under a dependency, in another project, and in shared history, open the dependency copy most recently within the project. Searching `readme.md` selects the project-root copy and does not list the other project's recent. Search an explicit directory to move the root of the ranking into it. A stronger exact match still beats a weaker match at the root.
