# Daily Typing Score and deferred settlement proposal

**Status: Approved design reference for 0.5.0-beta.**

**Date: 2026-10-24, Asia/Shanghai.** The user approved this direction for implementation and prerelease publication. The corresponding native implementation now lives in `DailyRewards.swift`, the daily receipt store and the reward/settlement views. This document preserves the reviewed design and examples; [SCORING.md](SCORING.md) is the authoritative implemented policy, and [VALIDATION.md](VALIDATION.md) records executed checks and remaining runtime limitations. Later UI revisions remove the settlement-review entry and the label beneath the score: committed unseen receipts open automatically at the next menu/app opening.

## Meaning of the score

Typing Score becomes an **uncapped whole-number index of the selected day's measured performance and practice**. It combines that day's weighted estimated WPM, Monkeytype-style consistency, actual accepted typing time and accepted keystrokes. It has no 1000-point ceiling and no fixed 90%/10% component allocation. Additional accepted practice can continue increasing the score, with diminishing returns.

The score is not an accuracy percentage, a certified skill rating, a productivity measure, or a semantic assessment of the user's text. Global WPM remains an accepted-operation estimate. It combines supported languages without claiming to count actual English words or Chinese characters.

The current day's score updates from its aggregate evidence and **can increase or decrease before the day is sealed**: more accepted practice raises its practice term, while changes in daily average speed or consistency can change the complete result. It is not an already earned balance. Selecting a past day reads that day's frozen result and coverage; it never substitutes today's metrics or recomputes the result from current activity. Weekly trends show daily values rather than summing them into a larger skill score. XP is the separate cumulative quantity.

## Accepted evidence

The proposal consumes the existing accepted global input stream once. Shortcut, ordinary navigation, space, system autorepeat, known generated-input, excluded-app and other current filtering rules remain in effect. Existing composition and editing semantics remain in effect. The validation editor is separate from ordinary daily activity. Hourly, session and optional app rows are views of the same activity and must not become additional input to the score.

Use only already measured metadata:

- `K`: accepted keystrokes for this day, including first events without a measurable predecessor.
- `t`: actual accepted interval seconds for this day. Idle tails, waiting for classification, sleep and elapsed session span do not contribute.
- `W`: the day's weighted estimated WPM, `12 × sum(accepted interval weights) / sum(accepted interval seconds)`. Do not average displayed session, hourly or per-interval speeds.
- `C`: **the same daily standalone Monkeytype-style consistency value shown in Activity**, from pooled complete one-second operation-rate moments. The old reward bonus's separately run-normalized aggregation is not silently substituted for it.

For the standalone consistency value:

```text
CV = population standard deviation of complete one-second rates / mean rate
C  = 100 × (1 − tanh(CV + CV³/3 + CV⁵/5))
```

Only full observed seconds inside accepted continuous input contribute samples. Do not append idle zeros, fill context gaps, invent incomplete tail samples, or save input content. The mapping follows the existing Monkeytype-style metric; different filtering and coverage mean it is not directly comparable with a Monkeytype test result.

No rate or composite score is shown before the existing minimum evidence is available: **20 accepted speed intervals and two measured seconds**, plus **10 complete one-second samples containing at least 20 covered accepted intervals** for consistency. Until then, show the observed count/time and “Sampling” or “Not enough evidence.” Missing consistency remains unavailable, never an assumed zero or perfect value.

Once those gates are met, display the score with a **Preliminary** label while `t < 300 seconds` **or** `K < 1000`. This label describes limited evidence; it does not create extra time or keystrokes and is not a claim of statistical confidence. These 300-second/1000-key thresholds are proposed display heuristics, not optimized or scientifically validated constants. A day with enough evidence for a score can retain that low-sample label in its settlement receipt. A day that never supplies a calculable score does not fabricate score-based XP.

All score inputs use the same fixed reward-day boundaries. If existing Activity history uses different calendar/timezone boundaries, implementation must aggregate the corresponding measured evidence correctly or disclose unavailable coverage rather than borrowing mismatched daily totals. Mixed or incompatible measurement policies require the existing coverage handling. A result computed from only part of the day must identify that coverage; totals retained under incompatible older rules must not be silently used as comparable speed/consistency evidence.

## Proposed formula

For valid, nonnegative measured inputs and the consistency metric's natural range `0 ≤ C ≤ 100`:

```text
Practice = t/60 + K/300
Speed factor = sqrt(W/50)
Consistency factor = exp((C − 75)/100)

Typing Score = round(150 × sqrt(Practice) × Speed factor × Consistency factor)
```

Round to the nearest whole point, with positive halves rounded upward. Keep full precision until that final display/settlement rounding. Invalid or nonfinite inputs produce an unavailable result rather than a high score.

`Practice` gives one unit for an actual typing minute and one unit for 300 accepted keystrokes. Its square root rewards additional practice without a linear race to accumulate hours. The speed factor equals one at 50 estimated WPM and continues growing above it; there is no reference-speed ceiling. A ten-point consistency increase multiplies the result by approximately 1.105 at otherwise equal inputs. Consistency's own 0–100 definition does not create a Typing Score cap.

The coefficient 150 sets a readable display scale. The 50-WPM reference, 300-key practice conversion, square-root response and consistency scale are transparent starting parameters requiring calibration with representative usage. They are not claimed to be optimal weights or statistical proof of skill. At fixed valid speed and consistency, increasing accepted time or keys can keep increasing the score without a configured maximum.

This formula reports a daily performance-and-practice index. Read estimated WPM and consistency alongside it when comparing the day's typing characteristics; changes in input volume also affect the index.

### Representative examples

The following are synthetic formula examples, not measured user performance. Each row uses 30 minutes of actual accepted typing and approximately `5 × WPM × 30` accepted keys. Consistency is supplied as the specified hypothetical measured percentage.

| Estimated WPM | Consistency 60 | Consistency 80 | Consistency 90 |
|---:|---:|---:|---:|
| 30 | 671 | 819 | 906 |
| 50 | 957 | 1,169 | 1,292 |
| 80 | 1,366 | 1,669 | 1,844 |
| 120 | 1,897 | 2,318 | 2,561 |

At 50 WPM and consistency 80:

| Actual typing | Accepted keys | Proposed score |
|---|---:|---:|
| 5 minutes | 1,250 | 477 |
| 15 minutes | 3,750 | 827 |
| 30 minutes | 7,500 | 1,169 |
| 60 minutes | 15,000 | 1,654 |

These rows use approximate interval-derived counts; adding actual chain-start keys can change rounding. At otherwise equal performance, quadrupling accepted practice doubles the unrounded score rather than hitting a cap. More practice can also exceed a slightly faster but much shorter day.

The main interactive preview uses **78 estimated WPM, consistency 88, 2,460 measured seconds, and 16,001 accepted keys**:

```text
Practice = 2460/60 + 16001/300 ≈ 94.336667
Speed factor = sqrt(78/50)
Consistency factor = exp((88 − 75)/100)

Unrounded score ≈ 2072.297505
Typing Score = 2072
```

Those counts are internally plausible: 15,990 accepted intervals over 2,460 seconds yield 78 WPM; 16,001 total keys allow 11 chain-start keys without predecessor intervals. The preview numbers remain illustrative.

## XP and personal improvement

Following the request for larger daily rewards, ordinary XP is proposed to use the finalized uncapped score **1:1**. Typical active-day examples fall in the hundreds to a few thousand XP. A long, high-performance day can exceed 5000 XP; the proposal does not turn the suggested approximate range into a hidden hard cap.

```text
ordinary daily XP = finalized whole-number Typing Score
receipt XP        = ordinary daily XP + newly verified improvement XP
```

There is **no fabricated 100-XP minimum**, no XP for an empty/unmeasurable day, and no extra credit from idle time. The main preview's 2072 score produces **2072 ordinary XP**, awarded once when the completed day is settled. Improvement XP remains a separately verified award.

| Synthetic accepted day | Estimated WPM / consistency | Accepted keys | Score | Ordinary XP |
|---|---|---:|---:|---:|
| 1 measured minute | 50 / 80 | 251 | 214, preliminary | 214 |
| 5 measured minutes | 50 / 80 | 1,251 | 478 | 478 |
| 30 measured minutes | 50 / 80 | 7,506 | 1,170 | 1,170 |
| Main 41-minute preview | 78 / 88 | 16,001 | 2,072 | 2,072 |
| 60 measured minutes | 50 / 80 | 15,012 | 1,654 | 1,654 |
| 120 measured minutes | 80 / 90 | 48,024 | 3,689 | 3,689 |
| 240 measured minutes | 120 / 95 | 144,048 | 7,617 | 7,617 |
| 300 measured minutes | 160 / 100 | 240,060 | 11,428 | 11,428 |

The extra keys beyond each row's interval-derived count represent chain-start inputs. These are illustrative, internally plausible metadata examples, not measured user days. An hour of slower practice may earn fewer XP than a shorter but faster and more consistent day. Additional accepted practice at the same performance continues increasing score and ordinary XP with diminishing returns, without a configured ceiling.

While the day is open or waiting for rest, show “Estimated settlement +2072 XP” or “Pending XP,” separately from the lifetime XP balance. Do not credit a changing live estimate repeatedly or withdraw lifetime XP when the current day's performance estimate decreases. Unavailable scores are not converted into made-up XP. The Preliminary label remains a coverage label, not an unasked hard 5-minute/1000-key XP eligibility gate.

**Open balance and abuse question:** a short high-performance day can still earn XP. For example, five measured minutes at 160 estimated WPM, consistency 100 and 4,001 accepted keys produce a 1475 score and 1475 XP. Existing shortcut, autorepeat, known generated-event and suspected-anomaly filters still apply, but this score/XP formula is not a semantic classifier and cannot identify all random typing or macros. It must not infer cheating merely from high speed or regular timing. Further short-day evidence weighting would need explicit review and validation rather than a hidden rule.

Personal-improvement XP stays separate. It uses compatible input contexts, completed-day calibration, frozen baselines, the existing multi-day average/evidence gates and persistent one-time milestone claims. A short burst or unfinished current day cannot trigger permanent improvement XP. Settling a day can make it eligible for verification; it does not guarantee a bonus. An already rewarded milestone is not awarded again after regression, restart or repeated evaluation.

## Illustrative XP-unit and level recalibration

Daily awards in the hundreds or thousands would make the existing **500-XP Level 20** threshold advance far too quickly if left unchanged. Following the request for harder leveling, the preview therefore proposes an explicit **150× unit conversion of both existing earned XP and all level costs/thresholds**, and the same conversion of improvement awards. This raises the numerical costs along with the larger XP rewards. It is a calibration proposal, not an implemented migration or a claim that the effective time to level is identical for every user.

Under that proposal:

- An old balance of 520 XP becomes 78,000 new-unit XP.
- Level 20's old 500-XP threshold becomes 75,000.
- Its next-level cost becomes 7,500 rather than 50.
- A previously defined 5-XP improvement step becomes 750 new-unit XP.

**Existing levels are preserved only if both balances and thresholds are converted consistently.** Scaling just one side does not preserve progress. The conversion itself is not a newly earned reward, a settlement animation or an opportunity to claim another improvement milestone.

| Target level | Proposed cumulative XP threshold |
|---|---:|
| 2 | 1,500 |
| 5 | 7,500 |
| 10 | 30,000 |
| 20 | 75,000 |
| 30 | 150,000 |
| 40 | 300,000 |
| 50 | 450,000 |
| 59 | 720,000 |
| 60 | 750,000 |

The proposed cost from Level 50 onward is 30,000 XP per level, with no fixed maximum. Raising displayed thresholds does not by itself prove a universally harder real-world progression curve: the main preview's old formula would earn `floor(2460/300) + floor(16001/2000) = 16` old XP, while 2,072 new XP is equivalent to approximately 13.81 old units under this conversion, about **13.7% less level progress for that particular day**. Repeating that same reference day would require approximately 15.8% more days to cover the same level cost. Representative longitudinal data is still required to calibrate the desired leveling difficulty. The preview chooses one explicit, consistent 150× conversion; it does not claim the same relative difficulty for every typing pattern.

If this direction is implemented, retain the old ledger, policy identifiers and original units. Record the conversion once under a stable new policy/version, retain claim lineage, and enforce idempotent migration. Old accumulating score records remain legacy records; this proposal does not retroactively invent daily performance scores, XP or animation receipts for uncovered history.

### Preview receipt sequence

The queue examples below are illustrative settlement receipts. Their rounded scores are examples of finalized daily values, not claimed real user measurements.

| State / receipt | Ordinary XP | Verified improvement XP | Lifetime XP after receipt | Level state |
|---|---:|---:|---:|---|
| Before the queue | — | — | 748,500 | Level 59; 28,500 / 30,000 |
| 2026-10-22 | 1,708 | 0 | 750,208 | Level 60; 208 / 30,000 |
| 2026-10-23 | 1,886 | 750 | 752,844 | Level 60; 2,844 / 30,000 |
| Open 2026-10-24 preview | 2,072 pending | Not assumed | 752,844 | No current-day XP credited yet |

The first receipt's formula inputs are 70 WPM, consistency 85, 2,100 seconds and 12,260 keys: score 1708 and ordinary XP 1708. The second uses 72 WPM, consistency 86, 2,400 seconds and 14,420 keys: score 1886 and ordinary XP 1886. Each count allows real chain-start inputs in addition to the interval-derived count.

The 750-XP bonus in the second receipt represents an independently verified milestone under the illustrative converted XP units. It is not awarded because that receipt's score happens to exceed the previous one. After this receipt, the next level's cumulative threshold is 780,000 XP, leaving 27,156 XP; today's pending 2,072 XP is not included in that lifetime balance.

## Reward-day lifecycle and settlement timing

Reward days keep fixed midnight boundaries in the persisted progression timezone. Continuing to use the computer at midnight opens the next day while the previous day is **sealed and awaiting rest**. New input belongs to the new day; it is not appended to yesterday to improve its frozen score.

```text
Open day
  → sealed, awaiting rest
  → committed, unseen
  → seen
```

At the midnight boundary:

- If the computer is being used, seal the completed day and defer its settlement. Continue recording the newly opened day normally.
- If the display is already off or the system is asleep, settle completed days at the first available execution opportunity. Do not wake the Mac solely to settle rewards.
- If the app was suspended or not running at midnight, catch up from persisted day boundaries on the next wake/launch. The design cannot promise code execution while the process or machine is asleep.

On the next display-off, sleep or orderly shutdown opportunity, commit **only completed, sealed days**. Do not close the current partial day early just because the user briefly sleeps or turns off the screen. If activity state is unknown, defer rather than pretending rest was observed. Shutdown handling must be best effort with durable catch-up after relaunch; it cannot assume every termination notification permits a successful write.

Settlement freezes the day's final eligible evidence, score, ordinary XP and any independently verified improvement XP into a transaction with a stable receipt identity. Measurement timing never grows while awaiting settlement. Restarts, missed midnight callbacks and repeated lifecycle notifications must not issue the same XP twice.

## Receipt queue, skip and level-up effects

Settlement and presentation are separate. A committed receipt has already credited XP before any menu or window animation is shown. The next opening of the menu or app presents **unseen receipts oldest first**. If several days have accumulated, show the first, then the next, until the queue is finished.

Skipping a receipt means “mark this receipt seen and advance.” It does not cancel earned XP, change its amount, or award it again. Closing the view midway leaves the receipt unseen until an explicit completion or skip acknowledgement is durably recorded, so a later opening can resume predictably.

Level changes are derived from that receipt's before/after XP. Present a finite grouped upgrade animation if a receipt crosses one or more levels. Higher unlocked presentation tiers may enrich the receipt or upgrade effects, while the earned score and XP remain unchanged. The same receipt must not generate another award merely because its animation is replayed.

Effects need a reduced-motion equivalent, an immediately available skip action, clear numerical before/after values, and no permanent background animation or timer. Animation state is lightweight presentation metadata keyed by receipt identity; it is not a second reward ledger.

## Decisions and verification before implementation

This file and its interactive preview are the reviewable proposal. Implementing it would still require versioned score/XP policies, a reviewed unit conversion, a durable receipt queue, lifecycle integration and migration tests. At minimum, verification must cover weighted daily mathematics, missing consistency, preliminary samples, score decreases before sealing, exact-once awards, active midnight rollover, display-off/sleep catch-up, shutdown failure/relaunch, ordered multi-day receipts, interrupted animations, skip acknowledgement, multi-level gains, reduced motion and preservation of legacy records.

No scoring or settlement code, database, installed app, release tag, changelog entry or public update source is changed by this proposal document.
