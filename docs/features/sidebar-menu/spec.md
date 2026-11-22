# Sidebar Menu

The sidebar header shows a semibold title with a downward chevron at its leading edge in both regular windows and full screen. The title opens the native sidebar switcher aligned with its leading edge. The switcher lists Worktree, Source Control, and Search in that order. Source Control is disabled, and the active sidebar is checked. Choosing Search focuses its query field and keeps the current query. [Worktree](../worktree/spec.md) is disabled until the window has an open folder.

A borderless ellipsis at the trailing edge opens the native menu for the active panel, aligned with the button's trailing edge. Search offers Refresh Search. Worktree offers New File and New Folder for the open folder, followed by Show Hidden Files. The ellipsis appears when the panel has actions. The sidebar's minimum width is 200 points so both controls fit beside the window buttons. The header controls appear when the sidebar finishes opening and disappear when it starts closing. Command-B toggles the sidebar in its last mode. Command-F focuses Search and Shift-Command-E focuses Worktree. Both shortcuts switch to their panel and reveal the sidebar if hidden. Press the same shortcut while focus is in that panel to return to the previous responder or to the editor, with the sidebar still visible.

## Acceptance

Open the sidebar and choose Search from the title menu. Verify that Search is checked, the query stays intact, and the field receives focus. Dismiss a result, then choose Refresh Search from the ellipsis menu to restore it. Close and reopen the sidebar and verify that the menu button follows its visibility.

Switch between Search and Worktree in a window and in full screen. Verify that the title follows the selected panel and that the ellipsis lists that panel's actions. Check that both controls fit on the narrowest sidebar.
