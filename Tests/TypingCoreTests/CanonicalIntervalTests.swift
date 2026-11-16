import Foundation
import Testing
@testable import TypingCore

struct CanonicalIntervalTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let rule = "canonical-interval-test"
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func smallClockCorrectionsKeepHourlyDailyAppSessionAndRewardAttributionAligned() {
        for midnight in [false, true] {
            for backfill in [false, true] {
                let base = date(midnight ? "2026-10-24T23:59:57Z" : "2026-10-24T12:59:57Z")
                    .addingTimeInterval(backfill ? 0.8 : 1.8)
                let times: [Double] = backfill ? [0, 0.8, 1.6, 2.4] : [0, 0.2, 0.4, 0.6, 0.8, 1]
                let config = SegmentationConfig(minimumGap: backfill ? 0.1 : 0.65,
                                                coldStartGap: backfill ? 0.1 : 1.5, ruleID: rule)
                var engine = StatisticsEngine(config: config, timeZone: utc)
                var tracker = ActivityTracker(timeZone: utc)
                var rewards = DailyRewardEngine(coverageStart: base, progressionTimeZone: utc)
                var legacyRewards = RewardEngine(coverageStart: base, progressionTimeZone: utc)
                let context = ImprovementContext(language: "en", inputMethod: "canonical-fixture",
                                                 measurementPolicy: rule, evidencePolicy: "global-probable-v1")
                var hours: [HourlyActivity] = [], sessions: [String: TypingSession] = [:]
                var deltas: [DailyDelta] = []
                for (index, time) in times.enumerated() {
                    let input = ClassifiedInput(time: time,
                        date: base.addingTimeInterval(time + (index == times.count - 1 ? 0.4 : 0)),
                        context: 1, category: .textEntry, evidence: .probable, source: .global, language: "en")
                    let result = engine.recordWithIntervals(input)
                    if backfill && index < 3 { checkTrue(result.acceptedIntervals.isEmpty) }
                    for interval in result.acceptedIntervals {
                        checkEqual(interval.startDate!, base.addingTimeInterval(interval.startTime))
                    }
                    deltas += result.deltas
                    let batch = tracker.record(input: input, result: result, rule: rule,
                                               applicationID: "test.editor", perAppEnabled: true)
                    hours += batch.hourly
                    for session in batch.sessions { sessions[session.id] = session }
                    rewards.record(input: input, result: result, rule: rule)
                    legacyRewards.record(input: input, result: result, context: context,
                                         pendingIntervalCount: engine.pendingProbableIntervals)
                }
                checkNil(rewards.error)
                checkNil(legacyRewards.error)
                let boundary = date(midnight ? "2026-10-25T00:00:00Z" : "2026-10-24T13:00:00Z")
                for app in ["", "test.editor"] {
                    let before = hours.filter { $0.applicationID == app && $0.bucketStart < boundary }
                        .reduce(into: RhythmTotals()) { $0.merge($1.totals) }
                    let after = hours.filter { $0.applicationID == app && $0.bucketStart >= boundary }
                        .reduce(into: RhythmTotals()) { $0.merge($1.totals) }
                    checkEqual(before.seconds, backfill ? 2.2 : 1, accuracy: 1e-6)
                    checkEqual(after.seconds, backfill ? 0.2 : 0, accuracy: 1e-6)
                    checkEqual(before.intervals, backfill ? 2.75 : 5, accuracy: 1e-6)
                    checkEqual(after.intervals, backfill ? 0.25 : 0, accuracy: 1e-6)
                    checkEqual(before.rateConsistency.count, backfill ? 2 : 1)
                    checkEqual(after.rateConsistency.count, 0)
                }
                let attributions = legacyRewards.unpersistedAwards.flatMap(\.attributions)
                let beforeTime = attributions.filter { $0.hour < boundary }.reduce(0) { $0 + $1.components.time }
                let afterTime = attributions.filter { $0.hour >= boundary }.reduce(0) { $0 + $1.components.time }
                let beforeSeconds = backfill ? 2.2 : 1.0, afterSeconds = backfill ? 0.2 : 0.0
                checkEqual(beforeTime, 60 * log1p(beforeSeconds / 3600), accuracy: 1e-7)
                checkEqual(afterTime, 60 * log1p(afterSeconds / (midnight ? 3600 : 3600 + beforeSeconds)), accuracy: 1e-7)
                checkEqual(sessions.values.reduce(0) { $0 + $1.totals.keys }, times.count)
                checkEqual(sessions.values.reduce(0) { $0 + $1.totals.seconds }, times.last!, accuracy: 1e-6)
                for (day, rows) in Dictionary(grouping: deltas, by: \.day) {
                    let actual = rewards.state.days[day]!.totals
                    checkEqual(actual.keys, rows.reduce(0) { $0 + $1.keys })
                    checkEqual(actual.intervals, rows.reduce(0) { $0 + $1.intervals }, accuracy: 1e-6)
                    checkEqual(actual.seconds, rows.reduce(0) { $0 + $1.seconds }, accuracy: 1e-6)
                    let legacy = legacyRewards.state.days[day]!
                    checkEqual(legacy.keys, rows.reduce(0) { $0 + $1.keys })
                    checkEqual(legacy.seconds, rows.reduce(0) { $0 + $1.seconds }, accuracy: 1e-6)
                }
            }
        }
    }

    @Test func legacyIntervalsWithoutWallAnchorsKeepTheirEventRelativeMapping() {
        let base = date("2026-10-24T12:00:00Z")
        var tracker = ActivityTracker(timeZone: utc)
        let first = ClassifiedInput(time: 0, date: base, context: 1, category: .textEntry,
                                    evidence: .probable, source: .global)
        let key = DailyDelta(day: "2026-10-24", timezoneID: utc.identifier, ruleID: rule,
                             evidence: .probable, keys: 1)
        _ = tracker.record(input: first, result: .init(deltas: [key], acceptedIntervals: []), rule: rule)
        let next = ClassifiedInput(time: 1, date: base.addingTimeInterval(1), context: 1,
                                   category: .textEntry, evidence: .probable, source: .global)
        let legacy = AcceptedTypingInterval(startTime: 0, endTime: 1, evidence: .probable,
                                            language: "en", ruleID: rule)
        checkNil(legacy.startDate)
        let batch = tracker.record(input: next, result: .init(deltas: [key], acceptedIntervals: [legacy]), rule: rule)
        checkEqual(batch.hourly.reduce(0) { $0 + $1.totals.seconds }, 1)
        checkEqual(tracker.currentSession!.start, base)
        checkEqual(tracker.currentSession!.end, next.date)
    }
}
