# Navigation history

Use **Go Back** with Control-Minus and **Go Forward** with Control-Shift-Minus. Expose both commands in the Go menu and Control. Follow the unfiltered Go Back and Go Forward stack in VS Code on macOS. [VS Code macOS shortcuts](https://code.visualstudio.com/shortcuts/keyboard-shortcuts-macos.pdf) · [VS Code history stack](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/history/browser/historyService.ts)

## Recording locations

- Each window keeps its own history of up to 50 locations. Record explicit file opens, editor changes, primary selection changes and edits, and explicit navigation jumps within that window. Switching focus between windows leaves their histories independent. Discard a window's history when it closes.
- Compare selections by their first line. An update on the same line replaces the current location. An ordinary move or edit less than ten lines away also replaces it. A move of ten or more lines adds a stop. An explicit jump to a different line adds a stop even when the destination is nearby. Switching to another editor or file adds a stop. [VS Code selection comparison](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/textEditor.ts#L321-L352)
- A definition jump records the clicked position and the destination. Selecting a row in a results sidebar only previews it. Activating a reference commits the navigation from the source symbol to the selected result. [Definition link](../lsp/spec.md#cmd-hover-and-cmd-click) · [References](../lsp/spec.md#references-in-the-sidebar)

## Going back and forward

- Go Back and Go Forward move the history pointer in the window where the command was invoked. Restore the exact primary selection, including its direction. Keep the viewport when the selection is already exposed. Center it when it is outside the visible viewport. Reopen a file in that same window through the normal file-opening and save flow when necessary. A cancelled open keeps the history position.
- Replaying a location leaves the history entries in place. A new stop after Go Back removes that window's forward branch. Refining the current stop preserves it. Disable each command at its end of the current window's stack.
- Follow Worktree renames and moves, and remove locations for files moved to Trash. Skip a closed untitled buffer or a missing file so the next reachable stop remains usable. If replay requests overlap in one window, the latest request in that window controls its visible result. Each window completes its own request without moving focus between windows.

## Acceptance

- Open two files and navigate back and forward with the macOS shortcuts. Verify the file and exact selection restore. Repeat with a definition jump and check that Back returns to the clicked position.
- Open two windows and create distinct navigation stops in both. Use Back and Forward in each window and verify that the other window retains its file, selection, and history position. Check each command at both ends of a window's stack while the other window still has destinations. Hold a cross-file Back transition in one window and use Back in the other. Verify the pending window keeps its current title and content until the restored file and title can appear together.
- Move within a line, move by fewer than ten lines, then by exactly ten lines. Verify the history stops match those cases. Navigate back, make a nearby move, and verify Forward is available. Add a new stop and verify Forward becomes unavailable.
- Select a reference in another file and verify that preview keeps focus in the list. Activate it and verify Back returns to the originating symbol. Repeat with a renamed or missing file and with a cancelled file open.
