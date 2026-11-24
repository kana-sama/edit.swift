# LSP Features in Edit

Status as of November 24, 2026. Check off a feature once it works in Edit through a language server and link to its feature spec.

The checklist covers user-facing features from LSP 3.18 and extensions implemented by popular language servers. Availability varies by language, server, and project. [LSP 3.18 Specification][lsp]

The identifiers after each title are request or notification methods. Command IDs and code action kinds appear alongside the methods where they identify a specific action.

## Code Navigation

- [x] **Go to Definition** (`textDocument/definition`) [ZLS specification](features/lsp/spec.md#cmd-hover-and-cmd-click)
- [ ] **Go to Declaration** (`textDocument/declaration`)
- [ ] **Go to Type Definition** (`textDocument/typeDefinition`)
- [ ] **Go to Implementation** (`textDocument/implementation`)
- [x] **Find All References** (`textDocument/references`) [ZLS specification](features/lsp/spec.md#references-in-the-sidebar)
- [x] **Document Highlights** (`textDocument/documentHighlight`) — Highlight occurrences of the same symbol in the current file. [Specification](features/lsp-document-highlights/spec.md)
- [ ] **Document Symbols** (`textDocument/documentSymbol`) — Browse the current file's outline and jump to classes, functions, and other declarations.
- [ ] **Workspace Symbols** (`workspace/symbol`) — Search for symbols by name across the project.
- [ ] **Call Hierarchy** (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`) — Browse incoming and outgoing calls.
- [ ] **Type Hierarchy** (`textDocument/prepareTypeHierarchy`, `typeHierarchy/supertypes`, `typeHierarchy/subtypes`) — Browse supertypes and subtypes.
- [ ] **Monikers** (`textDocument/moniker`) — Navigate to the same symbol across projects when a compatible index is available.
- [ ] **Document Links** (`textDocument/documentLink`, `documentLink/resolve`) — Open links recognized in source code and documents, including links to local files.
- [ ] **Open Library Source and Generated Interfaces** (`workspace/textDocumentContent`, `java/classFileContents`, `sourcekit/workspace/getReferenceDocument`, `deno/virtualTextDocument`) — Read decompiled Java classes, generated Swift module interfaces, or cached Deno modules in the editor. [JDT LS][java] · [SourceKit-LSP][swift] · [Deno][deno]
- [ ] **Go to Source Definition** (`workspace/executeCommand` with `_typescript.goToSourceDefinition`) — Jump from a TypeScript declaration to the library's implementation when the source is available. [TypeScript Language Server][ts]
- [ ] **Switch Between Source and Header** (`textDocument/switchSourceHeader`) [clangd][clangd]
- [ ] **Go to Parent Module** (`experimental/parentModule`) [rust-analyzer][ra]
- [ ] **Open Cargo.toml** (`experimental/openCargoToml`) — Open the manifest for the current Rust crate. [rust-analyzer][ra]
- [ ] **Go to Super, Imports, and Augmentations** (`dart/textDocument/super`, `dart/textDocument/imports`, `dart/textDocument/augmented`, `dart/textDocument/augmentation`) — Navigate to overridden Dart members, import directives, or augmentation files. [Dart Analysis Server][dart]
- [ ] **Open Stack Trace Location** (`workspace/executeCommand` with `java.project.resolveStackTraceLocation`) — Jump from a Java stack trace frame to the corresponding source line. [JDT LS][java-commands]
- [ ] **Find Variables of a Type** (`$ccls/vars`) — Find fields and variables of a given C or C++ type. [ccls][ccls]
- [ ] **Find Text in Dependency JARs** (`metals/findTextInDependencyJars`) — The Metals protocol heading uses this spelling, and its method field says `metals/findTextInDependecyJars`. [Metals][metals-jars]

[LSP Language Features][lsp-language] · [LSP Workspace Features][lsp-workspace]

## Completions, Hints, and Display

- [x] **Hover** (`textDocument/hover`) — Show type information, signatures, and documentation for the symbol under the pointer. [ZLS specification](features/lsp/spec.md#hover)
- [ ] **Code Completion** (`textDocument/completion`) — Show suggestions as you type or on demand.
- [ ] **Auto Imports** (`textDocument/completion`, `completionItem/resolve`) — Complete a symbol from another module and insert its import.
- [ ] **Snippet Completions** (`textDocument/completion`) — Insert a code template and tab through its placeholders.
- [ ] **Inline Completions** (`textDocument/inlineCompletion`) — Show and accept a suggested continuation directly in the editor.
- [ ] **Signature Help** (`textDocument/signatureHelp`) — Show overloads and highlight the active parameter as you enter arguments.
- [ ] **Inlay Hints** (`textDocument/inlayHint`) — Show information such as inferred types and parameter names alongside the code.
- [ ] **Inline Values** (`textDocument/inlineValue`) — Show variable values alongside the code while debugging.
- [ ] **CodeLens** (`textDocument/codeLens`, `codeLens/resolve`) — Show information or actions next to declarations, such as reference counts or Run Test.
- [ ] **Semantic Highlighting** (`textDocument/semanticTokens/full`, `textDocument/semanticTokens/range`) — Color identifiers by their role, such as type, parameter, or property.
- [ ] **Code Folding** (`textDocument/foldingRange`)
- [ ] **Expand and Shrink Selection** (`textDocument/selectionRange`) — Move between nested syntax ranges, such as an expression, its enclosing block, and the enclosing function.
- [ ] **Document Colors and Color Picker** (`textDocument/documentColor`, `textDocument/colorPresentation`) — Show swatches for colors in source code and edit their values with a color picker.
- [ ] **Inactive Preprocessor Regions** (`textDocument/inactiveRegions`) — Dim C and C++ code excluded by the current preprocessor conditions. [clangd][clangd]
- [ ] **Closing Labels** (`dart/textDocument/publishClosingLabels`) — Show labels beside closing delimiters in nested Dart expressions. [Dart Analysis Server][dart]
- [ ] **Flutter Outline** (`dart/textDocument/publishFlutterOutline`) — Browse the widget tree. [Dart Analysis Server][dart]
- [ ] **Open Documentation** (`experimental/externalDocs`, `textDocument/codeAction` with `source.doc`, `sourcekit/textDocument/doccDocumentation`) — Open package or symbol documentation, including locally generated docs. [rust-analyzer][ra] · [gopls][go-web] · [SourceKit-LSP][swift]
- [ ] **Next Edit Suggestions** (`textDocument/copilotInlineEdit`) — Suggest a change elsewhere in the file, including replacements and deletions. [GitHub Copilot Language Server][copilot]
- [ ] **Panel Completions** (`textDocument/copilotPanelCompletion`) — Browse several alternative completions in a separate panel. [GitHub Copilot Language Server][copilot]

[LSP Language Features][lsp-language]

## Diagnostics and Quick Fixes

- [ ] **Live Diagnostics** (`textDocument/diagnostic`, `textDocument/publishDiagnostics`) — See errors, warnings, and hints in the current file as you edit.
- [ ] **Workspace Diagnostics** (`workspace/diagnostic`) — Browse and jump to problems across the project, including in closed files.
- [ ] **Diagnostic Details** (`textDocument/diagnostic`, `textDocument/publishDiagnostics`) — Show related source locations and links to rule documentation.
- [ ] **Unnecessary and Deprecated Code** (`textDocument/diagnostic`, `textDocument/publishDiagnostics`) — Visually mark code reported as unnecessary or deprecated.
- [ ] **Quick Fix** (`textDocument/codeAction` with `quickfix`) — Apply a suggested fix for a specific problem.
- [ ] **Fix All** (`textDocument/codeAction` with `source.fixAll`) — Apply all available automatic fixes in the current file.
- [ ] **Disable Rule for Line or File** (`workspace/executeCommand` with `eslint.applyDisableLine` or `eslint.applyDisableFile`) [ESLint][eslint]
- [ ] **Spelling and Grammar Checks** (`textDocument/publishDiagnostics`, `textDocument/codeAction`) — Flag issues, add words to the dictionary, and hide false positives. [LTeX][ltex]
- [ ] **Reanalyze Workspace** (`dart/reanalyze`, `rust-analyzer/runFlycheck`) — Rerun project diagnostics on demand and see the progress. [Dart Analysis Server][dart] · [rust-analyzer][ra]

[LSP Diagnostics and Code Actions][lsp-language]

## Formatting and Code Actions

- [ ] **Format Document** (`textDocument/formatting`)
- [ ] **Format Selection** (`textDocument/rangeFormatting`)
- [ ] **Format Multiple Selections** (`textDocument/rangesFormatting`)
- [ ] **Format on Type** (`textDocument/onTypeFormatting`) — Format code after a trigger character, such as a closing brace.
- [ ] **Format on Save** (`textDocument/formatting`)
- [ ] **Code Actions on Save** (`textDocument/codeAction`) — Apply selected fixes automatically when saving.
- [ ] **Rename Symbol** (`textDocument/prepareRename`, `textDocument/rename`) — Update references across affected files.
- [ ] **Linked Editing** (`textDocument/linkedEditingRange`) — Edit related ranges together, such as matching HTML tags.
- [ ] **Auto Close Tags and Quotes** (`html/autoInsert`) [VS Code HTML Language Server][html]
- [ ] **Update Imports and Links on File Move or Rename** (`workspace/willRenameFiles`, `markdown/getEditForFileRenames`) [LSP File Operations][lsp-workspace] · [Markdown Language Server][markdown]
- [ ] **Update Code on File Creation or Deletion** (`workspace/willCreateFiles`, `workspace/willDeleteFiles`) — Get suggested edits to affected code. [LSP File Operations][lsp-workspace]
- [ ] **Organize Imports** (`textDocument/codeAction` with `source.organizeImports`) [LSP][lsp-language] · [TypeScript Language Server][ts] · [Ruff][ruff]
- [ ] **Add Missing Imports** (`textDocument/codeAction` with `source.addMissingImports.ts`) [TypeScript Language Server][ts]
- [ ] **Remove Unused Imports** (`textDocument/codeAction` with `source.removeUnusedImports.ts`) [TypeScript Language Server][ts]
- [ ] **Extract Variable or Function** (`textDocument/codeAction` with `refactor.extract`) — Move an expression or block into a new variable or function. [gopls][go] · [SourceKit-LSP][swift-refactors]
- [ ] **Inline Variable or Function** (`textDocument/codeAction` with `refactor.inline`) — Substitute its value or body at the use sites. [gopls][go] · [TypeScript Language Server][ts]
- [ ] **Move Declaration** (`java/getMoveDestinations`, `java/move`) — Move a declaration to another file and update its references. [JDT LS][java]
- [ ] **Change Signature** (`java/getChangeSignatureInfo`, `java/getRefactorEdit`) — Change a function's signature and update its callers. [JDT LS][java]
- [ ] **Generate Members** (`java/generateConstructors`, `java/generateAccessors`, `java/addOverridableMethods`, `java/generateDelegateMethods`) — Generate constructors, accessors, overrides, or method implementations. [JDT LS][java]
- [ ] **Create Type Stub** (`workspace/executeCommand` with `pyright.createtypestub`) — Generate a type stub for a Python library. [Pyright][pyright]
- [ ] **Snippet Placeholders in Refactorings** (`textDocument/codeAction`, `codeAction/resolve`) — Tab through editable placeholders after applying a refactoring. [LSP 3.18][lsp-changes] · [rust-analyzer][ra]
- [ ] **Join Lines** (`experimental/joinLines`) — Join lines with language-aware spacing and syntax adjustments. [rust-analyzer][ra]
- [ ] **Move Item** (`experimental/moveItem`) — Move an entire code item, such as a function, up or down. [rust-analyzer][ra]
- [ ] **Continue Comment on Enter** (`experimental/onEnter`) — Insert the comment prefix and indentation for the new line. [rust-analyzer][ra]
- [ ] **Structural Search** (`experimental/ssr`, `biome/search_pattern`) — Match code patterns with placeholders. [rust-analyzer][ra] · [Biome][biome]
- [ ] **Structural Replace** (`experimental/ssr`) — Replace matches while reusing captured parts of the original code. [rust-analyzer][ra]
- [ ] **Edit Arguments** (`dart/textDocument/editableArguments`, `dart/textDocument/editArgument`) — Edit argument values in a form, such as Flutter widget properties. [Dart Analysis Server][dart]
- [ ] **Sort JSON Keys** (`json/sort`) [VS Code JSON Language Server][json]
- [ ] **Tailwind CSS: Sort Selection** (`@/tailwindCSS/sortSelection`) — Sort classes in the selected text. Available in Tailwind CSS IntelliSense prereleases. [Tailwind CSS IntelliSense][tailwind] · [Server request][tailwind-server]

[LSP Formatting, Rename, and Code Actions][lsp-language] · [Code Actions on Save in VS Code][vscode-save]

## Schemas and Markup

- [ ] **JSON and YAML Schema Support** (`json/schemaAssociations`, `json/languageStatus`, `yaml/get/jsonSchema`, `yaml/get/all/jsonSchemas`) — Select or associate a schema, see which schema is active, and use it for validation and completion. [VS Code JSON Language Server][json] · [YAML Language Server][yaml]
- [ ] **HTML and CSS Custom Data** (`html/customDataChanged`, `html/customDataContent`, `css/customDataChanged`, `fs/content`) — Get suggestions for custom HTML tags and attributes or CSS properties. [VS Code HTML Language Server][html] · [VS Code CSS Language Server][css]
- [ ] **Find File References** (`markdown/getReferencesToFileInWorkspace`) — Find Markdown files that link to the current file. [Markdown Language Server][markdown]
- [ ] **Vue Template IntelliSense** (`textDocument/completion`, `textDocument/definition`) — Get completions and type navigation in Vue components, including their templates. [Vue Language Tools][vue]
- [ ] **Notebook Cell Language Features** (`textDocument/completion`, `textDocument/diagnostic`, `textDocument/publishDiagnostics`) — Get completion and diagnostics for code in notebook cells. [LSP Notebook Support][lsp-notebook]

## Build, Run, and Test

- [ ] **Run or Debug at Entry Point** (`experimental/runnables`) [rust-analyzer][ra]
- [ ] **Test Discovery** (`sourcekit/textDocument/tests`, `sourcekit/workspace/tests`, `experimental/discoverTest`, `deno/testModule`, `metals/executeClientCommand` with `metals-update-test-explorer`) — Browse tests by file or suite and jump to their source. [SourceKit-LSP][swift] · [rust-analyzer][ra] · [Deno][deno] · [Metals][metals-tests]
- [ ] **Run Tests** (`experimental/runTest`, `deno/testRun`, `deno/testRunCancel`) — Run a test, a suite, or all tests, see results as they arrive, and cancel the run. [rust-analyzer][ra] · [Deno][deno]
- [ ] **Find Related Tests** (`rust-analyzer/relatedTests`) — Find tests related to the current function. [rust-analyzer][ra]
- [ ] **Generate Test** (`textDocument/codeAction` with `source.addTest`) — Create a test skeleton for a function. [gopls][go]
- [ ] **Run Code Generators** (`workspace/executeCommand` with `gopls.generate`) — Run project code generators with `go generate`. [gopls][go-commands]
- [ ] **Build Project** (`java/buildWorkspace`, `java/buildProjects`, `textDocument/build`) — Build the project and jump to build errors. [JDT LS][java] · [Texlab][texlab]
- [ ] **Run Task** (`deno/task`) — Choose a project task returned by the server and run it through Deno. [Deno][deno]
- [ ] **Run Swift Playground** (`sourcekit/workspace/playgrounds`, `textDocument/codeLens` returns `swift.play`) — Find and run `#Playground` blocks from source. [SourceKit-LSP][swift]
- [ ] **Evaluate Comments** (`textDocument/codeLens`, `textDocument/codeAction`, `workspace/executeCommand`) — Evaluate an expression in a Haskell comment and write the result back to the source. [Haskell Language Server][hls]
- [ ] **SyncTeX Forward and Inverse Search** (`textDocument/forwardSearch`, `window/showDocument`) — Jump between a LaTeX source line and its corresponding position in the PDF. [Texlab][texlab]

## Project Tools

- [ ] **Language Server Progress** (`$/progress`, `window/workDoneProgress/cancel`) — See indexing and analysis progress and cancel operations when supported. [LSP Progress][lsp-window] · [SourceKit-LSP][swift]
- [ ] **Reindex or Reload Project** (`sourcekit/workspace/triggerReindex`, `java/projectConfigurationsUpdate`, `rust-analyzer/reloadWorkspace`) — Refresh the index or reload build settings on demand. [SourceKit-LSP][swift] · [JDT LS][java] · [rust-analyzer][ra]
- [ ] **Select Project Context** (`textDocument/_vs_getProjectContexts`) — Choose which project or .NET target framework to use for a shared source file. [Roslyn][roslyn]
- [ ] **Browse Project Dependencies** (`rust-analyzer/fetchDependencyList`, `rust-analyzer/viewCrateGraph`, `rubyLsp/workspace/dependencies`, `workspace/executeCommand` with `terraform-ls.module.calls` or `terraform-ls.module.callers`) — See dependencies and how they relate to one another. [rust-analyzer][ra] · [Ruby LSP][ruby] · [Terraform Language Server][terraform]
- [ ] **Manage Go Module Dependencies** (`workspace/executeCommand` with `gopls.upgrade_dependency` or `gopls.tidy`) — Update dependencies or tidy module files. [gopls][go]
- [ ] **Cache Remote Modules** (`deno/cache`) — Download Deno modules so their source and language features are available locally. [Deno][deno]
- [ ] **Inspect Syntax Tree or Intermediate Representation** (`textDocument/ast`, `rust-analyzer/viewSyntaxTree`, `rust-analyzer/viewHir`, `biome/get_syntax_tree`, `rubyLsp/textDocument/showSyntaxTree`) [clangd][clangd] · [rust-analyzer][ra] · [Biome][biome] · [Ruby LSP][ruby]
- [ ] **Expand Macro** (`rust-analyzer/expandMacro`, `workspace/executeCommand` with `expand.macro.command`) — Open the generated expansion of a macro invocation. [rust-analyzer][ra] · [SourceKit-LSP][swift-expand]
- [ ] **View Memory Layout** (`rust-analyzer/viewRecursiveMemoryLayout`) — Inspect a Rust type's size, alignment, and field offsets. [rust-analyzer][ra]
- [ ] **View Assembly and Compiler Optimization Details** (`workspace/executeCommand` with `gopls.assembly` or `gopls.gc_details`) [gopls][go] · [gopls Web-Based Features][go-web]
- [ ] **Inspect Language Server Performance** (`deno/performance`, `$/memoryUsage`) — View analysis timings or memory usage. [Deno][deno] · [clangd][clangd]

[lsp]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
[lsp-language]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#languageFeatures
[lsp-workspace]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFeatures
[lsp-window]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#windowFeatures
[lsp-notebook]: https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/notebookDocument/notebook.md
[lsp-changes]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#version_3_18_0
[clangd]: https://clangd.llvm.org/extensions.html
[ccls]: https://github.com/MaskRay/ccls/wiki/LSP-Extensions
[ra]: https://rust-analyzer.github.io/book/contributing/lsp-extensions.html
[swift]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Contributor%20Documentation/LSP%20Extensions.md
[swift-refactors]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Refactoring%20Actions.md
[swift-expand]: https://github.com/swiftlang/sourcekit-lsp/blob/main/Sources/SwiftLanguageService/ExpandMacroCommand.swift
[ts]: https://github.com/typescript-language-server/typescript-language-server/blob/v6.0.3/README.md#features
[go]: https://go.dev/gopls/features/
[go-web]: https://go.dev/gopls/features/web
[go-commands]: https://github.com/golang/tools/blob/master/gopls/internal/protocol/command/command_gen.go
[java]: https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/main/org.eclipse.jdt.ls.core/src/org/eclipse/jdt/ls/core/internal/lsp/JavaProtocolExtensions.java
[java-commands]: https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/main/org.eclipse.jdt.ls.core/plugin.xml
[dart]: https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server/tool/lsp_spec/README.md#custom-fields-methods-and-notifications
[deno]: https://docs.deno.com/runtime/reference/lsp_integration/
[metals-jars]: https://scalameta.org/metals/docs/integrations/new-editor/#metalsfindtextindependencyjars
[metals-tests]: https://scalameta.org/metals/docs/integrations/test-explorer/
[copilot]: https://github.com/github/copilot-language-server-release/blob/main/README.md
[eslint]: https://github.com/microsoft/vscode-eslint/blob/main/server/src/eslintServer.ts
[ruff]: https://docs.astral.sh/ruff/editors/features/
[ltex]: https://valentjn.github.io/ltex/ltex-ls/server-usage.html
[html]: https://github.com/microsoft/vscode/blob/main/extensions/html-language-features/server/src/htmlServer.ts
[css]: https://github.com/microsoft/vscode/blob/main/extensions/css-language-features/server/src/cssServer.ts
[json]: https://github.com/microsoft/vscode/blob/main/extensions/json-language-features/server/src/jsonServer.ts
[yaml]: https://github.com/redhat-developer/yaml-language-server#lsp-extensions
[markdown]: https://github.com/microsoft/vscode-markdown-languageserver#server-capabilities
[vue]: https://github.com/vuejs/language-tools/discussions/5456
[pyright]: https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/commands/commands.ts
[biome]: https://github.com/biomejs/biome/blob/main/crates/biome_lsp/src/server.rs
[tailwind]: https://github.com/tailwindlabs/tailwindcss-intellisense/blob/main/packages/vscode-tailwindcss/README.md#tailwind-css-sort-selection
[tailwind-server]: https://github.com/tailwindlabs/tailwindcss-intellisense/blob/main/packages/tailwindcss-language-server/src/tw.ts#L810-L848
[vscode-save]: https://code.visualstudio.com/docs/languages/javascript#_code-actions-on-save
[texlab]: https://github.com/latex-lsp/texlab/wiki/Previewing
[hls]: https://github.com/haskell/haskell-language-server/blob/master/plugins/hls-eval-plugin/README.md
[roslyn]: https://github.com/dotnet/vscode-csharp/pull/7328
[ruby]: https://github.com/Shopify/ruby-lsp/blob/main/lib/ruby_lsp/server.rb
[terraform]: https://github.com/hashicorp/terraform-ls/blob/main/docs/commands.md
