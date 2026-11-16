import Foundation
import Testing
@testable import TypingCore

struct DailyRewardUpgradeTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let oldRule = "adaptive-v4-no-space-ime-quality-on-max3.0"
    private let newRule = "adaptive-v5-no-space-ime-quality-on-max3.0"
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func record(_ time: Double, base: Date, stats: inout StatisticsEngine,
                        rewards: inout DailyRewardEngine) {
        let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                    category: .textEntry, evidence: .probable, source: .global, language: "en")
        rewards.record(input: input, result: stats.recordWithIntervals(input), rule: stats.config.ruleID)
    }

    @Test func upgradeKeepsTheMeasuredDayOnLegacySamplingAcrossRelaunchThenUsesV5Tomorrow() throws {
        let base = date("2026-10-24T12:00:00Z")
        var seed = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var legacyStats = StatisticsEngine(config: .init(ruleID: oldRule), timeZone: utc)
        for index in 0..<100 { record(Double(index) * 0.4, base: base, stats: &legacyStats, rewards: &seed) }
        checkTrue(seed.state.current!.score != nil)
        var upgraded = try DailyRewardEngine(restoring: seed.state, now: base.addingTimeInterval(60))
        var control = try DailyRewardEngine(restoring: seed.state, now: base.addingTimeInterval(60))
        var newStats = StatisticsEngine(config: .init(ruleID: newRule), timeZone: utc)
        legacyStats = StatisticsEngine(config: .init(ruleID: oldRule), timeZone: utc)
        for index in 0..<100 {
            let time = 60 + Double(index) * 0.4
            record(time, base: base, stats: &newStats, rewards: &upgraded)
            record(time, base: base, stats: &legacyStats, rewards: &control)
        }
        checkNil(upgraded.error)
        checkEqual(upgraded.state.current, control.state.current)
        checkEqual(upgraded.state.current!.rule, oldRule)
        checkTrue(!upgraded.state.current!.mixedRules)
        checkTrue(upgraded.state.current!.score != nil)

        upgraded = try DailyRewardEngine(restoring: upgraded.state, now: base.addingTimeInterval(120))
        control = try DailyRewardEngine(restoring: control.state, now: base.addingTimeInterval(120))
        for index in 0..<100 {
            let time = 120 + Double(index) * 0.4
            record(time, base: base, stats: &newStats, rewards: &upgraded)
            record(time, base: base, stats: &legacyStats, rewards: &control)
        }
        checkEqual(upgraded.state.current, control.state.current)
        checkTrue(upgraded.state.current!.score != nil)
        let yesterday = upgraded.state.current!.totals
        for index in 0...100 {
            record(86400 + Double(index) * 0.4, base: base, stats: &newStats, rewards: &upgraded)
        }
        checkNil(upgraded.error)
        checkEqual(upgraded.state.currentDay, "2026-10-25")
        checkEqual(upgraded.state.current!.rule, newRule)
        checkTrue(!upgraded.state.current!.mixedRules)
        checkEqual(upgraded.state.current!.totals.consistency!, 100, accuracy: 1e-6)
        checkEqual(upgraded.state.days["2026-10-24"]!.totals, yesterday)
    }

    @Test func lateMidnightBackfillRetainsOldDayTimingWithoutMixingNewRateMoments() throws {
        let coverage = date("2026-10-24T12:00:00Z")
        let base = date("2026-10-24T23:59:57Z").addingTimeInterval(0.8)
        let legacyTotals = RhythmTotals(keys: 100, intervals: 99, seconds: 39.6,
            squaredIntervalSeconds: 15.84,
            rateConsistency: .init(count: 10, intervals: 20, sum: 600, squaredSum: 36000))
        var state = DailyRewardState(coverageStart: coverage, progressionTimezone: utc.identifier, currentDay: "2026-10-24")
        state.days["2026-10-24"] = .init(day: "2026-10-24", totals: legacyTotals, rule: oldRule)
        var rewards = try DailyRewardEngine(restoring: state, now: base)
        var stats = StatisticsEngine(config: .init(minimumGap: 0.1, coldStartGap: 0.1, ruleID: newRule), timeZone: utc)
        for time in [0.0, 0.8, 1.6, 2.4] { record(time, base: base, stats: &stats, rewards: &rewards) }
        checkNil(rewards.error)
        let yesterday = rewards.state.days["2026-10-24"]!
        checkEqual(yesterday.rule, oldRule); checkTrue(!yesterday.mixedRules)
        checkTrue(yesterday.score != nil)
        checkEqual(yesterday.totals.keys, legacyTotals.keys + 3)
        checkEqual(yesterday.totals.seconds, legacyTotals.seconds + 2.2, accuracy: 1e-6)
        checkEqual(yesterday.totals.rateConsistency, legacyTotals.rateConsistency)
        checkEqual(rewards.state.current!.rule, newRule)
        checkEqual(rewards.state.current!.totals.keys, 1)
        checkEqual(rewards.state.current!.totals.seconds, 0.2, accuracy: 1e-6)
    }

    @Test func changingARealCountingSettingStillMarksTheRewardDayIncomparable() {
        let base = date("2026-10-24T12:00:00Z")
        var rewards = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: .init(ruleID: oldRule), timeZone: utc)
        for index in 0..<100 { record(Double(index) * 0.4, base: base, stats: &stats, rewards: &rewards) }
        checkTrue(rewards.state.current!.score != nil)
        stats.updateConfig(.init(ruleID: "adaptive-v5-no-space-ime-quality-off-max3.0"))
        record(60, base: base, stats: &stats, rewards: &rewards)
        checkNil(rewards.error)
        checkTrue(rewards.state.current!.mixedRules)
        checkNil(rewards.state.current!.score)
    }
}
