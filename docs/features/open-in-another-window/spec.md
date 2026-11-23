# Open in Another Window

File → Open… (⌘O) shows an **Open in Another Window** checkbox on a separate row above the native **Open** and **Cancel** buttons. Each new dialog starts with the checkbox clear. Selecting it opens the chosen file or folder in a new editor window when the user confirms with **Open**. Cancel leaves the editor as it was.

A file opens in a standalone window. A folder opens with its [folder context](../folders/spec.md) and, when available, its last opened file. This includes folders created with [New Folder](../open-new-folder/spec.md) in the same dialog. The originating window keeps its folder, buffer, and editing position.

AppKit provides a separate accessory row and requires the user to confirm the selection with its own Open control. [Accessory view](https://developer.apple.com/documentation/appkit/nssavepanel/accessoryview) · [Open confirmation](https://developer.apple.com/documentation/appkit/nssavepanel/ok%28_%3A%29)

## Acceptance

- On macOS 27, invoke ⌘O from a window containing an unsaved draft. Verify that **Open in Another Window** is visible and clear. Select a file, check the box, and click **Open**. Verify that the file appears in a new window and the draft and its selection remain in the original window.
- Repeat with an empty folder and verify that the new window shows its folder name and **No File Open**. Check that the option is clear in the next dialog. Cancel with it checked and verify that the window count stays the same.
