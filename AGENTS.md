# Repository Instructions

Edit is an independent macOS text editor written in Swift with AppKit. Build instructions apply to macOS 27 and Swift 6.4. This workflow applies to the main agent and to helpers.

- Keep work within the owner's request and preserve unrelated changes. Work in the current checkout by default. Read the [Jujutsu workflow](docs/jj-workflow.md) before creating or rewriting a commit or opening a workspace.
- Give every new feature one living specification and one owning commit titled `feat(feat-id): desc`. Keep the specification, implementation, and supporting visual materials in that commit. Follow the [correction workflow](docs/jj-workflow.md#correcting-a-feature) for changes to a committed feature.
- A direct implementation request authorizes the work and its checks. For an exploratory request, use the relevant [specification, design, or planning stage](docs/workflow.md). Resolve material product decisions with the owner.
- Check the scope and relevant specs before changing behavior. Use [project principles](docs/principles.md) and the [shared design](docs/design.md) when deciding behavior or visuals. Use the [coding guidelines](docs/coding.md) for implementation and tests.
- Follow the [test isolation rules](docs/agent-testing.md) before launching any test instance. Keep launches, profiles, and sample files separate from the owner's running editor and data.
- Use [verification and completion](docs/workflow.md#verification-and-completion) before reporting completion. For a visible feature, inspect the implemented UI and its [README screenshot](docs/workflow.md#readme-maintenance).
- Give the owner an exact copy-paste launch command for any implementation awaiting review, following the [handoff instructions](docs/workflow.md#owner-verification-handoff).
