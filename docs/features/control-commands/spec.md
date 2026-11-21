# Control · Command Mode

View → Command Mode… (⇧⌘P) opens the Control palette with available editor commands and their shortcuts. Commands come from native menus. Control briefly retains its last query when switching between modes with ⌘P and ⇧⌘P. A leading `>` switches from files to commands. Backspace at the start of Command Mode returns to files. Escape or the shortcut for the current mode dismisses Control and restores focus.

An empty query shows previously invoked commands first, then the other commands by title. Remember invocations from the palette across launches. Use case-insensitive fuzzy terms and prefer exact command titles. Up and Down navigate, Return or a click runs the selected command. Recheck commands against the originating editor and focus when running them.

## Acceptance

Open Control from an editing surface. Search for `save` and `sva`, navigate and run a command. Verify that editor actions keep the document’s selection and that cancelled and unavailable actions follow their usual rules. Switch modes by shortcut and by typing `>`.
