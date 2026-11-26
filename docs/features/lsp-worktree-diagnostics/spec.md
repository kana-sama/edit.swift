# Worktree error indicators

Show a small red triangle with an exclamation mark at the trailing edge of a Worktree file row when a language server has reported an error for that file. Keep the file's normal icon, version-control decoration, and selection behavior. Announce the error state along with the filename to VoiceOver.

Mark a collapsed folder when any descendant has a reported error, including when the folder has not been loaded. While the folder is expanded, show indicators on the affected descendants instead. Warnings, information, and hints do not get a marker. The same diagnostics are reflected in each Worktree that displays the affected paths.

Track the latest publication per file from each running server connection. An empty or warning-only replacement clears that connection's indicator for the file. Clear its indicators when the connection is replaced, stopped, or fails. Indicators for closed files depend on what the server publishes and retains; Edit does not scan the workspace for errors.

## Acceptance

Run `./script/check --only lsp-diagnostics`. Use a live SourceKit-LSP error to verify the indicator in a separate Worktree, from an unopened folder through its nested folder to the file. Check that a clean sibling is unmarked, collapsing restores the folder marker, and fixing the file or stopping the server removes obsolete markers.
