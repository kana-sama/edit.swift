# Autosave

Autosave writes changed text to the current file in the background. A buffer is eligible when it has a path and a known on-disk revision, including a known missing file opened by path. An untitled draft becomes eligible after its first successful Save. Autosave preserves the current encoding, byte order mark, and line endings through the same writer used by Save.

## Triggers

- Save after one second without a text edit. A new edit restarts the timer. Wait for marked input from a macOS input method to commit before a background write.
- Request an immediate save when focus leaves the editor, when a window loses focus or minimizes, and when a native menu or file picker opens.
- Actions that leave the editing context can request the same background save. New, Close, and Quit finish pending writes and attempt an autosave before changing buffers or recording the session. See [Files](../files/spec.md) for the prompts and draft recovery.

## Writes and errors

- Coalesce repeated requests and serialize them with explicit saves. Save a snapshot of the buffer and retain the edited marker when newer text has arrived. The next eligible request writes the newer text. A clean buffer needs no write.
- Preserve local text and the current on-disk version if a file has changed externally, disappeared, or cannot be written. Report a background write error when Edit is active and its window can show an alert. Avoid repeating the same error for the same edit. Explicit Save still offers to replace an external version. If Quit leaves unsaved text, record it in the session.

## Acceptance

- Edit a named file with a BOM and CRLF endings. Verify the file is unchanged while typing and is written after the idle interval. Then edit and move focus to another window, another app, or a menu. Verify the write happens without waiting for idle.
- Request a background write, edit again, and explicitly save. Verify the newest text reaches disk and the editor reflects the saved revision.
- Open a file, modify it externally, then try autosaving local edits. Verify the original buffer and external version are both retained. Close or replace it and verify the expected confirmation.
- Quit with dirty named and untitled buffers. Verify successful named writes are on disk and remaining text is restored from the session.
