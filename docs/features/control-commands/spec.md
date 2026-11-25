# Control · Command Mode

View → Command Mode… (⇧⌘P) opens the Control palette with available editor commands and their shortcuts. The catalog includes native menu commands, document navigation and deletion, and available Find and Replace actions. Keyboard-only editing commands show their native bindings and act directly on the document. With Go to File open, ⇧⌘P switches to Command Mode. With Command Mode open, ⌘P switches to Go to File. Both shortcuts keep the query and focus in the open palette. A leading `>` switches from files to commands. In Command Mode, the `>_` prompt sits on a small rounded tile in the same leading position as the magnifier. The text field and shortcuts keep their alignment when changing modes. Backspace at the start of Command Mode returns to files. Escape or the shortcut for the current mode dismisses Control and restores focus.

An empty query shows [pinned commands](../control-pins/spec.md), then previously invoked commands, then the other commands by title. Remember invocations from the palette across launches. Use case-insensitive fuzzy terms and prefer exact command titles. Up and Down navigate, Return or a click runs the selected command. Recheck commands against the originating editor and focus when running them.

Commands with an on/off state show a native switch at the trailing edge of the row, after any shortcut. Read the state from the originating window, workspace, or editor selection. Clicking the switch runs the same command as Return in its row. Search options show their current values when their commands are available. Text transformations such as Toggle Line Comments have no switch.

## Acceptance

Open Control from an editing surface. Search for `save` and `sva`, navigate and run a command. Verify that editor actions keep the document’s selection and that cancelled and unavailable actions follow their usual rules. With a query entered, switch modes in both directions by shortcut using ABC and Russian. Check that the query and field focus stay in the palette. Also switch from files to commands by typing `>`.

Open Command Mode from a window with Search displayed. Verify that the sidebar, search options, and workspace highlighting each show their current state. Compare rows with and without shortcuts for trailing switch alignment. Click the highlighting switch, reopen Command Mode, and verify the new state.
