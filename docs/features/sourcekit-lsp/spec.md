# SourceKit-LSP

Use [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp) in Edit for Swift, C, C++, Objective-C, and Objective-C++. The [support matrix](../../lsp-checklist.md#support-by-language-server) lists the commands and their protocol methods.

## Discovery and controls

- Resolve `sourcekit-lsp` from the editor’s PATH, or use `xcrun --find sourcekit-lsp` for the active Apple developer toolchain. Show **Toolchain unavailable** when neither lookup resolves a server. Edit launches the selected toolchain’s server directly.
- Discover SwiftPM projects by `Package.swift`, build-server projects by `buildServer.json`, and compilation databases by `compile_commands.json` or `compile_flags.txt`. Prefer the nearest recognized project for an open source file and use the containing folder for loose sources. With an explicitly open folder, keep discovery inside it. Skip hidden directories and generated build output during discovery.
- Reuse the trailing **Language Servers** button, with a Swift icon, **SourceKit-LSP** label, and its own Play/Stop and Restart controls. Show one SourceKit-LSP row for its supported languages and one ZLS row when the folder also contains Zig sources. Maintain each server’s stopped state independently for its project root. The header shows initialization and reported work, then its combined readiness.
- Send named, editable buffers to SourceKit-LSP with the language ID for the resolved mode and the server’s negotiated synchronization options. Changing between its modes reopens the buffer on the same server with the current unsaved text. Keep the current unsaved text through a restart. Report source file and manifest changes in the workspace so the server can refresh its index.

## Commands

- Reuse Cmd-hover, Cmd-click, the symbol context menu, and the References sidebar. **Go to Definition** uses `textDocument/definition`. Show hover documentation using the editor’s Markdown renderer. Use server-supplied document highlights for the symbol under the caret.
- Use `:` in Control to browse symbols from the active source document. Use `#` to search ready servers in the folder, including from a plain-text file. Project-wide results depend on the build settings and the server’s index. For C-family projects, SourceKit-LSP uses clangd with the project’s compiler options. [SourceKit-LSP project setup](https://github.com/swiftlang/sourcekit-lsp#getting-started)
- Use F2 or **Rename…** to edit a Swift symbol name or a single C-family identifier inline and apply changes to references inside the project. Renaming a Swift function’s base name preserves its argument labels. Keep the same snapshot, file-boundary, and conflict checks as Zig rename. [SourceKit-LSP rename implementation](https://github.com/swiftlang/sourcekit-lsp/blob/main/Sources/SwiftLanguageService/Rename.swift)

## Acceptance

Run `./script/check --only lsp-swift [screenshot-path]` against the installed Swift toolchain. A disposable Swift package exercises server discovery, indexing progress, cross-file navigation and references, hover, semantic highlights, both symbol searches, and a rename across open and closed files. The mixed-language fixture checks the two popover rows and independent Swift stop, start, and restart with unsaved text. Run the Zig LSP and progress checks for regressions.

Run `./script/check --only lsp-c-family [screenshot-path]` for a C-family folder with a compilation database. Check that all four modes use the same server and resolve real definitions, hover, and document symbols. The check also covers loose-source discovery, C rename, and synchronization after a manual mode change.
