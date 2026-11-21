# Project Principles

Edit is a personal text editor for macOS. Give each feature a concrete editing task and keep the interface focused on that task. Define new scope in its own specification.

## Native macOS

Build with Swift and AppKit. Target macOS 27 using Swift 6.4. Use public system controls and platform conventions for the shell, file selection, text input, menus, appearance, and accessibility. Consider BriskEdit when it provides useful prior art for a decision. Adopt dependencies only when an actual feature needs them.

## Performance and responsiveness

Cold builds and cold launches are first-class performance goals. Keep the build graph small and favor system frameworks and focused dependencies. Measure cold and incremental builds separately. Keep one terminal entry point for building the app bundle.

Keep startup work to what is needed for an editable window. Defer expensive services until they are useful. Keep blocking I/O and expensive work off the UI thread and limit updates to the content that changed. Keep typing and scrolling responsive during background work.

When work takes long enough to matter, show appropriate feedback. Preserve focus, selection, and click targets during background updates. Measure the actual user scenario for performance changes and keep the ordinary edit-build-run cycle short.
