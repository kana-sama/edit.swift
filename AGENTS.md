# Repository Instructions

Edit is an independent macOS text editor written in Swift with AppKit. Build instructions apply to macOS 27 and Swift 6.4. This workflow applies to the main agent and to helpers.

- Keep work within the owner's request and preserve unrelated changes. Work in the current checkout by default. Read the [Jujutsu workflow](docs/jj-workflow.md) before creating or rewriting a commit or opening a workspace.
- Keep feature development fast. Require only steps and artifacts that clarify behavior, coordinate work, or verify quality. Keep the README focused on setup and commands. Do not add screenshots or feature lists to the README or project documentation.
- Give every new feature one living specification and one owning commit titled `feat(feat-id): desc`. Keep the specification and implementation in that commit. Follow the [correction workflow](docs/jj-workflow.md#correcting-a-feature) for changes to a committed feature.
- A direct implementation request authorizes the work and its checks. For an exploratory request, use the relevant [specification, design, or planning stage](docs/workflow.md). Resolve material product decisions with the owner.
- Check the scope and relevant specs before changing behavior. Use [project principles](docs/principles.md) and the [shared design](docs/design.md) when deciding behavior or visuals. Use the [coding guidelines](docs/coding.md) for implementation and tests.
- Follow the [test isolation rules](docs/agent-testing.md) before launching any test instance. Keep launches, profiles, and sample files separate from the owner's running editor and data.
- For a narrow fix, start with the [focused correction workflow](docs/workflow.md#focused-corrections) and run the closest [native check](docs/agent-testing.md#focused-checks) during iteration. Follow [verification and completion](docs/workflow.md#verification-and-completion) before reporting completion. Inspect the running UI when it changes.
- For every completed feature or change to the runnable app, and when handing off an implementation for review, give a copy-paste `open` command with the absolute, quoted path to the retained `Edit.app` bundle built for that handoff. Follow the [launch instructions](docs/workflow.md#launch-command).
