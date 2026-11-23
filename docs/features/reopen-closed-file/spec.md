# Reopen Closed File

Use Shift-Command-T, File → Reopen Closed File, or the command in [Command Mode](../control-commands/spec.md) to reopen the most recently closed file. Further invocations work backward through the current Edit session’s close history. Each successful reopen consumes one entry. The shortcut follows [Safari’s reopen convention](https://support.apple.com/guide/mac-help/browse-the-web-mchlgtd_web01/mac).

Closing a named file, scratch, or preview records it after the normal [close flow](../files/spec.md#new-close-and-restore) succeeds. Record the close from a folder window when it reaches **No File Open**, and from a standalone window when the window closes.

Reuse the originating folder window when it is still open on **No File Open** for the same folder. Otherwise, open a separate window with the original folder context. Focus the reopened file and restore its saved editor position through the normal file-opening path. A failed reopen keeps its history entry available for retry. The command is available when there is a closed file to reopen and the active window can accept the command.

## Acceptance

- Close a file in a folder window. Press Shift-Command-T and check that the file returns in the same window with its selection restored.
- Close a standalone file, then a file in a folder window. Open another file in the folder window. Run Reopen Closed File from Command Mode and check that it opens the most recently closed file in a separate window with the original folder. Press Shift-Command-T to reopen the standalone file next.
- Run the command with an empty close history and after canceling a close. Close a scratch and reopen it with its scratch identity. Verify that a failed reopen keeps its place in the history.
