import Foundation
import Testing
@testable import TypingCore

struct ActivityAnalyticsTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func input(_ time: Double, base: Date, context: UInt64 = 1,
                       category: InputCategory = .textEntry, evidence: Evidence = .probable,
                       source: InputSource = .global, operationID: UInt64? = nil) -> ClassifiedInput {
        ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: context,
                        category: category, evidence: evidence, source: source,
                        operationID: operationID, language: "mul")
    }
    private func record(_ input: ClassifiedInput, engine: inout StatisticsEngine,
                        tracker: inout ActivityTracker, app: String? = nil, perApp: Bool = false) -> ActivityBatch {
        tracker.record(input: input, result: engine.recordWithIntervals(input),
                       rule: engine.config.ruleID, applicationID: app, perAppEnabled: perApp)
    }
    private func totals(_ rows: [HourlyActivity], app: String = "") -> RhythmTotals {
        var result = RhythmTotals()
        for row in rows where row.applicationID == app { result.merge(row.totals) }
        return result
    }

    @Test func hourlyAndSessionCountsUseObservedIntervalsWithoutIdleTail() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        var hours: [HourlyActivity] = []
        for time in [0.0, 0.2, 0.4, 0.6, 0.8] {
            hours += record(input(time, base: base), engine: &engine, tracker: &tracker).hourly
        }
        let summary = totals(hours)
        checkEqual(summary.keys, 5); checkEqual(summary.intervals, 4)
        checkEqual(summary.seconds, 0.8, accuracy: 1e-6)
        checkEqual(summary.squaredIntervalSeconds, 0.16, accuracy: 1e-6)
        checkEqual(summary.wpm!, 60, accuracy: 1e-4)
        let before = tracker.currentSession!
        engine.advance(to: 100)
        let closed = tracker.finish(reason: "pause").sessions[0]
        checkEqual(closed.end, base.addingTimeInterval(0.8))
        checkEqual(closed.totals, before.totals)
        checkEqual(closed.endReason, "pause")
        checkTrue(tracker.finish(reason: "exit").isEmpty)
    }

    @Test func singleInputCountsButDoesNotInventRhythmOrSkill() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        let batch = record(input(0, base: base), engine: &engine, tracker: &tracker)
        checkEqual(totals(batch.hourly).keys, 1)
        checkEqual(tracker.currentSession!.start, base)
        checkEqual(tracker.currentSession!.end, base)
        checkNil(tracker.currentSession!.totals.wpm)
        checkNil(tracker.currentSession!.totals.consistency)
        checkNil(tracker.currentSession!.totals.score)
        checkEqual(tracker.sessionDeadline, 300)
        checkTrue(tracker.finishIfIdle(at: 299.999).isEmpty)
        let stopped = tracker.finishIfIdle(at: 300).sessions[0]
        checkEqual(stopped.start, base); checkEqual(stopped.end, base)
        checkEqual(stopped.totals.keys, 1)
        checkNil(tracker.sessionDeadline)
    }

    @Test func hourAndMidnightSplitsPreserveEveryMomentAndNoExtraBoundaryKey() {
        for baseText in ["2026-10-23T12:59:59Z", "2026-10-23T23:59:59Z"] {
            let base = date(baseText).addingTimeInterval(0.9)
            var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
            let first = record(input(0, base: base), engine: &engine, tracker: &tracker)
            let second = record(input(0.2, base: base), engine: &engine, tracker: &tracker)
            let rows = first.hourly + second.hourly
            checkEqual(Set(rows.map(\.bucketStart)).count, 2)
            let all = totals(rows)
            checkEqual(all.keys, 2); checkEqual(all.intervals, 1, accuracy: 1e-6)
            checkEqual(all.seconds, 0.2, accuracy: 1e-6)
            checkEqual(all.squaredIntervalSeconds, 0.04, accuracy: 1e-6)
            if baseText.contains("23:59") {
                checkEqual(second.sessions.count, 2)
                let prior = second.sessions.first { $0.endReason == "dayBoundary" }!
                let current = tracker.currentSession!
                checkEqual(prior.end, date("2026-10-24T00:00:00Z"))
                checkEqual(current.start, prior.end)
                checkEqual(prior.totals.keys + current.totals.keys, 2)
                checkEqual(prior.totals.seconds + current.totals.seconds, 0.2, accuracy: 1e-6)
            }
        }
    }

    @Test func repeatedDSTHourHasDistinctAbsoluteBucketsWithoutDuplicatingTime() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let base = date("2026-11-01T08:59:59Z").addingTimeInterval(0.9)
        var engine = StatisticsEngine(timeZone: zone), tracker = ActivityTracker(timeZone: zone)
        let first = record(input(0, base: base), engine: &engine, tracker: &tracker)
        let second = record(input(0.2, base: base), engine: &engine, tracker: &tracker)
        let starts = Set((first.hourly + second.hourly).map(\.bucketStart)).sorted()
        checkEqual(starts.count, 2)
        checkEqual(starts[1].timeIntervalSince(starts[0]), 3_600, accuracy: 1e-6)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        checkEqual(calendar.component(.hour, from: starts[0]), 1)
        checkEqual(calendar.component(.hour, from: starts[1]), 1)
        checkEqual(totals(first.hourly + second.hourly).seconds, 0.2, accuracy: 1e-6)
        checkEqual(tracker.currentSession!.totals.keys, 2)
    }

    @Test func delayedSlowRhythmBackfillUpdatesTheOriginalPreviousDaySession() {
        let base = date("2026-10-23T23:59:59Z").addingTimeInterval(0.8)
        var engine = StatisticsEngine(config: SegmentationConfig(minimumGap: 0.1, coldStartGap: 0.1), timeZone: utc)
        var tracker = ActivityTracker(timeZone: utc)
        _ = record(input(0, base: base), engine: &engine, tracker: &tracker)
        let oldID = tracker.currentSession!.id
        _ = record(input(0.4, base: base), engine: &engine, tracker: &tracker)
        let newID = tracker.currentSession!.id
        _ = record(input(0.8, base: base), engine: &engine, tracker: &tracker)
        let backfilled = record(input(1.2, base: base), engine: &engine, tracker: &tracker)
        checkEqual(backfilled.sessions.count, 2)
        let old = backfilled.sessions.first { $0.id == oldID }!
        let current = backfilled.sessions.first { $0.id == newID }!
        checkEqual(old.endReason, "dayBoundary")
        checkEqual(old.totals.keys, 1); checkEqual(current.totals.keys, 3)
        checkEqual(old.totals.seconds, 0.2, accuracy: 1e-6)
        checkEqual(current.totals.seconds, 1, accuracy: 1e-6)
        checkEqual(old.totals.intervals + current.totals.intervals, 3, accuracy: 1e-6)
        checkEqual(old.totals.squaredIntervalSeconds + current.totals.squaredIntervalSeconds, 0.48, accuracy: 1e-6)
        checkEqual(tracker.currentSession!.id, newID)
    }

    @Test func sessionsGroupBurstsAndAppSwitchesButSplitAfterFiveMinutes() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        _ = record(input(0, base: base), engine: &engine, tracker: &tracker, app: "chat")
        _ = record(input(0.2, base: base), engine: &engine, tracker: &tracker, app: "chat")
        let id = tracker.currentSession!.id
        engine.interrupt()
        _ = record(input(1, base: base, context: 2), engine: &engine, tracker: &tracker, app: "editor")
        _ = record(input(1.2, base: base, context: 2), engine: &engine, tracker: &tracker, app: "editor")
        checkEqual(tracker.currentSession!.id, id)
        checkEqual(tracker.currentSession!.totals.keys, 4)
        checkEqual(tracker.currentSession!.totals.intervals, 2)
        checkEqual(tracker.currentSession!.totals.seconds, 0.4, accuracy: 1e-6)
        let batch = record(input(302, base: base, context: 2), engine: &engine, tracker: &tracker)
        let prior = batch.sessions.first { $0.id == id }!
        checkEqual(prior.end, base.addingTimeInterval(1.2))
        checkEqual(prior.endReason, "inactivity")
        checkEqual(prior.totals.keys, 4)
        checkTrue(tracker.currentSession!.id != id)
        checkEqual(tracker.currentSession!.totals.keys, 1)
        checkEqual(tracker.currentSession!.totals.seconds, 0)
    }

    @Test func compositionAndEditsAreActivityButUnknownDuplicateAndAdapterAreNot() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        _ = record(input(0, base: base, category: .composition, operationID: 1), engine: &engine, tracker: &tracker)
        _ = record(input(0.2, base: base, category: .editing, operationID: 2), engine: &engine, tracker: &tracker)
        let before = tracker.currentSession!
        let duplicate = record(input(0.4, base: base, operationID: 2), engine: &engine, tracker: &tracker)
        let command = record(input(0.6, base: base, category: .command, evidence: .unknown), engine: &engine, tracker: &tracker)
        let adapter = record(input(0.8, base: base, evidence: .confirmed, source: .adapter), engine: &engine, tracker: &tracker)
        checkTrue(duplicate.isEmpty); checkTrue(command.isEmpty); checkTrue(adapter.isEmpty)
        checkEqual(tracker.currentSession!, before)
        checkEqual(tracker.finish(reason: "exit").sessions[0].end, base.addingTimeInterval(0.2))
    }

    @Test func perAppMetadataIsOptInAndDoesNotBackfillBeforeConsent() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        _ = record(input(0, base: base), engine: &engine, tracker: &tracker, app: "private.chat")
        let off = record(input(0.2, base: base), engine: &engine, tracker: &tracker, app: "private.chat")
        checkTrue(off.hourly.allSatisfy { $0.applicationID.isEmpty })
        tracker.resetApplicationAttribution()
        let enabled = record(input(0.4, base: base), engine: &engine, tracker: &tracker, app: "local.editor", perApp: true)
        checkEqual(totals(enabled.hourly, app: "local.editor").keys, 1)
        checkEqual(totals(enabled.hourly, app: "local.editor").seconds, 0)
        let next = record(input(0.6, base: base), engine: &engine, tracker: &tracker, app: "local.editor", perApp: true)
        checkEqual(totals(next.hourly, app: "local.editor").seconds, 0.2, accuracy: 1e-6)
        checkEqual(totals(next.hourly).seconds, 0.2, accuracy: 1e-6)
        let disabled = record(input(0.8, base: base), engine: &engine, tracker: &tracker, app: "local.editor")
        checkTrue(disabled.hourly.allSatisfy { $0.applicationID.isEmpty })
        let encoded = String(data: try! JSONEncoder().encode(tracker.currentSession!), encoding: .utf8)!
        checkTrue(!encoded.contains("private.chat") && !encoded.contains("local.editor"))
    }

    @Test func clockAndTimezoneChangesCloseAtLastObservedEvent() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        _ = record(input(0, base: base), engine: &engine, tracker: &tracker)
        var corrected = input(1, base: base); corrected.date = base.addingTimeInterval(3_600)
        let changed = record(corrected, engine: &engine, tracker: &tracker)
        let closed = changed.sessions.first { $0.endReason == "clockChanged" }!
        checkEqual(closed.start, base); checkEqual(closed.end, base)
        checkEqual(closed.totals.seconds, 0)
        let timezone = tracker.setTimeZone(TimeZone(identifier: "Asia/Shanghai")!)
        checkEqual(timezone.sessions[0].end, corrected.date)
        checkEqual(timezone.sessions[0].endReason, "timezoneChanged")
        checkNil(tracker.currentSession)
        checkTrue(tracker.setTimeZone(tracker.timeZone).isEmpty)
    }

    @Test func momentsCombineWithWeightingRatherThanAveragingConsistencyOrSpeed() {
        var combined = RhythmTotals(keys: 11, intervals: 10, seconds: 1, squaredIntervalSeconds: 0.1)
        combined.merge(RhythmTotals(keys: 11, intervals: 10, seconds: 5, squaredIntervalSeconds: 2.5))
        checkEqual(combined.keys, 22); checkEqual(combined.intervals, 20)
        checkEqual(combined.wpm!, 40, accuracy: 1e-9)
        checkEqual(combined.coefficientOfVariation!, 2.0 / 3, accuracy: 1e-9)
        checkEqual(combined.legacyIntervalConsistency!, 60, accuracy: 1e-9)
        checkNil(combined.consistency) // Interval moments are not rate samples.
    }

    @Test func practiceScoreRewardsDurationAndVolumeOverSlightSpeedDifference() {
        let sustained = RhythmTotals(keys: 7_501, intervals: 7_500, seconds: 1_800,
                                     squaredIntervalSeconds: 1_800 * 1_800 / 7_500)
        let fasterShort = RhythmTotals(keys: 2_751, intervals: 2_750, seconds: 600,
                                      squaredIntervalSeconds: 600 * 600 / 2_750)
        checkEqual(sustained.wpm!, 50, accuracy: 1e-9)
        checkEqual(fasterShort.wpm!, 55, accuracy: 1e-9)
        let longScore = sustained.score!, shortScore = fasterShort.score!
        checkTrue(longScore.speed < shortScore.speed)
        checkTrue(longScore.duration > shortScore.duration && longScore.volume > shortScore.volume)
        checkTrue(longScore.value > shortScore.value)
        checkEqual(longScore.value, (longScore.speed + longScore.consistency + longScore.duration + longScore.volume) / 4)
        checkEqual(TypingScore.version, "practice-v1")
        let capped = TypingScore(wpm: 200, consistency: 100, typingSeconds: 3_600, keys: 20_000)
        checkEqual(capped.value, 100)
    }

    @Test func legacyScoreKeepsIntervalConsistencyWhileNewMetricRequiresRateSamples() {
        let short = RhythmTotals(keys: 5, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.16)
        checkEqual(short.wpm!, 60, accuracy: 1e-9)
        checkNil(short.consistency); checkNil(short.score)
        let steady = RhythmTotals(keys: 21, intervals: 20, seconds: 4, squaredIntervalSeconds: 0.8)
        let varied = RhythmTotals(keys: 21, intervals: 20, seconds: 4, squaredIntervalSeconds: 1)
        checkNil(steady.consistency); checkNil(varied.consistency)
        checkEqual(steady.legacyIntervalConsistency!, 100, accuracy: 1e-6)
        checkTrue(varied.legacyIntervalConsistency! < steady.legacyIntervalConsistency!)
        checkEqual(steady.wpm!, varied.wpm!, accuracy: 1e-9)
        checkTrue(steady.score!.value > varied.score!.value)
        for invalid in [RhythmTotals(keys: -1), RhythmTotals(intervals: .infinity),
                        RhythmTotals(keys: 21, intervals: 20, seconds: 4, squaredIntervalSeconds: 0)] {
            checkNil(invalid.consistency); checkNil(invalid.score)
        }
    }

    @Test func invalidResultsCannotAllocateUnboundedIntervalsOrReviveOldInput() {
        let base = date("2026-10-23T12:00:00Z")
        var engine = StatisticsEngine(timeZone: utc), tracker = ActivityTracker(timeZone: utc)
        let first = input(0, base: base)
        let result = engine.recordWithIntervals(first)
        _ = tracker.record(input: first, result: result, rule: engine.config.ruleID)
        checkTrue(tracker.record(input: first, result: result, rule: engine.config.ruleID).isEmpty)
        let next = input(1, base: base)
        let many = Array(repeating: AcceptedTypingInterval(startTime: 0, endTime: 1, evidence: .probable, language: "mul", ruleID: engine.config.ruleID), count: 4)
        let malformed = StatisticsRecordResult(deltas: [DailyDelta(day: "2026-10-23", timezoneID: "GMT", ruleID: engine.config.ruleID, evidence: .probable, keys: 1)], acceptedIntervals: many)
        let batch = tracker.record(input: next, result: malformed, rule: engine.config.ruleID)
        checkEqual(totals(batch.hourly).keys, 1); checkEqual(totals(batch.hourly).intervals, 0)
        checkEqual(tracker.currentSession!.totals.keys, 2)
    }
}
