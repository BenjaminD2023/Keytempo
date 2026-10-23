# Keytempo

A native macOS menu bar app for understanding your everyday typing rhythm. Built with Swift, AppKit and SwiftUI; statistics stay on your Mac.

[简体中文](README.zh-CN.md) · [Releases](https://github.com/BenjaminD2023/Keytempo/releases) · [Changelog](CHANGELOG.md) · [License](LICENSE) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## What it measures

Keytempo separates **context-based estimates** from **confirmed input**. Global keyboard monitoring can estimate activity in supported editable controls, but it cannot prove that every key inserted text or obtain Chinese character commits. An optional Chinese IME compatibility mode can also estimate keyboard activity when focused-control metadata is unavailable, with reduced ability to exclude non-text operations. Confirmed operation and character counts currently come from the app's built-in validation editor.

| Metric | Definition | Availability |
|---|---|---|
| Estimated WPM | Accepted input-process KPM divided by five; includes composition and editing, not actual words or Chinese characters | All global input-source languages, including Chinese; always marked as an estimate |
| CPM | Actually committed grapheme clusters divided by covered input-process time | Character-based languages, through the confirmed editor only |
| KPM | Accepted operation intervals per minute | Separate menu option and history columns; global values remain estimates |

The primary menu bar rate shows the **current input segment**, updating about once per second while active. Global estimates use the same **estimated WPM = KPM ÷ 5** scale for every input language, including Chinese. This describes accepted keystroke rhythm, not actual word or Chinese-character output; Pinyin keys are never converted into invented committed characters. Actual CPM remains available only through confirmed character-commit paths. Switching input source clears the current rate until a fresh matching sample is available; an old English rate is not retained as the Chinese result. KPM remains available independently and combines up to 128 recent accepted interval batches across all recorded languages, without joining the gaps between sources. The next accepted input after a pause longer than 30 seconds starts a fresh sample; waiting itself never changes the frozen rate.

At least four accepted intervals and 0.5 seconds are needed to display a rate. A segment's first operation still counts toward totals. When input stops or a same-source focus/command boundary occurs, the last available estimated rate remains visible as recent/stopped, including when opening Keytempo to inspect it. The boundary still ends timing continuity; the next input does not bridge across it. Source changes, lost permissions and explicit resets clear incompatible samples. Waiting does not add typing time or reduce the measured rate.

An optional **WPM while typing, today's keystrokes otherwise** menu bar mode shows live estimated WPM only while a continuous segment has enough fresh samples. During initial sampling, after input stops or at an interruption, it shows today's combined estimated keystroke count with K/M/B formatting. A retained recent/stopped rate does not keep this mode on WPM. The independent speed, KPM, count and icon modes remain available in Settings.

The menu popup emphasizes the **past ten minutes' average estimated WPM**, with current speed below it and today's statistics retained. The ten-minute value combines accepted intervals across all recorded global input languages and divides their total interval count by their actual typing duration, then by five. It is not throughput over ten wall-clock minutes. The rolling window is session-only; the UI reports shorter observed coverage after launch, resume or reset. Idle waiting adds no typing time, although an old interval can leave the rolling window after ten minutes. A bounded-buffer coverage failure suppresses the rate rather than presenting a partial sample as complete.

The daily overview and menu popup show one **estimated keystroke counter** for everyday input in other apps, combining all recorded languages. Today's average estimated WPM and secondary weighted KPM also combine languages, using the current counting rule. When older rules coexist, all quantities remain visible and the average's partial coverage is explicit. Current segment speed still follows the current input source. Shortcut and context filtering remain active, and spaces are excluded from the global counter and KPM. Large counts use at most three numeric digits with K/M/B suffixes (for example, `1.49K`); hover to see the full integer. History includes combined count/KPM summaries and per-language estimated WPM. Its chart plots only global estimated WPM for the selected language; actual confirmed CPM stays in the separate integrated-path table and is never overlaid on the WPM chart. Confirmed-editor details remain on the Validation tab and in raw CSV exports.

## Features

- Current menu bar speed or WPM while typing with today's count otherwise, a ten-minute average in the popup, daily average/totals, pause/resume and optional launch at login.
- English and Simplified Chinese app interfaces, independent of input-source language.
- Select which input languages to record; selecting none stops recording.
- Per-language 7-day, 30-day, 90-day, one-year and five-year history, separate KPM columns and CSV export.
- Application exclusions, optional Chinese IME compatibility and suspected-repeat/burst filtering, and a diagnostic view without input content.
- A real `NSTextView` validation path for composition, editing and character-commit coverage.
- Check for Updates, manual download/install and optional automatic checks/downloads through Sparkle.

History uses daily periods for ranges up to 90 days, weekly periods for one year and monthly periods for five years. Rates are recalculated from aggregate numerators and actual covered duration, never by averaging daily speeds. Language, evidence and rule boundaries remain separate. Long ranges load from SQLite when opened or selected, without a once-per-second database poll or a larger startup cache. Only previously saved history is shown; selecting five years does not reconstruct missing past activity. Startup retention keeps up to five calendar years and 50,000 aggregate rows. Closing history releases its loaded rows.

## Install

Download a macOS ZIP from [Releases](https://github.com/BenjaminD2023/Keytempo/releases), extract it, and move `Keytempo.app` to `/Applications` or `~/Applications`. Keep that location fixed before granting permissions.

Current maintainer builds use a stable local **Apple Development** signing identity; they are **not Developer ID distribution or notarized**. macOS may still require first-launch approval. Older 0.1.1 downloads (original app/tag `1.1.1`) were ad hoc signed, which tied permissions to a changing binary hash. Migrating to the new certificate identity requires one new grant. On the maintainer Mac, an actual Sparkle update from original `1.2.0` build 9 to original `1.2.1` build 10 retained both Input Monitoring and Accessibility authorization after relaunch and an in-app recheck, without changing permission settings. This local result does not guarantee every Mac or confirm every app's editable-control coverage; future builds must preserve the signing identity and installation path. Release assets identify their architecture; the locally tested build and automatic-update channel are Apple Silicon (`arm64`). Intel execution has not been verified.

The deployment target is **macOS 13 or later**. Actual runtime testing has been performed on an Apple M4 MacBook Air running macOS 27; older systems remain unverified.

### Permissions

For global estimates, allow Keytempo in **System Settings → Privacy & Security**:

1. **Input Monitoring** receives passive keyboard-event metadata.
2. **Accessibility** checks focused-control roles and editability metadata.
3. Return to Keytempo Settings and choose **Check permissions again**. If macOS still associates permissions with an older build, reselect the installed app and restart it.

The built-in validation editor works without these global permissions. Secure Input and revoked permissions stop global classification. Strict mode also withholds unknown or expired text contexts; the optional compatibility mode below changes only the stated Chinese keyboard-activity coverage. No events alone do not prove that you were idle.

### Updates

Choose **Check for Updates…** in the app menu or Settings to check manually, then use the update window to download and install. Settings also controls automatic update checks and automatic download/install on quit. Sparkle checks a public HTTPS appcast and verifies Ed25519 signatures for the feed and update archive before installation; it does not upload typing statistics. A final relaunch may be needed to finish an update.

The 0.1.1 app (original app/tag `1.1.1`) does not contain an updater; install the first updater-enabled release manually once. Updates do not grant privacy permissions, bypass macOS approval or convert global Chinese keystrokes into confirmed CPM. Certificate signing and download signatures protect different parts of the update process. See [release instructions](docs/RELEASING.md) for publisher setup and known signing limits.

Keytempo uses `0.x` versions: historical `1.1.0` and `1.2.0` are documented as `0.1.0` and `0.2.0`. The `0.3.1` release uses build 14 and adds Chinese input recovery and the optional typing/count menu mode. Existing signed `1.x` downloads and tags retain their original identifiers. Internal build numbers continue increasing, so `0.3.1` build 14 is newer for the updater than `1.2.1` build 10. See the [complete changelog and version mapping](CHANGELOG.md).

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

Recognized Command/Control shortcuts, navigation and generated operations interrupt continuity. Uncertain text contexts also interrupt strict-mode classification. Shift/Option text entry, code, punctuation and repeated text are not rejected for their content. Deletions are separate editing activity, not an error rate. System-marked key repeats do not become independent manual keystrokes.

Candidate keys may represent selection rather than new characters. A bounded input-method heuristic uses recent typing in an eligible editable context to count candidate digits, arrows and Return as **probable composition operations**. That estimates purpose; it does not observe marked text or prove a character commit. Without that context, navigation and ambiguous action keys remain excluded or unknown. Spaces are skipped by global count/KPM statistics; an otherwise valid space does not split continuity, and the next accepted interval retains its full actual duration. The confirmed editor still uses real commit callbacks, including genuine text or candidate confirmation, for character coverage.

### Chinese IME compatibility mode

**Settings → Input filtering → Chinese IME compatibility mode (keystroke estimate)** is off by default. Enable it if an app such as WeChat provides no usable focused-editor metadata. When the current source is a Chinese IME and a fresh frontmost-app/source identity is available, it can count eligible keyboard activity as estimated WPM/KPM without pretending to confirm text insertion. Identity checks are event-triggered with a 0.75-second lease, outside the keyboard callback. It does not count Chinese characters or supply CPM.

This mode applies only while text-control evidence is unavailable. A known noneditable control, excluded app, unsupported terminal/mode editor, unselected language, Secure Input or missing permission still blocks recording. Recognized shortcuts, spaces, navigation/action keys, system repeats and known synthetic events remain excluded; this fallback does not infer candidate selection from unknown-context arrow or Return keys. The optional suspected-input guard still applies.

The tradeoff is explicit: unrecognized non-text letter/number operations can enter the estimate when an app supplies no editor evidence. This is broader keyboard-activity coverage, not confirmed text input or complete macro detection. The UI identifies it as an unconfirmed-textbox estimate. Toggling the mode starts a separate counting rule (`-ime-fallback` suffix); existing aggregates remain intact and incompatible rates are not silently merged. A physical System Pinyin test in WeChat 4.1.15 on the maintainer Mac recorded and saved keystrokes through this fallback; broader coverage and error rates remain unmeasured. See [current evidence](docs/VALIDATION.md).

### Other input limits

Paste, autocomplete and known synthetic events do not count as manual character output. Global metadata cannot identify every custom shortcut, macro or intercepted web key. Terminals, Vim modes, games and custom editors may remain unsupported or unknown. See [coverage and validation](docs/VALIDATION.md) and [adapter boundaries](docs/ADAPTERS.md).

The suspected-input heuristic is enabled by default and can be disabled in Settings without disabling shortcut, system-repeat or known-synthetic filtering. It applies only to global probable text-entry events. Twelve presses of the same physical key within three seconds, each less than half a second apart, are treated as suspected repetition. A dense burst also needs at least 16 events within 0.20 seconds, at least four distinct keys and at least eight gaps of 8 ms or less. Speed or regular timing alone is not a rejection rule. Short repeated text, editing and input-method candidate operations are retained; a legitimate long run of one key can be a false positive, so disable the heuristic when appropriate. Arbitrary random text and macros with human-like, unmarked metadata cannot be reliably identified.

The filter buffers at most 24 content-free event summaries, forwards ordinary typing on the next different key and flushes a short final prefix after a one-shot half-second deadline. Original timestamps are preserved. Suspected input interrupts the segment, so removed events do not leave operation time hidden in the speed denominator. Diagnostics show suspected-repeat/burst counts and reasons, without input text or an ordered key sequence.

Counting-policy changes apply to new input. Existing aggregates are preserved rather than retrospectively reclassified. When a day contains old and current rules, today's displayed average uses only current-rule input with explicit coverage; counts and duration retain all saved input. Historical rates across incompatible rules remain unavailable. Current and rolling speeds start from fresh samples after a rule change.

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
