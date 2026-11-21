# Edit

A personal macOS text editor in Swift and AppKit.

## Build and run

Requires macOS 27 and Apple Command Line Tools with the macOS 27 SDK and Swift 6.4. Build and run from Terminal.

| Command | Result |
| --- | --- |
| `./script/build` | Build and sign `.build/app/debug/Edit.app`. |
| `./script/build release` | Build and sign `.build/app/release/Edit.app`. |
| `./script/run [file ...]` | Build and open the development app. Pass paths to open files or start new named buffers. |
| `./script/check` | Check editing and file-session recovery and render the result in a separate, non-activating test app. |
| `./script/install` | Build Release and install Edit to `~/Applications` with the `edit [file ...]` launcher in `/opt/homebrew/bin`. Pass an application directory or set `EDIT_BIN_DIRECTORY` to change those destinations. |

The app build reuses SDK modules under `.local/swift-sdk` even when `.build` is recreated.

When Edit is already open, `./script/run` reuses that instance.
