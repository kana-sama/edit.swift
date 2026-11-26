# Odin Language Server

Edit starts Odin Language Server (OLS) for named, editable Odin files. It finds the first `ols` executable on the same PATH used for ZLS, including the login shell's PATH for Finder and Dock launches. The Language Servers row shows **Not on PATH** when the executable is missing. Use a compatible Odin toolchain and OLS installation. [OLS installation and configuration][ols]

For an Odin file, use the nearest `ols.json` within the opened folder, or the opened folder for loose sources. When opening a file on its own, search its parent directories for `ols.json` before falling back to the file's directory. An opened folder with an Odin project keeps the OLS row available on non-Odin files. Initialize the server with the discovered root so OLS can load workspace collections and settings. Restart OLS after changing its configuration.

Use the existing Language Servers row and **Start LSP**, **Stop LSP**, and **Restart LSP** controls. A window reuses its OLS connection between files in the same project. Closing the window or changing root ends the previous connection. Stop is remembered independently for OLS in the current workspace and applies to its other windows.

Use the existing **Go to Definition**, **Find All References**, **Hover**, occurrence highlighting, document and workspace symbols, and **Rename Symbol** actions when OLS advertises the relevant capability. Send Odin buffers as `odin` and synchronize unsaved edits before requests. Use UTF-16 positions and preserve reserved characters in OLS file locations during navigation and rename. Forward changes to Odin files in the project so OLS can refresh its index.

Ask OLS for semantic tokens by default and respect a workspace `ols.json` setting of `"enable_semantic_tokens": false`. Full-file semantic tokens augment [Tree-sitter highlighting](../odin/spec.md) through the existing LSP Highlighting toggle.

Show an OLS signature in the same selectable code block as a Zig declaration, with Odin syntax colors. Render the following documentation as Markdown, including inline code, links, fenced examples, and tables with aligned rows and columns. Preserve line breaks within the supplied documentation so line-oriented sections such as the naming rules in `base:runtime` stay readable. Show indentation-based examples attached to top-level prose as code, including the format verbs in the `core:fmt` package hover. Ignore an OLS hover range that does not contain the hovered character and anchor the card to the hovered word.

## Acceptance

Run `./script/check --only lsp-odin` with OLS on PATH. The hidden native fixture checks package hovers opened by pointer events over the `core:fmt` and `base:runtime` imports. It verifies the signature, inline code, indented examples, authored line breaks, table columns, and scrolling. It also covers a nested workspace, a path with reserved characters, an emoji before the queried identifier, semantic paint, and the source and destination frames of cross-file navigation. It checks rename in the open buffer and a closed file, indexing a subsequent external change, and reloading the project settings on restart.

[ols]: https://github.com/DanielGavin/ols#installation
