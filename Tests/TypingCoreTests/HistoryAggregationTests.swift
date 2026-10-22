import Foundation
import Testing
@testable import TypingCore

struct HistoryAggregationTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ day: String, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let values = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2], hour: hour))!
    }
    private func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private func row(_ day: String, language: String = "en", evidence: Evidence = .probable,
                     rule: String = "adaptive", timezone: String = "UTC",
                     keys: Int = 5, intervals: Double = 4, seconds: Double = 0.8,
                     characters: Int = 0, ratedCharacters: Double = 0,
                     characterIntervals: Double = 0, characterSeconds: Double = 0) -> HistoryMetricRow {
        HistoryMetricRow(day: day, language: language, evidence: evidence, rule: rule, timezone: timezone,
                         keys: keys, characters: characters, intervals: intervals, seconds: seconds,
                         ratedCharacters: ratedCharacters, characterIntervals: characterIntervals,
                         characterSeconds: characterSeconds)
    }

    @Test func granularityUsesDailyThenWeeklyThenMonthlyPeriods() {
        checkEqual(HistoryGranularity.forHistoryDays(7), .day)
        checkEqual(HistoryGranularity.forHistoryDays(90), .day)
        checkEqual(HistoryGranularity.forHistoryDays(91), .week)
        checkEqual(HistoryGranularity.forHistoryDays(365), .week)
        checkEqual(HistoryGranularity.forHistoryDays(366), .week)
        checkEqual(HistoryGranularity.forHistoryDays(1828), .month)
    }

    @Test func weeklyAndMonthlyRatesUseWeightedIntervalsRatherThanAveragedSpeeds() {
        for granularity in [HistoryGranularity.week, .month] {
            let result = HistoryAggregation.aggregate([
                row("2026-10-20", seconds: 0.4), row("2026-10-21", seconds: 2.0)
            ], granularity: granularity, timeZone: utc)
            checkEqual(result.count, 1)
            let bucket = result[0]
            checkEqual(bucket.keys, 10)
            checkEqual(bucket.intervals, 8)
            checkEqual(bucket.seconds, 2.4, accuracy: 1e-9)
            checkEqual(bucket.kpm!, 200, accuracy: 1e-8)
            checkEqual(bucket.estimatedWPM!, 40, accuracy: 1e-8)
            checkNil(bucket.cpm)
        }
    }

    @Test func calendarWeeksStartOnMondayAndCrossTheYearBoundary() {
        let rows = [row("2026-12-31"), row("2027-01-01"), row("2027-01-04")]
        let buckets = HistoryAggregation.aggregate(rows, granularity: .week, timeZone: utc)
        checkEqual(buckets.count, 2)
        checkEqual(buckets[0].periodStart, "2026-12-28")
        checkEqual(buckets[0].periodEnd, "2027-01-03")
        checkEqual(buckets[0].keys, 10)
        checkEqual(buckets[1].periodStart, "2027-01-04")
        checkEqual(buckets[1].periodEnd, "2027-01-10")
    }

    @Test func dateRangeFilteringIsInclusiveAndClipsPartialCalendarBuckets() {
        let rows = [row("2026-09-30"), row("2026-10-01"), row("2026-10-22"), row("2026-10-23")]
        let buckets = HistoryAggregation.aggregate(rows, granularity: .month, timeZone: utc,
                                                    startDay: "2026-10-01", endDay: "2026-10-22")
        checkEqual(buckets.count, 1)
        checkEqual(buckets[0].periodStart, "2026-10-01")
        checkEqual(buckets[0].periodEnd, "2026-10-22")
        checkEqual(buckets[0].keys, 10)
        let partial = HistoryAggregation.aggregate([row("2026-10-22")], granularity: .month,
                                                   timeZone: utc, startDay: "2026-10-22", endDay: "2026-10-22")
        checkEqual(partial[0].periodStart, "2026-10-22")
        checkEqual(partial[0].periodEnd, "2026-10-22")
    }

    @Test func calendarYearRangeRetainsTheAnniversaryAcrossTwoLeapDays() {
        let range = HistoryDateRange.years(5, endingOn: date("2024-03-01"), timeZone: utc)
        checkEqual(range.startDay, "2019-03-01")
        checkEqual(range.endDay, "2024-03-01")
        checkEqual(range.dayCount, 1828)
        checkTrue(range.isValid)
        checkEqual(HistoryDateRange.years(Int.max, endingOn: date("2024-03-01"), timeZone: utc), range)
        checkEqual(HistoryDateRange.days(Int.max, endingOn: date("2024-03-01"), timeZone: utc), range)
        let week = HistoryDateRange.days(7, endingOn: date("2024-03-01"), timeZone: utc)
        checkEqual(week.startDay, "2024-02-24")
        checkEqual(week.endDay, "2024-03-01")
        checkEqual(week.dayCount, 7)
    }

    @Test func rangesUseTheRequestedLocalDateAndRejectNonfiniteEndDates() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let ending = date("2026-10-21", hour: 18) // Already October 22 in Shanghai.
        let range = HistoryDateRange.days(7, endingOn: ending, timeZone: shanghai)
        checkEqual(range.startDay, "2026-10-16")
        checkEqual(range.endDay, "2026-10-22")
        let invalid = HistoryDateRange.years(5, endingOn: Date(timeIntervalSince1970: .nan), timeZone: utc)
        checkTrue(!invalid.isValid)
        checkEqual(invalid.dayCount, 0)
    }

    @Test func fiveCalendarYearsProduceAtMostSixtyOneMonthlyBucketsWithoutLosingDays() {
        let range = HistoryDateRange.years(5, endingOn: date("2024-03-01"), timeZone: utc)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let start = date(range.startDay)
        let rows = (0..<range.dayCount).map { offset in
            row(day(calendar.date(byAdding: .day, value: offset, to: start)!, calendar: calendar),
                keys: 1, intervals: 0, seconds: 0)
        }
        let buckets = HistoryAggregation.aggregate(rows, granularity: .month, timeZone: utc,
                                                    startDay: range.startDay, endDay: range.endDay)
        checkEqual(buckets.count, 61)
        checkEqual(buckets.reduce(0) { $0 + $1.keys }, 1828)
        checkEqual(buckets.first?.periodStart, range.startDay)
        checkEqual(buckets.last?.periodEnd, range.endDay)
        checkTrue(buckets.allSatisfy { $0.kpm == nil })
    }

    @Test func languagesAndEvidenceStaySeparateAndOriginalTimezonesAreRetained() {
        let buckets = HistoryAggregation.aggregate([
            row("2026-10-21", language: "en", evidence: .confirmed),
            row("2026-10-21", language: "en", evidence: .probable),
            row("2026-10-22", language: "en", evidence: .probable, timezone: "Asia/Shanghai"),
            row("2026-10-22", language: "zh", evidence: .probable),
            row("2026-10-22", language: "en", evidence: .unknown)
        ], granularity: .month, timeZone: utc)
        checkEqual(buckets.count, 3)
        let englishEstimate = buckets.first { $0.language == "en" && $0.evidence == .probable }!
        checkEqual(englishEstimate.keys, 10)
        checkEqual(englishEstimate.timezones, Set(["UTC", "Asia/Shanghai"]))
        checkEqual(buckets.first { $0.language == "zh" }?.keys, 5)
        checkEqual(buckets.first { $0.evidence == .confirmed }?.keys, 5)
    }

    @Test func mixedRulesRetainCountsButDoNotCreateAComparableSpeed() {
        let bucket = HistoryAggregation.aggregate([
            row("2026-10-20", rule: "old"), row("2026-10-21", rule: "new")
        ], granularity: .month, timeZone: utc)[0]
        checkEqual(bucket.keys, 10)
        checkEqual(bucket.rules, Set(["old", "new"]))
        checkTrue(bucket.hasMixedRules)
        checkNil(bucket.kpm)
        checkNil(bucket.estimatedWPM)
        checkNil(bucket.cpm)
    }

    @Test func characterRateUsesCoveredWholeCommitNumeratorsAndConfirmedEvidence() {
        let rows = [
            row("2026-10-20", language: "zh", evidence: .confirmed, seconds: 0.8,
                characters: 13, ratedCharacters: 3, characterIntervals: 4, characterSeconds: 0.8),
            row("2026-10-21", language: "zh", evidence: .confirmed, seconds: 0.4,
                characters: 2, ratedCharacters: 2, characterIntervals: 4, characterSeconds: 0.4)
        ]
        let bucket = HistoryAggregation.aggregate(rows, granularity: .month, timeZone: utc)[0]
        checkEqual(bucket.characters, 15)
        checkEqual(bucket.ratedCharacters, 5)
        checkEqual(bucket.characterIntervals, 8)
        checkEqual(bucket.characterSeconds, 1.2, accuracy: 1e-9)
        checkEqual(bucket.cpm!, 250, accuracy: 1e-8)
        checkNil(bucket.estimatedWPM)
        var probable = rows[0]; probable.evidence = .probable
        checkNil(HistoryAggregation.aggregate([probable], granularity: .month, timeZone: utc)[0].cpm)
    }

    @Test func malformedDatesBoundsAndSmallSamplesNeverInventRates() {
        let malformed = ["2026-02-30", "2026-2-02", "0000-01-01", "2026/01/01", "garbage"]
        let rows = malformed.map { row($0) } + [row("2026-10-22", keys: 1, intervals: 0, seconds: 0)]
        let buckets = HistoryAggregation.aggregate(rows, granularity: .day, timeZone: utc)
        checkEqual(buckets.count, 1)
        checkEqual(buckets[0].keys, 1)
        checkNil(buckets[0].kpm)
        checkTrue(HistoryAggregation.aggregate(rows, granularity: .day, timeZone: utc, startDay: "bad").isEmpty)
        checkTrue(HistoryAggregation.aggregate(rows, granularity: .day, timeZone: utc,
                                                startDay: "2026-10-23", endDay: "2026-10-22").isEmpty)
    }

    @Test func invalidNumbersAndOverflowAreVisibleWithoutPoisoningTotalsOrProducingRates() {
        for invalid in [Double.nan, .infinity, -1] {
            let buckets = HistoryAggregation.aggregate([
                row("2026-10-21"), row("2026-10-22", seconds: invalid)
            ], granularity: .month, timeZone: utc)
            checkEqual(buckets[0].keys, 5)
            checkEqual(buckets[0].rejectedRows, 1)
            checkTrue(buckets[0].seconds.isFinite)
            checkNil(buckets[0].kpm)
        }
        let overflow = HistoryAggregation.aggregate([
            row("2026-10-21", keys: Int.max), row("2026-10-22", keys: 1)
        ], granularity: .month, timeZone: utc)[0]
        checkEqual(overflow.keys, Int.max)
        checkEqual(overflow.rejectedRows, 1)
        checkNil(overflow.kpm)
    }
}
