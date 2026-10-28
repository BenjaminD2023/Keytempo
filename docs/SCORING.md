# Daily Typing Score, XP and levels

This document describes **0.5.0-rc (build 20)**: `daily-score-v3`, `daily-xp-v2` and `levels-v2-150`. The scoring and settlement policies introduced in 0.5.0-beta are unchanged. Published 0.4.1 records and earned XP are preserved, while legacy score charts and reward-export entries are removed from the app interface.

Keytempo's score is an explainable personal-practice index. It is not an accuracy test, a productivity measure, a semantic-content detector or a certified skill assessment. Estimated WPM measures accepted input operations, including supported composition and editing, rather than actual words or committed Chinese characters.

## Policies and coverage

| Policy | Identifier | Status |
|---|---|---|
| Daily state | `daily-rewards-v1` | Open days, settlement and migration |
| Daily score | `daily-score-v3` | Current daily index |
| Daily XP | `daily-xp-v2` | Final score converted to whole XP, plus verified improvement |
| Level schedule | `levels-v2-150` | Exact thresholds scaled 150× |
| Improvement evidence | `improvement-v1` | Retained frozen baselines and completed-day verification |
| Legacy points / XP | `score-v2` / `xp-v1` | Preserved compatibility ledger; hidden from the app interface |
| Original practice score | `practice-v1` | Preserved historical 0–100 index; hidden from the app interface |

New daily-score coverage starts at first activation of the daily system in 0.5.0-beta or later; updating to the release candidate does not restart that coverage. Old daily totals cannot reconstruct complete one-second consistency samples or compatible new-policy evidence; no past scores or ordinary XP are fabricated. Existing input history, reward ledgers, baselines and milestone claims survive the additive migration. An uncovered date is unavailable, not a zero score.

Reward days use the persisted progression timezone, inherited from existing rewards when present. Changing the system timezone does not start a fresh budget. The logical current day does not move backward after a clock correction. Calendar changes never create typing time.

## One accepted stream and actual time

The daily engine consumes the classified **global probable-input** stream once. It does not sum daily, hourly, session or optional app records as separate input. The confirmed validation editor remains outside everyday rewards. Existing shortcut, space, navigation, auto-repeat, generated-input, excluded-app and text-context filters remain active; Chinese compatibility mode retains its estimation limits.

Only accepted monotonic intervals supply time. A chain's first operation counts as a key but has no predecessor interval. Pauses, commands, focus/source changes, sleep, missing permissions and other interruptions end continuity. No timeout tail, session span, wall-clock timer or relaunch gap earns time. In particular, waiting to confirm idle or to settle a day adds neither time nor rate samples.

Let `N` be the sum of accepted interval weights and `t` their full measured duration in seconds:

```text
estimated WPM = 12 × N / t
```

This weights intervals by actual time; it does not average displayed speeds or replace slow intervals with a threshold. A day's keys `K` include first keys, so `N` is not mechanically `K−1` when there are several chains. Calendar-boundary splits preserve proportional interval weights and actual duration without inventing extra observations.

## Daily score

For one compatible reward day's aggregate evidence:

```text
W = weighted estimated WPM
C = standalone pooled Monkeytype-style consistency, on 0–100
T = measured typing seconds / 60
K = accepted keystrokes

practice = T + K / 300
Score = round(150 × sqrt(practice) × sqrt(W / 50) × exp((C − 75) / 100))
```

The final result is a nonnegative whole number, rounded to nearest with positive halves upward. There is **no product ceiling**, component quota or fixed performance/practice percentage. Additional measured time and accepted keys increase practice evidence, speed uses a square-root factor, and consistency supplies a smooth exponential factor. These constants are transparent product heuristics, not population norms or statistically calibrated weights.

Score recomputes from the day's totals as accepted input arrives. It can decline when the day's weighted speed or consistency declines; it is not an accumulating award ledger. Pending XP follows the current score and can also change. Committed lifetime XP is separate and never reduced because later typing is slower. Days below five measured minutes or 1,000 keys are marked preliminary; this label does not add a second reward or silently discard their data.

The aggregate must be valid, have at least **20 accepted intervals and two measured seconds**, and provide both WPM and complete consistency evidence. Consistency additionally needs ten complete one-second samples and twenty represented intervals. Insufficient evidence, incompatible counting rules, invalid moments or numeric overflow yield unavailable score, never a guessed zero/perfect value. Keys and measured time remain visible. A finalized day without enough score evidence has zero ordinary XP and an explicitly unavailable score.

### Numerical examples

| WPM | Consistency | Measured minutes | Accepted keys | Score / ordinary XP |
|---:|---:|---:|---:|---:|
| 50 | 80 | 5 | 1,250 | 477 |
| 50 | 80 | 15 | 3,750 | 827 |
| 50 | 80 | 30 | 7,500 | 1,169 |
| 50 | 80 | 60 | 15,000 | 1,654 |
| 78 | 88 | 41 | 16,001 | **2,072** |
| 120 | 95 | 240 | 144,048 | 7,617 |

These formula examples assume the stated aggregate WPM and consistency have valid coverage. For the 78-WPM example, 15,990 accepted intervals over 2,460 seconds give exactly 78 WPM; the remaining eleven keys are chain starts. One coherent uninterrupted chain need not have the example's exact key count. Hundreds to a few thousand daily XP are typical examples, not a floor or a 5,000-XP cap.

Time and key volume are related during steady input; the formula intentionally gives both explicit contributions. It does not prove that practice was useful or distinguish arbitrary text from meaningful writing. Content shape, repeated words, code and punctuation are not semantic spam evidence. Existing optional metadata filters cannot detect every macro.

## Monkeytype-style consistency

The mapping follows Monkeytype's pinned [Kogasa function](https://github.com/monkeytypegame/monkeytype/blob/128e4029048f72d3a8106941c4c4602f60c51b24/packages/util/src/numbers.ts) and its [variation in per-second rates](https://github.com/monkeytypegame/monkeytype/blob/128e4029048f72d3a8106941c4c4602f60c51b24/frontend/src/ts/test/test-logic.ts). Keytempo uses filtered operation estimates and different continuity/evidence gates, so its number is not directly interchangeable with a Monkeytype test result.

A sampler starts half-open one-second bins at the beginning of a proven accepted interval chain. The chain's first operation counts once; later accepted interval endpoints contribute further operations. An operation exactly at a bin boundary belongs to the next bin. A bin is complete only when observed accepted coverage reaches its end. Zero-operation full seconds inside a proven chain are included. No timer adds future zero samples. An interruption discards only the unfinished trailing bin; completed samples remain in aggregate moments.

The daily engine pools completed sample counts, sums and squared sums. Operation counts or those counts multiplied by twelve have the same coefficient of variation:

```text
mean = sum(sample rates) / sample count
variance = sum(sample rates²) / sample count − mean²
CV = sqrt(population variance) / mean
C = 100 × (1 − tanh(CV + CV³ / 3 + CV⁵ / 5))
```

`C` is bounded to 0–100 and rounded to two decimals by the standalone sampler before the daily formula uses it. At least ten complete samples, twenty represented accepted intervals and a positive sampled mean are required. Negligible negative variance caused by floating-point roundoff is tolerated; corrupt/nonfinite evidence is rejected. Missing evidence is absent, not zero consistency.

This **pooled standalone consistency is the same value shown by Activity and used in the daily score**. Runs at different means can increase pooled variation. The retained legacy improvement evaluator normalizes each run/block fragment before interval-weighted combination of CV², then applies the same Kogasa mapping. That preserves comparability with its frozen baselines; its value can differ from daily standalone consistency. Neither metric is accuracy or raw inter-key-gap regularity.

## XP and settlement lifecycle

Ordinary XP is the finalized daily score **1:1**, with no daily cap. The current day's number is pending, not already committed lifetime XP. Additional verified-improvement XP is awarded through the existing completed-day gates below; the legacy time/key XP counters do not independently add ordinary XP to the new balance after migration.

1. At **00:00 in the persisted reward timezone**, the previous day is sealed and its XP is credited while the new day starts separately. The Mac may remain awake and in use; display sleep, system sleep and shutdown are not prerequisites. A single calendar deadline and lifecycle/input events advance this state; there is no continuous reward clock.
2. If the Mac is asleep or Keytempo is not running at midnight, processing catches up on the next wake, launch or menu/app opening. The app does not wake the computer to settle or play an animation. An awake relaunch can settle ended days without evidence of a prior rest.
3. Opening the menu or app also checks for overdue ended days before presenting receipts. A current, unfinished reward day is never settled merely because a window opens, the display sleeps or the app quits.
4. Ended days settle oldest first, once. A day's score and awarded XP become an immutable receipt with before/after balances and exact levels. Any newly verified improvement award is included once, on the latest eligible ended day in that settlement batch.
5. Input/activity deltas, daily checkpoint, receipts and permanent claims commit in one SQLite transaction. Only committed unseen receipts are eligible for animation. A save failure retains the immutable retry payload; retrying or opening a window cannot duplicate XP.
6. On the next menu or app opening, unseen receipts display in date order, one at a time. XP is already credited independently of playback. Skip-one/skip-all change only presentation acknowledgement. Closing before acknowledgement leaves the receipt unseen for next time. Replaying or skipping cannot award or revoke XP.

The settlement panel contains date, score, ordinary/improvement XP where applicable, and before/after level information. There is no settlement-review navigation entry or manual claim button. Effects are finite and cancelled when the panel closes. Visual tiers begin at levels 1, 18 and 58, separate from the Prism and Stellar theme unlocks at 20 and 60. Reduce Motion displays static feedback rather than requiring animated completion.

A day without recorded input does not create a fake score or an empty animation. A settled day's genuinely late evidence cannot rewrite its finalized score. It remains in ordinary measurement history according to existing rules; the daily ledger conservatively excludes it from the already committed day rather than awarding twice. Startup ends continuity and partial live rate bins; it does not invent intervals across a restart.

## Verified personal improvement

The existing `improvement-v1` evaluator and its permanent claim high-water marks are retained. Context tracks use normalized declared language/input-method metadata and compatible measurement/evidence policies, not app identities. Chinese operation estimates and English input do not become interchangeable baseline samples. Unknown source metadata cannot establish a baseline. State is bounded to 64 context lineages.

Speed and consistency calibrate independently:

- A qualifying completed context day contains at least **300 measured seconds**.
- Each metric needs **five qualifying completed days and 3,600 metric-covered seconds** before its baseline freezes.
- Speed pools accepted interval weights and seconds, rather than averaging displayed daily speeds.
- Improvement consistency pools qualified within-fragment normalized variation with the Kogasa mapping. Its duration gates use covered consistency seconds. Missing consistency is absent, not a zero baseline.
- Calibration-through days cannot also count as later verification evidence.

Verification uses the **latest seven qualifying completed days after that metric's baseline**. It requires three valid daily estimates and at least **1,800 metric-covered seconds**. Both the pooled estimate and at least three independent daily estimates must meet the milestone. Unknown-consistency days can age older evidence out of the window without fabricating a value. The unfinished current day and brief bursts cannot immediately mint improvement XP.

```text
speed milestone m = baseline WPM × (1 + 0.05 × m)
consistency milestone m = baseline consistency + 5 × m, at most 100
```

Each newly verified milestone earns **750 XP** in new units: the previous 5-XP award scaled by 150. A verified 40→44 or 100→110 WPM gain crosses two steps and earns 1,500 XP. A 70→80 consistency gain likewise earns 1,500 XP. Persistent per-metric high-water marks prevent repeat awards after retry, restart or regression/recovery. Incompatible policy changes preserve lineage and conservatively suspend that lineage rather than granting a fresh baseline reset. Deleting all user data remains the separate privacy reset.

These gates are transparent heuristics, not statistical proof of improved skill.

## Exact levels and migration

An existing balance `X` converts once to `150 × X`; every level threshold and next-level cost is multiplied by the same factor. This preserves level and proportional progress. For example, old **520 XP** becomes **78,000 XP**, still Level 20, at **3,000/7,500** toward Level 21 with **4,500** remaining. Historical XP is not also re-awarded as daily score.

| Current level | XP to the next level |
|---|---:|
| 1–3 | 1,500 |
| 4 | 3,000 |
| 5–19 | 4,500 |
| 20–29 | 7,500 |
| 30–49 | 15,000 |
| 50 onward | 30,000 |

| Target level | Exact lifetime XP |
|---|---:|
| 1 | 0 |
| 2 | 1,500 |
| 5 | 7,500 |
| 10 | 30,000 |
| 20 | 75,000 |
| 30 | 150,000 |
| 40 | 300,000 |
| 50 | 450,000 |
| 60 | 750,000 |

Balances and costs are whole integers. The piecewise level lookup is constant time; checked arithmetic rejects overflow. There is no fixed maximum level. A next threshold outside the integer representation is unavailable rather than wrapped. One settlement may cross several levels; level-up feedback adds no additional XP.

Scaling is not a universal claim that every user now levels faster or slower: ordinary XP changed from time/key thresholds to a score influenced by speed and consistency. For the 41-minute/16,001-key example, the old time/key formula gave 16 XP; the new 2,072 XP is about 13.81 old units under 150× costs. Different practice patterns yield different progress.

## Ranks and appearance

The Levels & Appearance page displays rank badges, the current level, exact whole-number XP progress, remaining XP, a complete unlock roadmap, previews and settings. It uses the settled lifetime balance and the same integer level schedule above; a rank label or visual unlock does not create an additional award or spend XP. System, light and dark appearance are selectable independently of the app language.

Classic and the Keyboard icon are available initially. Each later milestone in the appearance roadmap unlocks exactly one item, rather than a bundle:

| Level | New selectable item |
|---:|---|
| 1 | Classic theme and Keyboard icon (initial choices) |
| 5 | Wave menu icon |
| 10 | Ocean theme |
| 15 | Menu coloring by current estimated WPM |
| 18 | Prism settlement effects |
| 20 | Prism theme |
| 25 | Orbit menu icon |
| 30 | Forest theme |
| 35 | Spark menu icon |
| 40 | Ember theme |
| 45 | Menu coloring by today's accepted keystroke count |
| 50 | Graphite theme |
| 55 | Bolt menu icon |
| 58 | Stellar settlement effects |
| 60 | Stellar theme |
| 70 | Custom low/high speed colors and WPM range |
| 80 | Rose theme |
| 100 | Aurora theme |

The roadmap has eighteen distinct milestone levels, covering nine themes, five menu icons, three color-control unlocks and two enhanced settlement-effect tiers; Level 1 supplies the two initial choices. The Level 70 controls customize both endpoint colors and the WPM range of the speed-color ramp. An appearance selection changes presentation only, without changing accepted-input rules, score, XP, settlement timing or level costs. Locked options do not become selectable through preview or stored preferences; after a data reset, a stored preference above the user's new level falls back to an available choice.

Current daily-score history, raw activity totals and personal-improvement/calibration details remain available. The release candidate removes the old `score-v2` disclosure/export and `practice-v1` chart, rather than deleting their underlying evidence or ledger. Existing awarded XP, migration markers, frozen baselines and milestone claims are retained.

## Persistence, retention and privacy

SQLite schema 6 adds the daily checkpoint, immutable receipt rows and permanent daily claim identities. Checkpoint revisions must advance consecutively. Receipt score, ordinary XP, improvement XP, exact levels and balances reconcile before a transaction commits. Batch identities are idempotent; reusing an identity with different contents is rejected. Corrupt/nonfinite evidence and arithmetic overflow stop new rewards with a visible error while preserving ordinary input statistics.

Acknowledgement timestamps live separately from immutable receipt payloads. Already-seen detailed receipts follow the five-year retention horizon. Unseen receipts remain queued; permanent claims, migrated/lifetime XP and the state checkpoint survive detail pruning. Open pending days and queued receipts have explicit capacity bounds rather than unbounded per-key storage. Capacity exhaustion stops further reward changes with an error; it does not silently discard unpaid activity. Clearing optional per-app detail does not affect rewards. Delete all data removes every daily/legacy reward table, baseline and acknowledgement.

The coordinator completes all contributions from a canonical accepted event before capacity-triggered persistence. Normal saves coalesce around the existing thirty-second schedule off the keyboard callback. There is no per-key row/fsync, additional keyboard monitor, persistent sequence log or permanent high-frequency reward timer. Uncommitted input can be lost after crash or force quit; delayed or failed writes can leave more than thirty seconds unsaved. The app cannot recover activity it never saved.

The daily-rewards CSV exports committed receipts with day, timezone, policy, score, ordinary/improvement XP, balances, levels, aggregate evidence, settlement time and coverage. Pending daily values remain in the live checkpoint. The app no longer exposes a separate legacy-rewards export entry; its ledger remains stored for compatibility. Raw input/activity exports retain their existing formats; adding rows of different record types together would duplicate the same activity.

Only counts, durations, sufficient moments, necessary input-source identifiers and reward/checkpoint metadata are stored. There is no typed text, clipboard, window title, URL, physical-key sequence, interval sequence or per-second sequence. Optional per-app data is local and off by default.

## Historical policies

0.4.0's `practice-v1` combined four capped components into a 0–100 index. 0.4.1's `score-v2` accumulated daily logarithmic time/volume points and settled up to 25% speed plus 15% consistency bonuses in canonical 100-key blocks. Its independent `xp-v1` awarded one XP per 300 measured seconds, one per 2,000 accepted keys and five per verified improvement milestone, with persistent lifetime remainders. These records and claims remain intact as compatibility data, without a legacy score chart or reward disclosure/export in the app. They are not relabeled as new daily scores, summed into a new chart, or converted into ordinary XP a second time.

The legacy evaluator continues producing compatible improvement evidence and claims. Only newly observed improvement deltas are scaled into the daily engine; its ongoing legacy ordinary time/key counters do not become a second new XP source.

## Implementation and verification

- [DailyRewards.swift](../Sources/TypingCore/DailyRewards.swift): daily formula, level scaling, coverage, day closure and immutable settlement generation.
- [RateConsistency.swift](../Sources/TypingCore/RateConsistency.swift): complete one-second sampling and pooled standalone moments.
- [RewardProgression.swift](../Sources/TypingCore/RewardProgression.swift) and [TypingRewards.swift](../Sources/TypingCore/TypingRewards.swift): retained compatible improvement evidence and legacy ledger.
- [AggregateStore.swift](../Sources/TypingStore/AggregateStore.swift): transactional checkpoints, immutable receipts, claims, acknowledgements, retention and exports.
- [AppModel.swift](../Sources/Keytempo/AppModel.swift) and [SystemRestState.swift](../Sources/Keytempo/SystemRestState.swift): public display-power/lifecycle metadata, midnight deadline and committed FIFO presentation.
- [RewardViews.swift](../Sources/Keytempo/RewardViews.swift) and [SettlementViews.swift](../Sources/Keytempo/SettlementViews.swift): daily score/XP, lifetime progress and finite presentation effects.

Deterministic tests cover formula examples, missing evidence, partitioned/restarted streams, deferred settlement, migration, exact levels, corruption/overflow and receipt idempotence. Store/integration checks use isolated synthetic metadata. Executed test results and remaining native lifecycle/power/update limitations belong in [VALIDATION.md](VALIDATION.md) and [PERFORMANCE.md](../PERFORMANCE.md); this policy document does not claim that every physical-input, overnight sleep or update path has been exercised.
