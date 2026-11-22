# Initial window

Launching Edit opens one empty, centered AppKit window titled **Edit**. Its initial content area is 720 by 480 points. macOS supplies the appearance, title bar, and close, minimize, and zoom controls. The window can be resized. Closing it or choosing **Quit Edit** exits the application.

Edit's app icon is a graphite text field with a faint blue reflection, muted syntax colors, and a white insertion caret. macOS displays the bundled icon in Finder and the Dock.

## Acceptance

- Build from Terminal with the macOS 27 SDK and Swift 6.4.
- Confirm that macOS resolves the bundled Edit icon for `Edit.app`.
- Launch the signed `Edit.app` and confirm that the empty window uses standard macOS chrome and appearance.
- Run `./script/check` to exercise window creation and rendering in a separate app bundle without activating it.
