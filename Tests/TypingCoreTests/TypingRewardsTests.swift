import Foundation
import Testing
@testable import TypingCore

struct TypingRewardsTests {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let base = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
    private var context: ImprovementContext { .init(language: "en", inputMethod: "abc", measurementPolicy: "adaptive-v1", evidencePolicy: "probable") }
    private func input(_ time: Double, date: Date? = nil, control: UInt64 = 1, evidence: Evidence = .probable, source: InputSource = .global) -> ClassifiedInput {
        .init(time: time, date: date ?? base.addingTimeInterval(time), context: control, category: .textEntry, evidence: evidence, source: source, language: "en")
    }
    private func feed(_ times: [Double], measurement: inout StatisticsEngine, rewards: inout RewardEngine, control: UInt64 = 1, session: String? = nil) {
        for time in times {
            let event = input(time, control: control)
            let result = measurement.recordWithIntervals(event)
            rewards.record(input: event, result: result, context: context, sessionID: session, pendingIntervalCount: measurement.pendingProbableIntervals)
        }
    }
    private func baseline() -> RewardEngine { RewardEngine(coverageStart: base, progressionTimeZone: zone) }
    private func sum(_ awards: [RewardAward]) -> RewardComponents { awards.reduce(into: .init()) { $0.merge($1.components) } }

    @Test func exactNewMonkeytypeFixtureHasTruthfulCompletedBinCoverage() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<100).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        checkNil(rewards.error)
        checkTrue(rewards.state.blocks.isEmpty)
        checkEqual(rewards.state.days["2026-10-24"]!.keys, 100)
        checkEqual(rewards.state.days["2026-10-24"]!.seconds, 19.8, accuracy: 1e-9)
        checkEqual(rewards.state.lifetimeScore.base, 0.727768376954296, accuracy: 1e-12)
        // The former interval-only fixture was .934804129172188. The explicit
        // Monkeytype override covers94 interval endpoints in19 complete bins,
        // so the consistency evidence multiplier is .94 rather than .99.
        checkEqual(rewards.state.lifetimeScore.total, 0.929345866345031, accuracy: 1e-10)
        let write = rewards.checkpoint(at: base.addingTimeInterval(20))
        checkEqual(sum(write.awards).total, rewards.state.lifetimeScore.total, accuracy: 1e-12)
        checkEqual(write.awards.filter { $0.kind == "quality" }.count, 1)
        checkTrue(write.awards.count <= 3)
        checkTrue(write.awards.allSatisfy(\.isValid))
        let evidence = rewards.state.days["2026-10-24"]!.contexts[context.id]!.quality
        checkEqual(evidence.samples, 19); checkEqual(evidence.intervals, 94)
        checkEqual(evidence.consistency!, 1, accuracy: 1e-10)
    }

    @Test func baseDeltasTelescopeAndNeverDecreaseWithExtraActivity() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        var prior = 0.0
        for index in 0..<337 {
            feed([Double(index) * 0.2], measurement: &measurement, rewards: &rewards)
            checkTrue(rewards.state.lifetimeScore.total >= prior)
            prior = rewards.state.lifetimeScore.total
        }
        let day = rewards.state.days["2026-10-24"]!
        checkEqual(day.components.base, 60 * log1p(day.seconds / 3600) + 60 * log1p(Double(day.keys) / 15000), accuracy: 1e-10)
        checkTrue(day.components.speedBonus <= 0.25 * day.components.base + 1e-10)
        checkTrue(day.components.consistencyBonus <= 0.15 * day.components.base + 1e-10)
    }

    @Test func flushPartitionDoesNotChangeCanonicalBlocksOrQuality() {
        func run(flush: Bool) -> RewardState {
            var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
            for index in 0..<207 {
                feed([Double(index) * 0.2], measurement: &measurement, rewards: &rewards)
                if flush && index.isMultiple(of: 7) { _ = rewards.checkpoint(at: base.addingTimeInterval(Double(index) * 0.2)) }
            }
            return rewards.state
        }
        let whole = run(flush: false), batched = run(flush: true)
        checkEqual(whole.lifetimeScore.total, batched.lifetimeScore.total, accuracy: 1e-12)
        checkEqual(whole.blocks.map(\.keys), batched.blocks.map(\.keys))
        checkEqual(whole.blocks.first?.fragment?.rates, batched.blocks.first?.fragment?.rates)
        checkEqual(whole.xpProgress, batched.xpProgress)
    }

    @Test func isolatedKeysAndValidationDoNotInventTimeOrBonuses() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed([0], measurement: &measurement, rewards: &rewards)
        checkEqual(rewards.state.lifetimeScore.time, 0)
        checkEqual(rewards.state.lifetimeScore.volume, 60 * log1p(1.0 / 15000), accuracy: 1e-15)
        let before = rewards.state
        for (evidence, source) in [(Evidence.confirmed, InputSource.adapter), (.unknown, .global)] {
            let event = input(1, evidence: evidence, source: source)
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context)
        }
        checkEqual(rewards.state, before)
        rewards.interrupt(at: base.addingTimeInterval(100), reason: "pause")
        checkEqual(rewards.state.lifetimeScore.speedBonus, 0)
        checkEqual(rewards.state.lifetimeScore.consistencyBonus, 0)
    }

    @Test func partialBlockSurvivesRestartWithoutBridgingTheRun() throws {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<50).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        let snapshot = rewards.checkpoint(at: base.addingTimeInterval(10))
        let data = try JSONEncoder().encode(snapshot.state)
        let decoded = try JSONDecoder().decode(RewardState.self, from: data)
        var restored = try RewardEngine(restoring: decoded, now: base.addingTimeInterval(100))
        checkEqual(restored.state.pendingBlockKeys, 50)
        var fresh = StatisticsEngine(timeZone: zone)
        feed((0..<50).map { 100 + Double($0) * 0.2 }, measurement: &fresh, rewards: &restored)
        checkTrue(restored.state.blocks.isEmpty)
        checkEqual(restored.state.days["2026-10-24"]!.keys, 100)
        checkEqual(restored.state.days["2026-10-24"]!.seconds, 19.6, accuracy: 1e-8)
        checkTrue(restored.state.lifetimeScore.consistencyBonus > 0)
        checkTrue(restored.state.lifetimeScore.total >= snapshot.state.lifetimeScore.total)
        let encoded = String(decoding: data, as: UTF8.self)
        checkTrue(!encoded.contains("startTime") && !encoded.contains("endTime") && !encoded.contains("endpoints") && !encoded.contains("samplers"))
    }

    @Test func withinRunRateNormalizationDoesNotPenalizeTwoSteadySpeeds() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<50).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards, session: "chat")
        rewards.interrupt(at: base.addingTimeInterval(10)); measurement.interrupt()
        feed((0..<50).map { 100 + Double($0) * 0.5 }, measurement: &measurement, rewards: &rewards, control: 2, session: "editor")
        checkTrue(rewards.state.blocks.isEmpty)
        let q = rewards.state.days["2026-10-24"]!.contexts[context.id]!.quality
        checkEqual(q.consistency!, 1, accuracy: 1e-10)
        checkTrue(rewards.state.lifetimeScore.consistencyBonus > 0)
        let settled = rewards.unpersistedAwards.first { $0.kind == "quality" }!
        checkEqual(Set(settled.attributions.compactMap(\.sessionID)), Set(["chat", "editor"]))
        checkEqual(settled.attributions.reduce(0) { $0 + $1.components.total }, settled.components.total, accuracy: 1e-12)
    }

    @Test func shortRunFragmentsGiveSpeedButNoPerfectConsistency() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        for burst in 0..<20 {
            if burst > 0 { measurement.interrupt(); rewards.interrupt(at: base.addingTimeInterval(Double(burst) * 10)) }
            feed((0..<5).map { Double(burst) * 10 + Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        }
        checkTrue(rewards.state.lifetimeScore.speedBonus > 0)
        checkEqual(rewards.state.lifetimeScore.consistencyBonus, 0)
        checkEqual(rewards.state.days["2026-10-24"]!.keys, 100)
    }

    @Test func delayedEvidenceAtKey100IsResolvedBeforeSettlement() {
        var measurement = StatisticsEngine(config: .init(minimumGap: 0.1, coldStartGap: 0.1), timeZone: zone)
        var rewards = baseline()
        // 97 isolated keys keep a partial canonical block without timing.
        for index in 0..<97 { measurement.interrupt(); rewards.interrupt(at: base.addingTimeInterval(Double(index) * 10)); feed([Double(index) * 10], measurement: &measurement, rewards: &rewards) }
        measurement.interrupt(); rewards.interrupt(at: base.addingTimeInterval(970))
        feed([970, 970.4, 970.8], measurement: &measurement, rewards: &rewards)
        checkEqual(rewards.state.blocks.first!.keys, 100)
        checkEqual(measurement.pendingProbableIntervals, 2)
        checkEqual(rewards.unpersistedAwards.filter { $0.kind == "quality" }.count, 0)
        feed([971.2], measurement: &measurement, rewards: &rewards)
        checkEqual(rewards.state.pendingBlockKeys, 1)
        checkEqual(rewards.state.days["2026-10-24"]!.seconds, 1.2, accuracy: 1e-6)
        checkNil(rewards.error)
    }

    @Test func dayRolloverAndBackwardClockDoNotResetBudgetsOrXP() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
        var rewards = RewardEngine(coverageStart: midnight.addingTimeInterval(-0.1), progressionTimeZone: zone)
        var measurement = StatisticsEngine(timeZone: zone)
        for (time, date) in [(0.0, midnight.addingTimeInterval(-0.1)), (0.2, midnight.addingTimeInterval(0.1))] {
            let event = input(time, date: date)
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context)
        }
        checkEqual(rewards.state.currentDay, "2026-10-25")
        checkEqual(rewards.state.days["2026-10-24"]!.seconds, 0.1, accuracy: 1e-6)
        checkEqual(rewards.state.days["2026-10-25"]!.seconds, 0.1, accuracy: 1e-6)
        let earned = rewards.state.lifetimeScore.total
        rewards.interrupt(at: midnight.addingTimeInterval(1)); measurement.interrupt()
        let backwards = input(2, date: midnight.addingTimeInterval(-3600))
        rewards.record(input: backwards, result: measurement.recordWithIntervals(backwards), context: context)
        checkEqual(rewards.state.days["2026-10-25"]!.keys, 2)
        checkTrue(rewards.state.lifetimeScore.total > earned)
        checkEqual(rewards.state.progressionTimezone, "GMT")
        let saved = rewards.checkpoint(at: midnight.addingTimeInterval(2))
        let restored = try RewardEngine(restoring: saved.state, now: midnight.addingTimeInterval(86400))
        checkEqual(restored.state.xpProgress.eligibleKeys, 3)
        checkEqual(restored.state.progressionTimezone, saved.state.progressionTimezone)
    }

    @Test func malformedAndOverflowInputsAreAtomicNoOps() throws {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed([0], measurement: &measurement, rewards: &rewards)
        let before = rewards.state
        let event = input(0.2)
        rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context, pendingIntervalCount: 9)
        checkEqual(rewards.error, .invalidInput)
        checkEqual(rewards.state, before)
        var corrupt = before; corrupt.lifetimeScore.time = .nan
        #expect(throws: RewardError.self) { _ = try RewardEngine(restoring: corrupt, now: base) }
        var xp = RewardXP(time: Int.max); xp.merge(.init(time: 1))
        checkTrue(!xp.isValid)
        var q = RewardQuality(); q.samples = Int.max
        var more = RewardQuality(); more.samples = 1
        q.merge(more); checkTrue(!q.isValid)
    }
    @Test func midnightFractionKeepsOriginalTimingAndOnlyWholeOldDayRateBins() {
        let beginning = ISO8601DateFormatter().date(from: "2026-10-24T23:59:50Z")!
        var rewards = RewardEngine(coverageStart: beginning, progressionTimeZone: zone)
        var measurement = StatisticsEngine(timeZone: zone)
        for index in 0...60 {
            let t = Double(index) * 0.2
            let event = input(t, date: beginning.addingTimeInterval(t))
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context)
        }
        checkNil(rewards.error)
        let old = rewards.state.days["2026-10-24"]!, current = rewards.state.days["2026-10-25"]!
        checkEqual(old.keys + current.keys, 61)
        checkEqual(old.seconds + current.seconds, 12, accuracy: 1e-8)
        checkEqual(old.contexts[context.id]!.quality.samples, 10)
        checkEqual(old.contexts[context.id]!.quality.intervals, 49)
        checkEqual(old.contexts[context.id]!.quality.seconds, 10)
        checkTrue(old.completed)
        checkEqual(rewards.state.xpProgress.eligibleSeconds, 12, accuracy: 1e-8)
    }

    @Test func lateEvidenceAfterRestoreEarnsIdentifiedBaseAdjustmentWithoutRevaluation() throws {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<100).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        let saved = rewards.checkpoint(at: base.addingTimeInterval(20))
        var restored = try RewardEngine(restoring: saved.state, now: base.addingTimeInterval(20))
        let previousBonus = restored.state.lifetimeScore.speedBonus + restored.state.lifetimeScore.consistencyBonus
        let event = input(20)
        let delta = DailyDelta(day: "2026-10-24", timezoneID: "GMT", ruleID: "adaptive-v1", evidence: .probable, keys: 1)
        let result = StatisticsRecordResult(deltas: [delta], acceptedIntervals: [.init(startTime: 19.4, endTime: 19.6, evidence: .probable, language: "en", ruleID: "adaptive-v1")])
        restored.record(input: event, result: result, context: context)
        checkNil(restored.error)
        checkTrue(restored.unpersistedAwards.contains { $0.kind == "late-adjustment" && $0.components.time > 0 })
        checkEqual(restored.state.lifetimeScore.speedBonus + restored.state.lifetimeScore.consistencyBonus, previousBonus)
        checkEqual(restored.state.xpProgress.eligibleSeconds, 20, accuracy: 1e-8)
    }

    @Test func incompatiblePolicySettlesPartialWithoutRefreshingDailyBudget() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<50).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        let newContext = ImprovementContext(language: "en", inputMethod: "abc", measurementPolicy: "adaptive-other", evidencePolicy: "probable")
        measurement.updateConfig(.init(ruleID: "adaptive-other"))
        let event = input(100)
        rewards.record(input: event, result: measurement.recordWithIntervals(event), context: newContext)
        checkEqual(rewards.state.pendingBlockKeys, 1)
        let budget = rewards.state.days["2026-10-24"]!
        checkEqual(budget.keys, 51)
        checkEqual(budget.components.volume, 60 * log1p(51.0 / 15000), accuracy: 1e-12)
        checkEqual(rewards.state.xpProgress.eligibleKeys, 51)
    }

    @Test func unknownImprovementContextStillEarnsOrdinaryPractice() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        let unknown = ImprovementContext(language: "und", inputMethod: "", measurementPolicy: "adaptive-v1", evidencePolicy: "probable")
        for index in 0..<100 {
            let event = input(Double(index) * 0.2)
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: unknown)
        }
        checkNil(rewards.error)
        checkTrue(rewards.state.lifetimeScore.total > 0)
        checkTrue(rewards.state.days["2026-10-24"]!.contexts.isEmpty)
        checkTrue(rewards.state.improvement.tracks.isEmpty)
    }

    @Test func repeatedDSTHourDoesNotRefreshProgressionBudgetOrInventTime() {
        let localZone = TimeZone(identifier: "America/New_York")!
        let beginning = ISO8601DateFormatter().date(from: "2026-11-01T05:59:59Z")!.addingTimeInterval(0.9)
        var rewards = RewardEngine(coverageStart: beginning, progressionTimeZone: localZone)
        var measurement = StatisticsEngine(timeZone: localZone)
        for time in [0.0, 0.2] {
            let event = input(time, date: beginning.addingTimeInterval(time))
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context)
        }
        checkNil(rewards.error)
        checkEqual(rewards.state.currentDay, "2026-11-01")
        checkEqual(rewards.state.days.count, 1)
        checkEqual(rewards.state.days["2026-11-01"]!.seconds, 0.2, accuracy: 1e-8)
        checkEqual(rewards.state.progressionTimezone, "America/New_York")
    }

    @Test func candidateOnlyFullBlockResolvesAtBoundedIdleWithoutTimeTail() {
        var measurement = StatisticsEngine(config: .init(minimumGap: 0.1, coldStartGap: 0.1), timeZone: zone)
        var rewards = baseline()
        for index in 0..<97 {
            measurement.interrupt(); rewards.interrupt(at: base.addingTimeInterval(Double(index) * 10))
            feed([Double(index) * 10], measurement: &measurement, rewards: &rewards)
        }
        measurement.interrupt(); rewards.interrupt(at: base.addingTimeInterval(970))
        feed([970, 970.4, 970.8], measurement: &measurement, rewards: &rewards)
        checkEqual(measurement.pendingProbableIntervals, 2)
        checkTrue(measurement.completionPending)
        checkEqual(rewards.state.pendingBlockKeys, 100)
        let before = rewards.state.lifetimeScore
        let wasResolving = measurement.completionPending
        measurement.advance(to: 974)
        if wasResolving && !measurement.completionPending {
            rewards.interrupt(at: base.addingTimeInterval(974), reason: "idle-resolution")
        }
        checkEqual(measurement.pendingProbableIntervals, 0)
        checkTrue(!measurement.completionPending)
        checkEqual(rewards.state.pendingBlockKeys, 0)
        checkEqual(rewards.state.days["2026-10-24"]!.seconds, 0)
        checkEqual(rewards.state.lifetimeScore, before)
        checkEqual(rewards.state.xpProgress.eligibleSeconds, 0)
        checkNil(rewards.error)
    }

    @Test func equalAndBackwardEventClocksPreserveAcceptedKeysButBreakTiming() {
        for times in [[0.0, 0.0, 0.2], [1.0, 0.5, 0.7]] {
            var measurement = StatisticsEngine(timeZone: zone), rewards = baseline()
            for time in times {
                let event = input(time)
                let result = measurement.recordWithIntervals(event)
                checkEqual(result.deltas.filter { $0.evidence == .probable }.reduce(0) { $0 + $1.keys }, 1)
                rewards.record(input: event, result: result, context: context)
            }
            checkNil(rewards.error)
            let day = rewards.state.days["2026-10-24"]!
            checkEqual(day.keys, 3)
            checkEqual(rewards.state.xpProgress.eligibleKeys, 3)
            checkEqual(day.seconds, 0.2, accuracy: 1e-10)
            checkEqual(day.components.volume, 60 * log1p(3.0 / 15000), accuracy: 1e-15)
        }
    }

    @Test func latePriorDayTimeUsesOriginalBudgetButAwardsXPOnEarningDay() throws {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<1500).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        let nextDay = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
        let saved = rewards.checkpoint(at: nextDay)
        let prior = saved.state.days["2026-10-24"]!
        checkTrue(prior.completed)
        checkEqual(saved.state.xpProgress.timeXP, 0)
        var restored = try RewardEngine(restoring: saved.state, now: nextDay)
        let event = input(100, date: nextDay.addingTimeInterval(0.1))
        let delta = DailyDelta(day: "2026-10-25", timezoneID: "GMT", ruleID: "adaptive-v1", evidence: .probable, keys: 1)
        let result = StatisticsRecordResult(deltas: [delta], acceptedIntervals: [.init(startTime: 99.6, endTime: 100, evidence: .probable, language: "en", ruleID: "adaptive-v1")])
        restored.record(input: event, result: result, context: context)
        checkNil(restored.error)
        let old = restored.state.days["2026-10-24"]!, current = restored.state.days["2026-10-25"]!
        checkTrue(old.completed)
        checkEqual(old.seconds, 300.1, accuracy: 1e-6)
        checkEqual(old.components.time, 60 * log1p(old.seconds / 3600), accuracy: 1e-10)
        checkEqual(old.contexts, prior.contexts)
        checkEqual(old.components.speedBonus, prior.components.speedBonus)
        checkEqual(old.components.consistencyBonus, prior.components.consistencyBonus)
        checkEqual(old.xp.time, 0); checkEqual(current.xp.time, 1)
        checkEqual(restored.state.xpProgress.timeXP, 1)
        checkTrue(restored.unpersistedAwards.contains { $0.day == "2026-10-24" && $0.kind == "late-adjustment" })
        checkTrue(restored.unpersistedAwards.contains { $0.day == "2026-10-25" && $0.kind == "practice-xp" && $0.xpSources.time == 1 })
    }

    @Test func explicitPolicyBoundaryImmediatelySettlesPartialExactlyOnce() {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        feed((0..<50).map { Double($0) * 0.2 }, measurement: &measurement, rewards: &rewards)
        let old = rewards.state.days["2026-10-24"]!, xp = rewards.state.xpProgress
        rewards.interrupt(at: base.addingTimeInterval(10), reason: "settingsChanged")
        checkNil(rewards.error)
        checkEqual(rewards.state.pendingBlockKeys, 0)
        checkEqual(rewards.state.days["2026-10-24"]!.keys, old.keys)
        checkEqual(rewards.state.days["2026-10-24"]!.seconds, old.seconds)
        checkEqual(rewards.state.xpProgress, xp)
        checkTrue(rewards.state.lifetimeScore.speedBonus > 0)
        let settled = rewards.state.lifetimeScore
        rewards.interrupt(at: base.addingTimeInterval(11), reason: "policy-boundary")
        checkEqual(rewards.state.lifetimeScore, settled)
        checkEqual(rewards.unpersistedAwards.filter { $0.kind == "quality" }.count, 1)
    }

    @Test func incrementalValidationAgreesWithFullValidationAcrossRetainedHistory() throws {
        var rewards = baseline(), measurement = StatisticsEngine(timeZone: zone)
        var time = 0.0, random: UInt64 = 0x041_2026
        for dayOffset in 0..<33 {
            let beginning = base.addingTimeInterval(Double(dayOffset) * 86_400)
            rewards.advance(to: beginning)
            for method in 0..<5 {
                let runContext = ImprovementContext(language: method.isMultiple(of: 2) ? "en" : "zh",
                    inputMethod: "fixture-\(method)", measurementPolicy: "adaptive-v1", evidencePolicy: "probable")
                measurement.interrupt(); rewards.interrupt(at: beginning)
                for key in 0..<23 {
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    time += 0.1 + Double((random >> 32) % 5) * 0.1
                    let date = beginning.addingTimeInterval(Double(method) * 60 + Double(key) * 0.4)
                    let event = input(time, date: date, control: UInt64(method + 1))
                    rewards.record(input: event, result: measurement.recordWithIntervals(event), context: runContext,
                                   pendingIntervalCount: measurement.pendingProbableIntervals)
                    // The production path checks only changed budgets and the
                    // bounded live blocks. This independent full scan must
                    // accept every state, including prior-day calibration.
                    checkNil(rewards.error)
                    checkTrue(rewards.state.isValid)
                    checkTrue(rewards.state.days.count <= 30)
                }
                time += 10
            }
            _ = rewards.checkpoint(at: beginning.addingTimeInterval(600))
            checkTrue(rewards.state.isValid)
        }
        checkEqual(rewards.state.days.count, 30)
        checkEqual(rewards.state.improvement.tracks.count, 5)
        let saved = rewards.checkpoint(at: base.addingTimeInterval(32 * 86_400 + 600))
        let restored = try RewardEngine(restoring: saved.state, now: base.addingTimeInterval(32 * 86_400 + 600))
        checkTrue(restored.state.isValid)
        checkEqual(restored.state.xpProgress.eligibleKeys, 33 * 5 * 23)
        checkEqual(restored.state.lifetimeScore, saved.state.lifetimeScore)

        let historicDay = saved.state.days.keys.min()!
        var corruptBudget = saved.state
        corruptBudget.days[historicDay]!.keys += 1
        checkTrue(!corruptBudget.isValid)
        #expect(throws: RewardError.self) { _ = try RewardEngine(restoring: corruptBudget, now: base) }
        var corruptContext = saved.state
        let historicContext = corruptContext.days[historicDay]!.contexts.keys.first!
        corruptContext.days[historicDay]!.contexts[historicContext]!.seconds = .infinity
        checkTrue(!corruptContext.isValid)
        #expect(throws: RewardError.self) { _ = try RewardEngine(restoring: corruptContext, now: base) }
    }

    @Test func thirtyDayRetentionDoesNotRejectUnresolvedMidnightCandidate() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
        var historic = baseline().state
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        for offset in 1...29 {
            let day = formatter.string(from: base.addingTimeInterval(-Double(offset) * 86_400))
            var budget = RewardDayBudget(day: day); budget.completed = true
            historic.days[day] = budget
        }
        let oldest = historic.days.keys.min()!
        checkTrue(historic.isValid)
        var rewards = try RewardEngine(restoring: historic, now: base)
        var measurement = StatisticsEngine(config: .init(minimumGap: 0.1, coldStartGap: 0.1), timeZone: zone)
        for time in [0.0, 0.4] {
            let event = input(time, date: midnight.addingTimeInterval(-0.2 + time))
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context,
                           pendingIntervalCount: measurement.pendingProbableIntervals)
        }
        checkEqual(measurement.pendingProbableIntervals, 1)
        checkNil(rewards.error)
        checkEqual(rewards.state.days.count, 30)
        checkNil(rewards.state.days[oldest])
        checkTrue(!rewards.state.days["2026-10-24"]!.completed)
        checkEqual(rewards.state.xpProgress.eligibleSeconds, 0)
        for time in [0.8, 1.2] {
            let event = input(time, date: midnight.addingTimeInterval(-0.2 + time))
            rewards.record(input: event, result: measurement.recordWithIntervals(event), context: context,
                           pendingIntervalCount: measurement.pendingProbableIntervals)
        }
        checkNil(rewards.error)
        checkTrue(rewards.state.isValid)
        checkEqual(measurement.pendingProbableIntervals, 0)
        checkTrue(rewards.state.days["2026-10-24"]!.completed)
        checkEqual(rewards.state.xpProgress.eligibleSeconds, 1.2, accuracy: 1e-8)
        checkEqual(rewards.state.days["2026-10-24"]!.keys + rewards.state.days["2026-10-25"]!.keys, 4)
    }

}
