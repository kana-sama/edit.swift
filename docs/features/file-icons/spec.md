# File icons

The native window title, Open Recent, Go to File, and the Search result header display Seti icons beside file names. The editor title bar shows the file icon at all times, including a generic document icon for a new untitled buffer. Its named-file icon matches the one in Go to File. Right-click the icon to open the same language picker as Change Language Mode. Resolve an exact name first, the longest filename suffix next, and a path-based language association last. A manually chosen language determines the icon ahead of path associations. Use the generic file glyph for Plain Text and when no entry matches. The lookup is case-insensitive. The bundled theme supplies light and dark variants and does not inspect file contents or user settings.

The font, theme, and associations use the pinned Seti and VS Code assets from Rust Edit. The bundled directory contains the notices and license. Load resources when first displaying an icon.

## Acceptance

Compare the icons for `main.rs`, `MAIN.RS`, a compound TypeScript filename, and an unknown file. Switch appearance and check the corresponding theme variant. Menu and Control rows keep the file name available for navigation and accessibility.
