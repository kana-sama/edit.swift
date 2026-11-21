# Recent files

File → Open Recent lists ten named files, newest first, using absolute paths with the home directory abbreviated to `~/`. Choosing an entry opens its file in the current window and follows the same autosave and draft confirmation as Open. Failed or cancelled operations preserve the current editor.

Keep the most recent 500 entries across launches. Successful explicit opens, restored named documents, first saves and Save As promote their paths. Ordinary Save and autosave leave the order alone. Coalesce alternative spellings of a path, symlinks and hard links, keeping the latest path. Treat a confirmed deletion on the original mounted volume differently from an access error or disconnected volume. Removing an entry leaves the file and editor alone.

Read, validate and write the history off the UI thread. Keep the cached menu available during validation and drain pending writes on quit.

## Acceptance

Open more than ten files, including aliases of one file. Verify menu order and deduplication, reopen from the menu, and check that a manual Save leaves the order alone. Create a named buffer with Save and verify it appears. Restart and check history. Delete a historical file and verify it disappears after validation.
