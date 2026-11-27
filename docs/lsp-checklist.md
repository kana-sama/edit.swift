# LSP Feature Checklist

## Support by Language Server

✓ works in Edit. A blank cell means the server supports the method and Edit could add it. ✗ means the server does not support the method. The SourceKit-LSP column describes Swift. C-family support uses clangd and can expose different methods. Implemented methods come first, then implementation candidates, then methods unavailable on the listed servers.

Checked November 25, 2026 against ZLS 0.17.0 and SourceKit-LSP bundled with Apple Swift 6.4 (swiftlang-6.4.0.33.1). OLS was checked November 26, 2026 against dev-2026-11. See [Solar](#solar) for the Foundry integration checked with Forge 1.10.0. Some methods depend on client capabilities, server settings or project indexing. The table covers [LSP 3.18][lsp] editor features and the messages that enable them. It is a catalog of options for Edit. [OLS request handlers][ols-handlers]

Edit ranks comparable [workspace symbol matches](features/lsp-symbol-navigation/spec.md#go-to-workspace-symbol) by their proximity to the active folder's root across the connected servers.

Edit uses full [semantic token results](features/lsp-highlighting/spec.md) for scrolling and a concurrent visible-range preview for large ZLS files. It also supports range-only providers and deltas.

Edit [underlines published errors and shows their messages after the affected lines](features/lsp-diagnostics/spec.md).
The [Worktree marks files and collapsed folders with published errors](features/lsp-worktree-diagnostics/spec.md).

| Method                                                                       | ZLS   | SourceKit-LSP | OLS   |
| ---------------------------------------------------------------------------- | :---: | :-----------: | :---: |
| [`textDocument/definition`][lsp-definition]                                  | ✓     | ✓             | ✓     |
| [`textDocument/references`][lsp-references]                                  | ✓     | ✓             | ✓     |
| [`textDocument/documentHighlight`][lsp-documenthighlight]                    | ✓     | ✓             | ✓     |
| [`textDocument/semanticTokens/full`][lsp-semantictokens-fullrequest]         | ✓     | ✓             | ✓     |
| [`textDocument/semanticTokens/range`][lsp-semantictokens-rangerequest]       | ✓     | ✓             |       |
| [`workspace/semanticTokens/refresh`][lsp-semantictokens-refreshrequest]      | ✓     | ✓             | ✗     |
| [`textDocument/documentSymbol`][lsp-documentsymbol]                          | ✓     | ✓             | ✓     |
| [`workspace/symbol`][lsp-ws-symbol]                                          | ✓     | ✓             | ✓     |
| [`textDocument/hover`][lsp-hover]                                            | ✓     | ✓             | ✓     |
| [`textDocument/prepareRename`][lsp-preparerename]                            | ✓     | ✓             | ✓     |
| [`textDocument/rename`][lsp-rename]                                          | ✓     | ✓             | ✓     |
| [`textDocument/publishDiagnostics`][lsp-publishdiagnostics]                  | ✓     | ✓             | ✓     |
| [`window/workDoneProgress/create`][lsp-win-workdoneprogress-create]          | ✓     | ✓             | ✗     |
| [`$/progress`][lsp-progress]                                                 | ✓     | ✓             | ✗     |
| [`workspace/didChangeWorkspaceFolders`][lsp-ws-didchangeworkspacefolders]    | ✓     |               | ✗     |
| [`workspace/didChangeWatchedFiles`][lsp-ws-didchangewatchedfiles]            |       | ✓             | ✓     |
| [`textDocument/declaration`][lsp-declaration]                                |       | ✗             | ✗     |
| [`textDocument/typeDefinition`][lsp-typedefinition]                          |       |               |       |
| [`textDocument/implementation`][lsp-implementation]                          | ✗     |               | ✗     |
| [`textDocument/prepareCallHierarchy`][lsp-preparecallhierarchy]              | ✗     |               | ✗     |
| [`callHierarchy/incomingCalls`][lsp-callhierarchy-incomingcalls]             | ✗     |               | ✗     |
| [`callHierarchy/outgoingCalls`][lsp-callhierarchy-outgoingcalls]             | ✗     |               | ✗     |
| [`textDocument/prepareTypeHierarchy`][lsp-preparetypehierarchy]              | ✗     |               | ✗     |
| [`typeHierarchy/supertypes`][lsp-typehierarchy-supertypes]                   | ✗     |               | ✗     |
| [`typeHierarchy/subtypes`][lsp-typehierarchy-subtypes]                       | ✗     |               | ✗     |
| [`textDocument/completion`][lsp-completion]                                  |       |               |       |
| [`completionItem/resolve`][lsp-completionitem-resolve]                       | ✗     |               | ✗     |
| [`textDocument/signatureHelp`][lsp-signaturehelp]                            |       |               |       |
| [`textDocument/inlayHint`][lsp-inlayhint]                                    |       |               |       |
| [`inlayHint/resolve`][lsp-inlayhint-resolve]                                 | ✗     |               | ✗     |
| [`workspace/inlayHint/refresh`][lsp-ws-inlayhint-refresh]                    |       | ✗             | ✗     |
| [`textDocument/codeLens`][lsp-codelens]                                      | ✗     |               | ✗     |
| [`textDocument/foldingRange`][lsp-foldingrange]                              |       |               | ✗     |
| [`textDocument/selectionRange`][lsp-selectionrange]                          |       |               | ✗     |
| [`textDocument/documentLink`][lsp-documentlink]                              | ✗     | ✗             |       |
| [`textDocument/documentColor`][lsp-documentcolor]                            | ✗     |               | ✗     |
| [`textDocument/colorPresentation`][lsp-colorpresentation]                    | ✗     |               | ✗     |
| [`textDocument/diagnostic`][lsp-diagnostic]                                  | ✗     |               | ✗     |
| [`workspace/diagnostic/refresh`][lsp-diagnostic-refresh]                     | ✗     |               | ✗     |
| [`textDocument/codeAction`][lsp-codeaction]                                  |       |               |       |
| [`codeAction/resolve`][lsp-codeaction-resolve]                               | ✗     |               | ✗     |
| [`textDocument/formatting`][lsp-formatting]                                  |       |               |       |
| [`textDocument/rangeFormatting`][lsp-rangeformatting]                        | ✗     |               | ✗     |
| [`textDocument/onTypeFormatting`][lsp-ontypeformatting]                      | ✗     |               | ✗     |
| [`textDocument/willSave`][lsp-willsave]                                      | ✗     |               | ✗     |
| [`textDocument/willSaveWaitUntil`][lsp-willsavewaituntil]                    |       | ✗             | ✗     |
| [`textDocument/didSave`][lsp-didsave]                                        |       |               |       |
| [`workspace/configuration`][lsp-ws-configuration]                            |       | ✗             | ✗     |
| [`workspace/didChangeConfiguration`][lsp-ws-didchangeconfiguration]          |       | ✗             |       |
| [`workspace/executeCommand`][lsp-ws-executecommand]                          | ✗     |               | ✗     |
| [`workspace/applyEdit`][lsp-ws-applyedit]                                    |       |               | ✗     |
| [`window/showMessage`][lsp-win-showmessage]                                  |       | ✗             | ✗     |
| [`window/logMessage`][lsp-win-logmessage]                                    |       |               |       |
| [`documentLink/resolve`][lsp-documentlink-resolve]                           | ✗     | ✗             | ✗     |
| [`textDocument/moniker`][lsp-moniker]                                        | ✗     | ✗             | ✗     |
| [`workspaceSymbol/resolve`][lsp-ws-symbolresolve]                            | ✗     | ✗             | ✗     |
| [`workspace/textDocumentContent`][lsp-ws-textdocumentcontent]                | ✗     | ✗             | ✗     |
| [`workspace/textDocumentContent/refresh`][lsp-ws-textdocumentcontentrefresh] | ✗     | ✗             | ✗     |
| [`textDocument/inlineCompletion`][lsp-inlinecompletion]                      | ✗     | ✗             | ✗     |
| [`textDocument/inlineValue`][lsp-inlinevalue]                                | ✗     | ✗             | ✗     |
| [`workspace/inlineValue/refresh`][lsp-ws-inlinevalue-refresh]                | ✗     | ✗             | ✗     |
| [`codeLens/resolve`][lsp-codelens-resolve]                                   | ✗     | ✗             | ✗     |
| [`workspace/codeLens/refresh`][lsp-codelens-refresh]                         | ✗     | ✗             | ✗     |
| [`textDocument/semanticTokens/full/delta`][lsp-semantictokens-deltarequest]  | ✗     | ✗             | ✗     |
| [`workspace/foldingRange/refresh`][lsp-ws-foldingrange-refresh]              | ✗     | ✗             | ✗     |
| [`workspace/diagnostic`][lsp-ws-diagnostic]                                  | ✗     | ✗             | ✗     |
| [`textDocument/rangesFormatting`][lsp-documentrangesformattingparams]        | ✗     | ✗             | ✗     |
| [`textDocument/linkedEditingRange`][lsp-linkededitingrange]                  | ✗     | ✗             | ✗     |
| [`textDocument/didRename`][lsp-didrename]                                    | ✗     | ✗             | ✗     |
| [`workspace/willCreateFiles`][lsp-ws-willcreatefiles]                        | ✗     | ✗             | ✗     |
| [`workspace/didCreateFiles`][lsp-ws-didcreatefiles]                          | ✗     | ✗             | ✗     |
| [`workspace/willRenameFiles`][lsp-ws-willrenamefiles]                        | ✗     | ✗             | ✗     |
| [`workspace/didRenameFiles`][lsp-ws-didrenamefiles]                          | ✗     | ✗             | ✗     |
| [`workspace/willDeleteFiles`][lsp-ws-willdeletefiles]                        | ✗     | ✗             | ✗     |
| [`workspace/didDeleteFiles`][lsp-ws-diddeletefiles]                          | ✗     | ✗             | ✗     |
| [`window/showMessageRequest`][lsp-win-showmessagerequest]                    | ✗     | ✗             | ✗     |
| [`window/showDocument`][lsp-win-showdocument]                                | ✗     | ✗             | ✗     |
| [`window/workDoneProgress/cancel`][lsp-win-workdoneprogress-cancel]          | ✗     | ✗             | ✗     |

SourceKit-LSP advertises `textDocument/declaration` for C-family languages. Its Swift handler reports that the method is unsupported. To enable Swift on-type formatting, opt in to `on-type-formatting`. [Swift declaration handler][swift-service] · [SourceKit-LSP configuration][swift-config]

## ZLS

- [x] Discover Zig projects and launch the ZLS executable from PATH. [Edit specification](features/lsp/spec.md#server-discovery-and-session)
- [x] Render ZLS hover declarations, inferred types and clickable links to local type definitions. [Edit specification](features/lsp/spec.md#hover)
- [x] Rename Zig identifiers that require quoting or escapes. [Edit specification](features/lsp-rename/spec.md)
- [ ] Offer Zig completion snippets, editable argument placeholders and signature details in completion labels. [ZLS configuration][zls-config]
- [ ] Offer file and directory completions inside Zig import paths. [ZLS completion implementation][zls-completion]
- [ ] Show Zig build-on-save diagnostics, including support for a project’s `check` build step and custom build arguments. [ZLS build-on-save guide][zls-build]
- [ ] Surface Zig quick fixes, Organize Imports and Fix All, including the `force_autofix` save hook. [ZLS code actions][zls-actions] · [ZLS configuration][zls-config]
- [ ] Expose Zig-specific hint options for inferred types, struct and union fields, parameter names and builtins. [ZLS configuration][zls-config]
- [ ] Expose ZLS semantic token modes and warnings for style and global variables. [ZLS configuration][zls-config]
- [ ] Configure Zig executable and library paths, the builtin module and the ZLS cache directory. [ZLS configuration][zls-config]

ZLS 0.17.0 exposes these capabilities through standard methods and ZLS-specific settings, result data and action kinds. [ZLS request handlers][zls-handlers]

## SourceKit-LSP

- [x] Discover SwiftPM, build-server and compilation-database projects and use a SourceKit-LSP toolchain from PATH or `xcrun`. [Edit specification](features/sourcekit-lsp/spec.md#discovery-and-controls)
- [x] Route Swift, C, C++, Objective-C, and Objective-C++ buffers to SourceKit-LSP with their respective language IDs. Discover loose C-family sources and retain the server when switching modes in the same project. [Edit specification](features/sourcekit-lsp/spec.md#discovery-and-controls)
- [x] Save explicit stops for each language server and workspace across app relaunch. [Edit specification](features/lsp/spec.md#server-discovery-and-session)
- [x] Keep Swift function argument labels when renaming a function’s base name. [Edit specification](features/sourcekit-lsp/spec.md#commands)
- [ ] Open virtual Swift module interfaces and macro expansions (`workspace/getReferenceDocument`). [Reference documents][swift-reference-documents]
- [ ] Show Swift DocC documentation and its structured content (`textDocument/doccDocumentation`). [DocC request][swift-docc]
- [ ] Inspect Swift symbol metadata and USRs (`textDocument/symbolInfo`). [Symbol information][swift-symbol-info]
- [ ] Show Swift semantic refactorings such as Extract Function and Expand Macro (`semantic.refactor.command`, `expand.macro.command`). [Refactoring actions][swift-refactors] · [Macro expansion command][swift-macros]
- [ ] Show diagnostic-specific fixes supplied inline with Swift diagnostics. [Inline diagnostic actions][swift-diagnostic-actions]
- [ ] Offer Swift completion snippets and SourceKit-specific completion metadata and filtering. [Completion extensions][swift-completion]
- [ ] Reuse SourceKit symbol IDs and generated interface locations for call and type hierarchies. [Hierarchy extensions][swift-hierarchy]
- [ ] Render SourceKit-specific semantic token types and modifiers. [Semantic token modifiers][swift-token-modifiers] · [Semantic token types][swift-token-types]
- [ ] Discover and refresh Swift tests in a file or workspace (`textDocument/tests`, `workspace/tests`, `workspace/tests/refresh`). [Document tests][swift-document-tests] · [Workspace tests][swift-workspace-tests]
- [ ] Discover and refresh Swift playgrounds, and run `#Playground` entries from CodeLens where the toolchain supports them (`workspace/playgrounds`, `workspace/playgrounds/refresh`, `swift.play`). [Playground integration][swift-playgrounds]
- [ ] Show related documents in a peek view (`workspace/peekDocuments`). [Peek documents][swift-peek]
- [ ] Request a project reindex (`workspace/triggerReindex`). [Reindex request][swift-reindex]
- [ ] Signal that the active Swift document changed to prioritize its build target (`window/didChangeActiveDocument`). [Active document notification][swift-active-document]
- [ ] Pause or resume background indexing (`workspace/_setOptions`). [Indexing options][swift-set-options]
- [ ] Inspect Swift compiler arguments, target and build outputs (`workspace/_sourceKitOptions`, `workspace/_outputPaths`). [Compiler options][swift-options] · [Output paths][swift-output-paths]
- [ ] Wait for background workspace preparation and indexing (`workspace/synchronize`). [Workspace synchronization][swift-synchronize]
- [ ] Show structured SourceKit logs by task and log kind. [Log message extension][swift-logs]
- [ ] Expose SourceKit-LSP project settings for indexing, SwiftPM and fallback compiler options. [SourceKit-LSP configuration][swift-config]

Method names above use the audited toolchain’s spelling. Newer releases add the `sourcekit/` prefix to many extension methods. [Upstream protocol changes][swift-prefix]

## Maintenance

Use this catalog to compare server support and give the owner a list of candidate editor features. Follow the [language server integration workflow](workflow.md#language-server-integrations) when deciding which features to implement.

Update this checklist in the same change as an Edit LSP feature or server integration. Move implemented rows or items to the top of their lists. When updating the server versions recorded here, recheck their `initialize` capabilities, conditional registrations and language-specific handlers before changing a blank or a ✗. Add extension candidates when they become available in a supported toolchain.

## OLS

- [x] Discover Odin projects from ols.json and launch the OLS executable on PATH. [Edit specification](features/odin-lsp/spec.md)
- [x] Display full-document semantic tokens when OLS enables them. [Edit specification](features/odin-lsp/spec.md)
- [ ] Surface Odin compiler diagnostics and checker profiles. [OLS configuration][ols-config]
- [ ] Show inferred types, parameter names, and default arguments through OLS inlay hints. [OLS configuration][ols-config]

## Solar

- [x] Discover Foundry projects and launch `forge lsp --stdio`. Respect project profiles and remappings when opening source and dependency files. [Edit specification](features/solidity-lsp/spec.md)
- [x] Run `textDocument/definition`, `textDocument/references`, `textDocument/hover`, `textDocument/documentHighlight`, `textDocument/documentSymbol`, `workspace/symbol`, `textDocument/prepareRename`, and `textDocument/rename`.
- [x] Display `textDocument/publishDiagnostics` errors and send `textDocument/didSave` and `workspace/didChangeWatchedFiles`.
- [x] Display `textDocument/completion` results and accept edits, using `completionItem/resolve` when supported.
- [x] Show `textDocument/signatureHelp` with the active parameter and apply `textDocument/formatting` as an undoable document edit.
- [ ] Surface Solar's type definition, implementation, hierarchies, and inlay hints.
- [ ] Support pull and workspace diagnostics in addition to the push diagnostics used by Edit.

Forge 1.10.0 does not advertise semantic tokens. [Foundry editor integration](https://github.com/foundry-rs/foundry/blob/v1.10.0/editors/README.md)

[ols-config]: https://github.com/DanielGavin/ols#configuration
[ols-handlers]: https://github.com/DanielGavin/ols/blob/master/src/server/requests.odin

[lsp]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
[lsp-definition]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_definition
[lsp-references]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_references
[lsp-documenthighlight]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentHighlight
[lsp-documentsymbol]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentSymbol
[lsp-ws-symbol]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbol
[lsp-hover]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_hover
[lsp-preparerename]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareRename
[lsp-rename]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rename
[lsp-win-workdoneprogress-create]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
[lsp-progress]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
[lsp-ws-didchangeworkspacefolders]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeWorkspaceFolders
[lsp-ws-didchangewatchedfiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeWatchedFiles
[lsp-declaration]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_declaration
[lsp-typedefinition]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_typeDefinition
[lsp-implementation]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_implementation
[lsp-preparecallhierarchy]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareCallHierarchy
[lsp-callhierarchy-incomingcalls]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_incomingCalls
[lsp-callhierarchy-outgoingcalls]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_outgoingCalls
[lsp-preparetypehierarchy]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareTypeHierarchy
[lsp-typehierarchy-supertypes]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_supertypes
[lsp-typehierarchy-subtypes]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_subtypes
[lsp-completion]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_completion
[lsp-completionitem-resolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItem_resolve
[lsp-signaturehelp]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_signatureHelp
[lsp-inlayhint]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlayHint
[lsp-inlayhint-resolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint_resolve
[lsp-ws-inlayhint-refresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_inlayHint_refresh
[lsp-codelens]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeLens
[lsp-semantictokens-fullrequest]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_fullRequest
[lsp-semantictokens-rangerequest]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_rangeRequest
[lsp-semantictokens-refreshrequest]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_refreshRequest
[lsp-foldingrange]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_foldingRange
[lsp-selectionrange]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_selectionRange
[lsp-documentcolor]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentColor
[lsp-colorpresentation]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_colorPresentation
[lsp-publishdiagnostics]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics
[lsp-diagnostic]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_diagnostic
[lsp-diagnostic-refresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic_refresh
[lsp-codeaction]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeAction
[lsp-codeaction-resolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeAction_resolve
[lsp-formatting]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_formatting
[lsp-rangeformatting]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rangeFormatting
[lsp-ontypeformatting]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_onTypeFormatting
[lsp-willsave]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_willSave
[lsp-willsavewaituntil]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_willSaveWaitUntil
[lsp-didsave]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didSave
[lsp-ws-configuration]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration
[lsp-ws-didchangeconfiguration]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeConfiguration
[lsp-ws-executecommand]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_executeCommand
[lsp-ws-applyedit]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit
[lsp-win-showmessage]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage
[lsp-win-logmessage]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_logMessage
[lsp-documentlink]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentLink
[lsp-documentlink-resolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLink_resolve
[lsp-moniker]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_moniker
[lsp-ws-symbolresolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbolResolve
[lsp-ws-textdocumentcontent]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_textDocumentContent
[lsp-ws-textdocumentcontentrefresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_textDocumentContentRefresh
[lsp-inlinecompletion]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineCompletion
[lsp-inlinevalue]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineValue
[lsp-ws-inlinevalue-refresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_inlineValue_refresh
[lsp-codelens-resolve]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens_resolve
[lsp-codelens-refresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens_refresh
[lsp-semantictokens-deltarequest]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_deltaRequest
[lsp-ws-foldingrange-refresh]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_foldingRange_refresh
[lsp-ws-diagnostic]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_diagnostic
[lsp-documentrangesformattingparams]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentRangesFormattingParams
[lsp-linkededitingrange]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_linkedEditingRange
[lsp-didrename]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didRename
[lsp-ws-willcreatefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willCreateFiles
[lsp-ws-didcreatefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didCreateFiles
[lsp-ws-willrenamefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willRenameFiles
[lsp-ws-didrenamefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didRenameFiles
[lsp-ws-willdeletefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willDeleteFiles
[lsp-ws-diddeletefiles]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didDeleteFiles
[lsp-win-showmessagerequest]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest
[lsp-win-showdocument]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showDocument
[lsp-win-workdoneprogress-cancel]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_cancel
[zls-handlers]: https://github.com/zigtools/zls/blob/0.17.0/src/Server.zig#L1152-L1188
[zls-config]: https://github.com/zigtools/zls/blob/0.17.0/src/Config.zig
[zls-completion]: https://github.com/zigtools/zls/blob/0.17.0/src/features/completions.zig
[zls-build]: https://zigtools.org/zls/guides/build-on-save/
[zls-actions]: https://github.com/zigtools/zls/blob/0.17.0/src/features/code_actions.zig
[swift-service]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Sources/SwiftLanguageService/SwiftLanguageService.swift
[swift-config]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Configuration%20File.md
[swift-reference-documents]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacegetreferencedocument
[swift-docc]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekittextdocumentdoccdocumentation
[swift-symbol-info]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#textdocumentsymbolinfo
[swift-refactors]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Refactoring%20Actions.md
[swift-macros]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Sources/SwiftLanguageService/ExpandMacroCommand.swift
[swift-diagnostic-actions]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#diagnostic
[swift-completion]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#textdocumentcompletion
[swift-hierarchy]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#callhierarchyitem-and-typehierarchyitem
[swift-token-modifiers]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#semantic-token-modifiers
[swift-token-types]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#semantic-token-types
[swift-document-tests]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekittextdocumenttests
[swift-workspace-tests]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacetests
[swift-playgrounds]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspaceplaygrounds
[swift-peek]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacepeekdocuments
[swift-reindex]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacetriggerreindex
[swift-active-document]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitwindowdidchangeactivedocument
[swift-set-options]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacesetoptions
[swift-options]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacesourcekitoptions
[swift-output-paths]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspaceoutputpaths
[swift-synchronize]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#sourcekitworkspacesynchronize
[swift-logs]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md#windowlogmessage
[swift-prefix]: https://github.com/swiftlang/sourcekit-lsp/pull/2632
