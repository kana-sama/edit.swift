# Jujutsu change indicators

When a user opens a folder or file in a Jujutsu workspace, Edit shows what the workspace's current change adds, changes, deletes, or leaves in conflict. The user can find changed files in Worktree, read changed lines beside the text, and use the vertical scrollbar to find changes elsewhere in the document. Indicators are available by default when a compatible installed `jj` is available. Edit uses Jujutsu as its source of repository state. The scope is inspection and navigation within the editor and Worktree.

## Workspace and comparison

- Follow the working-copy change (`@`) of the workspace that owns the path. Opening a subfolder uses the enclosing workspace and decorates the portion shown in Worktree. Workspaces backed by the same repository have independent results. Paths owned by nested workspaces do not contribute to the enclosing workspace's folder status.
- A named file can show editor markers when opened directly from Finder or the command line, or from a window browsing another folder. Worktree uses the workspace of its opened folder. An outside-file row from another workspace has its ordinary appearance there. Untitled buffers and internal scratch drafts have no jj indicators. A file exported from scratch becomes eligible at its saved path.
- Compare `@` with its parent, or with the tree produced by merging its parents for a merge change. This is the meaning of `jj diff -r @`. Use the last recorded jj state for repository-wide status. For an open editable file with a known base and status, overlay the current window's text, including unsaved edits. Each window uses its own buffer. Saved changes to other files, including newly created paths, can appear when the next periodic snapshot or an external jj operation captures them.
- Save, autosave, a snapshot, and `jj describe` leave equivalent indicators intact. Undo or restoring text to the baseline removes the corresponding marks. After `jj new`, changes that became part of the new parent disappear from the current diff. After `jj edit`, rebase, squash, or undo in jj, refresh to the actual change and its parents, including when the change ID is unchanged.
- If an external operation replaces an open file on disk, Worktree uses the observed jj status. Suspend buffer-based status and line markers for a buffer based on the superseded version until the versions agree again. Closing and reopening the file reads the new version. Use the existing [Files](../files/spec.md) and [Autosave](../autosave/spec.md) rules for the buffer, its unsaved edits, and save conflicts.

See the Jujutsu references for [working copies and workspaces](https://docs.jj-vcs.dev/latest/working-copy/), [diff semantics](https://docs.jj-vcs.dev/latest/cli-reference/#jj-diff), and [snapshot settings](https://docs.jj-vcs.dev/v0.46.0/config/#snapshot-settings).

## Worktree

Color the names of existing rows in the [Worktree sidebar](../worktree/spec.md). Added files use green, changed files blue, and unresolved conflicts purple. Clean files use the usual appearance. Expose the status of a decorated row to accessibility. Preserve the outline's icons, disclosure, selection, focus, sort order, and visibility rules. Status colors remain legible in active and inactive selection, light and dark appearance, and increased contrast.

| jj state | Effect in Worktree |
| --- | --- |
| Added path | Green name if jj tracks it in the observed state. Ignore rules, auto-track exclusions, and jj's new-file size limit apply. |
| Content, mode, or type changed | Blue name. |
| Rename or copy reported by jj | Blue destination. Use the reported source as the text baseline. Count a rename's removed source toward its surviving ancestors. |
| Deleted path | No new row. The deletion counts toward its surviving ancestors. |
| Unresolved conflict | Purple name, including a conflict inherited from a parent without any new edits in `@`. |

Folder names summarize their descendants even while collapsed. A conflict takes precedence, followed by any change or deletion, then additions. A folder with only additions is green. A removed directory contributes through its surviving ancestors. Apply the same aggregation after overlaying the current document's unsaved status, including undo and resolving a conflict. Filtering a row from the outline does not change the repository status of its visible ancestors.

## Editor markers

Use the same status colors in Worktree and the editor, with red reserved for line deletions. Draw markers in a narrow strip to the left of the text, aligned with the text layout and fixed during horizontal scrolling. Clip the strip's drawing to its bounds so the editor text stays visible when marks appear or refresh. The strip has no click action. Review the exact spacing, palette, and hatching in both appearances. Focus editing always compares the full source buffer, including protected text.

| Text change | Marker |
| --- | --- |
| Lines inserted | Green vertical bar across the inserted lines. |
| Lines replaced | Blue bar across the new range of the replacement. |
| Lines deleted | Red triangle at the deletion boundary, including before the first line, after the last line, and in a fully emptied file. |
| Known unresolved text conflict | Purple hatching over the whole block, including its opening and closing marker lines. |

A newly added file has only its Worktree status unless it contains a confirmed conflict. An existing empty file with inserted text receives line markers. Reported renames and copies can show changes against their source text. A rename or mode change with identical text has no line markers. Binary files, read-only file previews, and ambiguous comparisons receive only the supported Worktree status. Preserve meaningful whitespace, line endings, and final newline changes in the comparison wherever the repository and editor representations allow them to be compared reliably.

## Scrollbar markers

Draw change marks inside the native vertical scrollbar track, within its existing width. Position them over the full document's laid-out height, including changes outside the visible text and excluding empty space beyond the document. For example, a conflict three quarters of the way through the file has a purple mark three quarters of the way down the track. The native thumb sits above the marks and can cover them. Marks appear in the same track area when the overlay thumb fades. When the whole file fits, marks in that area are passive. Preserve a visible minimum size for a one-line mark. When marks overlap, display conflict before deletion, deletion before replacement, and replacement before insertion.

Click an exposed mark to scroll to the start of its range or deletion boundary, centering the target when the scroll range allows it. A hit on overlapping marks uses the displayed priority. The thumb gets the click and drag when it covers a mark. Unmarked track clicks follow the system scrollbar setting. Wheel and trackpad scrolling use the regular editor behavior. A marker click preserves horizontal position, caret, selection, keyboard focus, undo history, and any active [Focus](../focus/spec.md) session. Refreshes and layout changes keep the reader's viewport anchored.

Use the [shared design](../../design.md) and native [NSScroller](https://developer.apple.com/documentation/appkit/nsscroller) and [NSScrollView](https://developer.apple.com/documentation/appkit/nsscrollview) behavior when checking the interaction.

## Conflicts

Take conflict status from metadata for the entire current jj tree. This includes inherited conflicts and add/add conflicts. Derive textual ranges from the known materialized conflict using the user's jj format, including `diff`, `snapshot`, and jj's `git` marker style, long delimiters, multiple sides, and missing final newlines. Marker-like text in a regular file has its normal diff meaning. If a conflict is binary or its bounds are uncertain, retain purple Worktree status and omit ambiguous line ranges.

Within a confirmed conflict block, the conflict marker takes precedence over ordinary diff. Outside it, show ordinary marks where the comparison is reliable. Resolving one block in the buffer removes its marker. Remaining blocks retain their markers and keep the file and ancestors purple. Resolving the last block restores the ordinary status of the file and its ancestors, taking other descendants into account. Undo restores the unresolved state. While a block is being edited, incomplete delimiters alone are insufficient evidence of resolution. Reconcile the provisional buffer state with jj after the text reaches disk.

See [Jujutsu's materialized conflict formats](https://docs.jj-vcs.dev/latest/conflicts/).

## Reading the repository

Run repository and diff work in the background when there is a relevant open file or visible Worktree. Coalesce edits and filesystem events. Refresh after external operations and when a window returns to use. Keep related file and folder results consistent with one observed operation, commit, and parent set. Discard late results for a superseded operation, file, or text revision. If an ordinary line diff exceeds its computation budget, keep known file and conflict status available and wait for a changed input before retrying that diff.

Each read-only command starts from an operation in the jj operation log and leaves the operation heads, stored operations, working copy, Git state, and configuration intact. Discover the current operation with `--at-op=@ --ignore-working-copy`. Read related metadata and text with `--at-op=<operation-id> --ignore-working-copy`. Pass both flags explicitly. The read path avoids commands that snapshot the working copy or reconcile divergent operation heads. `--no-integrate-operation` does not satisfy this requirement because it can still create an operation.

The observer suspends indicators in a stale workspace until jj can provide a coherent state after the user's correction. When jj is missing, unsupported, or unable to produce a usable observation, clear invalid indicators and keep editing available without a modal alert. A plain directory or Git-only project has ordinary editor and Worktree behavior. `jj 0.46.0` is the reference version for the initial implementation. Check discovery of the user's installed jj from both Finder and a shell launch.

## Working-copy snapshots

- Allow a background snapshot when disk changes may be pending in a workspace Edit is observing. Start with a three-minute interval and coalesce window activity for the same workspace. Opening a window, reading a diff, and refreshing indicators do not trigger an immediate snapshot. Saving and autosave make text available on disk for the next snapshot. The snapshot captures on-disk changes according to jj's tracking rules.
- Use `jj util snapshot` for the scheduled snapshot. When the working copy has changed, the resulting operation goes in the regular `jj op log` and is available through jj's existing recovery commands. An unchanged workspace does not need a new snapshot operation. A scheduled snapshot in a colocated repository follows jj's normal Git synchronization, which can record an import separately when Git state has changed. Preserve all existing operation entries.
- Defer the background snapshot when the workspace is stale or its operation heads are divergent. Disable automatic stale-workspace updates for the invoked process. Serialize Edit's scheduled snapshots for workspaces that share a repository and verify behavior with external jj and Git processes before enabling the snapshot path.
- An explicit repository-changing jj command must capture the necessary working-copy state on every invocation through its own snapshot or an explicit one if needed, regardless of the background interval. This feature observes commands such as `jj new`, `jj edit`, and `jj squash` and refreshes from their recorded results. It does not add Edit commands that mutate jj history.

In a disposable colocated repository with jj 0.46.0, reading with both flags created zero operation objects. A changed `jj util snapshot` created one operation. Repeating it on unchanged files created zero, and `jj op restore` recovered the earlier file from a previous snapshot. In the same setup, `--at-op=@` alone allowed a diff to snapshot disk changes.

See [Jujutsu CLI options](https://docs.jj-vcs.dev/latest/cli-reference/#jj), [`jj util snapshot`](https://docs.jj-vcs.dev/latest/cli-reference/#jj-util-snapshot), the [operation log](https://docs.jj-vcs.dev/latest/operation-log/), and [automatic updates of stale working copies](https://docs.jj-vcs.dev/v0.46.0/config/#automatic-update-of-stale-working-copies).

## Acceptance

- Open a workspace and a nested folder within it. Change, add, rename, and remove files, including beneath collapsed folders. After the changes reach the jj operation log, check status precedence, a removal without a row, and a file excluded by ignore, auto-track, or the new-file size limit. Open a file directly and from a window browsing another workspace.
- Edit a tracked file with typing, paste, and multiple carets. Check live line and folder marks before save, then save, snapshot with jj, and compare the result. Return to the baseline and exercise undo. Cover a rename/copy with content changes, a rename or chmod alone, whitespace, CRLF, missing final newline, a new file, an existing empty file, and deleting every line.
- Run `jj new`, `jj edit`, and an external rewrite in disposable workspaces. Cover two workspaces of the same repository, a merge with content inherited from both parents, and a rewrite retaining the change ID. Test an external replacement while an unsaved buffer is open and verify the existing save conflict flow.
- Check inherited, add/add, multi-sided, malformed-in-progress, and non-text conflicts. Resolve one of two blocks, resolve the second, and undo. Check all supported materialization styles, a literal marker in a clean file, and a conflicted parent with a resolved result.
- Inspect an isolated Edit instance in light and dark mode, with increased contrast, selected and collapsed Worktree rows, and both system scroller styles. Use a short document and a tall one. Scroll both axes, resize, zoom, and reveal and hide the sidebar. Check the first and last deletion boundaries and a one-line conflict. With Focus active, click an exposed mark, click an unmarked track position, and drag the thumb over a mark. Check that marks stay within the track after the thumb fades, and check the resulting scroll, caret, selection, and focus.
- Compare files, working-copy metadata, operation heads, stored operation objects, and Git HEAD/index/refs in disposable colocated fixtures before and after repeated read-only refreshes. Include unsnapshotted disk changes, stale and divergent states, and concurrent jj activity. Exercise a failing or missing executable, slow results after switching documents, and an expensive text comparison while typing.
- With an isolated workspace and a controllable clock, make several disk edits from two windows. Verify a single scheduled snapshot for the interval, one new logged operation for the combined changes, and zero new operations when nothing changed. Check that the open buffer shows changes between snapshots. Recover the earlier disk text with jj after a later snapshot. Follow the [test isolation rules](../../agent-testing.md).

## Reference

The personal Lite XL checkout's open change `mpxknwwn` is the reference, inspected over parent `05beb72cf36a8da1bd935abeba750fddd1a34cc9`. Its `docs/superpowers/specs/2026-11-11-jj-change-indicators-design.md` describes the behavior and proposed visuals. The working-copy implementation includes `data/core/jjrepo.lua`, `jjstatus.lua`, `jjdiff.lua`, and `jjconflict.lua`, plus Worktree-equivalent and editor drawing hooks and `tests/jj_*.lua`. The reference's visual design is provisional. The draft uses Edit's Worktree, AppKit editor, Focus, and file lifecycle.
