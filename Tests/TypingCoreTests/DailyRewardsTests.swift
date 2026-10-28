import Foundation
import Testing
@testable import TypingCore

struct DailyRewardsTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let rule = "daily-rewards-test"
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func input(_ time: Double, base: Date, category: InputCategory = .textEntry,
                       evidence: Evidence = .probable, source: InputSource = .global) -> ClassifiedInput {
        .init(time: time, date: base.addingTimeInterval(time), context: 1, category: category,
              evidence: evidence, source: source, language: "en")
    }
    private func measured(_ count: Int = 100, base: Date, legacyXP: Int = 0) -> DailyRewardEngine {
        var daily = DailyRewardEngine(coverageStart: base, legacyTotalXP: legacyXP, progressionTimeZone: utc)
        var engine = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for index in 0..<count {
            let event = input(Double(index) / 5, base: base)
            daily.record(input: event, result: engine.recordWithIntervals(event), rule: rule)
        }
        return daily
    }

    @Test func approvedUncappedFormulaExamplesAndNoFixedShares() {
        checkEqual(DailyRewardScore.value(wpm: 70, consistency: 85, typingSeconds: 2100, keys: 12260), 1708)
        checkEqual(DailyRewardScore.value(wpm: 72, consistency: 86, typingSeconds: 2400, keys: 14420), 1886)
        checkEqual(DailyRewardScore.value(wpm: 78, consistency: 88, typingSeconds: 2460, keys: 16001), 2072)
        let short = DailyRewardScore.value(wpm: 50, consistency: 80, typingSeconds: 1800, keys: 7500)!
        let long = DailyRewardScore.value(wpm: 50, consistency: 80, typingSeconds: 7200, keys: 30000)!
        checkEqual(short, 1169); checkEqual(long, 2339)
        checkTrue(long > 1000)
        checkTrue(DailyRewardScore.value(wpm: 160, consistency: 100, typingSeconds: 18000, keys: 240060)! > 10000)
        checkTrue(DailyRewardScore.value(wpm: 240, consistency: 100, typingSeconds: 18000, keys: 240060)! >
                  DailyRewardScore.value(wpm: 160, consistency: 100, typingSeconds: 18000, keys: 240060)!)
    }

    @Test func insufficientAndInvalidEvidenceNeverBecomesAZeroOrPerfectScore() {
        checkNil(DailyRewardScore.value(totals: .init(keys: 1)))
        checkNil(DailyRewardScore.value(totals: .init(keys: 100, intervals: 99, seconds: 19.8, squaredIntervalSeconds: 3.96)))
        let rates = RateConsistencyTotals(count: 10, intervals: 20, sum: 50, squaredSum: 250)
        checkNil(DailyRewardScore.value(totals: .init(keys: 20, intervals: 19, seconds: 19, squaredIntervalSeconds: 19, rateConsistency: rates)))
        checkNil(DailyRewardScore.value(wpm: .infinity, consistency: 80, typingSeconds: 60, keys: 500))
        checkNil(DailyRewardScore.value(wpm: 50, consistency: 101, typingSeconds: 60, keys: 500))
        checkNil(DailyRewardScore.value(wpm: 50, consistency: .nan, typingSeconds: 60, keys: 500))
        checkNil(DailyRewardScore.value(wpm: 50, consistency: 80, typingSeconds: -1, keys: 500))
        checkNil(DailyRewardScore.value(wpm: 50, consistency: 80, typingSeconds: 60, keys: -1))
        checkNil(DailyRewardScore.value(wpm: .greatestFiniteMagnitude, consistency: 100, typingSeconds: .greatestFiniteMagnitude, keys: Int.max))
        checkEqual(DailyRewardEngine(coverageStart: Date(timeIntervalSince1970: .nan)).error, .invalidState)
    }

    @Test func existingLevelsSurviveTheExplicitUnitConversionWithExactNewProgress() {
        for oldXP in [0, 9, 10, 49, 50, 499, 500, 520, 999, 3000, 4988, 5000] {
            let old = LevelProgress(totalXP: oldXP)!, current = DailyLevelProgress(totalXP: oldXP * 150)!
            checkEqual(current.level, old.level)
            checkEqual(current.progressXP, old.progressXP * 150)
            checkEqual(current.requiredXP, old.requiredXP * 150)
        }
        let new = DailyLevelProgress(totalXP: 752844)!
        checkEqual(new.level, 60); checkEqual(new.progressXP, 2844)
        checkEqual(new.requiredXP, 30000); checkEqual(new.remainingXP, 27156)
        checkEqual(new.nextThreshold, 780000)
        checkEqual(DailyLevelProgress(totalXP: 750001)!.progressXP, 1)
        checkNil(DailyLevelProgress(totalXP: -1))
        checkNil(DailyLevelSchedule.threshold(for: Int.max))
        checkTrue(DailyLevelProgress(totalXP: Int.max) != nil)
    }

    @Test func migrationDoesNotFabricateHistoricalDailyScoresOrClaimOldImprovementAgain() {
        let start = date("2026-10-24T12:00:00Z")
        var daily = DailyRewardEngine(coverageStart: start, legacyTotalXP: 520, legacyImprovementXP: 10, progressionTimeZone: utc)
        checkTrue(daily.state.isValid); checkEqual(daily.state.totalXP, 78000)
        checkEqual(daily.state.days.count, 1); checkNil(daily.state.current!.score)
        checkEqual(daily.state.current!.totals.keys, 0)
        daily.observeLegacyImprovement(total: 10)
        checkEqual(daily.state.pendingImprovementXP, 0)
        daily.observeLegacyImprovement(total: 15)
        checkEqual(daily.state.pendingImprovementXP, 750)
        checkEqual(daily.state.totalXP, 78000)
        daily.observeLegacyImprovement(total: 15)
        checkEqual(daily.state.pendingImprovementXP, 750)
        checkTrue(DailyRewardEngine(coverageStart: start, legacyTotalXP: Int.max, progressionTimeZone: utc).error == .capacity)
    }

    @Test func canonicalMetadataCountsEveryAcceptedKeyAndUsesTheSameStandaloneConsistency() {
        let base = date("2026-10-24T12:00:00Z")
        let daily = measured(base: base)
        checkNil(daily.error)
        let totals = daily.state.current!.totals
        checkEqual(totals.keys, 100); checkEqual(totals.intervals, 99)
        checkEqual(totals.seconds, 19.8, accuracy: 1e-6)
        checkEqual(totals.wpm!, 60, accuracy: 1e-6)
        checkEqual(totals.consistency!, 100)
        checkEqual(totals.rateConsistency.count, 19)
        checkTrue(daily.state.current!.score != nil)
        checkEqual(daily.state.totalXP, 0)
        checkTrue(daily.state.current!.preliminary)
    }

    @Test func midnightSettlementCreditsScoreAndImprovementExactlyOnceWithoutRest() {
        let base = date("2026-10-24T12:00:00Z"), midnight = date("2026-10-25T00:00:00Z")
        var daily = measured(base: base, legacyXP: 10)
        let score = daily.state.current!.score!
        daily.advance(to: midnight)
        checkNil(daily.error); checkTrue(daily.state.days["2026-10-24"]!.sealed)
        checkEqual(daily.state.currentDay, "2026-10-25")
        checkEqual(daily.state.totalXP, 1500); checkTrue(daily.unpersistedReceipts.isEmpty)
        daily.observeLegacyImprovement(total: 5)
        checkEqual(daily.state.totalXP, 1500)
        daily.settleEndedDays(at: midnight)
        checkNil(daily.error); checkEqual(daily.unpersistedReceipts.count, 1)
        let receipt = daily.unpersistedReceipts[0]
        checkEqual(receipt.ordinaryXP, score); checkEqual(receipt.improvementXP, 750)
        checkEqual(receipt.settledAt, midnight)
        checkEqual(receipt.beforeXP, 1500); checkEqual(receipt.afterXP, 1500 + score + 750)
        checkTrue(receipt.isValid); checkEqual(daily.state.pendingImprovementXP, 0)
        checkNil(daily.state.days["2026-10-24"])
        daily.settleEndedDays(at: midnight.addingTimeInterval(120))
        checkEqual(daily.unpersistedReceipts.count, 1)
        checkEqual(daily.state.totalXP, receipt.afterXP)
        let saved = daily.checkpoint(at: midnight.addingTimeInterval(120))
        checkEqual(saved.receipts.count, 1); checkTrue(daily.unpersistedReceipts.isEmpty)
    }

    @Test func sameDaySettlementDoesNotCloseTheCurrentDayAndIdleDoesNotAddPoints() {
        let base = date("2026-10-24T12:00:00Z")
        var daily = measured(base: base)
        let totals = daily.state.current!.totals, score = daily.state.current!.score
        daily.settleEndedDays(at: base.addingTimeInterval(300))
        daily.advance(to: base.addingTimeInterval(3600))
        checkEqual(daily.state.current!.totals, totals); checkEqual(daily.state.current!.score, score)
        checkEqual(daily.state.totalXP, 0); checkTrue(daily.unpersistedReceipts.isEmpty)
    }

    @Test func repeatedSettlementChecksPreserveCurrentDayInputContinuity() {
        let yesterday = date("2026-10-24T12:00:00Z"), today = date("2026-10-25T12:00:00Z")
        var daily = measured(base: yesterday)
        let earned = daily.state.current!.score!
        daily.settleEndedDays(at: date("2026-10-25T00:00:00Z"))
        var uninterrupted = DailyRewardEngine(coverageStart: today, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for index in 0..<200 {
            let event = input(86400 + Double(index) / 5, base: yesterday)
            let result = stats.recordWithIntervals(event)
            daily.record(input: event, result: result, rule: rule)
            uninterrupted.record(input: event, result: result, rule: rule)
            // Reopening the menu or app may check for ended days repeatedly.
            daily.settleEndedDays(at: event.date.addingTimeInterval(0.05))
        }
        checkNil(daily.error)
        checkEqual(daily.state.current, uninterrupted.state.current)
        checkEqual(daily.state.current!.totals.keys, 200)
        checkEqual(daily.state.current!.totals.intervals, 199)
        checkEqual(daily.state.current!.totals.seconds, 39.8, accuracy: 1e-6)
        checkEqual(daily.state.totalXP, earned)
        checkEqual(daily.unpersistedReceipts.count, 1)
    }

    @Test func fixedShanghaiMidnightSettlesAtUTC16AndClockRollbackCannotCreditAgain() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let base = date("2026-10-24T15:00:00Z"), midnight = date("2026-10-24T16:00:00Z")
        var daily = DailyRewardEngine(coverageStart: base, progressionTimeZone: zone)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: zone)
        for index in 0..<100 {
            let event = input(Double(index) / 5, base: base)
            daily.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
        }
        let score = daily.state.current!.score!
        daily.settleEndedDays(at: midnight.addingTimeInterval(-0.001))
        checkEqual(daily.state.currentDay, "2026-10-24")
        checkEqual(daily.state.totalXP, 0)
        checkTrue(daily.unpersistedReceipts.isEmpty)

        daily.settleEndedDays(at: midnight)
        checkNil(daily.error)
        checkEqual(daily.state.currentDay, "2026-10-25")
        checkEqual(daily.state.progressionTimezone, "Asia/Shanghai")
        checkEqual(daily.state.totalXP, score)
        checkEqual(daily.unpersistedReceipts.map(\.day), ["2026-10-24"])
        checkEqual(daily.unpersistedReceipts.first?.settledAt, midnight)
        let settledState = daily.state, receipt = daily.unpersistedReceipts

        for check in [base, midnight, midnight.addingTimeInterval(60)] {
            daily.settleEndedDays(at: check)
        }
        checkNil(daily.error)
        checkEqual(daily.state, settledState)
        checkEqual(daily.unpersistedReceipts, receipt)
    }

    @Test func multiDaySettlementKeepsChronologicalReceiptsAndPreservesTheNewOpenDay() {
        let first = date("2026-10-22T12:00:00Z"), second = date("2026-10-23T12:00:00Z")
        var daily = measured(base: first)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        daily.interrupt(at: second)
        for index in 0..<100 {
            let event = input(86400 + Double(index) / 5, base: first)
            daily.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
        }
        let third = date("2026-10-24T12:00:00Z")
        daily.advance(to: third)
        checkEqual(daily.state.totalXP, 0)
        daily.settleEndedDays(at: third)
        checkEqual(daily.unpersistedReceipts.map(\.day), ["2026-10-22", "2026-10-23"])
        checkEqual(daily.unpersistedReceipts[1].beforeXP, daily.unpersistedReceipts[0].afterXP)
        checkEqual(daily.state.days.count, 1); checkEqual(daily.state.currentDay, "2026-10-24")
        checkTrue(daily.state.isValid)
    }

    @Test func checkpointIsNotSettlementOrAnInputContinuityBoundary() {
        let base = date("2026-10-24T12:00:00Z")
        var periodic = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for index in 0..<200 {
            let event = input(Double(index) / 5, base: base)
            periodic.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
            if index.isMultiple(of: 17) { _ = periodic.checkpoint(at: event.date) }
        }
        let uninterrupted = measured(200, base: base)
        checkEqual(periodic.state.current, uninterrupted.state.current)
        checkEqual(periodic.state.totalXP, 0)
        checkTrue(periodic.unpersistedReceipts.isEmpty)
    }

    @Test func restoringSealsEndedDaysForCoordinatorSettlementAndCannotBridgeInput() throws {
        let base = date("2026-10-24T12:00:00Z")
        var first = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for index in 0..<50 {
            let event = input(Double(index) / 5, base: base)
            first.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
        }
        let checkpoint = first.checkpoint(at: base.addingTimeInterval(9.8))
        var reopened = try DailyRewardEngine(restoring: checkpoint.state, now: base.addingTimeInterval(10))
        let next = input(10, base: base)
        reopened.record(input: next, result: stats.recordWithIntervals(next), rule: rule)
        checkEqual(reopened.state.current!.totals.keys, 51)
        checkEqual(reopened.state.current!.totals.seconds, 9.8, accuracy: 1e-6)
        let tomorrow = date("2026-10-25T12:00:00Z")
        let again = try DailyRewardEngine(restoring: reopened.checkpoint(at: tomorrow).state, now: tomorrow)
        checkEqual(again.state.totalXP, 0); checkTrue(again.unpersistedReceipts.isEmpty)
        checkTrue(again.state.days["2026-10-24"]!.sealed)
    }

    @Test func commandsUnknownAndValidationEditorNeverEnterTheDailyRewardStream() {
        let base = date("2026-10-24T12:00:00Z")
        var daily = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for event in [input(0, base: base, category: .command), input(1, base: base, evidence: .unknown),
                      input(2, base: base, evidence: .confirmed, source: .adapter)] {
            daily.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
        }
        checkEqual(daily.state.current!.totals.keys, 0); checkEqual(daily.state.totalXP, 0)
    }

    @Test func policyChangesRetainCountsButDoNotInventComparableDailyPerformance() {
        let base = date("2026-10-24T12:00:00Z")
        var daily = measured(base: base)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: "new-counting-policy"), timeZone: utc)
        let event = input(100, base: base)
        daily.record(input: event, result: stats.recordWithIntervals(event), rule: "new-counting-policy")
        checkEqual(daily.state.current!.totals.keys, 101)
        checkTrue(daily.state.current!.mixedRules); checkNil(daily.state.current!.score)
    }

    @Test func serializingStateDropsNoPendingDaysAndReceiptsRemainIndependent() throws {
        let base = date("2026-10-24T12:00:00Z")
        var daily = measured(base: base)
        daily.advance(to: date("2026-10-25T12:00:00Z"))
        let state = daily.checkpoint(at: date("2026-10-25T12:00:00Z")).state
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(DailyRewardState.self, from: data)
        checkEqual(restored, state); checkTrue(restored.isValid)
        var reopened = try DailyRewardEngine(restoring: restored, now: date("2026-10-25T12:00:00Z"))
        reopened.settleEndedDays(at: date("2026-10-25T12:00:00Z"))
        let first = reopened.checkpoint(at: date("2026-10-25T12:00:00Z"))
        var afterCommit = try DailyRewardEngine(restoring: first.state, now: date("2026-10-25T12:00:00Z"))
        afterCommit.settleEndedDays(at: date("2026-10-25T12:00:00Z"))
        checkEqual(afterCommit.state.totalXP, first.state.totalXP)
        checkTrue(afterCommit.unpersistedReceipts.isEmpty)
    }

    @Test func midnightBackfillPreservesObservedTimeAndEveryBoundaryKey() {
        let base = date("2026-10-24T23:59:59Z").addingTimeInterval(0.4)
        var daily = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        for index in 0..<5 {
            let event = input(Double(index) / 5, base: base)
            daily.record(input: event, result: stats.recordWithIntervals(event), rule: rule)
        }
        checkNil(daily.error)
        let yesterday = daily.state.days["2026-10-24"]!.totals, today = daily.state.current!.totals
        checkEqual(yesterday.keys + today.keys, 5)
        checkEqual(yesterday.intervals + today.intervals, 4, accuracy: 1e-6)
        checkEqual(yesterday.seconds + today.seconds, 0.8, accuracy: 1e-6)
        checkTrue(daily.state.days["2026-10-24"]!.sealed)
        checkEqual(daily.state.totalXP, 0)
    }

    @Test func wallClockRollbackDoesNotReopenYesterdayOrDuplicateDailyBudgets() {
        let base = date("2026-10-24T12:00:00Z")
        var daily = measured(base: base)
        let yesterday = daily.state.current!
        daily.advance(to: date("2026-10-25T00:00:00Z"))
        var stats = StatisticsEngine(config: SegmentationConfig(maximumGap: 3, ruleID: rule), timeZone: utc)
        var rolledBack = input(86400, base: base)
        rolledBack.date = base.addingTimeInterval(60)
        daily.record(input: rolledBack, result: stats.recordWithIntervals(rolledBack), rule: rule)
        checkNil(daily.error); checkEqual(daily.state.currentDay, "2026-10-25")
        checkEqual(daily.state.current!.totals.keys, 1)
        checkEqual(daily.state.days["2026-10-24"]!.totals, yesterday.totals)
        checkEqual(daily.state.days.count, 2)
    }

    @Test func capacityFailurePreservesEveryUnsettledDayInsteadOfDroppingOldAwards() throws {
        let start = date("2020-01-01T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        func key(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        let last = calendar.date(byAdding: .day, value: DailyRewardPolicy.maximumPendingDays - 1, to: start)!
        var state = DailyRewardState(coverageStart: start, progressionTimezone: utc.identifier, currentDay: key(last))
        for offset in 0..<DailyRewardPolicy.maximumPendingDays {
            let day = key(calendar.date(byAdding: .day, value: offset, to: start)!)
            state.days[day] = .init(day: day, sealed: day != state.currentDay)
        }
        var daily = try DailyRewardEngine(restoring: state, now: last)
        daily.advance(to: calendar.date(byAdding: .day, value: 1, to: last)!)
        checkEqual(daily.error, .capacity)
        checkEqual(daily.state, state)
        checkEqual(daily.state.days.count, DailyRewardPolicy.maximumPendingDays)
    }
}
