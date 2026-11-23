# Create a folder from Open

File → Open… (⌘O) offers the native **New Folder** button. Create a folder in the location shown in the dialog, then use **Open** to make it the current window’s [folder context](../folders/spec.md). A newly created empty folder opens on **No File Open**.

AppKit handles folder naming and creation. Cancel the naming prompt to return to the Open dialog without creating a folder. Cancel Open after creating a folder to keep the current editor context and leave the new folder on disk. [AppKit’s directory creation option](https://developer.apple.com/documentation/appkit/nssavepanel/cancreatedirectories)

## Acceptance

- On macOS 27, open ⌘O in a writable test directory. Click **New Folder**, enter a name, and confirm. Check that the new folder is the location shown in the dialog. Click **Open** and verify that the folder name appears in the window title and the editor shows **No File Open**.
- Cancel the naming prompt and verify that no folder appears. Create a folder and cancel Open. Check that the folder exists and the editor retains its current folder and buffer.
