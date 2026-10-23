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
| 0.3.1 | 0.3.1 / `v0.3.1` | 14 | Chinese input recovery and hybrid menu display |
| 0.3.2 | 0.3.2 / `v0.3.2` | 15 | Combined language metrics and clearer menu behavior |
| 0.4.0 | 0.4.0 / `v0.4.0` | 16 | Local activity timeline, sessions and multi-factor practice score |

Already published signed archives, source tags and download URLs retain their original `1.x` identifiers. Their changelog labels are normalized; their embedded app versions have not been rewritten. New releases use `0.x` app versions and tags. The internal build number continues increasing, so Sparkle can offer `0.3.0` (build 11) to apps displaying `1.2.0` (build 9) or `1.2.1` (build 10).

## [Unreleased]

## [0.4.0] - 2026-10-23

### Added

- Add a local hourly activity timeline with accepted keystrokes, actual typing duration and weighted estimated WPM. Intervals crossing an hour or day are divided proportionally, including their rate numerator and timing moments; repeated daylight-saving hours remain distinct.
- Automatically summarize input sessions with average WPM, consistency, score, typing duration and keystroke count. A five-minute gap between accepted events, or a pause, sleep, quit, day, timezone or counting-rule boundary, ends the session at its last accepted event. Elapsed span and actual typing time are shown separately.
- Add optional per-app activity, off by default. Only application bundle identifiers and aggregates are stored locally. Disabling it stops new app-specific collection; a separate confirmed action clears app details while keeping combined totals and session summaries.
- Show rhythm consistency from aggregate accepted-interval timing moments, using `100 / (1 + coefficient of variation)`. No input text, key sequence or individual interval sequence is saved.
- Add Typing Score and a 30-day score trend. Four equally weighted components reward speed, consistency, actual typing time and keystroke volume. Speed, time and volume reach their respective component caps at 100 estimated WPM, 30 typing minutes and 10,000 keystrokes; consistency and scoring require at least 20 accepted intervals and two seconds of actual typing.

### Changed

- Add an Activity page and additive local database tables without rewriting existing daily history. Hourly, session, per-app and score details begin with 0.4.0 recording; old daily totals cannot reconstruct them.
- Retain combined input languages, existing text-context and shortcut filtering, and separate KPM. The confirmed validation editor is excluded from these everyday activity analytics.

Typing Score is an explainable personal practice index, not a standardized skill test, accuracy measure or actual word/Chinese-character output rate. Its fixed references are product heuristics, not population norms. Daily rates, consistency and scores are recomputed from summed interval counts, durations and timing moments, rather than averaged hourly/session scores. Incompatible counting methods are identified rather than silently mixed. Idle waiting adds neither typing time nor score.

## [0.3.2] - 2026-10-23

### Changed

- Limit GitHub release notes to the current version's changes while retaining the complete version history in this changelog.
- Combine accepted input from all languages into one live and historical estimated WPM, with separate KPM retained. Remove recorded-language settings, the history language selector and per-language detail table; the App language picker remains available. Existing saved language rows are preserved and combined at query time without rewriting the database, while confirmed character metrics stay separate from global estimates.

### Fixed

- Name the menu setting **Primary rate (estimated WPM)** / **主要速度（估算 WPM）** and consistently show operation KPM divided by five, including while the confirmed editor is active. Actual confirmed CPM remains available in validation and statistics; the typing/count hybrid and independent KPM modes remain available.
- Keep the hybrid menu mode on WPM during input, sample warm-up and temporary context rechecks. After input is confirmed stopped, show `— WPM` for three seconds before today's keystroke count, without adding that waiting time to typing duration.
- Label today's average consistently as **今日平均速度** / **Today's average** in the popup and statistics card. When some older records were counted differently, show the number of keystrokes used for the average and explain the excluded records in help; all saved counts remain in the total.

## [0.3.1] - 2026-10-23

### Added

- Add a menu bar mode that shows live estimated WPM while a continuous input segment has enough fresh samples, and today's combined estimated keystrokes otherwise. Candidate, stopped and interrupted input falls back to the count with the existing K/M/B formatting; the separate speed, KPM, count and icon modes remain available.
- Add an opt-in Chinese IME keyboard-activity compatibility mode for apps whose focused-editor metadata is unavailable. It is off by default. A fresh frontmost-app/source lease is required; known noneditable controls, mode editors, app/language exclusions, permissions and existing shortcut/space/repeat/synthetic filters remain enforced. This mode may include unrecognized non-text activity and never supplies Chinese character counts or CPM. Its aggregates use a separate `-ime-fallback` rule.
- Add optional content-free diagnostics for the focus-query route, AX error stages, and context-confirmed replay/discard counts. The temporary context queue is limited to 64 event summaries and 350 milliseconds, with explicit loss on expiry or interruption.

### Fixed

- Retain the latest usable estimated rate as recent/stopped across same-source focus, command and inspection-window boundaries, while ending timing continuity. Opening Keytempo no longer makes a successfully recorded rate disappear; incompatible source, permission and explicit-reset boundaries still clear it.
- Recover short input bursts after an Accessibility context lease expires: withhold the stale context, query it again, and replay recent events at their original times only after fresh metadata confirms the same focused control. Changed focus, source, permissions, commands and other interruption boundaries cannot revive the queued input.
- Resolve focus through bounded application, system and focused-window queries, validating the owning process before using a control. Recognize independently supported editable, value-setter or selected-text-setter metadata without reading the attributes' text values; selectable read-only text remains insufficient.
- Retry transient focus failures twice with short bounded delays before returning to event-triggered backoff, and reject query results from an application or input source that changed while the query was running.
- Recheck noneditable focus metadata on later input events with a short lease, even when an application accepts focus-notification registration, so missing descendant notifications cannot keep a stale exclusion for thirty seconds.
- Preserve an existing probable Chinese composition state when `=`, `-`, `[` or `]` pages candidates, so subsequent candidate selection is not lost. These keys retain their ordinary text meaning outside that bounded state; spaces remain excluded from global counts.

Global Chinese speed remains an estimate on the same WPM scale as other languages. A physical ChatGPT test produced accepted estimated input and a usable rate. The tested WeChat 4.1.15 version supplied no focused-editor evidence; with compatibility mode explicitly enabled, physical System Pinyin input on the maintainer Mac produced counted keystrokes and a usable estimated WPM, and the aggregates were saved. This verifies those observed paths, not coverage or error rates for every app or Chinese input method.

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

[Unreleased]: https://github.com/BenjaminD2023/Keytempo/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/BenjaminD2023/Keytempo/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/BenjaminD2023/Keytempo/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/BenjaminD2023/Keytempo/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/BenjaminD2023/Keytempo/compare/v1.2.1...v0.3.0
[0.2.1]: https://github.com/BenjaminD2023/Keytempo/compare/v1.2.0...v1.2.1
[0.2.0]: https://github.com/BenjaminD2023/Keytempo/compare/v1.1.1...v1.2.0
[0.1.1]: https://github.com/BenjaminD2023/Keytempo/releases/tag/v1.1.1
[0.1.0]: docs/VALIDATION.md
