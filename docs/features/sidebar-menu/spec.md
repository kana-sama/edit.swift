# Sidebar Menu

In a window, an ellipsis button at the right edge of the sidebar header opens a native menu aligned to the button’s right edge. In full screen, the toolbar shows the active sidebar name at the left with a downward chevron. This opens the same menu at the title’s leading edge and keeps the header at the same height. The menu always lists Worktree, Source Control, and Search in that order. Source Control is disabled. The active sidebar is checked. Choosing Search focuses its query field and keeps the current query. [Worktree](../worktree/spec.md) is disabled until the window has an open folder. A separator follows the sidebar list. Search offers Refresh Search, and Worktree offers Show Hidden Files. The menu control appears when the sidebar finishes opening and disappears when it starts closing. Command-B toggles the sidebar in its last mode. Command-F always opens Search and focuses the Find field.

## Acceptance

Open the sidebar and choose Search from the ellipsis menu. Verify that Search is checked, the query stays intact, and the field receives focus. Dismiss a result, then choose Refresh Search below the separator to restore it. Close and reopen the sidebar and verify that the menu button follows its visibility.

Enter full screen and switch between Search and Worktree from the sidebar title. Verify that the title follows the selected panel and that exiting full screen restores the ellipsis.
