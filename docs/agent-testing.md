# Agent Testing and Builds

Read this before building or launching for agent checks or changing the build and test scripts.

## Commands

- `./script/build` builds the development app incrementally. Use `./script/build release` for an optimized build.
- `./script/run` launches the interactive app for owner use and review.
- `./script/check [screenshot-path]` checks that the native window renders without activating the app. Pass a path to capture the window.
- `./script/install [directory]` installs the release app bundle and leaves bundles with unrelated identifiers untouched.

The app build invokes `swiftc` directly for the dependency-free `Edit` target. Keep `Package.swift` in sync for Swift tooling. The build reuses compiled SDK modules in `.local/swift-sdk` and reuses a signed bundle when its inputs match. Use the default debug build during development and an optimized build when measuring runtime or launch performance.

Use separate fresh directories via `EDIT_BUILD_DIR` and `EDIT_SDK_CACHE_DIR` to measure a fully cold build. Setting just `EDIT_BUILD_DIR` to a fresh directory measures rebuilding the project with the existing SDK cache. Report incremental build times separately. For cold launch, measure first launch to the first usable window and record the machine, OS, and cache conditions.

## Quiet agent checks

Prefer process or model checks when a window is unnecessary. Test the real implementation through its ordinary entry points where practical. When startup, layout, or drawing requires AppKit, use a dedicated test instance and disposable data with an identity separate from the owner's app.

- Prevent activation before launch and window creation. Keep the test instance in the background throughout the check.
- Suppress Dock attention, interactive alerts, restoration, and other owner-facing effects for that test instance. Collect diagnostics through the runner.
- Use synthetic files and a disposable profile. Identify the exact test instance before controlling it or closing it.
- Verify quiet behavior without changing global macOS settings or interacting with the owner's running editor.

Capture screenshots from the running test UI under the same isolation rules when review or the README needs them. If an operation would interrupt the owner, stop that operation and report the specific blocker.
