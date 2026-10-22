import Testing
import Foundation
@testable import TypingCore

final class StatisticsCoreTests {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let utc = TimeZone(secondsFromGMT: 0)!

    func event(_ t: Double, category: InputCategory = .textEntry, evidence: Evidence = .confirmed,
               context: UInt64 = 1, source: InputSource = .adapter, id: UInt64? = nil,
               date: Date? = nil) -> ClassifiedInput {
        ClassifiedInput(time: t, date: date ?? base.addingTimeInterval(t), context: context,
                        category: category, evidence: evidence, source: source, operationID: id)
    }

    @discardableResult
    func type(_ times: [Double], into engine: inout StatisticsEngine) -> [DailyDelta] {
        times.flatMap { engine.record(event($0)) }
    }

    @Test func testFiveEventsHaveFourIntervalsAndNoTail() {
        var engine = StatisticsEngine(timeZone: utc)
        let deltas = type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
        let initial = engine.snapshot(now: 0.8).confirmed
        checkEqual(initial.keys, 5)
        checkEqual(initial.intervals, 4)
        checkEqual(initial.seconds, 0.8, accuracy: 1e-9)
        checkEqual(initial.rawKPM!, 300, accuracy: 1e-8)
        checkEqual(deltas.reduce(0) { $0 + $1.intervals }, 4)
        for t in [5.8, 30.8, 60_000] {
            engine.advance(to: t)
            let idle = engine.snapshot(now: t)
            checkEqual(idle.confirmed, initial)
            checkEqual(idle.phase, .idle)
        }
    }

    @Test func testSeparateBurstsMergeWeightedIntervals() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8, 10, 10.2, 10.4], into: &engine)
        let result = engine.snapshot(now: 10.4).confirmed
        checkEqual(result.keys, 8)
        checkEqual(result.intervals, 6)
        checkEqual(result.seconds, 1.2, accuracy: 1e-8)
        checkEqual(result.rawKPM!, 300, accuracy: 1e-6)
    }

    @Test func testWeightedSpeedIsNotAverageOfSegmentSpeeds() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.1, 0.2, 0.3, 0.4, 10, 10.5, 11, 11.5, 12], into: &engine)
        let result = engine.snapshot(now: 12).confirmed
        checkEqual(result.intervals, 8)
        checkEqual(result.seconds, 2.4, accuracy: 1e-8)
        checkEqual(result.rawKPM!, 200, accuracy: 1e-6)
    }

    @Test func testSingleEventCountsWithoutDurationOrSpeed() {
        var engine = StatisticsEngine(timeZone: utc)
        type([5], into: &engine)
        engine.advance(to: 100)
        let result = engine.snapshot(now: 100).confirmed
        checkEqual(result.keys, 1)
        checkEqual(result.intervals, 0)
        checkEqual(result.seconds, 0)
        checkNil(result.rawKPM)
        checkNil(result.rhythmKPM)
        checkNil(result.recentRhythmKPM)
    }

    @Test func testShortMessagesAreNotDiscarded() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2], into: &engine)
        engine.interrupt()
        type([10, 10.2], into: &engine)
        let result = engine.snapshot(now: 10.2).confirmed
        checkEqual(result.keys, 4)
        checkEqual(result.intervals, 2)
        checkEqual(result.seconds, 0.4, accuracy: 1e-8)
        checkNil(result.rhythmKPM)
        checkEqual(result.rawKPM!, 300, accuracy: 1e-6)
    }

    @Test func testCommandsNavigationGeneratedAndUnknownBreakContinuity() {
        for category in [InputCategory.command, .navigation, .generated, .unknown] {
            var engine = StatisticsEngine(timeZone: utc)
            type([0, 0.2], into: &engine)
            checkTrue(engine.record(event(0.3, category: category)).isEmpty)
            type([0.4, 0.6], into: &engine)
            let result = engine.snapshot(now: 0.6).confirmed
            checkEqual(result.keys, 4, "\(category)")
            checkEqual(result.intervals, 2, "\(category)")
            checkEqual(result.seconds, 0.4, accuracy: 1e-8)
        }
    }

    @Test func testEditingIncludedInProcessButBreaksNewInputRhythm() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2], into: &engine)
        _ = engine.record(event(0.4, category: .editing))
        type([0.6, 0.8], into: &engine)
        let result = engine.snapshot(now: 0.8).confirmed
        checkEqual(result.keys, 5)
        checkEqual(result.edits, 1)
        checkEqual(result.intervals, 4)
        checkEqual(result.seconds, 0.8, accuracy: 1e-8)
        checkEqual(result.newIntervals, 2)
        checkEqual(result.newSeconds, 0.4, accuracy: 1e-8)
    }

    @Test func testCompositionIsOperationNotCommittedChineseCharacter() {
        var engine = StatisticsEngine(timeZone: utc)
        for t in [0.0, 0.2, 0.4, 0.6] { _ = engine.record(event(t, category: .composition)) }
        let result = engine.snapshot(now: 0.6).confirmed
        checkEqual(result.keys, 4)
        checkEqual(result.composition, 4)
        checkEqual(result.newIntervals, 0)
        checkEqual(result.newSeconds, 0)
        checkEqual(result.intervals, 3)
    }

    @Test func testEvidenceAndContextsNeverConnect() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.record(event(0))
        _ = engine.record(event(0.2, evidence: .probable))
        _ = engine.record(event(0.4, evidence: .probable))
        _ = engine.record(event(0.6, context: 2))
        _ = engine.record(event(0.8, context: 2))
        _ = engine.record(event(1, evidence: .unknown))
        _ = engine.record(event(1.2, context: 2))
        let result = engine.snapshot(now: 1.2)
        checkEqual(result.confirmed.keys, 4)
        checkEqual(result.probable.keys, 2)
        checkEqual(result.confirmed.intervals, 1)
        checkEqual(result.probable.intervals, 1)
    }

    @Test func testSourceChangesAndExplicitPauseBreakContinuity() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.record(event(0))
        _ = engine.record(event(0.2, source: .global))
        _ = engine.record(event(0.4, source: .global))
        engine.interrupt()
        _ = engine.record(event(0.6, source: .global))
        checkEqual(engine.snapshot(now: 0.6).confirmed.intervals, 1)
    }

    @Test func testCrossSourceOperationIDsDeduplicateBeforeInterrupt() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.record(event(0, id: 1))
        checkTrue(engine.record(event(0, category: .unknown, evidence: .unknown, source: .global, id: 1)).isEmpty)
        _ = engine.record(event(0.2, id: 2))
        let result = engine.snapshot(now: 0.2)
        checkEqual(result.confirmed.keys, 2)
        checkEqual(result.confirmed.intervals, 1)
        checkEqual(result.deduplicationCount, 1)
    }

    @Test func testAdaptiveModelRelearnsStableSlowerRhythmAndBackfills() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.1, 0.2, 0.3, 0.4], into: &engine)
        checkEqual(engine.snapshot(now: 0.4).threshold, 0.65, accuracy: 1e-8)
        type([1.2, 2.0], into: &engine)
        checkEqual(engine.snapshot(now: 2).pendingCount, 2)
        checkEqual(engine.snapshot(now: 2).confirmed.intervals, 4)
        let deltas = type([2.8], into: &engine)
        let result = engine.snapshot(now: 2.8)
        checkEqual(result.pendingCount, 0)
        checkEqual(result.confirmed.intervals, 7)
        checkEqual(result.confirmed.seconds, 2.8, accuracy: 1e-8)
        checkEqual(deltas.reduce(0) { $0 + $1.seconds }, 2.4, accuracy: 1e-8)
        checkEqual(result.median!, 0.8, accuracy: 1e-8)
        checkEqual(result.threshold, 2.4, accuracy: 1e-8)
    }

    @Test func testUIIdleChecksDoNotDiscardSlowerShadowCandidates() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.1, 0.2, 0.3, 0.4], into: &engine)
        for t in [1.2, 2.0, 2.8] {
            engine.advance(to: t - 0.01)
            _ = engine.record(event(t))
        }
        checkEqual(engine.snapshot(now: 2.8).confirmed.intervals, 7)
        checkEqual(engine.snapshot(now: 2.8).confirmed.seconds, 2.8, accuracy: 1e-8)
    }

    @Test func testIsolatedSlowGapNeverConnectsBursts() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.1, 0.2, 0.3, 0.4, 1.5, 1.6, 1.7], into: &engine)
        let result = engine.snapshot(now: 1.7).confirmed
        checkEqual(result.keys, 8)
        checkEqual(result.intervals, 6)
        checkEqual(result.seconds, 0.6, accuracy: 1e-8)
    }

    @Test func testClockCorrectionDoesNotCreateDuration() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.record(event(0))
        _ = engine.record(event(0.2, date: base.addingTimeInterval(3_600)))
        _ = engine.record(event(0.4, date: base.addingTimeInterval(3_600.2)))
        let result = engine.snapshot(now: 0.4).confirmed
        checkEqual(result.keys, 3)
        checkEqual(result.intervals, 1)
        checkEqual(result.seconds, 0.2, accuracy: 1e-8)
    }

    @Test func testBackwardMonotonicTimestampBreaksRatherThanSubtracts() {
        var engine = StatisticsEngine(timeZone: utc)
        type([10, 9, 9.2], into: &engine)
        let result = engine.snapshot(now: 9.2).confirmed
        checkEqual(result.keys, 3)
        checkEqual(result.intervals, 1)
        checkEqual(result.seconds, 0.2, accuracy: 1e-8)
    }

    @Test func testCrossMidnightSplitsSecondsAndNumeratorWeight() {
        var engine = StatisticsEngine(timeZone: utc)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
        _ = engine.record(event(0, date: midnight.addingTimeInterval(-0.1)))
        let deltas = engine.record(event(0.2, date: midnight.addingTimeInterval(0.1)))
        let intervals = deltas.filter { $0.intervals > 0 }
        checkEqual(intervals.map(\.day), ["2026-10-22", "2026-10-23"])
        checkEqual(intervals.reduce(0) { $0 + $1.seconds }, 0.2, accuracy: 1e-6)
        checkEqual(intervals.reduce(0) { $0 + $1.intervals }, 1, accuracy: 1e-6)
        checkEqual(intervals[0].intervals, 0.5, accuracy: 1e-6)
    }

    @Test func testTimezoneChangeAndRuleChangeBreakAndPreserveTotals() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2], into: &engine)
        engine.updateTimeZone(TimeZone(identifier: "Asia/Shanghai")!)
        _ = engine.record(event(0.4))
        engine.updateConfig(SegmentationConfig(maximumGap: 2, ruleID: "adaptive-v1-cap2"))
        let delta = engine.record(event(0.6))
        checkEqual(engine.snapshot(now: 0.6).confirmed.intervals, 1)
        checkEqual(engine.snapshot(now: 0.6).confirmed.keys, 4)
        checkEqual(delta.first?.ruleID, "adaptive-v1-cap2")
        checkEqual(delta.first?.timezoneID, "Asia/Shanghai")
    }

    @Test func testBoundedModelDedupAndCandidatesAfterManyEvents() {
        var engine = StatisticsEngine(config: SegmentationConfig(sampleCapacity: 16), timeZone: utc)
        for i in 0..<10_000 { _ = engine.record(event(Double(i) * 0.1, id: UInt64(i))) }
        let result = engine.snapshot(now: 999.9)
        checkEqual(result.confirmed.keys, 10_000)
        checkEqual(result.confirmed.intervals, 9_999)
        checkEqual(result.sampleCount, 16)
        checkLessThanOrEqual(result.pendingCount, 3)
        // An old ID falls outside bounded dedup; caller must issue IDs per physical operation.
        _ = engine.record(event(1_000, id: 0))
        checkEqual(engine.snapshot(now: 1_000).confirmed.keys, 10_001)
    }

    @Test func testInvalidTimesAreRejectedAndInterrupt() {
        var engine = StatisticsEngine(timeZone: utc)
        _ = engine.record(event(0))
        checkTrue(engine.record(event(.nan)).isEmpty)
        _ = engine.record(event(0.2))
        checkEqual(engine.snapshot(now: 0.2).confirmed.intervals, 0)
    }

    @Test func testDeltasCodableRoundtripPreservesFractionalNumerators() throws {
        let delta = DailyDelta(day: "2026-10-22", timezoneID: "Asia/Shanghai", ruleID: "adaptive-v1",
                               evidence: .probable, keys: 9, edits: 2, composition: 3,
                               intervals: 0.5, seconds: 0.1, newIntervals: 0.5, newSeconds: 0.1)
        checkEqual(try JSONDecoder().decode(DailyDelta.self, from: JSONEncoder().encode(delta)), delta)
    }
}
