# Coding Guidelines

Write direct Swift with descriptive names and a readable execution order. Keep related logic together and use types or helpers for concrete concepts that simplify their callers. Keep short local repetition when extraction would make the operation harder to follow.

Use AppKit and Foundation APIs for platform behavior. Keep AppKit state and view updates on the main actor. Keep expensive work out of UI callbacks and handle cancellation and stale results when background work can overlap. Add a dependency only when its first use justifies its build and maintenance cost.

Validate external data and fallible operations at their boundaries. Use Swift types, `throws`, and explicit invariants to keep the rest of the code simple. Route errors to the caller or UI that can act on them. Explain non-obvious constraints or tradeoffs in comments near the relevant code.

Use SwiftPM test targets under `Tests/`. Include focused tests when a behavior contract, boundary case, or regression needs coverage. Prefer assertions on observable behavior over snapshots of internal state. Control completion and time explicitly in asynchronous tests. Run native checks for behavior that depends on AppKit events or rendering.
