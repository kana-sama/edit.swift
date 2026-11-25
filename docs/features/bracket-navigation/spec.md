# Bracket matching and navigation

The behavior reference is the default bracket matching in [VS Code 1.147.0](https://code.visualstudio.com/updates/v1_147). Edit uses its native text rendering, menus, and Control palette.

## Matching

- Use the bracket pairs for the document's language. Plain Text and Swift support `()`, `[]`, and `{}`. Quotes and angle operators in Swift are ordinary text for these actions. JavaScript supports `${…}` in template substitutions. Tree-sitter supplies the lexical context to exclude bracket-like text in comments, string contents, and regular expressions while allowing delimiters in embedded expressions. Bundled HTML and Markdown injections supply their own bracket pairs.
- VS Code extensions can classify individual tokens through their TextMate scopes. Edit uses the bundled Tree-sitter grammars for this context, so some extension-specific tokens, such as JavaScript documentation scopes, can behave differently.
- An empty selection in the focused editor highlights both delimiters of one complete pair. First consider pairs whose opening or closing token touches the caret, including either edge of the token. If multiple complete pairs touch it, use the one with the rightmost touching token. Otherwise use the innermost complete pair that strictly encloses the caret. An unmatched delimiter contributes no highlight of its own.
- Evaluate each empty selection independently. Nonempty selections contribute no bracket highlight. Clear the highlights when the editor loses focus or there are more than 100 selections. Refresh them after caret movement, edits, and language or document changes. While ordinary typing preserves a pair and the caret stays with it, keep both highlights at their updated positions until the new index is ready. Invalidate the displayed pair when an edit can affect delimiters or lexical boundaries. Navigation commands use the current index. Preserve native selection, syntax colors, and Find marks.

## Commands

Expose **Go to Bracket** and **Select to Bracket** in Control and in Edit → Selection. Both commands are available without a default keyboard shortcut. From each selection, use the earlier document position as the starting point, including for backward selections. Reveal the active end of the primary result.

| Starting point | Go to Bracket | Select to Bracket |
| --- | --- | --- |
| Touches a matched delimiter | Move to the start of its partner. If the caret touches both delimiters of the same empty pair, move to the start of the opener. | Select the full pair including both delimiters. If the starting point touches the closer, make a backward selection. |
| Inside a complete pair | Move to the start of the innermost closer. | Select the full innermost pair, forward. |
| Outside a complete pair | Move to the start of the next recognized bracket token. An unpaired opener is a valid destination. Unexpected closers are skipped by the reference model's bracket tree. | Try pairing the next recognized bracket token at its start. If it has no pair, stop this search. |
| No result | Collapse the selection at its earlier document position. | If every selection fails, preserve all of them. If at least one succeeds, keep only the successful results. |

Both commands navigate and update selections without editing the document. Preserve anchor and head so Shift-arrow extends from the expected side after **Select to Bracket**. The VS Code command API also accepts `selectBrackets: false` for the interior range. The Control and menu action use the default inclusive selection.

In Focus mode, restrict pairing and command destinations to the starting active block. This keeps navigation and selection within that block's editable text.

## Acceptance

- In `{ start([ value ]) end }`, put the caret immediately before and after each delimiter, in `value`, and in `start`. Verify both decorated characters and which pair wins. In `()|[]`, where `|` marks the caret, verify the square pair wins. In `(|)`, verify Go lands at the opening parenthesis.
- Compare both commands from each end of a pair, its middle, a forward and backward selection, before a paired opener, before an unpaired opener followed by a valid pair, and after the last pair. Include a multi-caret case with one successful result and one failure. Verify the revealed position and the next Shift-arrow.
- Check multiline and mixed nesting, adjacent pairs, quoted delimiters and comments in Swift, a JavaScript template interpolation, UTF-16 offsets after emoji, and a Swift-to-Plain Text language change. In `([)]`, only `(` and `)` form a complete pair. Ensure an old document's highlights are never painted on a new document.
- Check empty and nonempty selections together, the 100-selection boundary, focus loss, horizontal and vertical scrolling, both Control entries, and both native menu actions. In Focus, include a pair that straddles protected lines. Inspect light and dark appearances while native selection, syntax and Find marks are present.
- Type and backspace on the lines before the closing brace of an added Zig block, including a space after `return` and a dot after `error`. Hold the bracket index and the gutter comparison and check that both brace outlines and the green stripe on the closing row stay painted from the first frame. Delete the closing brace and check that its old outline clears immediately.

## Reference

- [VS Code 1.147.0 bracket controller and command bindings](https://raw.githubusercontent.com/microsoft/vscode/8a14f0cc1b08d531eb83255ea3764ae22aa932b5/src/vs/editor/contrib/bracketMatching/browser/bracketMatching.ts) and [default editor options](https://github.com/microsoft/vscode/blob/1.147.0/src/vs/editor/common/config/editorOptions.ts#L6313-L6318).
- [Stable bracket range and priority rules](https://raw.githubusercontent.com/microsoft/vscode/8a14f0cc1b08d531eb83255ea3764ae22aa932b5/src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsImpl.ts), [forward token lookup](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.ts#L246-L267), [Plain Text pairs](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/languages/languageConfigurationRegistry.ts#L279-L286), and [Swift pairs](https://github.com/microsoft/vscode/blob/main/extensions/swift/language-configuration.json).
- Eleven reference command cases were checked by running the VS Code 1.143.1 command bodies with controlled bracket ranges. Edit's native check exercises both command entry points, backward selection and extension, syntax-mode changes, and bracket pixels in light and dark appearances.
