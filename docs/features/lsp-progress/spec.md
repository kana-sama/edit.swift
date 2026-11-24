# Language Server Progress

The Language Servers button shows when a server is connecting or reports ongoing work. For ZLS, **Loading build configuration** means it is reading the project's Zig build configuration. The server can already answer requests while it does this. [ZLS 0.17.0 build progress](https://github.com/zigtools/zls/blob/0.17.0/src/DocumentStore.zig#L959-L1049)

- Show a small native spinner in the header button while any applicable server is starting, stopping, or reporting active work. Use a static indicator when Reduce Motion is enabled. Keep the button in the same place and keep it clickable. Restore the usual status dot when the last operation finishes.
- In the popover, show a secondary status line below the server name. During startup it reads **Initializing**. During reported work it shows the server's title and percentage when supplied. Show the number of active operations when several overlap, with details in the tooltip and accessibility label. Keep the two controls aligned at the trailing edge as statuses change.
- Accept server-initiated work via `window/workDoneProgress/create` and `$/progress`. Track operations by token until their end. Clear old work when the server stops, exits, restarts, or the project changes. Report only activity that the server announces once it is connected. [LSP work done progress](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress)

## Acceptance checks

Run `./script/check --only lsp-progress [screenshot-path]` with Zig and ZLS on `PATH` to check startup and build configuration progress in the native header and popover.

- Start ZLS and verify that the header shows activity and the popover reads **Initializing** until the server connects.
- Open a Zig file in a project with a `build.zig` file. Verify the ZLS progress title while the build configuration loads and the ready dot when it finishes.
- When two operations overlap, finishing one keeps the header busy. Stopping or restarting a server clears its previous operations.
