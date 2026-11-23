# Development Workflow

A direct request to implement a defined change authorizes specification updates, design within the agreed direction, implementation, and verification. Work through the stages below as needed. A request for research, a design, or a plan ends with that deliverable. If the work exposes a material unresolved product decision, present the choices to the owner while continuing independent work.

## Focused corrections

Apply an explicitly requested, clear correction directly and check the affected scenario. Update the feature specification or shared design when the correction changes a documented decision. Review and verify the affected behavior before recording the correction. See [Correcting a feature](jj-workflow.md#correcting-a-feature).

For a narrow fix, start with the failing interaction and the code that owns it. Run the smallest relevant check first. For drawing and geometry bugs, verify that the test reaches the failing state and inspect one native capture or measurement before choosing a rendering change. If a check fails, determine whether the fixture reached the intended state before revising the implementation.

Reuse the checkout, build directory, and test bundle across iterations. Keep the first feedback loop to a few minutes. If two attempts leave the cause unclear, isolate the failing interaction or gather a diagnostic that distinguishes the remaining explanations before trying another implementation. See [focused checks](agent-testing.md#focused-checks).

## Feature specification

Use `docs/features/<feat-id>/spec.md` for each feature. Give it a stable, descriptive directory name. Record the feature's purpose and scope, user actions and expected results, relevant states and edge cases, and checkable acceptance criteria. Keep it understandable from the repository without the chat. Describe the feature as it exists at its own revision and update the same specification when its contract changes.

A feature should deliver a coherent, verifiable user scenario. When a request spans several independent outcomes, propose the boundaries and order. Each resulting feature should have a useful result that can be completed and checked on its own.

Research reference software when it affects a decision. BriskEdit is useful prior art when a proposed behavior has a comparable implementation. Record the concrete requirement locally and make it possible to implement and verify from the specification. Record the inspected version or pin source links to an immutable revision where possible.

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

Review the diff against the request and the specification. Choose checks for the actual change. Review text and links for documentation, exercise affected scenarios for behavior, inspect the native UI for visual changes, and measure the reported workload for performance changes. Run the focused check during iteration and the full `./script/check` on the final code before recording the change. Build the review bundle once the last code change has passed. Each completed revision must build, run, and satisfy the specifications it contains.

Check the final history and current working state after any amend or squash. Verify affected descendants when rewriting a mutable ancestor. Report the changed behavior, relevant commit or change ID, checks completed, and any specific limitation that remains.

## Launch command

When reporting a completed feature or change to the runnable app, handing off an implementation for review, or asking the owner to test, build the app first. Retain the concrete `Edit.app` bundle in a revision-specific or review-specific location so later builds leave it available. The bundle may live outside the current checkout. Verify that it contains the intended revision.

Give a copy-paste `open` command that launches the retained bundle directly. Use a `bash` code block with an absolute, quoted `.app` path and no prompt or placeholders. Give a separate command for each review target. When asking the owner to test, state what to check.

## README maintenance

Keep the README focused on setup and the build, launch, check, and install commands. Update it when those instructions change. Document feature behavior in the owning specification.

## Maintaining these instructions

Propose persistent process rules for recurring situations where the right action is easy to get wrong. Present rule changes explicitly for owner review.
