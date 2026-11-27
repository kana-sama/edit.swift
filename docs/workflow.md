# Development Workflow

A direct request to implement a defined change authorizes specification updates, design within the agreed direction, implementation, and verification. Work through the stages below as needed. A request for research, a design, or a plan ends with that deliverable. If the work exposes a material unresolved product decision, present the choices to the owner while continuing independent work.

## Focused corrections

Apply a clear correction in the current checkout. Update the existing specification or shared design if the request changes a decision recorded there. Reuse the agreed design and context on follow-up iterations. See [Correcting a feature](jj-workflow.md#correcting-a-feature).

For a reported bug, start with the failing interaction and the code that owns it. For clipping, flicker, or another rendering defect, inspect the failing frame or measure the affected view. If a check fails, establish that its fixture reached the intended state before revising the implementation.

Reuse the checkout, build directory, and test bundle across iterations. Keep the first feedback loop to a few minutes. If two attempts leave the cause unclear, isolate the failing interaction or gather a diagnostic that distinguishes the remaining explanations before trying another implementation. See [focused checks](agent-testing.md#focused-checks).

## Feature specification

Use `docs/features/<feat-id>/spec.md` for each feature. Give it a stable, descriptive directory name. Record the feature's purpose and scope, user actions and expected results, relevant states and edge cases, and checkable acceptance criteria. Keep it understandable from the repository without the chat. Describe the feature as it exists at its own revision and update the same specification when its contract changes.

A feature should deliver a coherent, verifiable user scenario. When a request spans several independent outcomes, propose the boundaries and order. Each resulting feature should have a useful result that can be completed and checked on its own.

Research reference software when it affects a decision. BriskEdit is useful prior art when a proposed behavior has a comparable implementation. Record the concrete requirement locally and make it possible to implement and verify from the specification. Record the inspected version or pin source links to an immutable revision where possible.

## Language server integrations

Adding a language server extends Edit's existing LSP features to the new language. Reuse the editor's shared commands, shortcuts, and interface. Aim for comparable behavior across servers, enable each feature where the server supports it, and record verified limitations in the [LSP checklist](lsp-checklist.md).

The owner chooses new editor features individually. If a server integration request mentions a capability that Edit does not yet provide, confirm that the owner wants to add that feature to the editor as a separate decision. Specify its shared behavior and plan support across the connected servers that can provide it. Treat advertised capabilities and unimplemented entries in the checklist as candidates for the owner's selection.

## Visual design

Follow the [shared design](design.md) for app-wide rules. Record feature-specific decisions in the owning specification. Record the selected option when alternatives mattered. Use a mockup when it helps the owner distinguish materially different designs. Use a small native trial when focus, scrolling, or dragging determines which design will work.

For a design requested on its own, hand off the design for review. When work has implementation authorization, use the agreed appearance and established native controls. Consult the owner before choosing a materially different visual direction.

## Implementation plan

For substantial work, state the approach, relevant starting revision and specification, a small number of verifiable steps, and how to check the outcome. Keep plans in the conversation or under ignored `.local/plans/` when a file helps coordination. Put lasting decisions in their owning specification or shared design document.

## Execution and review

Finish the authorized scope autonomously and check each substantial step. Use delegation for substantial, bounded investigations, independent implementations, or reviews where it improves the result. Give each helper a clear brief and distinct ownership. Coordinate changes to shared files. The main agent integrates the work, checks the combined result, and handles product decisions with the owner.

An explicit request to try an idea authorizes a reversible experiment. State the hypothesis and what to evaluate, and preserve the owner's working state. Apply final review, documentation, and verification to an accepted experiment.

If repeated attempts uncover a concrete blocker or the implementation calls for changing an agreed decision, give the owner the relevant evidence and choices.

## Verification and completion

Update the [LSP checklist](lsp-checklist.md) in the same change when adding or changing an LSP capability or updating a supported language server.

Every bundled language must meet the [Tree-sitter editing requirements](features/syntax-highlighting/spec.md#tokenization-during-editing). A new language may ship only with language-aware tokenization and a passing native check for flicker-free editing with LSP off. Apply the same acceptance criteria when bringing existing modes up to standard. Treat a known flicker as missing highlighting support for that mode until its regression check passes. Update the [language support matrix](language-support.md) in the same change whenever language support or its verification status changes.

Review the diff against the request. Select the smallest check that could expose a plausible failure in the affected path. The acceptance scenarios in feature specifications describe available coverage. Choose the ones the change can affect.

| Change | Sufficient verification |
| --- | --- |
| Documentation only | Read the changed text and verify affected references or commands. |
| Local appearance value, such as an icon width or inset | Confirm the value reaches the intended view and build the review app once. Inspect the affected view if its rendered result is uncertain or the owner asks to see it. |
| A specific interaction, bug, or performance issue | Exercise the affected path and its relevant boundary. Use an isolated native view for rendering or input and measure the reported workload for performance. Run a live service when its behavior is part of the change. |
| A new feature | Exercise its acceptance scenario through the normal entry point, including the relevant failure or recovery path. Apply the broader checks below if it changes shared behavior. |
| Shared changes with broad or uncertain impact, or high-risk changes such as save/recovery, shared async state, or build infrastructure | Exercise the failure modes directly and run the full `./script/check` on the final code. Include any relevant scenario the suite does not exercise. |

Expand verification if inspection reveals additional affected callers or a failure the chosen check cannot explain. Honor explicit requests for checks or captures. Reuse a passing result while its inputs remain the same. If a failure is confirmed unrelated, report it and finish the relevant verification. Retry when there is a specific cause to test.

Check the final history and current working state after any amend or squash. Verify affected descendants when rewriting a mutable ancestor. Report the changed behavior, relevant commit or change ID, checks completed, and any specific limitation that remains. For a bug fix, explain what caused the failure and how the change removes that cause. State when the cause is still uncertain.

## Launch command

For runnable changes, retain a normal `Edit.app` built from the intended sources. To build directly into the handoff location, set `EDIT_BUILD_DIR` to a review-specific directory and reuse the SDK cache. An existing signed review bundle can serve again when its build inputs match. Keep it available after subsequent builds.

Give a copy-paste `open` command that launches the retained bundle directly. Use a `bash` code block with an absolute, quoted `.app` path and no prompt or placeholders. Give a separate command for each review target. When asking the owner to test, state what to check.

## README maintenance

Keep the README focused on setup and the build, launch, check, and install commands. Update it when those instructions change. Document feature behavior in the owning specification. Keep screenshots and feature lists out of the README and project documentation.

## Maintaining these instructions

Propose persistent process rules for recurring situations where the right action is easy to get wrong. Present rule changes explicitly for owner review.
