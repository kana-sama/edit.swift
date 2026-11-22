# Folder context

File → Open… (⌘O) accepts folders and files. The terminal launchers `edit [path ...]` and `./script/run [path ...]` accept both. A folder opens in the current editor window through the usual autosave and draft confirmation. Cancel keeps its current folder and buffer. A window can have one document and one folder context. Opening another folder replaces its context. Opening a file or creating a new buffer keeps the context. File → New Window starts without a folder.

Open the last file opened within the folder if it is readable. Otherwise show **No File Open** in the center of the document area with **Press ⌘P to open a file.** and **Press ⌘W to close the folder.** The screen has no editable document. The owner can open a file from it or create an untitled document with ⌘N. Opening or first saving a file inside the folder updates its remembered file. An outside file leaves it alone.

⌘W and the window’s close button close the current file, preview, or untitled document and show **No File Open** in the same folder window. Finish autosave and handle any unsaved changes through the usual [close rules](../files/spec.md#new-close-and-restore). Cancel leaves the current document open. From **No File Open**, the next close action closes the window and its folder context. Holding ⌘W performs at most one step.

File → Open Recent shows the ten most recently opened folders before a separator and the ten most recently opened files. Choosing a folder follows the same rules as Open. A folder's remembered file persists across launches and is independent of the menu limit.

With a folder open, a nonempty ⌘P query searches recent files and regular files within the folder according to the [Control folder search rules](../control/spec.md). Clearing the query shows eligible pins followed by recent files, including [recent scratches associated with that folder](../scratch-files/spec.md#go-to-file).

The title bar displays the folder name. An open document adds its file name or “Untitled”. Secondary-click or Control-click the folder name for recent folders or the file name for files in the same directory, including when the toolbar is revealed in full screen. The native menus align with their title labels and show an icon next to each entry. Drag either label to move the window. Choosing an entry replaces the buffer or folder in that window through the regular Open command. Session restoration reopens the folder with its current document, draft, or empty screen. If the current file is missing or unreadable and there is no draft, show **No File Open** in the restored folder window.

## Acceptance

- Open a folder containing a README using ⌘O and the terminal launcher. Verify window reuse, the empty screen, and both shortcuts. Open a file inside the folder, switch away, and reopen the folder from Open Recent to recover that file. Delete the remembered file, then reopen the folder to check the empty screen again.
- Close an edited file in a folder window and verify its edits reach disk and the window stays open on **No File Open**. Close again to close the window. Repeat with the window’s close button. Invoke ⌘N on the empty screen, edit the new draft, and cancel a close and a folder switch to check that both its text and folder stay intact.
- Compare ⌘P with an empty query and with a query for a nested file that has never been opened.
- Quit with multiple folder windows, including a named file, an untitled draft, and the empty screen of a folder that remembers a file. Reopen Edit and verify the folder names, geometry, and contents of each window.
