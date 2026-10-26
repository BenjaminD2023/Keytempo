# Keytempo

A native macOS menu bar app for understanding your everyday typing rhythm. Built with Swift, AppKit and SwiftUI; statistics stay on your Mac.

[简体中文](README.zh-CN.md) · [Releases](https://github.com/BenjaminD2023/Keytempo/releases) · [Changelog](CHANGELOG.md) · [License](LICENSE) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

**Stable release: 0.5.1 (build 23).** [Download for Apple Silicon](https://github.com/BenjaminD2023/Keytempo/releases/download/v0.5.1/Keytempo-0.5.1-macos-arm64.zip) · [Release notes](https://github.com/BenjaminD2023/Keytempo/releases/tag/v0.5.1). Requires macOS 13 or later.

## What it measures

Keytempo separates **context-based estimates** from **confirmed input**. Global keyboard monitoring can estimate activity in supported editable controls, but it cannot prove that every key inserted text or obtain Chinese character commits. An optional Chinese IME compatibility mode can also estimate keyboard activity when focused-control metadata is unavailable, with reduced ability to exclude non-text operations. Confirmed operation and character counts currently come from the app's built-in validation editor.

| Metric | Definition | Availability |
|---|---|---|
| Estimated WPM | Accepted input-process KPM divided by five; includes composition and editing, not actual words or Chinese characters | All global input-source languages, including Chinese; always marked as an estimate |
| CPM | Actually committed grapheme clusters divided by covered input-process time | Character-based languages, through the confirmed editor only |
| KPM | Accepted operation intervals per minute | Separate menu option and history columns; global values remain estimates |

The primary menu bar rate updates about once per second while typing, combining recent accepted intervals from **all input languages** on the same **estimated WPM = KPM ÷ 5** scale, including Chinese. This describes accepted keystroke rhythm, not actual word or Chinese-character output; Pinyin keys are never converted into invented committed characters. Actual CPM remains available only through confirmed character-commit paths. Input-source changes still break timing continuity, but a usable combined global rate can remain visible during the recheck. KPM remains available independently and uses the same merged recent intervals, without joining interruption gaps. The next accepted input after a pause longer than 30 seconds starts a fresh sample; waiting itself never changes the measured rate.

The menu setting is named **Primary rate (estimated WPM)**. It always shows operation KPM divided by five, including when the confirmed validation editor is active; it does not switch the menu bar to CPM. Actual confirmed character rates remain in validation and statistics.

At least four accepted intervals and 0.5 seconds are needed to display a rate. A segment's first operation still counts toward totals. When input stops or a focus/command boundary occurs, the last available estimated rate remains visible as recent/stopped, including when opening Keytempo to inspect it. The boundary still ends timing continuity; the next input does not bridge across it. Evidence changes, lost permissions and explicit resets clear incompatible samples. Waiting does not add typing time or reduce the measured rate.

The default **Live WPM while typing, today's keys when idle** menu bar mode keeps the WPM unit during input, sample warm-up and temporary context or source rechecks. It retains a usable measured rate during brief rechecks, or shows `— WPM` while gathering samples. After input is confirmed stopped, it shows `— WPM` for three seconds, then today's combined estimated keystroke count with K/M/B formatting. Pausing, losing permission or changing the evidence or counting method returns directly to the count. This display delay adds no typing time. The independent speed, KPM, count and icon modes remain available in Settings. Upgrades preserve saved selections; the default applies when no menu display preference exists.

The menu popup emphasizes the **past ten minutes' average estimated WPM**, with current speed below it and today's statistics retained. The ten-minute value combines accepted intervals across all recorded global input languages and divides their total interval count by their actual typing duration, then by five. It is not throughput over ten wall-clock minutes. The rolling window is session-only; the UI reports shorter observed coverage after launch, resume or reset. Idle waiting adds no typing time, although an old interval can leave the rolling window after ten minutes. A bounded-buffer coverage failure suppresses the rate rather than presenting a partial sample as complete.

The daily overview and menu popup show one **estimated keystroke counter** for everyday input in other apps. Current speed, today's average estimated WPM and secondary weighted KPM combine accepted input across all languages. The average is labeled **Today's average**. If some older records were counted differently, the UI shows how many keystrokes the average uses and explains the excluded records in help; all quantities remain in the total. Shortcut and context filtering remain active, and spaces are excluded from the global counter and KPM. Large counts use at most three numeric digits with K/M/B suffixes (for example, `1.49K`); hover to see the full integer. History shows a combined estimated WPM chart and one table with combined quantities, WPM and separate KPM. Confirmed-editor character metrics stay on the Validation tab and in raw CSV exports, separate from the global WPM trend.

## Activity, Typing Score and XP

Stable release **0.5.1 (build 23)** uses the daily scoring and deferred-settlement policy below. See the [changelog](CHANGELOG.md) and [validation notes](docs/VALIDATION.md) for release changes and executed checks.

The **Activity** tab provides a date-selectable hourly timeline, automatic sessions, separate speed/consistency trends, and a daily-score chart. Hours and sessions show accepted keystrokes, actual typing time and weighted estimated WPM. Sessions end after a five-minute gap or a pause, sleep, quit, day, timezone or counting-rule boundary. Elapsed span is separate from measured typing time; interruptions add no time.

**Typing Score** and **XP gained** appear side by side. Score describes that reward day's speed, consistency and amount of measured practice. It refreshes with accepted input and can rise or fall as the day's aggregate performance changes. There is no product ceiling or fixed 90/10 allocation:

```text
Score = round(150 × sqrt(typingMinutes + acceptedKeys / 300)
                  × sqrt(weightedEstimatedWPM / 50)
                  × exp((consistencyPercent − 75) / 100))
```

For example, **78 estimated WPM**, **88 consistency**, **41 measured minutes** and **16,001 accepted keys** give **2,072 points**. Similar-speed users earn more for sustained practice. The formula is a personal practice index, not an accuracy test, productivity assessment or population-calibrated skill rating. Hundreds to a few thousand points are typical examples, not a daily minimum or maximum.

Consistency uses **Monkeytype-style complete one-second operation rates and the Kogasa mapping**. The daily score uses the same pooled rate moments as the Activity consistency indicator. At least ten complete samples, twenty represented accepted intervals and two seconds of measured typing are required. Incomplete trailing seconds, context gaps and idle tails add no samples. Insufficient or incompatible evidence is unavailable, never perfect consistency. The source, filtering and boundaries differ from a Monkeytype test, so the numbers are not directly interchangeable.

**Ordinary XP equals the final daily score, one for one.** Today's XP is shown as pending, separate from committed lifetime XP and exact level progress. At midnight in the fixed reward timezone, the day closes. If the computer is still awake with its displays on, settlement waits until display sleep, system sleep or shutdown while the next day's score starts separately. Sleeping across midnight is caught up after wake without waking the computer just to settle. Only ended days settle, once; opening the app does not itself award XP.

The next opening of the menu or app automatically presents committed unseen settlements in date order. There is no settlement-review tab or manual reward-claim step. Each card shows the date, score, XP and any level change; skip controls acknowledge animations without changing earnings. Unfinished presentations remain available next time. Loading panels can be closed with Escape, and read errors offer a retry. Standard finite settlement animations are available at every level, with an announcement for actual level gains. Reduce Motion uses static feedback.

Verified personal improvement still requires completed-day evidence, with frozen compatible-context baselines and independent speed/consistency calibration. Each newly verified **+5% relative speed** or **+5 consistency points** earns **750 additional XP**, once. Brief bursts and the unfinished current day cannot claim a milestone. The legacy evaluator retains its run-normalized rate consistency for comparable improvement evidence; this differs from the pooled daily-score consistency.

Existing XP and every level threshold are both multiplied by **150**, preserving the previous level and proportional progress. Level 20 requires **75,000 lifetime XP**; level 60 requires **750,000**. For example, an old balance of 520 becomes 78,000: still Level 20, now 3,000/7,500 XP toward Level 21. Levels have no fixed maximum. The daily policy starts at first activation; older score records and earned XP stay preserved on disk, without old score charts or reward exports in the app. No historical daily scores or second awards are fabricated. The previously unpublished 0.4.2 work was included in 0.5.0-beta.

The **Levels & Appearance** page brings rank badges, exact current/required XP, remaining XP, a 16-milestone unlock roadmap, previews and appearance settings together. Choose system, light or dark appearance. The roadmap spreads rewards across separate milestones, with one new item per milestone after the initial Classic theme and keyboard icon:

| Choice | Unlock levels |
|---|---|
| Themes | Classic 1 · Ocean 10 · Prism 20 · Forest 30 · Ember 40 · Graphite 50 · Stellar 60 · Rose 80 · Aurora 100 |
| Menu icons | Keyboard 1 · Wave 5 · Rhythm 15 · Orbit 25 · Spark 35 · Ripple 45 · Bolt 55 · Comet 70 |

Cosmetic unlocks consist of themes and menu icons. Unlocks use settled lifetime XP; previews and selections do not spend XP. Menu icons and text use the native macOS system foreground color. These local appearance choices do not change input filtering, scores, XP or level thresholds. Current daily history and personal-improvement calibration remain available in Activity.

In 0.5.1, Rhythm, Ripple and Comet change their monochrome patterns proportionally with current estimated WPM: bar height, ring visibility and trail length follow the percentage through your selected range. **Levels & Appearance** lets you set the lower and upper WPM endpoints, defaulting to **20–120 WPM**. Endpoints must be between 0 and 1,000 WPM, with at least 1 WPM between them. Values outside the range use its minimum or maximum response; a missing, nonfinite or nonpositive current rate uses the idle drawing. Existing aggregate snapshots drive these patterns, including with motion disabled, Reduce Motion or low power. The panel shows static examples across the selected range, and a bounded cache stores patterns at 1% increments.

The theme gallery uses distinct vector artwork and geometric rank seals, with compact cached menu icons. Standard menu-icon motion is available at every level: the same selected WPM range controls sweep cadence and intensity for every icon. Levels & Appearance includes an off switch and a six-second preview that ramps through the selected range for five seconds, then holds its upper endpoint for one second on the actual menu icon; preview values never enter typing statistics or XP. Active snapshots renew short, finite animation leases; idle, stale updates, pause, permission loss, sleep, hidden menu items, Reduce Motion, Increase Contrast and low power stop continuous effects. Standard settlement effects are finite and stop when dismissed or interrupted.

**Coverage and durability:** reward days use a persisted timezone, independent of later OS timezone changes. Accepted monotonic intervals supply all measured time. Batched SQLite transactions save input/activity deltas, daily state and immutable settlement receipts together; stable identities prevent duplicate XP on retries. Presentation acknowledgements are separate from balances. Normal saves coalesce around thirty seconds; crashes or delayed writes can lose unsaved input. No per-key database row or permanent high-frequency reward timer is added. Completed settlement details follow the five-year retention horizon; lifetime totals and permanent claims survive detail pruning. Delete all data also removes progression and baselines.

**Store per-app activity locally** remains optional and off by default. Only bundle identifiers and aggregates are saved when enabled; rewards do not require app identities. No text, clipboard, titles, URLs, key sequences, interval logs or per-second sequences are stored. The separate daily-rewards export contains committed receipts and policy/coverage metadata. The old reward ledger remains stored for migration and compatible improvement evidence, without a separate legacy export entry in the app. See [the complete scoring policy](docs/SCORING.md) for evidence gates, lifecycle behavior, formulas and exact levels.

## Features

- Current menu bar speed or WPM while typing with today's count otherwise, a ten-minute average in the popup, daily average/totals, pause/resume and optional launch at login.
- Hourly activity, automatic sessions, optional local per-app activity, Monkeytype-style consistency, daily Typing Score, score-based XP, deferred settlement and exact levels.
- A Levels & Appearance page with exact XP progress, a roadmap for theme and icon unlocks, nine themes, eight menu icons including three with speed-responsive shapes, and a standard menu-motion switch, configurable WPM range and preview.
- English and Simplified Chinese app interfaces, independent of input-source language.
- Combined input statistics across all accepted languages, without recorded-language selection.
- Combined 7-day, 30-day, 90-day, one-year and five-year history, separate KPM columns and CSV export.
- Application exclusions, optional Chinese IME compatibility and suspected-repeat/burst filtering, and a diagnostic view without input content.
- A real `NSTextView` validation path for composition, editing and character-commit coverage.
- Check for Updates, manual download/install and optional automatic checks/downloads through Sparkle.

History uses daily periods for ranges up to 90 days, weekly periods for one year and monthly periods for five years. Rates combine accepted interval counts and actual covered duration across languages, never by averaging daily or language speeds. Existing per-language rows remain saved and are combined when history is read; there is no destructive database rewrite. Evidence and incompatible counting methods remain separate. Long ranges load from SQLite when opened or selected, without a once-per-second database poll or a larger startup cache. Only previously saved history is shown; selecting five years does not reconstruct missing past activity. Input history retention keeps up to five calendar years and 50,000 daily aggregate rows. Reward lifetime state, daily earned totals and milestone claims are independent of detailed-history pruning. Closing history releases its loaded rows.

## Install

Download [Keytempo 0.5.1 for Apple Silicon](https://github.com/BenjaminD2023/Keytempo/releases/download/v0.5.1/Keytempo-0.5.1-macos-arm64.zip), extract it, and move `Keytempo.app` to `/Applications` or `~/Applications`. Keep that location fixed before granting permissions. Other versions and checksums are available in [Releases](https://github.com/BenjaminD2023/Keytempo/releases).

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

**Prerelease channel:** stable installations continue to receive stable updates. A manually installed beta or release candidate also accepts the signed prerelease channel; prereleases do not replace the stable GitHub Latest release.

The 0.1.1 app (original app/tag `1.1.1`) does not contain an updater; install the first updater-enabled release manually once. Updates do not grant privacy permissions, bypass macOS approval or convert global Chinese keystrokes into confirmed CPM. Certificate signing and download signatures protect different parts of the update process. See [release instructions](docs/RELEASING.md) for publisher setup and known signing limits.

Keytempo uses `0.x` versions: historical `1.1.0` and `1.2.0` are documented as `0.1.0` and `0.2.0`. Version `0.5.1` uses build 23, brings proportional icons and the configurable WPM range to the stable channel, and makes the typing/count menu mode the default for unset preferences. Version `0.5.1-beta` uses build 22 and adds proportional icon response with a configurable animation range on the preview channel. Version `0.5.0` uses build 21 and brings daily score, deferred XP settlement, themes and speed-responsive icons to the stable channel. Version `0.4.1` uses build 17 and adds accumulating score, independent XP/levels and verified personal improvement. Version `0.4.0` build 16 introduced activity analytics and the legacy practice score. Version `0.3.2` build 15 combined language metrics and clarified the menu's WPM display. Version `0.3.1` build 14 introduced Chinese input recovery and the optional typing/count menu mode; its tag and downloads are preserved. Existing signed `1.x` downloads and tags also retain their original identifiers. Internal build numbers continue increasing for updater compatibility. Release notes describe the current version's changes; the [complete changelog and version mapping](CHANGELOG.md) retains the full history.

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

This mode applies only while text-control evidence is unavailable. A known noneditable control, excluded app, unsupported terminal/mode editor, Secure Input or missing permission still blocks recording. Recognized shortcuts, spaces, navigation/action keys, system repeats and known synthetic events remain excluded; this fallback does not infer candidate selection from unknown-context arrow or Return keys. The optional suspected-input guard still applies. Combining languages does not bypass these filters or enable compatibility mode automatically.

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
