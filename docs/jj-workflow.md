# Jujutsu Workflow

## Git compatibility

Use a colocated Git-backed Jujutsu repository so Git tooling can inspect the checkout. Initialize new repositories with `jj git init --colocate`. Prefer `jj` for supported history operations. Read-only Git inspection and Git-based tooling are compatible with this workflow.

## Workspace isolation

Use the current checkout for ordinary work. If parallel edits would collide, an experiment needs an isolated checkout, or owner review needs a separate runnable revision, use `jj workspace add --colocate` under `.local/temp/` with an explicit starting revision. Give each writer distinct files or a separate workspace.

Before changing revisions or integrating work, check the working state and identify any unrelated edits. Preserve the owner's files and running work. Keep temporary files, build artifacts, and test profiles out of versioned history. Retire workspaces created for the task once no review, artifacts, or unique changes depend on them.

## Change ownership and status

Build on the current tip and keep completed work on a linear history. Give each feature one owning commit titled `feat(feat-id): desc` and one living specification. Put its implementation, specification, and visual material together. Prepare unfinished work in the working copy. The initial `feat(init)` contains the skeleton, instructions, and build infrastructure.

Use these descriptions for subsequent commits. The bracketed scope is optional.

| Description | Purpose |
| --- | --- |
| `feat(feat-id): desc` | Introduce a feature and its specification. |
| `fix[(feat-id)]: desc` | Correct an existing behavior or its specification. |
| `refactor[(feat-id)]: desc` | Reorganize implementation while preserving behavior. |
| `chore[(feat-id)]: desc` | Maintain the project, its tools, or its documentation. |

For example, a scoped correction is `fix(file-search): Preserve the query on reopen` and an unscoped maintenance change is `chore: Update build instructions`.

Introduce dependencies and API extensions where a feature first needs them. Keep existing behavior stable unless the feature changes it. A completed revision must work with the features and dependencies recorded at that revision.

## Correcting a feature

Identify the target and check whether Jujutsu considers it mutable. When the target is mutable, record the verified correction as a separate `fix` commit. A fix can update the specification and the implementation together. Where helpful, a fix may be squashed into its mutable target after verification. Preserve the feature title and change ID, check affected descendants, and preserve unrelated changes. A direct request authorizes routine corrections and their integration.

Leave immutable history untouched. If Jujutsu considers the target immutable, explain the limit when it affects the requested result.

## Final verification

Review the resulting diff, commit descriptions, and live graph after integration. Resolve conflicts or divergence introduced by this task and retire superseded temporary changes only after confirming the retained result contains the requested work. Preserve unrelated revisions and active workspaces.
