# Design

Use standard AppKit window controls, menus, toolbars, file panels, dialogs, and scroll views. Follow macOS appearance, accessibility, focus, and keyboard conventions. Use native sidebar and inspector items in `NSSplitViewController` when a feature calls for them. Let AppKit supply Liquid Glass for system components and use `NSGlassEffectView` for custom controls where appropriate.

Match the corresponding interaction in the current macOS system app by default. A feature specification may define a different interaction when the owner requests it. Use the system reference for the placement of controls, focus changes, keyboard shortcuts, selection, and cancellation as well as appearance.

- For a single item rename, follow Finder. Return edits the name in its row and selects the basename of a file. Return confirms and Escape cancels. In a tree, creating an item starts with an editable row in the destination folder. [Finder rename](https://support.apple.com/guide/mac-help/rename-files-folders-and-disks-on-mac-mchlp1144/27/mac/27)
- For opening files and confirming unsaved changes, use the system file panel and document sheet conventions. Reserve modal confirmation for actions that require a separate decision.
- For sidebars and menus, follow native placement, keyboard navigation, glass materials, and active and inactive selection states. Search and Worktree leave 10 points of space below the last row at the bottom of their scroll areas.

Document windows use the compact unified AppKit toolbar with a fixed icon-only display. Let editor content scroll beneath the filename and system window buttons to receive the native scroll-edge material. Let the editor’s scroll view extend behind the native sidebar. Use AppKit’s safe area and automatic scroll insets so text begins in the exposed area and can pass under the titlebar and sidebar during scrolling.

Use system appearance, semantic colors, text styles, control metrics, and SF Symbols for interface chrome. Respect platform preferences for contrast and reduced transparency. Keep persistent controls focused on actions the owner needs.

## Pointer cursor

Show the pointing hand across the entire clickable area of an enabled button, a selectable row in a list or tree, or another explicit click target. Use the foreground control's click area when it overlaps the editor. Disabled actions and empty areas use the default cursor. Selectable text keeps its text cursor, including during inline renaming. Dragging and resizing use the corresponding system cursors.

## Asynchronous updates

Flicker is a rendering defect. Keep the last complete presentation visible while preparing its replacement, then install the new presentation in one update. When the visible result is temporarily out of date, give it a short, fixed timeout that repeated requests cannot extend. Suspend actions that need current information while the result is stale. At the timeout, show a stable pending or unavailable state until the current result is ready. Clear an old result immediately if it belongs to a different active context.

File Preview keeps the current document and title together until the next preview is ready. Syntax highlighting keeps the existing colors while a new parse runs. Go to File keeps previous results visible and disables opening them while the next query runs. [File Preview](features/file-preview/spec.md) · [Syntax highlighting](features/syntax-highlighting/spec.md) · [Go to File](features/control/spec.md)

## Verifying native interactions

Before implementing or changing an interaction, identify the closest system app and the equivalent view on the supported macOS release. Use Finder list view for a file tree. Follow the system app for layout, controls, feedback, keyboard access, and state transitions. Record any owner-requested exception in the feature specification.

1. Start with Apple’s user guide for the actual commands, then consult the Human Interface Guidelines and the framework documentation for the matching controls. Use an existing system control wherever it supplies the behavior.
2. Reproduce the action in the system app with disposable data. Exercise the keyboard, the relevant mouse or context-menu path, and the sequence immediately after the action. For selection and focus, record where focus starts and ends, which rows are selected, and what the next key does. Include relevant boundaries such as the first and last row, an empty list, multiple selection, cancellation, and undo or redo. For scrolling, resizing, and animation, observe intermediate frames as well as the settled state.
3. Put the repeatable steps, macOS version, expected results, and primary source links in the feature specification when they affect the implementation. Identify observations, explicit product decisions, and states that still need verification. Keep the reference and test data disposable.
4. Repeat the sequence in a running AppKit instance of Edit. Compare the starting, intermediate, and final states with the reference. Assert the affected focus, selection, visible rows, or geometry in the native check when a regression can otherwise pass. Report the tested sequence and any remaining verification gap.

For file-list checks, create a disposable folder and open it in Finder when the reference window can be used without interrupting ongoing work.

```bash
finder_fixture="$(mktemp -d "${TMPDIR%/}/edit-finder.XXXXXX")"
mkdir -p "$finder_fixture/Folder/Nested" "$finder_fixture/OtherFolder"
touch "$finder_fixture/"{A,B,C,D,E}.txt "$finder_fixture/Folder/Nested/Child.txt" "$finder_fixture/OtherFolder/Child.txt"
open -a Finder "$finder_fixture"
```

Use Command-2 for list view and sort by name. Select C, E, B through C, B and D, B and E, and then all items in separate trials. Use Shift-click for ranges and Command-click for separate rows. Exercise Command-Delete and contextual Move to Trash, check selection with Up or Down, and repeat with Command-Z and Shift-Command-Z. Select both folders and press Right and Left, then repeat with a file also selected. Test the first expansion and a second expansion of the same branch. With a descendant already expanded, collapse and reopen its parent. Use Return, type another name, and press Escape. Then commit a rename and press Command-Z and Shift-Command-Z. Check the focused control and selected row after each action. Use the same boundaries and selection order in Edit. [Mac keyboard shortcuts](https://support.apple.com/102650) · [Select items](https://support.apple.com/guide/mac-help/select-items-mchlp1378/mac)

Record app-wide visual rules here when they are used across features. Record the feature's layout, controls, and interaction states in its own specification.
