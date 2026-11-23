# Control · Search in both keyboard layouts

Go to File, Command Mode, and the language picker search the query as entered and as if the same keys were pressed in the other keyboard layout. Use the two enabled macOS keyboard layouts. Read the enabled layouts again for each search so the next query reflects changes in System Settings. When there is no pair of supported layouts, search the text as entered.

Use the physical key positions, including Shift punctuation. If the letters suggest which layout produced a pasted query, use that layout to interpret shared punctuation. Otherwise use the selected layout. Keep the query visible as entered. Keep spaces between terms and escaped spaces within terms. In an explicit directory query the prefix through `/` defines the literal directory, and both layout variants apply to its file filter.

Show results in one list. A title that matches the text as entered exactly comes first. Otherwise use the usual fuzzy score with a small penalty for the other layout. Show one row per match and highlight the characters from the query variant that ranked it.

## Acceptance

With ABC and Russian enabled, search for `куфвьуюьв` in a folder with `readme.md` and `куфвьуюьв`. Both files appear and the Cyrillic filename comes first. Repeat with `readme.md` to see the order reversed. Search for `docs/куфвьуюьв` with matching files inside and outside `docs` and check that only files inside `docs` appear. In Command Mode, type `ыфму` and verify that `File: Save` appears and highlights `Save` while the field still reads `ыфму`. Disable one layout in System Settings and verify that the translation is absent on the next search.
