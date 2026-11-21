# Design

Use standard AppKit window controls, menus, toolbars, file panels, dialogs, and scroll views. Follow macOS appearance, accessibility, focus, and keyboard conventions. Use native sidebar and inspector items in `NSSplitViewController` when a feature calls for them. Let AppKit supply Liquid Glass for system components and use `NSGlassEffectView` for custom controls where appropriate.

Use system appearance, semantic colors, text styles, control metrics, and SF Symbols for interface chrome. Respect platform preferences for contrast and reduced transparency. Keep persistent controls focused on actions the owner needs.

Record app-wide visual rules here when they are used across features. Record the feature's layout, controls, and interaction states in its own specification.
