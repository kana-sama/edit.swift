# LSP Feature Checklist

## Support by Language Server

✓ works in Edit. A blank cell means the server supports the method and Edit could add it. ✗ means the server does not support the method for Zig or Swift, respectively. Implemented methods come first, then implementation candidates, then methods unavailable on both servers.

Checked November 25, 2026 against ZLS 0.17.0 and SourceKit-LSP bundled with Apple Swift 6.4 (swiftlang-6.4.0.33.1). Some methods depend on client capabilities, server settings or project indexing. The table covers [LSP 3.18][lsp] editor features and the messages that enable them. It is a catalog of options for Edit.

| Method | ZLS | SourceKit-LSP |
| --- | :---: | :---: |
| [`textDocument/definition`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_definition) | ✓ | ✓ |
| [`textDocument/references`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_references) | ✓ | ✓ |
| [`textDocument/documentHighlight`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentHighlight) | ✓ | ✓ |
| [`textDocument/documentSymbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentSymbol) | ✓ | ✓ |
| [`workspace/symbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbol) | ✓ | ✓ |
| [`textDocument/hover`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_hover) | ✓ | ✓ |
| [`textDocument/prepareRename`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareRename) | ✓ | ✓ |
| [`textDocument/rename`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rename) | ✓ | ✓ |
| [`window/workDoneProgress/create`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create) | ✓ | ✓ |
| [`$/progress`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress) | ✓ | ✓ |
| [`workspace/didChangeWorkspaceFolders`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeWorkspaceFolders) | ✓ |  |
| [`workspace/didChangeWatchedFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeWatchedFiles) |  | ✓ |
| [`textDocument/declaration`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_declaration) |  | ✗ |
| [`textDocument/typeDefinition`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_typeDefinition) |  |  |
| [`textDocument/implementation`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_implementation) | ✗ |  |
| [`textDocument/prepareCallHierarchy`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareCallHierarchy) | ✗ |  |
| [`callHierarchy/incomingCalls`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_incomingCalls) | ✗ |  |
| [`callHierarchy/outgoingCalls`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_outgoingCalls) | ✗ |  |
| [`textDocument/prepareTypeHierarchy`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareTypeHierarchy) | ✗ |  |
| [`typeHierarchy/supertypes`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_supertypes) | ✗ |  |
| [`typeHierarchy/subtypes`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_subtypes) | ✗ |  |
| [`textDocument/completion`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_completion) |  |  |
| [`completionItem/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItem_resolve) | ✗ |  |
| [`textDocument/signatureHelp`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_signatureHelp) |  |  |
| [`textDocument/inlayHint`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlayHint) |  |  |
| [`inlayHint/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint_resolve) | ✗ |  |
| [`workspace/inlayHint/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_inlayHint_refresh) |  | ✗ |
| [`textDocument/codeLens`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeLens) | ✗ |  |
| [`textDocument/semanticTokens/full`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_fullRequest) |  |  |
| [`textDocument/semanticTokens/range`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_rangeRequest) |  |  |
| [`workspace/semanticTokens/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_refreshRequest) |  |  |
| [`textDocument/foldingRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_foldingRange) |  |  |
| [`textDocument/selectionRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_selectionRange) |  |  |
| [`textDocument/documentColor`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentColor) | ✗ |  |
| [`textDocument/colorPresentation`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_colorPresentation) | ✗ |  |
| [`textDocument/publishDiagnostics`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics) |  |  |
| [`textDocument/diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_diagnostic) | ✗ |  |
| [`workspace/diagnostic/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic_refresh) | ✗ |  |
| [`textDocument/codeAction`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeAction) |  |  |
| [`codeAction/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeAction_resolve) | ✗ |  |
| [`textDocument/formatting`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_formatting) |  |  |
| [`textDocument/rangeFormatting`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rangeFormatting) | ✗ |  |
| [`textDocument/onTypeFormatting`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_onTypeFormatting) | ✗ |  |
| [`textDocument/willSave`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_willSave) | ✗ |  |
| [`textDocument/willSaveWaitUntil`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_willSaveWaitUntil) |  | ✗ |
| [`textDocument/didSave`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didSave) |  |  |
| [`workspace/configuration`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration) |  | ✗ |
| [`workspace/didChangeConfiguration`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeConfiguration) |  | ✗ |
| [`workspace/executeCommand`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_executeCommand) | ✗ |  |
| [`workspace/applyEdit`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit) |  |  |
| [`window/showMessage`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage) |  | ✗ |
| [`window/logMessage`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_logMessage) |  |  |
| [`textDocument/documentLink`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentLink) | ✗ | ✗ |
| [`documentLink/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLink_resolve) | ✗ | ✗ |
| [`textDocument/moniker`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_moniker) | ✗ | ✗ |
| [`workspaceSymbol/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbolResolve) | ✗ | ✗ |
| [`workspace/textDocumentContent`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_textDocumentContent) | ✗ | ✗ |
| [`workspace/textDocumentContent/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_textDocumentContentRefresh) | ✗ | ✗ |
| [`textDocument/inlineCompletion`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineCompletion) | ✗ | ✗ |
| [`textDocument/inlineValue`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineValue) | ✗ | ✗ |
| [`workspace/inlineValue/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_inlineValue_refresh) | ✗ | ✗ |
| [`codeLens/resolve`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens_resolve) | ✗ | ✗ |
| [`workspace/codeLens/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens_refresh) | ✗ | ✗ |
| [`textDocument/semanticTokens/full/delta`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_deltaRequest) | ✗ | ✗ |
| [`workspace/foldingRange/refresh`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_foldingRange_refresh) | ✗ | ✗ |
| [`workspace/diagnostic`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_diagnostic) | ✗ | ✗ |
| [`textDocument/rangesFormatting`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentRangesFormattingParams) | ✗ | ✗ |
| [`textDocument/linkedEditingRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_linkedEditingRange) | ✗ | ✗ |
| [`textDocument/didRename`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didRename) | ✗ | ✗ |
| [`workspace/willCreateFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willCreateFiles) | ✗ | ✗ |
| [`workspace/didCreateFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didCreateFiles) | ✗ | ✗ |
| [`workspace/willRenameFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willRenameFiles) | ✗ | ✗ |
| [`workspace/didRenameFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didRenameFiles) | ✗ | ✗ |
| [`workspace/willDeleteFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willDeleteFiles) | ✗ | ✗ |
| [`workspace/didDeleteFiles`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didDeleteFiles) | ✗ | ✗ |
| [`window/showMessageRequest`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest) | ✗ | ✗ |
| [`window/showDocument`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showDocument) | ✗ | ✗ |
| [`window/workDoneProgress/cancel`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_cancel) | ✗ | ✗ |

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

Update this checklist in the same change as an Edit LSP feature or server integration. Move implemented rows or items to the top of their lists. When updating the server versions recorded here, recheck their `initialize` capabilities, conditional registrations and language-specific handlers before changing a blank or a ✗. Add extension candidates when they become available in a supported toolchain.

[lsp]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
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
