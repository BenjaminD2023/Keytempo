import Foundation
import Testing
@testable import TypingCore

struct RollingTypingWindowTests {
    let base = Date(timeIntervalSince1970: 1_767_225_599.9)
    let utc = TimeZone(secondsFromGMT: 0)!
    func interval(_ start: Double, _ end: Double, evidence: Evidence = .probable,
                  language: String = "en") -> AcceptedTypingInterval {
        AcceptedTypingInterval(startTime: start, endTime: end, evidence: evidence,
                               language: language, ruleID: "test")
    }
    func input(_ time: Double, language: String = "en", context: UInt64 = 1,
               category: InputCategory = .textEntry, source: InputSource = .global,
               id: UInt64? = nil) -> ClassifiedInput {
        ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: context,
                        category: category, evidence: .probable, source: source,
                        operationID: id, language: language)
    }

    @Test func weightedWindowCombinesLanguagesWithoutIdlePadding() {
        var window = RollingTypingWindow()
        var engine = StatisticsEngine(timeZone: utc)
        for time in [0.0, 0.1, 0.2, 0.3, 0.4] {
            let result = engine.recordWithIntervals(input(time))
            window.record(result.acceptedIntervals, at: time)
        }
        for time in [10.0, 10.5, 11, 11.5, 12] {
            let result = engine.recordWithIntervals(input(time, language: "zh"))
            window.record(result.acceptedIntervals, at: time)
        }
        for now in [12.0, 17, 42, 599] {
            let result = window.snapshot(at: now)
            checkEqual(result.intervals, 8)
            checkEqual(result.seconds, 2.4, accuracy: 1e-9)
            checkEqual(result.kpm!, 200, accuracy: 1e-8)
            checkEqual(result.estimatedWPM!, 40, accuracy: 1e-8)
        }
        let clipped = window.snapshot(at: 600.05)
        checkEqual(clipped.intervals, 7.5, accuracy: 1e-8)
        checkEqual(clipped.seconds, 2.35, accuracy: 1e-8)
        checkEqual(clipped.kpm!, 60 * 7.5 / 2.35, accuracy: 1e-6)
        checkEqual(clipped.nextExpiry!, 600.1, accuracy: 1e-8)
        let expired = window.snapshot(at: 612)
        checkEqual(expired.intervals, 0)
        checkEqual(expired.seconds, 0)
        checkNil(expired.kpm)
        checkNil(expired.nextExpiry)
    }

    @Test func adaptiveBackfillExposesOriginalIntervalTimes() {
        var engine = StatisticsEngine(timeZone: utc)
        for time in stride(from: 0.0, through: 1.6, by: 0.2) { _ = engine.record(input(time)) }
        _ = engine.recordWithIntervals(input(10))
        checkTrue(engine.recordWithIntervals(input(11.2)).acceptedIntervals.isEmpty)
        checkTrue(engine.recordWithIntervals(input(12.4)).acceptedIntervals.isEmpty)
        let backfill = engine.recordWithIntervals(input(13.6))
        checkEqual(backfill.acceptedIntervals.count, 3)
        checkEqual(backfill.acceptedIntervals.map(\.startTime), [10, 11.2, 12.4])
        checkEqual(backfill.acceptedIntervals.map(\.endTime), [11.2, 12.4, 13.6])
        var window = RollingTypingWindow()
        window.record(backfill.acceptedIntervals, at: 13.6)
        let partial = window.snapshot(at: 610.6)
        checkEqual(partial.intervals, 2.5, accuracy: 1e-8)
        checkEqual(partial.seconds, 3, accuracy: 1e-8)
        checkNil(partial.kpm) // Honest sample insufficiency after clipping.
        checkNil(window.snapshot(at: 613.6).kpm)
        checkEqual(window.intervalCount, 0)
    }

    @Test func commandsContextsSourcesAndLanguagesNeverCreateBridges() {
        var engine = StatisticsEngine(timeZone: utc)
        var accepted = [AcceptedTypingInterval]()
        for event in [input(0), input(0.2), input(0.3, category: .command), input(0.4), input(0.6),
                      input(0.8, context: 2), input(1, context: 2),
                      input(1.2, language: "zh", context: 2), input(1.4, language: "zh", context: 2),
                      input(1.6, language: "zh", context: 2, source: .adapter),
                      input(1.8, language: "zh", context: 2, source: .adapter)] {
            accepted += engine.recordWithIntervals(event).acceptedIntervals
        }
        checkEqual(accepted.count, 5)
        checkEqual(accepted.map(\.startTime), [0, 0.4, 0.8, 1.2, 1.6])
        var window = RollingTypingWindow()
        window.record(accepted, at: 1.8)
        let result = window.snapshot(at: 1.8)
        checkEqual(result.intervals, 5)
        checkEqual(result.seconds, 1, accuracy: 1e-9)
        checkEqual(result.kpm!, 300, accuracy: 1e-6)
    }

    @Test func midnightSplitDoesNotDuplicateRollingInterval() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.recordWithIntervals(input(0))
        let result = engine.recordWithIntervals(input(0.2))
        let split = result.deltas.filter { $0.intervals > 0 }
        checkEqual(split.count, 2)
        checkEqual(result.acceptedIntervals.count, 1)
        checkEqual(result.acceptedIntervals[0].startTime, 0)
        checkEqual(result.acceptedIntervals[0].endTime, 0.2)
        checkEqual(split.reduce(0.0) { $0 + $1.intervals }, 1, accuracy: 1e-9)
        var window = RollingTypingWindow()
        window.record(result.acceptedIntervals, at: 0.2)
        checkEqual(window.snapshot(at: 0.2).intervals, 1)
    }

    @Test func confirmedDuplicatesAndInvalidMetadataCannotContaminateEstimate() {
        var window = RollingTypingWindow()
        window.record([interval(0, 0.2, evidence: .confirmed), interval(.nan, 0.2),
                       interval(1, 1), interval(2, 1)], at: 2)
        checkEqual(window.intervalCount, 0)
        window.record([interval(0, 0.2), interval(0, 0.2), interval(0.1, 0.3)], at: 2)
        checkEqual(window.snapshot(at: 2).intervals, 1)
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.recordWithIntervals(input(0, id: 1))
        checkEqual(engine.recordWithIntervals(input(0.2, id: 2)).acceptedIntervals.count, 1)
        checkTrue(engine.recordWithIntervals(input(0.2, id: 2)).acceptedIntervals.isEmpty)
        checkTrue(engine.recordWithIntervals(input(0.3, category: .navigation)).acceptedIntervals.isEmpty)
    }

    @Test func boundedOverflowShowsIncompleteUntilOmittedSamplesExpire() {
        var window = RollingTypingWindow(capacity: 4)
        for n in 0..<5 { window.record([interval(Double(n), Double(n + 1))], at: Double(n + 1)) }
        checkLessThanOrEqual(window.intervalCount, 4)
        let incomplete = window.snapshot(at: 5)
        checkTrue(!incomplete.isComplete)
        checkNil(incomplete.kpm)
        let recovered = window.snapshot(at: 601)
        checkTrue(recovered.isComplete)
        checkEqual(recovered.intervals, 4)
        checkEqual(recovered.kpm!, 60)
        window.reset()
        checkNil(window.snapshot(at: 601).kpm)
        checkEqual(window.intervalCount, 0)
    }
}
