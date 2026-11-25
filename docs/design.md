# Design

Use standard AppKit window controls, menus, toolbars, file panels, dialogs, and scroll views. Follow macOS appearance, accessibility, focus, and keyboard conventions. Use native sidebar and inspector items in `NSSplitViewController` when a feature calls for them. Let AppKit supply Liquid Glass for system components and use `NSGlassEffectView` for custom controls where appropriate.

Match the corresponding interaction in the current macOS system app by default. A feature specification may define a different interaction when the owner requests it. Use the system reference for the placement of controls, focus changes, keyboard shortcuts, selection, and cancellation as well as appearance.

- For a single item rename, follow Finder. Return edits the name in its row and selects the basename of a file. Return confirms and Escape cancels. In a tree, creating an item starts with an editable row in the destination folder. [Finder rename](https://support.apple.com/guide/mac-help/rename-files-folders-and-disks-on-mac-mchlp1144/27/mac/27)
- For opening files and confirming unsaved changes, use the system file panel and document sheet conventions. Reserve modal confirmation for actions that require a separate decision.
- For sidebars and menus, follow native placement, keyboard navigation, glass materials, and active and inactive selection states. Search and Worktree leave 10 points of space below the last row at the bottom of their scroll areas.

## Document header

Use one compact unified AppKit toolbar with native glass and a fixed icon-only display mode in every document presentation, in windowed and full-screen layouts. The source editor, rendered Markdown, file previews, and historical revisions all scroll under the same header. Wherever content passes beneath it, that content must remain visible through the glass. Use the same scroll-edge treatment when the visible surface changes. Use AppKit’s safe area and automatic scroll insets to place the initial content below the header and let it pass underneath during scrolling. Let the editor’s scroll view extend behind the native sidebar.

Place document-wide status and actions in the existing header row. This includes Read-only, Deleted File, revision details, and conflict controls. Fit essential status and actions in the available width and put secondary details or overflow in a popover anchored to the header. Never add a second row, strip, or panel beneath the header, or a status bar. Preserve vertical space for document content.

Keep the filename whole while any lower-priority element can yield space. Compact the header in this order: collapse Diff / Snapshot to its format menu, shorten Read-only, then shorten the project name, and only then truncate the filename. Keep the Pending Changes control immediately to the left of the format control in Diff mode. Its icon and tooltip indicate that it dims resolved diff fragments.

Present the new document, title, header status, and restored scroll position together on the first rendered frame. Keep the current header and content paired while a replacement is pending. Verify the glass with content visibly passing beneath it, including when entering and leaving preview, and verify that status changes do not change the header height or reduce the document viewport.

Use system appearance, semantic colors, text styles, control metrics, and SF Symbols for interface chrome. Respect platform preferences for contrast and reduced transparency. Keep persistent controls focused on actions the owner needs.

Place context-wide status controls at the trailing edge of the relevant header. Show a control when its context has a matching service or action. Use an icon and a compact status cue for the closed control. Give the icon an accessible name and tooltip. Put per-item names and actions together in the popover, with the identity leading and the actions trailing.

## Anchored hover cards

Every rich tooltip or hover card has a pointer. Its tip meets the edge of the element it describes. Put the arrow in the gap between the element and the card, clear of the element, nearby controls, and the card contents. When space is limited, reposition the card and its arrow together so the arrow still points to the element’s edge.

Use the same revision hover card in the Jujutsu graph and on the Read-only status in the document header. The status is an indicator and reveals the card on hover.

## Sidebar results

Use one content grid for controls and results. Align both edges of the control stack with the first-level file and folder gutter and the trailing count column. For two exclusive modes, use the small native segmented control with equal segments spanning the stack. Give independent text inputs a full row each, with short visible labels and full accessible names. Keep contextual options inside the field they affect. Check the full stack at the sidebar’s minimum width.

Reuse the editor’s existing result component and interaction patterns for new lists of document locations. Match Search’s row spacing, excerpts, highlight treatment, and focus behavior. Align top-level file icons and folder chevrons with the Search controls and Worktree's first level. Indent excerpts slightly past the filename and give separate file groups 8 points of additional space. Keep the full path in the heading tooltip and align subdued count badges 10 points from the trailing edge. When file groups are always open, treat each file heading as a label and skip it in mouse and keyboard selection.

Keep folder and file counts in one column at every nesting depth. A folder count includes all retained results beneath it and stays visible when collapsed. Use the ellipsis menu for the tree layout preference. Reserve space for row actions so excerpts keep the same width when those actions appear.

Clicking a result or moving with the arrow keys selects it and reveals its location while focus stays in the list. Space and Return activate the result and give focus to the editor. Keep the selected row available for subsequent navigation. When the preview goes to another file, update the document and highlighted location together, and apply the latest selection if several previews overlap.

## Pointer cursor

Show the pointing hand as soon as the pointer enters any part of the clickable area of an enabled button, a selectable row in a list or tree, or another explicit click target. Use the foreground control's click area when it overlaps the editor. Include controls in the window titlebar and controls that appear beneath the pointer during hover. Use the arrow over disabled actions and empty chrome, including where text scrolls beneath the titlebar. Selectable text keeps its text cursor, including during inline renaming. Use the system resize cursor across the whole divider grip.

Keep the pointer image steady while clicking, moving between targets that use the same cursor, or updating the content under a stationary pointer. Active drags use their system cursors.

## Asynchronous updates

Flicker, jumps, and unexpected displacement are rendering defects. Keep the last complete presentation visible while preparing its replacement, then install the new presentation in one update. Keep titles, counts, and the content they describe together during the transition. When the visible result is temporarily out of date, give it a short, fixed timeout that repeated requests cannot extend. Suspend actions that need current information while the result is stale. At the timeout, show a stable pending or unavailable state until the current result is ready. Clear an old result immediately if it belongs to a different active context.

Keep line heights, wrapping, and visible text positions stable as background decorations arrive. Put CodeLens and other per-line actions beside their line, outside the text layout. Keep a line’s space for the document text itself.

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
