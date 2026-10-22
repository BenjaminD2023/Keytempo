# Keytempo

A native macOS menu bar app for understanding your everyday typing rhythm. Built with Swift, AppKit and SwiftUI; statistics stay on your Mac.

[简体中文](README.zh-CN.md) · [Releases](https://github.com/BenjaminD2023/Keytempo/releases) · [License](LICENSE) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## What it measures

Keytempo separates **context-based estimates** from **confirmed input**. Global keyboard monitoring can estimate activity in supported editable controls, but it cannot prove that every key inserted text or obtain Chinese character commits. Confirmed operation and character counts currently come from the app's built-in validation editor.

| Metric | Definition | Availability |
|---|---|---|
| Estimated WPM | Current-source input-process KPM divided by five; includes composition and editing | Word-based input-source languages; always marked as an estimate |
| CPM | Actually committed grapheme clusters divided by covered input-process time | Character-based languages, through the confirmed editor only |
| KPM | Accepted operation intervals per minute | Separate menu option and history columns; global values remain estimates |

The primary menu bar rate shows the **current input segment**, updating about once per second while active. Its main unit follows the current keyboard/input-method language: `zh/ja/ko/th/lo/km/my` use CPM; other known languages use estimated WPM. Switching input source clears the current rate until a new matching sample is available. It never keeps an English WPM value as the Chinese rate. Missing character coverage displays `— CPM`, rather than converting Pinyin keys to characters. KPM remains available independently and combines up to 128 recent accepted interval batches across all recorded languages, without joining the gaps between sources. The next accepted input after a pause longer than 30 seconds starts a fresh sample; waiting itself never changes the frozen rate.

At least four accepted intervals and 0.5 seconds are needed to display a rate. A segment's first operation still counts toward totals. During a natural idle pause, the measured rate freezes and is marked as recent/stopped; waiting does not add typing time or reduce it.

The daily overview and menu popup show one **estimated keystroke counter** for everyday input in other apps, combining all recorded languages. Daily typing duration and weighted KPM are combined too; primary WPM/CPM stays specific to the current input-source language. Shortcut and context filtering remain active, and spaces are excluded from the global counter and KPM. Large counts use at most three numeric digits with K/M/B suffixes (for example, `1.49K`); hover to see the full integer. History includes daily combined count/KPM summaries alongside per-language WPM/CPM details. Confirmed-editor details remain on the Validation tab and in raw CSV exports.

## Features

- Menu bar speed, daily totals, pause/resume and optional launch at login.
- English and Simplified Chinese app interfaces, independent of input-source language.
- Select which input languages to record; selecting none stops recording.
- Per-language 7-day, 30-day, 90-day, one-year and five-year history, separate KPM columns and CSV export.
- Application exclusions and an optional diagnostic view without input content.
- A real `NSTextView` validation path for composition, editing and character-commit coverage.
- Check for Updates, manual download/install and optional automatic checks/downloads through Sparkle.

History uses daily periods for ranges up to 90 days, weekly periods for one year and monthly periods for five years. Rates are recalculated from aggregate numerators and actual covered duration, never by averaging daily speeds. Language, evidence and rule boundaries remain separate. Long ranges load from SQLite when opened or selected, without a once-per-second database poll or a larger startup cache. Only previously saved history is shown; selecting five years does not reconstruct missing past activity. Startup retention keeps up to five calendar years and 50,000 aggregate rows. Closing history releases its loaded rows.

## Install

Download a macOS ZIP from [Releases](https://github.com/BenjaminD2023/Keytempo/releases), extract it, and move `Keytempo.app` to `/Applications` or `~/Applications`. Keep that location fixed before granting permissions.

Current maintainer builds use a stable local **Apple Development** signing identity; they are **not Developer ID distribution or notarized**. macOS may still require first-launch approval. Older 1.1.1 downloads were ad hoc signed, which tied permissions to a changing binary hash. Migrating to the new certificate identity requires one new grant. Future builds keep that identity and installation path stable; actual permission retention still needs a user-authorized update check. Release assets identify their architecture; the locally tested build and automatic-update channel are Apple Silicon (`arm64`). Intel execution has not been verified.

The deployment target is **macOS 13 or later**. Actual runtime testing has been performed on an Apple M4 MacBook Air running macOS 27; older systems remain unverified.

### Permissions

For global estimates, allow Keytempo in **System Settings → Privacy & Security**:

1. **Input Monitoring** receives passive keyboard-event metadata.
2. **Accessibility** checks focused-control roles and editability metadata.
3. Return to Keytempo Settings and choose **Check permissions again**. If macOS still associates permissions with an older build, reselect the installed app and restart it.

The built-in validation editor works without these global permissions. Secure Input, revoked permissions and unknown or expired contexts stop global classification; no events alone do not prove that you were idle.

### Updates

Choose **Check for Updates…** in the app menu or Settings to check manually, then use the update window to download and install. Settings also controls automatic update checks and automatic download/install on quit. Sparkle checks a public HTTPS appcast and verifies Ed25519 signatures for the feed and update archive before installation; it does not upload typing statistics. A final relaunch may be needed to finish an update.

The 1.1.1 app does not contain an updater; install the first updater-enabled release manually once. Updates do not grant privacy permissions, bypass macOS approval or convert global Chinese keystrokes into confirmed CPM. Certificate signing and download signatures protect different parts of the update process. See [release instructions](docs/RELEASING.md) for publisher setup and known signing limits.

## Build and test

Install a Swift toolchain through Xcode or Command Line Tools. The test suite uses Swift Testing and requires Swift 6 or later; this project has been built locally with Swift 6.4. The test framework in that toolchain requires macOS 14 or later, even though the app targets macOS 13.

From the repository root:

```sh
./scripts/test.sh
open dist/Keytempo.app
```

The test script runs the core/store tests, builds the Release app, verifies its signature and runs isolated AppKit/coordinator integration checks. To build without the tests:

```sh
./scripts/build.sh
```

Generated artifacts are placed in `dist/`. To open the statistics window on a fresh launch:

```sh
open dist/Keytempo.app --args --show-stats
```

See [release instructions](docs/RELEASING.md) for versioning and GitHub distribution.

## Timing and classification

The pipeline is: events → context/purpose classification → contiguous segments → speed → aggregate storage. Only accepted intervals between two effective operations in the same segment add time:

```text
KPM = 60 × sum(accepted intervals) / sum(actual interval seconds)
```

There is no fixed activity tail after a key, no continuously growing active-time clock, and no averaging of individual interval speeds. Median/MAD-based bounded rhythm samples help distinguish pauses and adapt to slower continuous typing. The coefficients are a tested baseline, not a claim of an optimal human model.

Recognized Command/Control shortcuts, navigation, generated operations and uncertain contexts interrupt continuity. Shift/Option text entry, code, punctuation and repeated text are not rejected for their content. Deletions are separate editing activity, not an error rate. System-marked key repeats do not become independent manual keystrokes.

Candidate keys may represent selection rather than new characters. A bounded input-method heuristic uses recent typing in an eligible editable context to count candidate digits, arrows and Return as **probable composition operations**. That estimates purpose; it does not observe marked text or prove a character commit. Without that context, navigation and ambiguous action keys remain excluded or unknown. Spaces are skipped by global count/KPM statistics; an otherwise valid space does not split continuity, and the next accepted interval retains its full actual duration. The confirmed editor still uses real commit callbacks, including genuine text or candidate confirmation, for character coverage.

Paste, autocomplete and known synthetic events do not count as manual character output. Global metadata cannot identify every custom shortcut, macro or intercepted web key. Terminals, Vim modes, games and custom editors may remain unsupported or unknown. See [coverage and validation](docs/VALIDATION.md) and [adapter boundaries](docs/ADAPTERS.md).

The no-space/candidate-estimate counting policy applies to new input. Existing aggregates are preserved rather than retrospectively reclassified. When a day contains both old and new policies, its combined rate may be unavailable because incompatible rules are not averaged; counts remain visible, and current speed starts from fresh samples after the update.

## Privacy and storage

Typing statistics stay local. The updater can contact GitHub/raw.githubusercontent.com and GitHub release-download servers to check and download releases; those requests do not include typing aggregates or input content. Automatic checks can be disabled in Settings. It does not save typed text, reconstructable key sequences, clipboard contents, document contents, window titles or URLs. The confirmed editor briefly counts text in its insertion callback, then passes only counts and coverage metadata to statistics.

- Database: `~/Library/Application Support/TypingSpeed/statistics.sqlite`
- Preferences: `~/Library/Preferences/local.benjamin.TypingSpeed.plist`
- Legacy bundle identifier: `local.benjamin.TypingSpeed`

These legacy identifiers preserve history and settings across the rename to Keytempo. Diagnostics are opt-in, bounded and memory-only. New aggregate data is normally saved in batches around every 30 seconds; pause, sleep and normal exit attempt to flush it. A crash or force quit may lose unsaved data.

Keyboard callbacks use a fixed-capacity buffer. Accessibility work runs outside those callbacks, with coalesced queries, timeouts and event-driven refresh. UI timers stop after pending work settles. Resource measurements and limitations are recorded in [PERFORMANCE.md](PERFORMANCE.md) and [POWER.md](POWER.md): a full battery-power target below 1 W has **not** been verified, and the post-UI RSS target is not yet met.

## Feedback

[Open an issue](https://github.com/BenjaminD2023/Keytempo/issues) with the app version, macOS version, input source, affected app, selected metric and visible permission/context status. A small artificial reproduction is more useful than personal text. Do not upload typing databases, chat content, clipboard data or system permission databases. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). You may use, modify and redistribute Keytempo, including commercially, while retaining the copyright and permission notice required by that license. There is no additional project-specific field-of-use restriction. Third-party notices are in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md); see [Resources/ICON.md](Resources/ICON.md) for the app icon's provenance.
