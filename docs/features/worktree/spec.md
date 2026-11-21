# Worktree sidebar

Worktree browses the contents of the folder open in the current window. Use Shift-Command-E or the sidebar’s menu to show it. The shortcut hides Worktree when it is already visible. The Search and Worktree modes share the native, full-height sidebar. Each window restores its mode and visibility independently.

The native outline shows folders before files, with one level loaded at a time. Open a file with a double-click or Return in the tree. It replaces the current buffer through the normal opening and autosave flow. The current file is marked and its parent folders are expanded. An open file outside the worktree appears with its parent path below the worktree.

Files and folders matched by .gitignore appear in gray. By default, the tree hides dotfiles, Finder-hidden items, and paths hidden through the context menu. The Worktree toolbar menu has a Show Hidden Files toggle. Manually hidden paths are remembered for that worktree. The current file and its ancestors remain visible regardless of these filters.

The context menu reveals items in Finder, copies items or their paths, pastes files, opens files with registered apps, renames items, and moves them to the Trash. The folder menu creates files or folders from relative names that may contain subfolders. Directory changes are reflected while the tree is visible. File operations keep open buffers associated with their new paths after a rename or move.

Drag files and folders between folders in Edit, or use Option to copy them. Drops from other apps copy items into the target folder. Drag out of Edit to share standard file URLs with other apps. Existing destination items are protected from being overwritten.

## Acceptance

Open Worktree in a folder and switch between it and Search. Hide a folder containing the active file, and confirm its path stays expanded. Confirm ignored rows stay navigable and gray, and Show Hidden Files reveals both manually hidden and system-hidden entries. Exercise creation, rename, copy, paste, Trash and drops using disposable files.
