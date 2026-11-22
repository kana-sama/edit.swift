# Design

Use standard AppKit window controls, menus, toolbars, file panels, dialogs, and scroll views. Follow macOS appearance, accessibility, focus, and keyboard conventions. Use native sidebar and inspector items in `NSSplitViewController` when a feature calls for them. Let AppKit supply Liquid Glass for system components and use `NSGlassEffectView` for custom controls where appropriate.

Match the corresponding interaction in the current macOS system app by default. A feature specification may define a different interaction when the owner requests it. Use the system reference for the placement of controls, focus changes, keyboard shortcuts, selection, and cancellation as well as appearance.

- For a single item rename, follow Finder. Return edits the name in its row and selects the basename of a file. Return confirms and Escape cancels. In a tree, creating an item starts with an editable row in the destination folder. [Finder rename](https://support.apple.com/guide/mac-help/rename-files-folders-and-disks-on-mac-mchlp1144/27/mac/27)
- For opening files and confirming unsaved changes, use the system file panel and document sheet conventions. Reserve modal confirmation for actions that require a separate decision.
- For sidebars and menus, follow native placement, keyboard navigation, glass materials, and active and inactive selection states.

Verify changes to those interactions in a running AppKit window. Exercise the normal keyboard and mouse paths, including how focus enters and leaves the control.

Document windows use the compact unified AppKit toolbar with a fixed icon-only display. Let editor content scroll beneath the filename and system window buttons to receive the native scroll-edge material. Let the editor’s scroll view extend behind the native sidebar. Use AppKit’s safe area and automatic scroll insets so text begins in the exposed area and can pass under the titlebar and sidebar during scrolling.

Use system appearance, semantic colors, text styles, control metrics, and SF Symbols for interface chrome. Respect platform preferences for contrast and reduced transparency. Keep persistent controls focused on actions the owner needs.

Record app-wide visual rules here when they are used across features. Record the feature's layout, controls, and interaction states in its own specification.
