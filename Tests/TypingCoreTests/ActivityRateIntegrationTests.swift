import Foundation
import Testing
@testable import TypingCore

struct ActivityRateIntegrationTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let base = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!

    private func input(_ time: Double, context: UInt64 = 1, category: InputCategory = .textEntry) -> ClassifiedInput {
        ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: context, category: category,
                        evidence: category.isEffective ? .probable : .unknown, source: .global, language: "mul")
    }
    private func merged(_ rows: [HourlyActivity], applicationID: String = "") -> RhythmTotals {
        rows.filter { $0.applicationID == applicationID }.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
    }

    @Test func completeRateSecondsPersistAlongsideUnchangedIntervalMathAndScore() {
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        var rows = [HourlyActivity]()
        for i in 0...50 {
            let value = input(Double(i) / 5)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID).hourly
        }
        let total = merged(rows)
        #expect(total.keys == 51 && total.intervals == 50)
        #expect(abs(total.seconds - 10) < 1e-6 && abs(total.wpm! - 60) < 1e-6)
        #expect(total.rateConsistency.count == 10 && total.rateConsistency.intervals == 49)
        #expect(abs(total.consistency! - 100) < 1e-6)
        #expect(total.score!.consistency == total.legacyIntervalConsistency!)
        let moments = tracker.currentSession!.totals.rateConsistency
        engine.advance(to: 1000)
        #expect(tracker.currentSession!.totals.rateConsistency == moments)
        #expect(tracker.finish(reason: "idle").sessions[0].totals == total)
    }

    @Test func commandAndGapDiscardPartialSecondsWithoutInventingZeroBuckets() {
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        var rows = [HourlyActivity]()
        for time in [0.0, 0.2, 0.4] {
            let value = input(time)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID).hourly
        }
        let command = input(0.5, category: .command)
        #expect(tracker.record(input: command, result: engine.recordWithIntervals(command), rule: engine.config.ruleID).isEmpty)
        tracker.interruptConsistency()
        for i in 0...50 {
            let value = input(10 + Double(i) / 5, context: 2)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID).hourly
        }
        let total = merged(rows)
        #expect(total.keys == 54 && abs(total.seconds - 10.4) < 1e-6)
        #expect(total.rateConsistency.count == 10 && total.rateConsistency.sum == 600)
        #expect(abs(total.consistency! - 100) < 1e-6)
    }

    @Test func acceptedSlowRhythmBackfillBuildsRateSamplesAtOriginalTimes() {
        var engine = StatisticsEngine(config: SegmentationConfig(minimumGap: 0.1, coldStartGap: 0.1), timeZone: utc)
        var tracker = ActivityTracker(timeZone: utc)
        var rows = [HourlyActivity]()
        for i in 0...30 {
            let value = input(Double(i) * 0.4)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID).hourly
        }
        let total = merged(rows)
        #expect(total.keys == 31 && total.intervals == 30)
        #expect(abs(total.seconds - 12) < 1e-6)
        #expect(total.rateConsistency.count == 12 && total.rateConsistency.intervals == 29)
        #expect(total.rateConsistency.sum == 360)
        // Even 0.4-second spacing alternates two and three operations in
        // one-second bins. This is a rate metric, not interval regularity.
        #expect(total.consistency == 80)
        #expect(abs(total.legacyIntervalConsistency! - 100) < 1e-5)
    }

    @Test func appRateSamplesRequireContinuousConsentAndKnownAttribution() {
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        var rows = [HourlyActivity]()
        for i in 0..<30 {
            let value = input(Double(i) / 5)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID,
                                   applicationID: "org.example.Editor").hourly
        }
        tracker.resetApplicationAttribution()
        for i in 30...80 {
            let value = input(Double(i) / 5)
            rows += tracker.record(input: value, result: engine.recordWithIntervals(value), rule: engine.config.ruleID,
                                   applicationID: "org.example.Editor", perAppEnabled: true).hourly
        }
        #expect(merged(rows).rateConsistency.count == 16)
        let app = merged(rows, applicationID: "org.example.Editor")
        #expect(app.keys == 51 && abs(app.seconds - 10) < 1e-6)
        #expect(app.rateConsistency.count == 10 && app.rateConsistency.intervals == 49)
        #expect(abs(app.consistency! - 100) < 1e-6)
        tracker.resetApplicationAttribution()
        let next = input(16.2)
        let off = tracker.record(input: next, result: engine.recordWithIntervals(next), rule: engine.config.ruleID,
                                 applicationID: "org.example.Editor", perAppEnabled: false)
        #expect(off.hourly.allSatisfy { $0.applicationID.isEmpty })
    }

    @Test func legacyCodableAndMergedCoverageNeverFabricateRateSamplesOrChangeScore() throws {
        let old = Data("{\"keys\":21,\"intervals\":20,\"seconds\":4,\"squaredIntervalSeconds\":0.8}".utf8)
        var total = try JSONDecoder().decode(RhythmTotals.self, from: old)
        #expect(total.rateConsistency == .init() && total.consistency == nil)
        let score = total.score
        total.merge(RhythmTotals(rateConsistency: .init(count: 10, intervals: 49, sum: 600, squaredSum: 36000)))
        #expect(total.consistency == 100 && total.score == score)
        #expect(total.keys == 21 && total.intervals == 20 && total.seconds == 4)
        #expect(try JSONDecoder().decode(RhythmTotals.self, from: JSONEncoder().encode(total)) == total)
    }
}
