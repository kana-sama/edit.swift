# Occurrence highlighting

The behavior reference is [VS Code 1.147.0](https://code.visualstudio.com/updates/v1_147). Highlights are temporary decorations in the current text buffer. They do not change the actual selection, caret, or document.

## Word under the caret

- For an empty primary selection, use the word at its position. The word includes either caret edge. Where the language defines a word pattern, use it to extract the query. The default treats `_` as part of a word. The textual provider matches case-sensitive whole words using the default VS Code separators. Draw the first 999 results, including the source occurrence if it qualifies as one of them. A position between separators, with neither edge touching a word, clears the word highlights.
- Use the primary selection for the word query in multi-caret mode. If a primary selection fits entirely inside one word, the word highlights can coexist with the selected-text highlights. A selection spanning beyond that word clears the word highlights.
- Compute the word query for explicit caret moves and selection gestures. VS Code debounces these events for about 50 ms. Clear word highlights when typing, leaving the editor, or changing documents. A result for an obsolete buffer, caret, selection, or language cannot repaint the active editor.
- Edit follows VS Code's built-in textual behavior. VS Code language providers can additionally supply symbol references and separate read and write marks.

## Selected text

- Find occurrences of the exact selected text as a literal substring, applying Match Case and Whole Word from Find even when its panel is closed. Edit's existing defaults are Match Case on and Whole Word off. A manual selection of `foo` can also highlight `Foo` with Match Case off, or `food` and `foo_bar` with Whole Word off. Regex mode has no effect on this literal match. If the open Find panel is already marking the same literal query with the same options, use its existing marks.
- For Whole Word, use VS Code word separators, including spaces and tabs. With the default separators, `foo` can match in `.foo` and `foo.`, while `foo—` and `foo🙂` lack the required right boundary. A separator within the selected literal can satisfy a boundary at that edge.
- The selected source occurrence keeps its native selection appearance. The decoration pass skips equal selected ranges and an earlier match that crosses into a selection. For an overlapping repeated pattern, VS Code's forward comparison can still decorate a later match starting inside that selection. Find nonoverlapping results in document order, with the first 999 results available for decoration before selection suppression.
- Skip an empty selection, selections containing only spaces or tabs, selections spanning more than one line, and selections longer than 200 UTF-16 code units. With multiple manual selections, use the primary selection when the selected strings agree under Match Case. Otherwise suppress selected-text decorations. An active occurrence-selection command uses its own case-sensitive literal query.
- Keep word and selected-text marks distinct from native selection and the active Find match. Render only the ranges relevant to the visible TextKit fragments. Refresh after a selection gesture and debounce recomputing after content edits. VS Code schedules the content refresh after 300 ms and skips the selected-text scan when the buffer is too large for tokenization. Discard results from expired searches when files switch.

- In Focus, search the active blocks using their document offsets. The single-line highlights stay within the active blocks. Select Next Occurrence, Skip to Next Occurrence, and Select All Occurrences can still operate on selections spanning blocks.

## Acceptance

- In Plain Text, use `foo foo Foo food foo_bar` and put the caret before, inside and after the first `foo`. Verify the two lowercase whole-word highlights. Then select `foo`, and separately `oo`, with both Find toggles off. Check substrings, case variants, and when the two kinds of marks coexist. Move to whitespace away from a word and type into the word to verify clearing.
- Toggle Match Case, Whole Word and Regex. Check `f.o fxo f.o` with `f.o` selected. Open and close Find on an identical query. Check simultaneous highlights and different queries, with native selection still readable in light and dark appearances.
- Test two equal selections with a third match, different selections, two empty carets, and a manual selection in an active occurrence-selection session. Check the overlapping case `abababa`, with `aba` selected at UTF-16 range `[2, 5)`.
- Check whitespace-only and multiline selections, UTF-16 lengths of 200 and 201 including emoji, matches after non-ASCII text, the match cap, a large document, horizontal and vertical scrolling, Focus blocks, rapid edits, and switching buffers. Check text, selection, and undo state after highlights appear and clear.

## Reference

- [VS Code 1.147.0 default occurrence options](https://github.com/microsoft/vscode/blob/1.147.0/src/vs/editor/common/config/editorOptions.ts#L6384-L6409) and [selection options](https://github.com/microsoft/vscode/blob/1.147.0/src/vs/editor/common/config/editorOptions.ts#L6544-L6568).
- [Word highlighter](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.ts#L624-L695), [textual provider](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.ts#L15-L37), [selection highlighter](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/multicursor/browser/multicursor.ts#L883-L1014), and [default word handling](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/core/wordHelper.ts).
- [Find's initial state](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/find/browser/findState.ts#L102-L118) and [search boundary rules](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/textModelSearch.ts#L392-L449).
- The occurrence controllers were read from upstream `main`. The highlighting options and decoration types were cross-checked in the VS Code 1.143.1 bundle. Edit's native check exercises both kinds of matches, Find settings, focus, document edits, and rendered pixels.
