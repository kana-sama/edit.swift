# Syntax highlighting

Edit colors source code and markup with Tree-sitter. TextKit 2 applies rendering attributes to newly visible fragments and updates foreground attributes in the visible text to repaint glyphs already on screen. Syntax colors leave the document text, editing metrics, undo history, dirty state, and saved bytes intact.

- Auto Detect is the initial mode. It uses a case-insensitive exact basename match first and then the longest recognized extension. Untitled and unrecognized files display as Plain Text. Save and Save As resolve the new path in automatic mode.
- **Change Language Mode…** in Control and a right-click on the title bar file icon open the same language picker for the current document. Auto Detect appears first, Plain Text second, and the bundled languages follow alphabetically. The active choice is indicated. Select a language to override detection or select Plain Text to remove colors. Auto Detect clears the override and restores the mode for the current path.
- Manual choices follow their buffer through Save As. Edit remembers up to 100 named path overrides and restores the mode of each saved session document, including an untitled draft. An older session or an unknown mode can fall back to automatic detection.
- Prepare syntax for source files up to 64 KiB on the same background task that reads the file, so the first frame of the opened buffer can draw its colors. Mode changes request syntax immediately and redraw the visible editor as results become available, even while the editor is stationary. Edits schedule a background parse after 45 ms and leave existing colors in place until the replacement arrives. For larger documents, Tree-sitter queries the first visible range before collecting the remaining captures from the same tree. TextKit applies available captures before preparing each newly visible rendering surface during scrolling. A canceled or outdated result cannot recolor the current document. An unavailable language query leaves editable plain text. If the first result is pending for 150 ms, the native window shows an activity indicator. Rendering adapts to macOS appearance.

## Bundled languages

C, C++, Clojure, CSS, Erlang, Go, HTML, JavaScript, JavaScript JSX, JSON, Lua, Markdown, Python, Ruby, Rust, Shell Script, Solidity, Swift, TOML, TypeScript, TypeScript JSX, YAML, and Zig. JSON also recognizes comments in JSONC, Clojure covers EDN, and Zig covers ZON. Markdown uses inline and fenced-code grammars and HTML supports embedded JavaScript and CSS.

[Grammar versions and licenses](../../../resources/syntax/README.md)

## Acceptance

- Open `main.RS`, `widget.test.ts`, `widget.tsx`, `data.jsonc`, `.zshrc`, `Cargo.lock`, `Gemfile`, `library.h`, `build.zig.zon`, `app.app.src`, and `deps.edn`. Check that their resolved languages and syntax colors match the file modes.
- Select Rust on an untitled buffer, save to a different extension, and verify the manual mode follows the buffer. Select Plain Text, and then Auto Detect to restore path-based colors. Quit and reopen named and untitled drafts to check persistent choices.
- Change a highlighted buffer containing Unicode and incomplete code. Undo and redo, and switch modes while highlighting runs. Verify that no obsolete syntax result overlays the document and that the caret, selections, scroll, and dirty state behave normally.
- `./script/check` checks real captures in every bundled grammar and checks the pixels on the first frame after opening small Rust and mid-size Swift files and after scrolling. It samples the stationary viewport after opening and reopening a Swift file above 64 KiB, then checks color when scrolling. It also checks that highlighting preserves the text, selection, dirty state, and undo history, and validates Plain Text clearing and manual mode recovery.
