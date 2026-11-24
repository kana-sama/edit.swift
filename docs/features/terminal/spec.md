# Embedded Terminal

Run local shell commands alongside the current buffer. Each Edit window owns its terminal panel and spaces. The bottom dock uses the same regular Liquid Glass as the sidebars across the exposed width of the editor and ends at the leading sidebar when it is open. Editor text can scroll underneath both the leading sidebar and the bottom dock. Scroll insets keep the start of lines, the caret, and the end of the file reachable in the exposed editor. Dock Right moves the terminal into a native trailing glass sidebar that spans the window from top to bottom. The terminal header controls sit over that sidebar in the title bar. The dividers between the editor and its open sidebars continue through the title bar in regular windows and full screen, including when the macOS window buttons appear or hide. The dividers and toolbar sections stay aligned as the sidebars resize. The leading sidebar continues to follow the [Sidebar Menu layout](../sidebar-menu/spec.md) in either dock position and in full screen.

Use the native tracking separators when the split view and toolbar share a full-size content window. When AppKit moves the toolbar into a separate full-screen window, continue the visible sidebar edges through the toolbar at their screen positions. [AppKit tracking separators](https://developer.apple.com/documentation/appkit/nstrackingseparatortoolbaritem)

## Open, hide, and focus

Control plus the physical key above Tab works across keyboard layouts. If a terminal pane has focus, the shortcut hides the panel and returns focus to the buffer or file preview. If focus is in the editor, a sidebar, Control, or another control, it focuses the last-used terminal in the current space and reveals the panel if necessary. From Control it also dismisses the palette. Holding the shortcut does not repeat the action. View → Toggle Terminal shows or hides the panel directly.

Showing the panel for the first time starts a shell in a space with one terminal. Hiding the panel, changing its dock position, and switching spaces preserve the existing shells, scrollback, and layout.

The terminal panel opens and closes immediately in either dock position, in a window and in full screen. The right sidebar’s header appears and disappears with the panel.

## Quit and reopen

On Quit, save each open window’s terminal panel with its editor session. Restore the panel’s visibility, dock side, remembered size in each dock position, and whether it had focus. When reopening a full-screen window, apply the saved panel dimensions after the window enters full screen. Keep the right sidebar’s width in points, within the space available at the restored window size. Restore the spaces in order with their names, split trees and divider positions, selected space, and last-used terminal in each space. Restore each terminal’s last known working directory, text size, wrapping preference, recent history, and both scroll positions. A hidden panel stays hidden and can be shown with its layout and history intact.

Keep up to 2,000 recent scrollback rows and the last visible alternate screen in the private session file. Save up to 256 KiB of text per terminal with a bounded set of color and style changes for the newest output. Reopening preserves ANSI palette colors and true-color text. Unstyled text follows the current terminal appearance. Older sessions saved as plain text still reopen.

Leave the trailing input prompt out of saved history when its single line is identified by OSC 133 or matches the prompt observed at shell startup while bracketed paste is enabled. Preserve output, lines with typed input, and history saved by older versions.

Quitting ends the shell processes. Reopening Edit starts a fresh login shell in every saved pane, including hidden panels and unselected spaces. Replay the saved output before the shell starts. Use the saved directory when available and the home directory if it no longer exists. Closing an individual window closes its terminal spaces. If a file is missing at startup, keep its window available when it has terminal history to restore.

## Spaces and splits

Use the space picker to switch spaces. The plus and minus buttons sit side by side in the panel header. Plus starts a new space with a single terminal. Minus asks for confirmation before closing all terminals in the selected space. Focus the next available space after deletion. If the final space is deleted, the plus button and terminal shortcut can start a new one.

Each space owns its layout and remembers its most recently focused terminal. Its title combines the foreground program names and current folder names of idle shells in pane order, listing each name once. Folder and foreground changes update the picker automatically. Different spaces can share a title and remain individually selectable.

Place Split Terminal Right and Split Terminal Down beside plus and minus in both dock positions. Each button splits the current space’s last-focused terminal, keeps the source shell running, starts a shell in the new pane and focuses it. In Control Command Mode, show the same actions if the original responder was a terminal pane. Splits may nest. Click the terminal surface to change pane focus. Drag the divider beside the editor to size the panel, or the shared edge between adjacent terminals to resize that split. Terminal panes have no individual title bars.

The bottom panel keeps its chosen height in points when the window resizes. If the buffer and panel cannot both fit, the panel shrinks temporarily and returns to its chosen height as space becomes available. Session saving remembers the chosen height during temporary compression.

Every terminal pane has a one-point gray border, flush with the panel at its outer edges. At a window corner the border follows the window’s curve. Adjacent panes share one border that also acts as the divider. The focused pane uses the system accent color on its border. The border keeps the same thickness, so pane frames, dividers, and terminal grid sizes stay fixed when focus moves.

## Shell and display

SwiftTerm renders the terminal and runs the account's login shell in a local PTY. Start in the window's folder, the current file's containing directory, or the user's home directory, in that order. A split starts in the source terminal's working directory when the shell has reported it. [SwiftTerm 1.99.3 local terminal view](https://github.com/migueldeicaza/SwiftTerm/blob/282c3c3a932b55c129628876b70f37d993af1615/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift)

When a shell exits or fails to start, its pane closes and any sibling takes up the space it leaves. An empty space closes, and if it was selected, the next available space becomes selected. If the last terminal closes, the panel hides. When the exiting pane had focus, focus moves to another terminal or back to the buffer or file preview if the panel hides.

The header's ellipsis opens a placement picker with two labeled window miniatures, Dock Below and Dock Right. A short pointer aims at the center of the ellipsis, above the picker in the right dock and below it in the bottom dock when there is room. Keep the picker within the display and its corners rounded, including near the edge of the screen. The current dock is outlined in the system accent color. Choose a miniature to move the whole terminal panel. The PTYs and their history stay open.

The terminal's context menu offers Copy, Paste, Split Terminal Right, Split Terminal Down, Wrap Lines, Clear Terminal, and Kill Terminal. Each action targets the clicked pane. Splitting focuses the new pane in the same space. Copy uses its selection and Paste sends clipboard text to its running PTY. Clear Terminal uses the same behavior as Command-K. Kill Terminal closes the pane and terminates its session. Use Shift with the contextual click if a terminal application has taken over mouse events.

Terminals wrap to the pane width by default. Turning Wrap Lines off gives the current terminal at least 240 columns and widens it further for longer recent lines. When the terminal is wider than the pane, scroll horizontally over that pane with the trackpad or the scrollbar. A diagonal gesture follows its dominant axis. The PTY wraps at the terminal's full width.

With a terminal focused, Option-Z expands it to fit the longest recent wrapped line when that line exceeds the current width. Press Option-Z again to wrap to the pane width. Command-K clears output and scrollback in the focused terminal, moving the current input line to the top while the shell keeps running. When a full-screen program uses the alternate screen, Command-K clears that screen and preserves the normal buffer. These shortcuts follow VS Code’s [content-width toggle](https://code.visualstudio.com/docs/terminal/basics#_fixed-dimension-terminals) and [clear shortcut](https://code.visualstudio.com/docs/terminal/advanced#_macos-clear-screen).

With a terminal focused, Command-Plus or Command-Equal increases its text size, Command-Minus decreases it, and Command-0 restores the default. Size changes apply only to that terminal. Start at 12 points and change by one point within the editor's 6 to 72 point range.

## Acceptance

- From the buffer, open the terminal with Control plus the key above Tab. Click the buffer or the left sidebar and use the shortcut again. The panel stays open and the last terminal receives focus. Repeat from Control, then use the shortcut in the terminal to hide it and again to restore the same terminal.
- Open and hide the terminal in each dock position, in a window and in full screen. Check that the panel and its header switch immediately, the terminal returns at its saved size, and focus goes to the right place.
- With a project folder open, run `pwd` and check the starting directory. Run a command and dock the panel on the right. Check that both sidebars have their controls in the title bar. Resize it and dock it below again. Check that glass covers the bottom panel to its edges and that the command output and shell are still available.
- With both sidebars open and the terminal docked right, enter full screen, reveal the window buttons, then exit full screen. Check that each vertical line in the title bar is one physical pixel wide and at the same horizontal pixel as its sidebar edge below. Both sidebars keep their controls, and the terminal keeps its layout and focus.
- Open Control from a terminal and split right, then split the new terminal down. Click each pane and verify that the accent outline follows focus while dividers and text stay in place. Drag the dividers to verify both axes. Open Control from the buffer and check that the split commands are unavailable.
- Use the header buttons to split right in the bottom dock and down in the right dock. Check that each action focuses the new pane. Narrow the right sidebar to its minimum and check that both split buttons, the space controls, and the options menu remain visible.
- Set the bottom panel's height using its divider, then resize the window. Check that the height stays fixed until the buffer needs more space. Shrink the window further, then enlarge it and check that the panel recovers its chosen height.
- Open the leading sidebar and bottom terminal over a buffer with long lines. Compare their glass over the editor background in dark and light appearance. Scroll in both directions and check that text moves under both glass surfaces. The bottom dock starts at the sidebar edge, and a terminal border at a window corner follows its shape.
- Add a second space and switch between spaces with the same folder title. Change folders in a shell, launch a foreground app, then exit it. Verify the title updates and each space keeps its panes and last focus. Cancel a deletion from the minus button next to plus, then confirm it and verify that the other space still works.
- Open the dock picker in both positions near the right edge of the display. Check that its pointer faces the ellipsis and stays distinct from the rounded corner. Choose each miniature and check the selected outline and that the same sessions move with the panel. Right-click a pane and verify that Copy, Paste, both split commands, Wrap Lines, Clear Terminal, and Kill Terminal target that pane.
- With two panes in a space, change the font size and wrapping in one pane. Observe both panes and reset the changed pane with Command-0. Check editor zoom with the buffer focused.
- Print a line wider than the pane, press Option-Z, and scroll to the end of that line. Press Option-Z again to fit the pane. Press Command-K with the terminal focused and check that the current input remains and previous output is gone.
- Run `exit` in a split and check that the sibling expands with its shell still running. Exit the remaining shells and check that the panel hides. Open it again to start a new shell.
- Print indexed and true-color text on the same terminal line, then print default-color text. Quit with one terminal panel visible and another hidden. Reopen Edit and check dock positions, panel sizes, space order, divider positions, focus, text size, wrap and history, including all three colors. Verify that the restored terminals accept commands immediately, including when revealing a hidden panel or switching spaces. Run `pwd` to check the saved directory. Quit again and verify that the remaining history survives.
- In full screen, dock the terminal on the right, resize the sidebar, and split it down. Quit and reopen Edit. Once the window enters full screen, check that the sidebar width and split divider match their saved positions.
