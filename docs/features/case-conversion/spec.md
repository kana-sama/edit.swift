# Case Conversion

Use **Edit → Transformations → Uppercase** or **Lowercase** to change text in the focused editor. Both commands are searchable in Command Mode and use the standard menu without default keyboard shortcuts.

Convert selected text using Unicode case mapping. Apply the command to all nonempty selections together and undo the whole action in one step. A single caret in the ordinary editor uses AppKit's word action. In Focus Selection and inline diffs, use the existing editable selection boundaries. Disable the commands in read-only editors.

Verify both commands through the editor's action routing, including a selection whose length changes, disjoint selections, single-step undo, and read-only validation.
