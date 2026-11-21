# Edit

A personal macOS text editor in Swift and AppKit. [Editor](docs/features/editor/spec.md) provides native plain-text editing, line commands, and scrolling. [Files](docs/features/files/spec.md) opens and saves UTF-8 text, with one document per window and draft recovery on relaunch. See the [project principles](docs/principles.md).

![Edit with a named file open in a native macOS window](docs/features/files/design/screenshot.png)

## Build and run

Requires macOS 27 and Apple Command Line Tools with the macOS 27 SDK and Swift 6.4. Build and run from Terminal.

| Command | Result |
| --- | --- |
| `./script/build` | Build and sign `.build/app/debug/Edit.app`. |
| `./script/build release` | Build and sign `.build/app/release/Edit.app`. |
| `./script/run [file ...]` | Build and open the development app. Pass existing files to open them in Edit. |
| `./script/check` | Check editing and file-session recovery and render the result in a separate, non-activating test app. |
| `./script/install` | Build Release and install Edit to `~/Applications`. Pass a directory to choose a different destination. |

The app build reuses SDK modules under `.local/swift-sdk` even when `.build` is recreated.

Use Command-O to open a file, Command-S to save, and Shift-Command-S to save under a new name. You can also choose Edit in Finder’s Open With menu. When Edit is already open, `./script/run` reuses that instance.
