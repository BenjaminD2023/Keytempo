# Changelog

## 1.1.1 — 2026-10-22

- Restore the menu bar to the current input segment, with active updates around once per second.
- Select WPM or CPM from the current input-source language; clear stale rates at language/source changes instead of retaining a previous English WPM value.
- Preserve the separate KPM menu option and honest unavailable CPM state when global character commits are not covered.
- Exclude spaces from global keystroke counts and KPM while retaining full actual time between accepted operations.
- Use bounded recent input-method metadata to estimate candidate digits, arrows and Return as probable composition, without inventing character commits.
- Preserve older aggregates under their original rule; do not average daily rates across incompatible old/new counting policies.
- Simplify daily counts to one estimated keystroke counter across all recorded languages; combine duration and weighted KPM while keeping primary WPM/CPM language-specific.
- Compact large keystroke counts to K/M/B notation with full integer tooltips; add daily combined count/KPM history summaries alongside language-specific rates.
- Deduplicate unchanged input-source notifications while retaining real input-mode boundaries.
- Refresh Accessibility context leases without discarding an entire previously valid queued batch; changed focus identity or failed queries still invalidate the context.
- End source-state mutation before delivering synchronous notifications, preventing reentrant readers from triggering an exclusivity crash.
- Add public project documentation, MIT licensing and GitHub release infrastructure.

## 1.1.0 — Local builds

- Introduce the Keytempo name and icon, English/Chinese interfaces, input-language selection, per-language history, estimated WPM, confirmed CPM and separate KPM details.
- Separate global estimates from a real confirmed editor adapter, with adaptive segment timing and local aggregate storage.
- Establish core, persistence and application integration tests and document the limits of real-world input and resource validation.
