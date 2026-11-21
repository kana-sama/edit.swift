# Design

Use standard AppKit window controls, menus, toolbars, file panels, dialogs, and scroll views. Follow macOS appearance, accessibility, focus, and keyboard conventions. Use native sidebar and inspector items in `NSSplitViewController` when a feature calls for them. Let AppKit supply Liquid Glass for system components and use `NSGlassEffectView` for custom controls where appropriate.

Document windows use a unified AppKit toolbar in every sidebar state. Let editor content scroll beneath the filename and system window buttons to receive the native scroll-edge material. Use AppKit’s automatic top inset so the first line starts beneath the titlebar.

Use system appearance, semantic colors, text styles, control metrics, and SF Symbols for interface chrome. Respect platform preferences for contrast and reduced transparency. Keep persistent controls focused on actions the owner needs.

Record app-wide visual rules here when they are used across features. Record the feature's layout, controls, and interaction states in its own specification.
