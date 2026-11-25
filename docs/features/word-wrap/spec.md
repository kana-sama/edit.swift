# Word Wrap

Use **View → Toggle Word Wrap** or **View: Toggle Word Wrap** in Command Mode to change how the current text buffer is displayed. The View menu shows a checkmark when wrapping is enabled. The command is available for file and untitled buffers in the text editor, including Markdown source.

With wrapping enabled, use the width of the exposed editor between the sidebars and preserve its text padding. Reflow when the window, a split pane, or the text size changes. Wrap at word boundaries and split a word across display rows when it cannot fit on one. Use vertical scrolling and keep the caret and selection. Soft wraps are presentation only. They do not insert line breaks, mark the document edited, or add an undo step.

Wrapping starts off. The setting belongs to the named file’s canonical path and survives switching files, closing the window, and relaunching Edit. Windows showing the same file share it. Edit carries an enabled setting through a Worktree move. Save As from a named file uses the destination’s setting. An untitled buffer can wrap while open, and its enabled setting is saved with its first file.

The width behavior follows [TextEdit’s Wrap to Window](https://support.apple.com/guide/textedit/txte3ab65427/mac) and uses [AppKit text container width tracking](https://developer.apple.com/documentation/appkit/nstextcontainer/widthtrackstextview).

## Acceptance

- Open a file with a long paragraph and a long unbroken word. Verify that horizontal scrolling is available. Enable wrapping from View, resize the window, and open a sidebar. Verify that the display rows fit the exposed editor and the file contents and selection stay intact.
- While another file opens, verify that the outgoing text and title keep their current presentation. Check the new file’s title and its own wrap mode on its first frame. Reopen the first file and verify wrapping is restored, including in a second window and after relaunch.
- Turn wrapping off from Command Mode, reopen the file, and verify that horizontal scrolling is available again. Start an untitled buffer, enable wrapping, save it, and verify its mode on reopening.
