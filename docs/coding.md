# Coding Guidelines

Write direct Swift with descriptive names and a readable execution order. Keep related logic together and use types or helpers for concrete concepts that simplify their callers. Keep short local repetition when extraction would make the operation harder to follow.

Use AppKit and Foundation APIs for platform behavior. Keep AppKit state and view updates on the main actor. Keep expensive work out of UI callbacks and handle cancellation and stale results when background work can overlap. Add a dependency only when its first use justifies its build and maintenance cost.

Validate external data and fallible operations at their boundaries. Use Swift types, `throws`, and explicit invariants to keep the rest of the code simple. Route errors to the caller or UI that can act on them. Explain non-obvious constraints or tradeoffs in comments near the relevant code.

Add a test when a requirement or concrete regression needs lasting coverage and existing checks would miss the failure. Exercise the cheapest boundary that exhibits it. Put SwiftPM tests under `Tests/`. Use the native checks for AppKit input or rendering, and control completion and time explicitly in asynchronous tests.

Keep ordinary styling values in the view. Remove assertions that only repeat an icon width, inset, color, or AppKit setter when touching that case. A geometry check earns its place when it catches a failure such as clipped text at the minimum window width, an inaccessible click target, or a title jumping during a transition. Assert the observable outcome across the relevant states.
