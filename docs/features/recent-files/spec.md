# Recent files

File → Open Recent lists up to ten [recent folders](../folders/spec.md) and ten eligible recent named files in separate sections, each newest first. The folder list remains a way to switch projects. Paths are absolute, with the home directory abbreviated to `~/`. Choosing an entry opens its file in the current window and follows the same autosave and draft confirmation as Open. Failed or cancelled operations preserve the current editor.

Open Recent and [Go to File](../control/spec.md) use the active project's history together with the shared history. A window without a project shows only shared recent files. A file under a known project root belongs to the innermost such project, including when opened from a different window. Other files belong to the project in which they were opened, or to shared history if opened without a project. When a folder becomes a known project, associate any existing recents under it with that project unless they already belong to an inner project. Use known roots to scope older history that had no project association; older entries that cannot be attributed stay in shared history.

Keep the most recent 500 entries per project and up to 500 shared entries across launches. Successful explicit opens, restored named documents, first saves and Save As promote their paths. Ordinary Save and autosave leave the order alone. Coalesce alternative spellings of a path, symlinks and hard links within each history, keeping the latest path. When combining visible histories, show an item once. Treat a confirmed deletion on the original mounted volume differently from an access error or disconnected volume. Removing an entry does not remove it from another history or change the file or editor.

Read, validate and write the history off the UI thread. Keep the cached menu available during validation and drain pending writes on quit.

## Acceptance

Open more than ten files, including aliases of one file. Verify menu order and deduplication, reopen from the menu, and check that a manual Save leaves the order alone. Create a named buffer with Save and verify it appears. Restart and check history. Delete a historical file and verify it disappears after validation.

Open equally named files in two projects and outside both in a folderless window. Switch between the three windows and verify the file section and both empty and nonempty Go to File queries never include another project's recent files. Repeat after restart. Verify that a legacy archive with known project roots also keeps those projects' files out of shared history.
