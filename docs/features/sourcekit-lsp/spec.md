# SourceKit-LSP for Swift

Use Swift’s [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp) in Edit for the same editing and navigation commands available with ZLS. The [support matrix](../../lsp-checklist.md#support-by-language-server) lists the commands and their protocol methods.

## Discovery and controls

- Resolve `sourcekit-lsp` from the editor’s PATH, or use `xcrun --find sourcekit-lsp` for the active Apple developer toolchain. Show **Toolchain unavailable** when neither lookup resolves a server. Edit launches the selected toolchain’s server directly.
- Discover SwiftPM projects by `Package.swift`, build-server projects by `buildServer.json`, and compilation databases by `compile_commands.json` or `compile_flags.txt`. Prefer the nearest recognized project for an open Swift file and use the containing folder for loose Swift sources. With an explicitly open folder, keep discovery inside it. Skip hidden directories and generated build output during discovery.
- Reuse the trailing **Language Servers** button, with a Swift icon, **SourceKit-LSP** label, and its own Play/Stop and Restart controls. Show both rows in a folder with Swift and Zig sources. Maintain each server’s stopped state independently for its project root. The header shows initialization and reported work, then its combined readiness.
- Send named, editable Swift buffers to SourceKit-LSP using the Swift language ID and the server’s negotiated synchronization options. Keep the current unsaved text through a restart. Report Swift file and manifest changes in the workspace so the server can refresh its index.

## Commands

- Reuse Cmd-hover, Cmd-click, the symbol context menu, and the References sidebar. **Go to Definition** uses `textDocument/definition` for Swift. Show Swift hover documentation using the editor’s Markdown renderer. Use server-supplied document highlights for the symbol under the caret.
- Use `:` in Control to browse symbols from the active Swift document. Use `#` to search ready servers in the folder, including from a plain-text file. Cross-file results depend on the server’s index. Use the toolchain’s background indexing or build the project to populate it. [SourceKit-LSP project setup](https://github.com/swiftlang/sourcekit-lsp#getting-started)
- Use F2 or **Rename…** to edit the Swift symbol name inline and apply changes to references inside the project. Renaming a function’s base name preserves its argument labels. Keep the same snapshot, file-boundary, and conflict checks as Zig rename. [SourceKit-LSP rename implementation](https://github.com/swiftlang/sourcekit-lsp/blob/main/Sources/SwiftLanguageService/Rename.swift)

## Acceptance

Run `./script/check --only lsp-swift [screenshot-path]` against the installed Swift toolchain. A disposable Swift package exercises server discovery, indexing progress, cross-file navigation and references, hover, semantic highlights, both symbol searches, and a rename across open and closed files. The mixed-language fixture checks the two popover rows and independent Swift stop, start, and restart with unsaved text. Run the Zig LSP and progress checks for regressions.
