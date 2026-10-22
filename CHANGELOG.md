# Changelog

All notable changes to Keytempo are recorded here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and three-part version numbers. Keytempo uses the `0.x` series while its input coverage and statistical policies are still evolving.

## Version-number normalization

The project changed its public version convention before the `0.3.0` release. Historical versions are listed below under the normalized `0.x` names:

| Normalized version | Original app version / tag | Internal build | Distribution |
|---|---|---|---|
| 0.1.0 | 1.1.0 | 5–7 | Local builds |
| 0.1.1 | 1.1.1 / `v1.1.1` | 8 | Original public release |
| 0.2.0 | 1.2.0 / `v1.2.0` | 9 | Original public release |
| 0.2.1 | 1.2.1 / `v1.2.1` | 10 | Original public release |
| 0.3.0 | 0.3.0 / `v0.3.0` | 11 | First release with the normalized app version |

Already published signed archives, source tags and download URLs retain their original `1.x` identifiers. Their changelog labels are normalized; their embedded app versions have not been rewritten. New releases use `0.x` app versions and tags. The internal build number continues increasing, so Sparkle can offer `0.3.0` (build 11) to apps displaying `1.2.0` (build 9) or `1.2.1` (build 10).

## [Unreleased]

## [0.3.0] - 2026-10-22

### Added

- Add a session-only, bounded ten-minute average across all recorded global input languages, calculated from accepted operation intervals and their actual typing duration. Idle time is excluded; intervals at the rolling boundary contribute only their proportional overlap.
- Show the ten-minute average as the main menu-popup value, current speed as a secondary value, and today's combined average alongside the existing daily counts, duration and KPM.
- Report the observed session window and partial coverage when today's saved data contains older counting rules. The rolling average is not reconstructed from daily aggregates after launch or resume.
- Add conservative, optional filtering for suspected long same-key runs and dense multi-key bursts before they enter speed statistics. Known system repeats and identifiable synthetic events remain excluded independently of that option.

### Changed

- Adopt `0.x` app versions and tags, normalize earlier changelog labels, and retain increasing internal builds for upgrade compatibility.
- Keep today's quantities across older counting rules while calculating today's displayed average only from the current rule. Incompatible historical rates are not silently averaged.
- Keep global Chinese, English and other language estimates on the same five-operation WPM scale, with KPM retained as a separate option and actual CPM restricted to confirmed commit coverage.

### Fixed

- Prevent a mixture of legacy and current counting rules from making the current-rule daily average unavailable when it has enough data.
- Preserve exact event times through delayed input classification and adaptive segment confirmation, so rolling averages do not acquire artificial idle tails.
- Recognize actual private event-source state identifiers when excluding known synthetic events, rather than comparing only with the private-source initializer sentinel.
- Refresh update-control translations immediately when the app language changes.

### Security

- Verify a real, in-place Sparkle upgrade from original `1.2.0` build 9 to original `1.2.1` build 10 on the maintainer Mac: Input Monitoring and Accessibility grants remained available after relaunch and an in-process permission recheck, with the same code-signing requirement. This is a measured local result, not a guarantee for every Mac or a proof of every app's editable-control coverage.
- After publication, verify the production upgrade from `1.2.1` build 10 to `0.3.0` build 11, preserving both grants and existing aggregates. A subsequent update check correctly identifies `0.3.0` as current despite older releases' larger display version numbers.

The suspected-input filter uses metadata heuristics. It does not understand whether arbitrary text is intentional, identify every macro, or reject code, punctuation and repeated words for their spelling. Diagnostic reasons and the ability to disable the heuristic are provided for possible false positives; confirmed editor input remains separate from global estimates.

## [0.2.1] - 2026-10-22

Originally published as `1.2.1` / `v1.2.1`, build 10.

### Changed

- Show global typing estimates in the same five-operation WPM scale for Chinese, English and other input languages; retain actual CPM only where a confirmed commit adapter supplies characters.
- Keep per-language estimated WPM history separate from measured CPM, with the existing optional KPM display and filtering unchanged.
- Maintain the existing signing identity and update channel for an in-place permission-retention upgrade test.

### Fixed

- Reopen the statistics window when opening an already running app with no visible windows.

## [0.2.0] - 2026-10-22

Originally published as `1.2.0` / `v1.2.0`, build 9.

### Added

- Add Sparkle 2.10.0 update checks, manual download/install and optional automatic checks/downloads.
- Add an explicit local release preparation/publication script; CI validates tags without publishing temporary ad-hoc builds to the stable update channel.

### Changed

- Use a stable local Apple Development signing identity for maintainer builds instead of a changing ad-hoc binary identity. Migration from ad hoc signing requires one new permission grant.
- Preserve existing history, privacy filters, input-language settings and statistics definitions across update installation.

### Security

- Require Ed25519 signatures for both the update feed and archives, with archive verification before extraction.
- Keep private update-signing and certificate keys in the maintainer's local Keychain; exclude them from source, archives and CI.
- Reject unintended changes to the publisher's signing identity and update-channel keys.

## [0.1.1] - 2026-10-22

Originally published as `1.1.1` / `v1.1.1`, build 8.

### Added

- Add 90-day, one-year and five-year history ranges with on-demand database loading and daily, weekly or monthly aggregation.
- Add daily combined count/KPM history summaries alongside language-specific rates.
- Add public project documentation, MIT licensing and GitHub release infrastructure.

### Changed

- Calculate long-range rates from summed interval/character numerators and actual covered duration while preserving language, evidence and counting-rule boundaries.
- Restore the menu bar to the current input segment, with active updates around once per second.
- Select WPM or CPM from the current input-source language. At this version, unavailable global character commits remain an honest unavailable CPM state; global WPM for all languages arrives in 0.2.1.
- Preserve the separate KPM menu option.
- Exclude spaces from global keystroke counts and KPM while retaining full actual time between accepted operations.
- Use bounded recent input-method metadata to estimate candidate digits, arrows and Return as probable composition, without inventing character commits.
- Preserve older aggregates under their original rule; do not average daily rates across incompatible old/new counting policies.
- Simplify daily counts to one estimated keystroke counter across all recorded languages; combine duration and weighted KPM while keeping primary WPM/CPM language-specific in this version.
- Compact large keystroke counts to K/M/B notation with full integer tooltips.

### Fixed

- Clear stale rates at language/source changes instead of retaining a previous English WPM value.
- Deduplicate unchanged input-source notifications while retaining real input-mode boundaries.
- Refresh Accessibility context leases without discarding an entire previously valid queued batch; changed focus identity or failed queries still invalidate the context.
- End source-state mutation before delivering synchronous notifications, preventing reentrant readers from triggering an exclusivity crash.

## [0.1.0] - 2026-10-22

Originally local `1.1.0` builds; no separate public release archive was published.

### Added

- Introduce the Keytempo name and icon, English/Chinese interfaces, input-language selection, per-language history, estimated WPM, confirmed CPM and separate KPM details.
- Separate global estimates from a real confirmed editor adapter, with adaptive segment timing and local aggregate storage.
- Establish core, persistence and application integration tests and document the limits of real-world input and resource validation.

[Unreleased]: https://github.com/BenjaminD2023/Keytempo/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/BenjaminD2023/Keytempo/compare/v1.2.1...v0.3.0
[0.2.1]: https://github.com/BenjaminD2023/Keytempo/compare/v1.2.0...v1.2.1
[0.2.0]: https://github.com/BenjaminD2023/Keytempo/compare/v1.1.1...v1.2.0
[0.1.1]: https://github.com/BenjaminD2023/Keytempo/releases/tag/v1.1.1
[0.1.0]: docs/VALIDATION.md
