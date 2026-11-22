# Folder context

File → Open… (⌘O) accepts folders and files. The terminal launchers `edit [path ...]` and `./script/run [path ...]` accept both. A folder opens in the current editor window through the usual autosave and draft confirmation. Cancel keeps its current folder and buffer. A window has one buffer and can have one folder. Opening another folder replaces its context. Opening a file or creating a new buffer keeps the context. File → New Window starts without a folder.

Open the last file opened within the folder if it is readable. Otherwise look for a readable file in the folder root. Match names case-insensitively and try `README.md`, `README`, `README.txt`, then other `README.*` files. If none are available, open an empty untitled buffer. Opening or first saving a file inside the folder updates its remembered file. An outside file leaves it alone.

File → Open Recent shows the ten most recently opened folders before a separator and the ten most recently opened files. Choosing a folder follows the same rules as Open. A folder's remembered file persists across launches and is independent of the menu limit.

With a folder open, a nonempty ⌘P query searches recent files and regular files within the folder according to the [Control folder search rules](../control/spec.md). Clearing the query shows only eligible recent files.

The title bar displays the folder name followed by the current file or “Untitled”. Leave a margin between the sidebar divider and the folder name when the sidebar is visible. Secondary-click or Control-click the folder name for recent folders or the file name for files in the same directory. The native menus align with their title labels and show an icon next to each entry. Drag either label to move the window. Choosing an entry replaces the buffer or folder in that window through the regular Open command. Session restoration reopens the folder alongside the window's current file or draft. If that file is missing or unreadable and there is no draft, keep the folder window open with an untitled buffer.

## Acceptance

- Open a folder using ⌘O and the terminal launcher. Verify window reuse and default README selection. Open another file inside the folder, switch away, and reopen the folder from Open Recent.
- Open a folder with no README and check the untitled buffer. Cancel a folder switch over an edited untitled buffer and check that both its text and folder stay intact.
- Compare ⌘P with an empty query and with a query for a nested file that has never been opened.
- Quit with multiple folder windows, including a named file and an untitled draft. Reopen Edit and verify the folder names, geometry, and buffer contents.
