# Open in Another Window

File → Open… (⌘O) shows **Open in This Window** as its native confirmation button. Hold Option (⌥) to change the label to **Open in New Window**. Release Option to restore the original label. Confirm with Option held to open the selection in a new editor window. The confirmation determines the destination even if Option is released while the panel closes. Cancel leaves the editor as it was.

A file opens in a standalone window. A folder opens with its [folder context](../folders/spec.md) and, when available, its last opened file. This includes folders created with [New Folder](../open-new-folder/spec.md) in the same dialog. The originating window keeps its folder, buffer, and editing position.

The dialog reads the current modifier state and changes the native button’s prompt on macOS 27. It records Option when AppKit validates the accepted selection. [Modifier state](https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.type.property) · [Button prompt](https://developer.apple.com/documentation/appkit/nssavepanel/prompt) · [Selection validation](https://developer.apple.com/documentation/appkit/nsopensavepaneldelegate/panel%28_%3Avalidate%3A%29)

## Acceptance

- On macOS 27, invoke ⌘O from a window containing an unsaved draft and select a file. Hold and release Option to check both labels and verify that the selection stays put. Hold Option again, click **Open in New Window**, and immediately release Option. Verify that the file opens in a new window and the draft and its selection remain in the original window.
- Repeat with an empty folder and verify that the new window shows its folder name and **No File Open**. With Option released, confirm a selection and verify that it opens in the current window. Hold Option and click **Cancel** to verify that the window count stays the same.
