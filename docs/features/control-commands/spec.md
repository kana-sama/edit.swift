# Control · Command Mode

View → Command Mode… (⇧⌘P) opens the Control palette with available editor commands and their shortcuts. The catalog includes native menu commands, document navigation and deletion, and available Find and Replace actions. Keyboard-only editing commands show their native bindings and act directly on the document. Control briefly retains its last query when switching between modes with ⌘P and ⇧⌘P. A leading `>` switches from files to commands. In Command Mode, the `>_` prompt occupies the search field’s leading icon slot. Backspace at the start of Command Mode returns to files. Escape or the shortcut for the current mode dismisses Control and restores focus.

An empty query shows previously invoked commands first, then the other commands by title. Remember invocations from the palette across launches. Use case-insensitive fuzzy terms and prefer exact command titles. Up and Down navigate, Return or a click runs the selected command. Recheck commands against the originating editor and focus when running them.

## Acceptance

Open Control from an editing surface. Search for `save` and `sva`, navigate and run a command. Verify that editor actions keep the document’s selection and that cancelled and unavailable actions follow their usual rules. Switch modes by shortcut and by typing `>`.
