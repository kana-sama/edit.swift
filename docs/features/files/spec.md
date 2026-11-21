# Files

Edit opens and saves UTF-8 regular files. Each window has one document and shows its file’s basename or “Untitled” in the title bar. macOS indicates unsaved changes in the window’s close button. Each window uses the text surface and editing commands in the [Editor specification](../editor/spec.md).

## Open and save

- Use Command-O to select one or more files in the native open panel. Finder’s Open With menu and `./script/run [file ...]` also open existing files. Paths passed to the launcher are relative to the caller’s directory. Open requests reuse the running app and focus a file’s window if it is already open.
- To edit a file that does not exist yet, pass its path to the app bundle’s executable. The parent directory must exist. The document starts empty and the file is created on Save or when the edited buffer autosaves.
- Use Command-S to save to the current path, or select a path in the native save panel for an untitled document. Use Shift-Command-S to save under a new name. Cancel either panel to continue editing with the same text and document path.
- Opening and saving preserves the UTF-8 byte order mark if present and preserves existing line endings. Show an error when a file is missing, unreadable, or invalid UTF-8. If a file on disk has changed or been removed since opening or saving it, ask before saving to that path.

## New, close, and restore

- Command-N replaces the current document with an empty untitled buffer in the same window. Preserve the window and its geometry, reset the selection and undo history, and focus the editor. Command-Shift-N or File → New Window opens a separate empty editor window.
- Before New or Close, let any pending write finish and [autosave](../autosave/spec.md) the outgoing named document. If the buffer is still edited, use the appropriate confirmation below. Cancel or a failed manual save keeps the current buffer.
- Command-W closes the current window. When closing or replacing an edited untitled document, use one native save sheet with a filename, destination, and Save, Delete, and Cancel actions. Show UTF-8 as the fixed encoding. Hide the Tags field and the extension option. Delete discards the draft without writing a file.
- For a document with a path and edits left after autosave, offer Save, Don’t Save, and Cancel. Closing after Save requires a successful write. Cancel keeps the current window and changes. Closing the last window exits Edit and remembers its frame for the next new window.
- Command-Q finishes pending writes, attempts autosave for dirty named buffers, and atomically saves the session, including open windows, the active window, and any remaining drafts. On relaunch, load clean files from disk and restore unsaved text from the drafts. Report files that are missing or unreadable.
- Restore each window’s position, size, and full-screen state. Remember the normal window frame when a window goes full screen. If a saved frame is off the available displays, restore the window on an available screen.

## Acceptance

- Open and save a UTF-8 file with a BOM and mixed line endings. Edit its text, then check that the BOM and existing line breaks survive saving.
- Open existing files from the native panel, Finder, and the terminal. Run the launcher from a different directory with a relative path that includes spaces. Open the same file twice and confirm that its existing window is focused.
- Create an untitled document, cancel the save panel, then save it. Use Save As to continue editing a second file. Pass a new path to the app executable and verify that Save creates the file even when its buffer is empty.
- Modify or remove an open file externally and attempt to save. Cancel the confirmation and verify the document stays open with its edits. Check all three choices when closing a modified window.
- From a dirty named buffer press Command-N and verify the same window becomes untitled after its file is written. Repeat with an edited untitled buffer and cancel to keep the text. Use Command-Shift-N and verify a separate empty window opens.
- Close an edited untitled document. Check that the initial filename is Untitled.txt and that the native sheet lets you choose a destination, save and close, discard the draft, or cancel and keep editing.
- Quit with clean and dirty documents, including an untitled draft and a full-screen window. Verify that eligible named edits reach disk and that untitled or failed named writes are recoverable as drafts. Relaunch and check the drafts, the saved documents, the active window, and window geometry.
