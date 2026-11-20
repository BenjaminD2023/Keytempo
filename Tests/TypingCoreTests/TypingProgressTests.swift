import Foundation
import Testing
@testable import TypingCore

struct TypingProgressTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-11-16T12:00:00Z") }

    private func day(_ offset: Int, wpm: Double = 60, seconds: Double = 100,
                     rules: Set<String> = ["rule-a"], rates: Bool = true) -> TypingProgressDay {
        let intervals = wpm * seconds / 12
        let samples = Int(seconds)
        return TypingProgressDay(date: calendar.date(byAdding: .day, value: offset, to: now)!,
            totals: RhythmTotals(keys: Int(intervals) + 1, intervals: intervals, seconds: seconds,
                squaredIntervalSeconds: seconds * seconds / intervals,
                rateConsistency: rates ? RateConsistencyTotals(count: samples, intervals: Int(intervals),
                    sum: Double(samples) * wpm, squaredSum: Double(samples) * wpm * wpm) : .init()),
            rules: rules)
    }

    @Test func comparisonPoolsTimingAndMomentsWhileKeepingAllPracticeQuantities() {
        let days = [-14, -12, -8].map { day($0) }
            + [day(-7), day(-4, wpm: 120, seconds: 200), day(-1), day(-2, seconds: 2)]
        let progress = TypingProgress.analyze(days: days, through: now, now: now, calendar: calendar)
        checkEqual(progress.speedReadiness, .ready)
        checkEqual(progress.recent.wpm!, 90, accuracy: 1e-9)
        checkEqual(progress.previous.wpm!, 60, accuracy: 1e-9)
        checkEqual(progress.speedChangeWPM!, 30, accuracy: 1e-9)
        checkEqual(progress.speedChangePercent!, 50, accuracy: 1e-9)
        checkEqual(progress.recent.activeDays, 4)
        checkEqual(progress.recent.qualifyingDays, 3)
        checkEqual(progress.recent.totals.seconds, 402, accuracy: 1e-9)
        checkEqual(progress.recent.rateTotals.seconds, 400, accuracy: 1e-9)
        checkEqual(progress.recent.totals.keys, days.filter { $0.date >= progress.recent.start }.reduce(0) { $0 + $1.totals.keys })
        checkEqual(progress.recent.consistencySampleSeconds, 400)
        let pooled = RateConsistencyTotals(count: 400, intervals: 3_000, sum: 36_000, squaredSum: 3_600_000)
        checkEqual(progress.recent.consistency!, pooled.consistency!, accuracy: 1e-9)
        checkEqual(progress.consistencyChangePoints!, pooled.consistency! - 100, accuracy: 1e-9)
        // The two-second practice observation is inspectable without becoming
        // a meaningful speed data point or an equal-weight daily rate.
        checkNil(progress.dailyData.first { calendar.isDate($0.date, inSameDayAs: day(-2).date) }?.wpm)
    }

    @Test func currentPartialDayAndFutureNeverEnterComparisonOrTrend() {
        let historical = [-14, -12, -8, -7, -4, -1].map { day($0) }
        let baseline = TypingProgress.analyze(days: historical, through: now, now: now, calendar: calendar)
        let extra = [day(0, wpm: 200, seconds: 10_000), day(1, wpm: 300, seconds: 10_000)]
        let progress = TypingProgress.analyze(days: historical + extra, through: day(7).date, now: now, calendar: calendar)
        checkEqual(progress, baseline)
        checkEqual(progress.recent.end, date("2026-11-16T00:00:00Z"))
        checkTrue(progress.dailyData.allSatisfy { $0.date < progress.recent.end })
        checkTrue(progress.trend.allSatisfy { $0.date < progress.recent.end })
    }

    @Test func historicalSelectionIncludesSelectedCompletedDayAndExcludesLaterDays() {
        let selected = date("2026-11-08T12:00:00Z")
        let progress = TypingProgress.analyze(days: [-14, -12, -8, -7, -1].map { day($0) },
            through: selected, now: now, calendar: calendar)
        checkEqual(progress.recent.start, date("2026-11-02T00:00:00Z"))
        checkEqual(progress.recent.end, date("2026-11-09T00:00:00Z"))
        checkEqual(progress.previous.start, date("2026-10-26T00:00:00Z"))
        checkEqual(progress.recent.activeDays, 3)
        checkEqual(progress.dailyData.count, 3)
    }

    @Test func evidenceRequiresThreeQualifyingDaysAndFiveMeasuredMinutesInEachPeriod() {
        let previous = [-14, -12, -8].map { day($0) }
        for current in [[day(-7, seconds: 600), day(-1, seconds: 600)],
                        [day(-7, seconds: 99), day(-4, seconds: 100), day(-1, seconds: 100)],
                        [day(-7, seconds: 140), day(-4, seconds: 140), day(-1, seconds: 29)]] {
            let progress = TypingProgress.analyze(days: previous + current, through: now, now: now, calendar: calendar)
            checkEqual(progress.speedReadiness, .insufficientEvidence)
            checkNil(progress.speedChangeWPM)
            checkNil(progress.speedChangePercent)
        }
        let sparse = TypingProgress.analyze(days: [day(-14), day(-12), day(-8), day(-7), day(-4), day(-1)],
                                           through: now, now: now, calendar: calendar)
        checkEqual(sparse.dailyData.count, 6)
        checkEqual(sparse.recent.wpm!, 60, accuracy: 1e-9)
        checkEqual(sparse.previous.wpm!, 60, accuracy: 1e-9)
        checkEqual(sparse.speedChangeWPM!, 0, accuracy: 1e-9)
    }

    @Test func rateChangesRequireIdenticalKnownRulesAcrossBothPeriods() {
        let previous = [-14, -12, -8].map { day($0) }
        let current = [-7, -4, -1].map { day($0, rules: ["rule-b"]) }
        let changed = TypingProgress.analyze(days: previous + current, through: now, now: now, calendar: calendar)
        checkEqual(changed.recent.speedReadiness, .ready)
        checkEqual(changed.previous.speedReadiness, .ready)
        checkEqual(changed.speedReadiness, .incompatibleRules)
        checkEqual(changed.consistencyReadiness, .incompatibleRules)
        checkNil(changed.speedChangePercent)
        checkNil(changed.consistencyChangePoints)

        for ruleSet: Set<String> in [[], [""], ["rule-a", "rule-b"]] {
            let progress = TypingProgress.analyze(days: previous + [day(-7), day(-4), day(-1, rules: ruleSet)],
                                                 through: now, now: now, calendar: calendar)
            checkEqual(progress.recent.speedReadiness, .incompatibleRules)
            checkNil(progress.recent.wpm)
            checkNil(progress.speedChangeWPM)
            checkNil(progress.dailyData.last?.wpm)
        }
    }

    @Test func consistencyNeedsCoveredDaysAndDoesNotReconstructLegacyIntervalSamples() {
        let previous = [-14, -12, -8].map { day($0) }
        for current in [[day(-7, rates: false), day(-4, rates: false), day(-1, rates: false)],
                        [day(-7), day(-4), day(-1, rates: false)]] {
            let progress = TypingProgress.analyze(days: previous + current, through: now, now: now, calendar: calendar)
            checkEqual(progress.speedReadiness, .ready)
            checkEqual(progress.consistencyReadiness, .insufficientEvidence)
            checkNil(progress.recent.consistency)
            checkNil(progress.consistencyChangePoints)
            checkTrue(progress.recent.consistencyDays < 3)
        }
    }

    @Test func trendUsesTrailingCalendarWindowsWithoutBridgingLongMissingPeriods() {
        let days = [day(-30), day(-29), day(-28), day(-7), day(-4), day(-1)]
        let progress = TypingProgress.analyze(days: days, through: now, now: now, calendar: calendar)
        checkEqual(progress.trend.count, 2)
        checkEqual(progress.trend[0].date, calendar.startOfDay(for: day(-28).date))
        checkEqual(progress.trend[1].date, calendar.startOfDay(for: day(-1).date))
        checkEqual(progress.trend[1].period.start, date("2026-11-09T00:00:00Z"))
        checkEqual(progress.trend[1].wpm, 60, accuracy: 1e-9)
        checkEqual(progress.dailyData.count, 6)
    }

    @Test func trendRequiresItsEntireCalendarWindowInsideLoadedHistory() {
        let days = [day(-29), day(-28), day(-27), day(-23, seconds: 2)]
            + [-14, -12, -8, -7, -4, -1].map { day($0) }
        let unbounded = TypingProgress.analyze(days: days, through: now, now: now, calendar: calendar)
        let queryStart = day(-29).date
        let bounded = TypingProgress.analyze(days: days, through: now, now: now, calendar: calendar,
                                             historyStart: queryStart)
        checkEqual(unbounded.trend.first?.date, calendar.startOfDay(for: day(-27).date))
        checkEqual(bounded.trend.first?.date, calendar.startOfDay(for: day(-23).date))
        checkTrue(bounded.trend.allSatisfy { $0.period.start >= calendar.startOfDay(for: queryStart) })
        checkEqual(bounded.recent, unbounded.recent)
        checkEqual(bounded.previous, unbounded.previous)
        checkEqual(bounded.speedChangeWPM, unbounded.speedChangeWPM)
        checkEqual(bounded.consistencyChangePoints, unbounded.consistencyChangePoints)
        checkEqual(bounded.dailyData, unbounded.dailyData)

        for invalidBoundary in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            let invalid = TypingProgress.analyze(days: days, through: now, now: now, calendar: calendar,
                                                 historyStart: invalidBoundary)
            checkTrue(invalid.trend.isEmpty)
            checkEqual(invalid.recent, unbounded.recent)
            checkEqual(invalid.previous, unbounded.previous)
        }
    }

    @Test func duplicateFragmentsMergeIntoOneCalendarDayBeforeEvidenceChecks() {
        let fragments = [day(-7, seconds: 50), day(-7, wpm: 120, seconds: 50), day(-4), day(-1)]
        let progress = TypingProgress.analyze(days: fragments, through: now, now: now, calendar: calendar)
        checkEqual(progress.dailyData.count, 3)
        checkEqual(progress.recent.qualifyingDays, 3)
        checkEqual(progress.recent.rateTotals.seconds, 300, accuracy: 1e-9)
        checkEqual(progress.recent.wpm!, 70, accuracy: 1e-9)
        let mixed = TypingProgress.analyze(days: fragments + [day(-7, rules: ["rule-b"])],
                                          through: now, now: now, calendar: calendar)
        checkEqual(mixed.recent.speedReadiness, .incompatibleRules)
    }

    @Test func invalidValuesDoNotLookLikeValidPartialComparisons() {
        let valid = [-14, -12, -8, -7, -4, -1].map { day($0) }
        for invalidTotals in [RhythmTotals(seconds: .nan), RhythmTotals(intervals: .infinity),
                              RhythmTotals(keys: -1), RhythmTotals(rateConsistency: .init(count: -1))] {
            let invalid = TypingProgressDay(date: day(-2).date, totals: invalidTotals, rules: ["rule-a"])
            let progress = TypingProgress.analyze(days: valid + [invalid], through: now, now: now, calendar: calendar)
            checkEqual(progress.speedReadiness, .invalidData)
            checkEqual(progress.consistencyReadiness, .invalidData)
            checkNil(progress.speedChangeWPM)
            checkEqual(progress.dailyData.count, 6)
            checkTrue(progress.trend.allSatisfy { $0.date < calendar.startOfDay(for: invalid.date) })
        }
        for invalidDate in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            let badRow = TypingProgressDay(date: invalidDate, totals: .init(keys: 1), rules: ["rule-a"])
            let rejectedRow = TypingProgress.analyze(days: [badRow], through: now, now: now, calendar: calendar)
            checkTrue(rejectedRow.dailyData.isEmpty)
            let badBound = TypingProgress.analyze(days: valid, through: invalidDate, now: now, calendar: calendar)
            checkEqual(badBound.speedReadiness, .invalidData)
            checkTrue(badBound.trend.isEmpty)
        }
        let empty = TypingProgress.analyze(days: [], through: now, now: now, calendar: calendar)
        checkEqual(empty.speedReadiness, .insufficientEvidence)
        checkNil(empty.speedChangeWPM)
        checkTrue(empty.trend.isEmpty)
    }

    @Test func timezoneAndDSTUseLocalCalendarDaysRatherThanFixedSeconds() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let reference = date("2026-11-09T04:00:00Z") // November 8 in Los Angeles.
        let progress = TypingProgress.analyze(days: [], through: reference, now: reference, calendar: local)
        checkEqual(progress.recent.end, date("2026-11-08T08:00:00Z"))
        checkEqual(progress.recent.start, date("2026-11-01T07:00:00Z"))
        checkEqual(progress.previous.start, date("2026-10-25T07:00:00Z"))
        checkEqual(progress.recent.end.timeIntervalSince(progress.recent.start), 7 * 86_400 + 3_600, accuracy: 1e-9)
        let justBeforeLocalMidnight = TypingProgressDay(date: date("2026-11-08T07:59:59Z"),
                                                      totals: .init(keys: 7), rules: ["rule-a"])
        let justAfterLocalMidnight = TypingProgressDay(date: date("2026-11-08T08:00:00Z"),
                                                     totals: .init(keys: 9), rules: ["rule-a"])
        let rows = TypingProgress.analyze(days: [justBeforeLocalMidnight, justAfterLocalMidnight],
                                         through: reference, now: reference, calendar: local)
        checkEqual(rows.recent.totals.keys, 7)
        checkEqual(rows.dailyData.count, 1)
        checkEqual(rows.dailyData[0].date, date("2026-11-07T08:00:00Z"))
    }
}
