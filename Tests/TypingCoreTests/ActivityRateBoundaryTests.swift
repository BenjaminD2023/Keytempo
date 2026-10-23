import Foundation
import Testing
@testable import TypingCore

struct ActivityRateBoundaryTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let app = "org.example.Editor"

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func input(_ time: Double, base: Date) -> ClassifiedInput {
        ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                        category: .textEntry, evidence: .probable, source: .global, language: "mul")
    }
    private func merged(_ rows: [HourlyActivity], applicationID: String = "") -> RhythmTotals {
        rows.filter { $0.applicationID == applicationID }.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
    }

    @Test func hourAndMidnightRateCoverageBelongsToTheCompletionDate() {
        let cases = [(date("2026-10-24T12:59:59Z"), date("2026-10-24T13:00:00Z"), false),
                     (date("2026-10-24T23:59:59Z").addingTimeInterval(0.8), date("2026-10-25T00:00:00Z"), true)]
        let expected = RateConsistencyTotals(count: 10, intervals: 49, sum: 600, squaredSum: 36_000)
        for (base, boundary, crossesDay) in cases {
            var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
            var rows: [HourlyActivity] = [], sessions: [String: TypingSession] = [:]
            for index in 0...50 {
                let value = input(Double(index) / 5, base: base)
                let batch = tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID,
                                           applicationID: app, perAppEnabled: true)
                rows += batch.hourly
                for session in batch.sessions { sessions[session.id] = session }
            }
            for session in tracker.finish(reason: "testComplete").sessions { sessions[session.id] = session }

            let global = merged(rows), attributed = merged(rows, applicationID: app)
            let sessionMoments = sessions.values.reduce(into: RateConsistencyTotals()) { $0.merge($1.totals.rateConsistency) }
            checkEqual(global.rateConsistency, expected)
            checkEqual(attributed.rateConsistency, expected)
            checkEqual(sessionMoments, expected)
            // A completed bin is assigned once by its end date. Neither a
            // fractional prior-day portion nor the exact prior-hour endpoint
            // creates an extra sample in the preceding calendar bucket.
            for applicationID in ["", app] {
                let prior = rows.filter { $0.applicationID == applicationID && $0.bucketStart < boundary }
                let after = rows.filter { $0.applicationID == applicationID && $0.bucketStart >= boundary }
                checkTrue(!prior.isEmpty)
                checkEqual(merged(prior, applicationID: applicationID).rateConsistency, .init())
                checkEqual(merged(after, applicationID: applicationID).rateConsistency, expected)
            }
            if crossesDay {
                checkEqual(sessions.count, 2)
                let prior = sessions.values.first { $0.start < boundary }!
                let current = sessions.values.first { $0.start >= boundary }!
                checkTrue(prior.totals.seconds > 0)
                checkEqual(prior.totals.rateConsistency, .init())
                checkEqual(current.totals.rateConsistency, expected)
            } else {
                checkEqual(sessions.count, 1)
            }
        }
    }

    @Test func explicitInterruptDiscardsPartialRateCoverageDespiteAContiguousEndpoint() {
        let base = date("2026-10-24T12:00:00Z"), rule = "boundary-fixture"
        var tracker = ActivityTracker(timeZone: utc), rows: [HourlyActivity] = []
        func result(_ start: Double?, _ end: Double) -> StatisticsRecordResult {
            let accepted = start.map {
                [AcceptedTypingInterval(startTime: $0, endTime: end, evidence: .probable, language: "mul", ruleID: rule)]
            } ?? []
            return StatisticsRecordResult(deltas: [DailyDelta(day: "2026-10-24", timezoneID: utc.identifier,
                                                               ruleID: rule, evidence: .probable, keys: 1)],
                                          acceptedIntervals: accepted)
        }
        for (start, end) in [(nil as Double?, 0.0), (0, 0.2), (0.2, 0.4)] {
            rows += tracker.record(input: input(end, base: base), result: result(start, end), rule: rule).hourly
        }
        tracker.interruptConsistency()
        // This accepted interval starts at the previous accepted endpoint.
        // Only the explicit reset can prevent reuse of the old partial bin.
        let afterInterrupt = tracker.record(input: input(1, base: base), result: result(0.4, 1), rule: rule)
        rows += afterInterrupt.hourly
        checkEqual(merged(rows).rateConsistency, .init())
        checkEqual(tracker.currentSession!.totals.rateConsistency, .init())

        rows += tracker.record(input: input(1.4, base: base), result: result(1, 1.4), rule: rule).hourly
        let total = merged(rows)
        let expected = RateConsistencyTotals(count: 1, intervals: 1, sum: 24, squaredSum: 576)
        checkEqual(total.rateConsistency, expected)
        checkEqual(tracker.currentSession!.totals.rateConsistency, expected)
        checkEqual(total.keys, 5)
        checkEqual(total.intervals, 4)
        checkEqual(total.seconds, 1.4, accuracy: 1e-6)
    }
}
