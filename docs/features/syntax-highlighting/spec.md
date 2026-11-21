# Syntax highlighting

Edit colors source code and markup with Tree-sitter. TextKit 2 applies colors as rendering attributes. Syntax colors leave the document text, editing metrics, undo history, dirty state, and saved bytes intact.

- Auto Detect is the initial mode. It uses a case-insensitive exact basename match first and then the longest recognized extension. Untitled and unrecognized files display as Plain Text. Save and Save As resolve the new path in automatic mode.
- **Change Language Mode…** in Control opens the language picker for the active document. Auto Detect appears first, Plain Text second, and the bundled languages follow alphabetically. The active choice is indicated. Select a language to override detection or select Plain Text to remove colors. Auto Detect clears the override and restores the mode for the current path.
- Manual choices follow their buffer through Save As. Edit remembers up to 100 named path overrides and restores the mode of each saved session document, including an untitled draft. An older session or an unknown mode can fall back to automatic detection.
- First-load and mode changes request syntax immediately. Edits schedule a background parse after 45 ms and leave existing colors in place until the replacement arrives. For larger documents, Tree-sitter queries the first visible range before collecting the remaining captures from the same tree. Scrolling applies the available captures to newly visible text. A canceled or outdated result cannot recolor the current document. An unavailable language query leaves editable plain text. If the first result is pending for 150 ms, the native window shows an activity indicator. Rendering adapts to macOS appearance.

## Bundled languages

C, C++, Clojure, CSS, Erlang, Go, HTML, JavaScript, JavaScript JSX, JSON, Lua, Markdown, Python, Ruby, Rust, Shell Script, Solidity, Swift, TOML, TypeScript, TypeScript JSX, YAML, and Zig. JSON also recognizes comments in JSONC, Clojure covers EDN, and Zig covers ZON. Markdown uses inline and fenced-code grammars and HTML supports embedded JavaScript and CSS.

[Grammar versions and licenses](../../../resources/syntax/README.md)

## Acceptance

- Open `main.RS`, `widget.test.ts`, `widget.tsx`, `data.jsonc`, `.zshrc`, `Cargo.lock`, `Gemfile`, `library.h`, `build.zig.zon`, `app.app.src`, and `deps.edn`. Check that their resolved languages and syntax colors match the file modes.
- Select Rust on an untitled buffer, save to a different extension, and verify the manual mode follows the buffer. Select Plain Text, and then Auto Detect to restore path-based colors. Quit and reopen named and untitled drafts to check persistent choices.
- Change a highlighted buffer containing Unicode and incomplete code. Undo and redo, and switch modes while highlighting runs. Verify that no obsolete syntax result overlays the document and that the caret, selections, scroll, and dirty state behave normally.
- `./script/check` checks real captures in every bundled grammar and validates Rust rendering before and after scrolling through a 2,400-line document, Plain Text clearing, and manual mode recovery on a quiet AppKit window.
