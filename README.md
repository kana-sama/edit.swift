# Edit

A personal macOS text editor in Swift and AppKit. The initial version opens one empty native window. See the [window specification](docs/features/init/spec.md) and [project principles](docs/principles.md).

![Edit’s initial native window](docs/features/init/design/screenshot.png)

## Build and run

Requires macOS 27 and Apple Command Line Tools with the macOS 27 SDK and Swift 6.4. Build and run from Terminal.

| Command | Result |
| --- | --- |
| `./script/build` | Build and sign `.build/app/debug/Edit.app`. |
| `./script/build release` | Build and sign `.build/app/release/Edit.app`. |
| `./script/run` | Build and open the development app. |
| `./script/check` | Render the window in a separate, non-activating test app. |
| `./script/install` | Build Release and install Edit to `~/Applications`. Pass a directory to choose a different destination. |
