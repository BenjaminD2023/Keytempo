# Typing Score, XP and levels

This document describes Keytempo 0.4.1's accumulating rewards. It is a local personal-practice system, not an accuracy test, semantic-content detector, productivity measure or certified typing-skill assessment. Global WPM remains an accepted-operation estimate, including supported composition and editing; it is not an actual word or Chinese-character count.

## Policies and coverage

| Policy | Identifier | Meaning |
|---|---|---|
| Historical score | `practice-v1` | Original 0–100, four-component practice index |
| Accumulating points | `score-v2` | Daily logarithmic base points and settled block bonuses |
| Practice XP | `xp-v1` | Independent time, key and verified-improvement XP |
| Improvement evidence | `improvement-v1` | Frozen context baselines and completed-day verification |
| Level schedule | `levels-v1` | Exact whole-XP thresholds |

New reward coverage begins at first activation after the 0.4.1 migration. Existing daily/activity history and legacy score information are preserved. Old totals cannot reconstruct canonical 100-key blocks, new one-second samples or comparable improvement baselines; this version does not invent those records or backfill XP. New score charts sum awarded points and leave uncovered legacy dates distinct from zero earned points. Existing performance indicators and legacy exports remain separate.

The progression timezone is initialized from the system timezone once and persisted. Reward days end at midnight in that fixed timezone, including its daylight-saving rules. Changing the OS timezone does not create a new daily budget. The current reward-day key does not move backward with a clock correction. Neither calendar changes nor elapsed wall time creates measured typing time; accepted monotonic intervals supply time.

## One accepted stream

Progression consumes the existing classified **global probable-input** stream once. It does not sum daily, hourly, session and per-app rows as separate input. Accepted text-entry, composition and editing operations retain their existing meanings. The validation editor is excluded from ordinary progression.

Only the segmentation engine's accepted intervals contribute actual time. First keys can count without a measurable predecessor. Pauses, commands, focus/source changes, sleep, missing permissions and other real continuity boundaries end measurable runs. A five-minute activity session can contain several runs. No timeout tail, elapsed session span, live wall clock or relaunch gap earns time.

Existing shortcut, space, navigation, repeat, generated-input, context and excluded-app rules remain in place. Compatibility-mode estimates retain their existing disclosures. The rewards system does not inspect text or claim it can distinguish every macro from intentional input.

## Incremental base points

For a reward day's already accepted seconds `t` and keystrokes `K`:

```text
TimePoints(t)   = 60 × ln(1 + t / 3600)
VolumePoints(K) = 60 × ln(1 + K / 15000)
A(t,K)         = TimePoints(t) + VolumePoints(K)
```

For new accepted `(dt,dK)`, the actual award is:

```text
dTimePoints   = 60 × log1p(dt / (3600 + t_before))
dVolumePoints = 60 × log1p(dK / (15000 + K_before))
dBase         = dTimePoints + dVolumePoints
```

Then the day's counters advance. The complete daily formula is never added again on every update. These increments telescope to `A(t,K)` for a fixed day, apart from floating-point summation roundoff. `log1p` improves behavior for small deltas. Internal values keep full precision; the UI displays points to one decimal place.

Initially each measured minute and each 250 accepted keys contribute about one point independently. Marginal returns decrease during a day but never hit a hard cap. An isolated key earns volume progress without invented time. Pauses, sessions, app changes, checkpoints, relaunches and window changes do not reset the daily counters. Weekly and lifetime scores **sum actual daily awards**, rather than applying the logarithm to pooled week/lifetime activity. Nothing subtracts previously earned points.

## Canonical blocks and speed bonus

The accepted input order defines blocks of 100 keys. Ordinary interruptions end run fragments, but not the block. A partial block survives a checkpoint or relaunch. Its final bonuses settle at the reward-day boundary using its actual key count. Incompatible measurement/evidence policies settle the old partial block under its own policy; daily budgets and XP remainders continue.

Each persisted block contains counts, already credited time/volume points, aggregate speed evidence, fragment/quality moments, attribution aggregates, stable identity and policy. It contains no text or individual interval sequence.

For a block with `k > 0` keys and usable speed evidence `(Nw,tw)`:

```text
WPM      = 12 × Nw / tw
S        = min(1, log1p(WPM / 50) / log1p(160 / 50))
q(N,k)   = min(1,N/40) × min(1,N/k)
qW       = q(Nw,k)
speedBonus = 0.25 × blockBase × qW × S
```

Speed requires `Nw >= 20` and `tw >= 2 seconds`; otherwise its bonus is zero. `Nw` is an observed interval count/weight, not the block's key count. In a fresh 100-key run it is 99; later blocks and interruptions need their actual evidence rather than mechanically using `k−1`.

Intervals crossing calendar/hour boundaries preserve the segmentation engine's proportional interval weights and actual seconds. A split does not become several independent observations. Waiting for classification or settlement never adds time.

## Monkeytype-style consistency bonus

The final user-selected consistency method uses **completed one-second operation-rate samples**, replacing the earlier proposed raw-interval-CV bonus. The mapping follows Monkeytype's [Kogasa function](https://github.com/monkeytypegame/monkeytype/blob/128e4029048f72d3a8106941c4c4602f60c51b24/packages/util/src/numbers.ts); its [consistency calculation](https://github.com/monkeytypegame/monkeytype/blob/128e4029048f72d3a8106941c4c4602f60c51b24/frontend/src/ts/test/test-logic.ts) uses variation in per-second rates. Keytempo has different context filtering, continuity boundaries and evidence defaults, so its result is not a directly comparable Monkeytype test score.

A fragment is an uninterrupted run's intersection with a reward block. One-second half-open bins start at its first proven accepted-chain input. That first input counts once; each subsequent accepted interval endpoint contributes another operation. An input exactly on a bin boundary belongs to the next bin. The bin is emitted only after accepted interval coverage reaches its end. Zero-count full seconds inside a proven accepted chain are included. No timer emits future zero samples, and trailing incomplete seconds are discarded at interruption. A block/day fence cannot create a new accepted interval or bridge missing coverage.

For fragment `r`, use its complete rate bins (operation counts or `12 × counts`, which have the same CV):

```text
CVr = populationStandardDeviation(rate bins) / mean(rate bins)
```

A usable fragment needs **ten accepted intervals and two complete bins**, positive sampled mean, and valid moments. Its weight `nr` is the accepted interval count represented inside those complete bins, excluding the chain's first key and unsampled tail endpoints. Shorter fragments retain base points and usable speed evidence but do not become perfect-consistency evidence.

Combine within-fragment variation:

```text
CVcontext = sqrt(Σ(nr × CVr²) / Σnr)
C = 1 − tanh(CVcontext + CVcontext³/3 + CVcontext⁵/5)
consistencyPercent = 100 × C
```

This normalizes each fragment before combining it. Two internally steady runs at different mean speeds can both have `CVr = 0`; their different means alone do not lower bonus consistency. Aggregate moment variance tolerates negligible floating-point roundoff; invalid/nonfinite/corrupt moments cannot become perfect consistency.

Let `Nc = Σnr` and `tc` be the total complete-bin seconds of qualified fragments. The bonus requires **at least ten complete bins, `Nc >= 20` and `tc >= 2 seconds`**:

```text
qC = q(Nc,k)
consistencyBonus = 0.15 × blockBase × qC × C
```

`Nc`, `tc` and `qC` are independent from speed coverage. Missing evidence means unavailable, not poor consistency or a zero baseline.

The separate Activity consistency indicator uses population CV from pooled complete per-second rate moments and displays its sample/interval coverage. It requires ten complete bins and twenty represented accepted intervals. It is not the same aggregation as the run-normalized reward bonus, so the two can differ. Neither uses `100/(1+rawIntervalCV)` as the new reward method. Legacy `practice-v1` retains its original information under an explicit label.

## Settlement, attribution and numerical fixture

Base points are already earned before a block settles. Settlement adds **only** the speed and consistency bonuses, once:

```text
complete award = blockBase + speedBonus + consistencyBonus
```

Total bonuses cannot exceed 40% of base. Speed is bounded at its 160-WPM reference, while additional accepted activity continues earning base points and independent XP. Pending bonus estimates are not put into totals and later removed.

Hour/session point totals sum their actual attributed contributions. A block's finalized bonuses are allocated in proportion to the base-point contribution already attributed to each hour/session. Optional per-app collection is not required for scoring.

Reward attribution uses the persisted progression timezone. Activity history can use a different timezone. When those historical hour boundaries are incompatible, the hour's reward value is unavailable rather than inventing a redistribution; the reward-day label identifies the fixed timezone used by daily points and XP.

Fresh reward day, one uninterrupted 100-key block, 99 intervals of exactly 0.2 seconds:

| Quantity | Value |
|---|---:|
| Actual seconds / speed intervals | 19.8 / 99 |
| WPM | 60 |
| Base points | 0.727768376954296 |
| Complete one-second bins | 19 |
| Represented consistency intervals `Nc` | 94 |
| `qW` / `qC` | 0.99 / 0.94 |
| Normalized consistency `C` | 1 |
| Speed bonus | 0.09896214824017868 |
| Consistency bonus | 0.10261534115055572 |
| Final score | **0.9293458663450304** |

The final 0.8-second tail adds measured speed/base time but no complete consistency sample. Reusing all 99 intervals for `qC` would incorrectly overstate consistency coverage. The earlier raw-interval proposal's 0.934804129172188 fixture does not describe the implemented one-second-sample method.

## Delayed evidence and restart rules

The existing adaptive model can accept up to three earlier intervals after recognizing a slower stable rhythm. Reward reconciliation keeps four transient endpoint-to-block assignments, not an event log. Blocks with unresolved endpoint evidence remain unsettled. Live periodic checkpoints preserve continuity and do not change canonical blocks or clear partial live rate bins.

Candidate resolution is distinct from waiting time. When the measurement engine reaches its maximum continuity bound without another accepted event, it resolves/discards the pending candidate rather than leaving a block unresolved indefinitely. The coordinator forwards that completed idle-resolution boundary to rewards, closes the measured fragment and permits an otherwise complete block to settle without requiring another key. A still-incomplete 100-key block remains saved. Resolution never accepts a rejected interval, adds the waiting period to time, or creates future zero-rate samples.

On relaunch, saved block keys, base points, aggregate moments and settled quality survive; timing continuity and unfinished rate bins end. This prevents inventing a predecessor interval across a restart. A relaunch after midnight settles saved prior-day partial blocks once before verifying completed-day improvement.

Genuine late evidence after its block/day has already finalized cannot rewrite an old bonus. It adds an explicit `late-adjustment` base contribution under the still-open applicable daily budget, or the current reward day when the old day is closed. Its accepted time still advances lifetime XP counters. An integer XP threshold is attributed to the day it is earned, including a separate current-day XP award when late time belongs to an older open day. Finalized bonuses and claimed milestones do not get reissued.

## Independent XP

Lifetime counters begin at progression coverage start:

```text
timeXP = floor(lifetimeAcceptedSeconds / 300)
volumeXP = floor(lifetimeAcceptedKeys / 2000)
totalXP = timeXP + volumeXP + awardedImprovementXP
```

Only newly crossed thresholds are awarded. One delta can cross several. Seconds and key remainders persist across days, sessions, restarts and updates; three minutes today plus two tomorrow earns one time XP, and 1,500 keys today plus 500 tomorrow earns one volume XP. Daily/weekly XP sums integer awards attributed when earned, rather than summing floors of daily counters.

| Actual practice | XP, before improvement |
|---|---:|
| 30 minutes + 5,000 keys | 6 + 2 = 8 |
| 60 minutes + 10,000 keys | 12 + 5 = 17 |
| 60 minutes + 20,000 keys | 12 + 10 = 22 |
| 120 minutes + 20,000 keys | 24 + 10 = 34 |

The 17-XP example plus a newly verified +10% speed gain earns 27 XP. There is no score conversion, logarithmic XP curve, absolute-WPM bonus, current-consistency multiplier, daily XP cap, achievement XP or punitive streak. Faster input can earn more volume XP only by producing more accepted keys. All XP is integral; partial seconds/keys remain progress, not fractional XP.

## Verified personal improvement

Tracks are normalized by declared input language and input-method/source identifier, with separate measurement/evidence policy. They do not use app identities. Chinese IME operation estimates and English input do not become interchangeable improvement samples. Unknown source metadata cannot create a baseline. State is bounded to 64 context lineages.

Each metric calibrates independently:

- A qualifying completed context day contains at least **300 measured seconds**.
- A baseline requires **five qualifying completed days and 3,600 measured seconds** for that metric.
- Speed pools accepted interval weights and actual seconds: `12 × ΣNw / Σtw`, not averaged displayed WPM.
- Consistency pools qualified within-fragment normalized rate variation and uses the same Kogasa mapping. Its minute gates use **qualified consistency seconds**. Unknown consistency is absent, not zero; speed can be ready while consistency still calibrates.
- The metric's baseline freezes, with its calibration-through day. Those days never reappear as post-baseline verification evidence.

Verification uses the **latest seven qualifying completed days after that metric's baseline**. It needs three valid daily estimates, at least **1,800 metric-covered seconds**, a pooled estimate at the milestone, and at least three independent daily estimates at that same milestone. Unknown-consistency days can age older evidence out of the seven-day window without inventing a value. Short spikes or the unfinished current day cannot immediately mint permanent improvement XP.

Speed milestones are additive steps against the original baseline:

```text
threshold(m) = baselineWPM × (1 + 0.05 × m), m = 1,2,3,...
```

Consistency milestones increase the original 0–100 baseline by `5 × m` points, with no threshold above 100. Each newly verified speed or consistency milestone earns **5 XP**. A verified 40→44 or 100→110 WPM improvement crosses two steps and earns 10 XP; 70→80 consistency also earns 10 XP. Staying fast without improving earns ordinary practice XP, not improvement XP.

Persistent per-metric high-water marks identify already rewarded steps. Multi-step jumps produce one stable claim range and award every new step. Repeated evaluation, retry, relaunch, regression/recovery and history pruning do not award those steps again. Policy changes preserve the lineage and high-water marks; this version conservatively suspends that lineage's improvement awards instead of silently recalibrating it for fresh XP. There is no baseline-reset button that preserves rewards. Explicit deletion of all user data is the separate privacy reset.

These evidence defaults are transparent heuristics, not statistical proof of improved skill.

## Exact levels

Everyone starts at Level 1, at zero XP. Cost depends on the **current** level:

| Current level | Cost to next level |
|---|---:|
| 1–3 | 10 XP |
| 4 | 20 XP |
| 5–19 | 30 XP |
| 20–29 | 50 XP |
| 30–49 | 100 XP |
| 50 onward | 200 XP |

| Target level | Exact lifetime XP threshold |
|---|---:|
| 1 | 0 |
| 2 | 10 |
| 3 | 20 |
| 4 | 30 |
| 5 | 50 |
| 10 | 200 |
| 20 | 500 |
| 30 | 1,000 |
| 40 | 2,000 |
| 50 | 3,000 |
| 60 | 5,000 |

At 520 XP: Level 20, 20/50 XP toward Level 21, 30 XP remaining. Piecewise lookup is constant time and uses checked integer arithmetic; there is no fixed maximum level. If the next cumulative threshold exceeds the integer representation, it is unavailable rather than wrapped. Display abbreviations such as `1k` represent exact multiples of 1,000, not rounded requirements or rounded-up balances. One award can cross several levels; feedback groups the change and adds no extra XP.

## Persistence, retention and privacy

The SQLite schema adds a checkpoint, daily earned aggregates, award ledger, attributions, permanent claim identities and batch receipts. One transaction commits ordinary measurement/activity deltas with reward state and awards. Stable batch fingerprints make identical retries idempotent; a reused ID with different content is rejected. Checkpoint revisions must advance consecutively. Source XP and score-component deltas must reconcile with new ledger awards; attributed amounts reconcile with their award. Baselines, high-water marks and earned totals cannot move backward. Finite/nonnegative checks and checked integer operations reject corrupt state rather than awarding extra rewards.

The coordinator completes all measurement, activity and reward contributions from **one canonical accepted event before initiating a capacity-triggered flush**. Deferring that flush prevents a batch from checkpointing one side of an event while leaving its other deltas behind. An in-flight failure retains the identical immutable write payload for retry; subsequent unsaved contributions wait behind it instead of being folded into the retried identity.

Normal saves coalesce on the existing roughly 30-second schedule, off the keyboard callback. There is no per-key database row/fsync, extra keyboard monitor, lifetime-history poll or permanent high-frequency reward timer. Uncommitted in-memory input can be lost on crash/force quit; the scheduling interval is **not a hard maximum** when writes are delayed or failing. A successfully committed batch survives retries; the app does not claim to recover input never saved.

Detailed reward ledger/attribution history follows the five-year horizon, with a 200,000-award bound. Lifetime checkpoint totals, daily earned totals, claim identities and retry receipts are independent of that pruning. Clearing optional per-app detail does not affect progression. Delete all data removes every progression table and baseline.

The separate rewards CSV includes lifetime/daily/award/attribution record types, score components, XP sources, versions, coverage start, progression timezone and checkpoint revision. Additive record types must not be summed together as duplicate earnings. Existing input/activity CSV formats remain available separately.

Only necessary counts, durations, moments, language/input-source context identifiers and award/checkpoint metadata are stored. There is no text, clipboard, title, URL, physical-key sequence, interval sequence or per-second sequence. Metadata filters cannot prove usefulness or detect every macro. Valid code, repeated punctuation and repeated words are not rejected for their spelling.

## Implementation and verification

- [TypingRewards.swift](../Sources/TypingCore/TypingRewards.swift): base points, canonical blocks, measured evidence, settlement, attribution and checkpoint state.
- [RewardProgression.swift](../Sources/TypingCore/RewardProgression.swift): independent XP, exact levels, compatible-context calibration and milestone verification.
- [RateConsistency.swift](../Sources/TypingCore/RateConsistency.swift): complete one-second sampling and standalone consistency moments.
- [AggregateStore.swift](../Sources/TypingStore/AggregateStore.swift): transactional writes, migration, durable identities, retention, deletion and rewards export.
- [RewardViews.swift](../Sources/Keytempo/RewardViews.swift): native score, XP, levels, coverage and formula explanations.

Deterministic tests cover numerical fixtures, partitioning, evidence gates, exact levels, overflow/corruption and independent improvement. Store/integration checks use isolated synthetic data. Current executed validation and unverified runtime/performance limits are recorded in [VALIDATION.md](VALIDATION.md) and [PERFORMANCE.md](../PERFORMANCE.md); this policy document does not claim every native, power or update path has been verified.
