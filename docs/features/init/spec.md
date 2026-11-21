# Initial window

Launching Edit opens one empty, centered AppKit window titled **Edit**. Its initial content area is 720 by 480 points. macOS supplies the appearance, title bar, and close, minimize, and zoom controls. The window can be resized. Closing it or choosing **Quit Edit** exits the application.

## Acceptance

- Build from Terminal with the macOS 27 SDK and Swift 6.4.
- Launch the signed `Edit.app` and confirm that the empty window uses standard macOS chrome and appearance.
- Run `./script/check` to exercise window creation and rendering in a separate app bundle without activating it.
