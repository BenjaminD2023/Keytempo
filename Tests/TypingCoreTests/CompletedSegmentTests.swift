import Foundation
import Testing
@testable import TypingCore

struct CompletedSegmentTests {
    private let base = Date(timeIntervalSince1970: 1_767_225_600)
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func event(_ time: Double, category: InputCategory = .textEntry,
                       language: String = "en", evidence: Evidence = .confirmed,
                       context: UInt64 = 1, source: InputSource = .adapter,
                       characters: Int? = nil) -> ClassifiedInput {
        ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: context,
                        category: category, evidence: evidence, source: source,
                        language: language, committedCharacters: characters)
    }

    private func type(_ times: [Double], into engine: inout StatisticsEngine) {
        for time in times { _ = engine.record(event(time)) }
    }

    @Test func completionWaitsForSafeBoundAndNeverAddsConfirmationTime() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
        let before = engine.snapshot(now: 0.8).confirmed
        checkNil(engine.latestCompletedSegment)
        checkTrue(engine.completionPending)
        checkEqual(engine.completionDeadline!, 3.8, accuracy: 1e-9)
        engine.advance(to: 1.5)
        checkEqual(engine.snapshot(now: 1.5).phase, .idle)
        checkNil(engine.latestCompletedSegment)
        checkTrue(engine.completionPending)
        engine.advance(to: 3.8)
        checkNil(engine.latestCompletedSegment)
        engine.advance(to: 3.81)
        let completed = engine.latestCompletedSegment!
        checkEqual(completed.kpm!, 300, accuracy: 1e-8)
        checkEqual(completed.intervals, 4)
        checkEqual(completed.seconds, 0.8, accuracy: 1e-9)
        checkEqual(completed.endTime, 0.8)
        checkEqual(completed.endDate, base.addingTimeInterval(0.8))
        checkEqual(completed.language, "en")
        checkEqual(completed.evidence, .confirmed)
        checkTrue(!engine.completionPending)
        checkNil(engine.completionDeadline)
        checkEqual(engine.snapshot(now: 3.81).confirmed, before)
        for time in [30.0, 500, 10_000] { engine.advance(to: time) }
        engine.interrupt()
        checkEqual(engine.latestCompletedSegment, completed)
        checkEqual(engine.snapshot(now: 10_000).confirmed, before)
    }

    @Test func nextBurstDoesNotReplaceCompletedRateUntilFinished() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
        engine.advance(to: 4)
        let previous = engine.latestCompletedSegment!
        for time in [10.0, 10.5, 11, 11.5, 12] {
            _ = engine.record(event(time))
            checkEqual(engine.latestCompletedSegment, previous)
        }
        checkEqual(engine.snapshot(now: 12).confirmed.recentRhythmKPM!, 120, accuracy: 1e-8)
        engine.advance(to: 15.1)
        checkEqual(engine.latestCompletedSegment!.revision, previous.revision + 1)
        checkEqual(engine.latestCompletedSegment!.kpm!, 120, accuracy: 1e-8)
        checkEqual(engine.latestCompletedSegment!.seconds, 2)
    }

    @Test func longGapCompletesPreviousBurstBeforeNewFirstKey() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8, 10], into: &engine)
        let completed = engine.latestCompletedSegment!
        checkEqual(completed.kpm!, 300, accuracy: 1e-8)
        checkEqual(completed.endTime, 0.8)
        checkEqual(engine.snapshot(now: 10).confirmed.keys, 6)
        checkEqual(engine.snapshot(now: 10).confirmed.seconds, 0.8, accuracy: 1e-9)
        checkTrue(!engine.completionPending)
        engine.advance(to: 20)
        checkEqual(engine.latestCompletedSegment, completed)
    }

    @Test func excludedOperationsFinalizeWithoutCountingOrBridging() {
        for category in [InputCategory.command, .navigation, .generated, .unknown] {
            var engine = StatisticsEngine(timeZone: utc)
            type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
            let deltas = engine.record(event(1, category: category, characters: 500))
            checkTrue(deltas.isEmpty)
            let completed = engine.latestCompletedSegment!
            checkEqual(completed.kpm!, 300, accuracy: 1e-8)
            checkEqual(completed.endTime, 0.8)
            checkEqual(engine.snapshot(now: 1).confirmed.keys, 5)
            checkEqual(engine.snapshot(now: 1).confirmed.seconds, 0.8, accuracy: 1e-9)
            engine.interrupt()
            checkEqual(engine.latestCompletedSegment, completed)
        }
    }

    @Test func contextLanguageSourceAndEvidenceChangesCompleteOldMetadata() {
        let replacements = [
            event(1, context: 2),
            event(1, language: "zh"),
            event(1, source: .global),
            event(1, evidence: .probable)
        ]
        for replacement in replacements {
            var engine = StatisticsEngine(timeZone: utc)
            type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
            _ = engine.record(replacement)
            let completed = engine.latestCompletedSegment!
            checkEqual(completed.language, "en")
            checkEqual(completed.evidence, .confirmed)
            checkEqual(completed.endTime, 0.8)
            checkEqual(completed.kpm!, 300, accuracy: 1e-8)
            checkTrue(!engine.completionPending)
        }
    }

    @Test func settingsTimezoneAndExplicitPauseCompleteUsingOriginalConfiguration() {
        for reason in 0..<3 {
            var engine = StatisticsEngine(timeZone: utc)
            type([0, 0.2, 0.4, 0.6, 0.8], into: &engine)
            if reason == 0 { engine.interrupt() }
            else if reason == 1 { engine.updateTimeZone(TimeZone(secondsFromGMT: 3600)!) }
            else { engine.updateConfig(SegmentationConfig(maximumGap: 5, minimumIntervals: 10)) }
            checkEqual(engine.latestCompletedSegment!.kpm!, 300, accuracy: 1e-8)
            checkEqual(engine.latestCompletedSegment!.seconds, 0.8, accuracy: 1e-9)
        }
    }

    @Test func shortBurstReportsInsufficientDataAndSingletonInventsNothing() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2], into: &engine)
        engine.interrupt()
        let short = engine.latestCompletedSegment!
        checkNil(short.kpm)
        checkNil(short.cpm)
        checkEqual(short.intervals, 1)
        checkEqual(short.seconds, 0.2, accuracy: 1e-9)
        _ = engine.record(event(10, characters: 20))
        engine.advance(to: 100)
        checkEqual(engine.latestCompletedSegment, short)
        checkEqual(engine.snapshot(now: 100).confirmed.keys, 3)
        checkEqual(engine.snapshot(now: 100).confirmed.characters, 20)
    }

    @Test func completionDoesNotDiscardSlowerCandidatesOrChangeBackfillMath() {
        var engine = StatisticsEngine(config: SegmentationConfig(minimumSeconds: 0.1), timeZone: utc)
        type([0, 0.1, 0.2, 0.3, 0.4], into: &engine)
        for time in [1.2, 2.0] {
            engine.advance(to: time - 0.01)
            _ = engine.record(event(time))
            checkNil(engine.latestCompletedSegment)
        }
        engine.advance(to: 2.79)
        _ = engine.record(event(2.8))
        let fast = engine.latestCompletedSegment!
        checkEqual(fast.kpm!, 600, accuracy: 1e-8)
        checkEqual(fast.endTime, 0.4)
        checkEqual(engine.snapshot(now: 2.8).confirmed.intervals, 7)
        checkEqual(engine.snapshot(now: 2.8).confirmed.seconds, 2.8, accuracy: 1e-8)
        _ = engine.record(event(3.6))
        checkEqual(engine.latestCompletedSegment, fast)
        engine.advance(to: 6.61)
        let slow = engine.latestCompletedSegment!
        checkEqual(slow.revision, fast.revision + 1)
        checkEqual(slow.kpm!, 75, accuracy: 1e-8)
        checkEqual(slow.intervals, 4)
        checkEqual(slow.seconds, 3.2, accuracy: 1e-8)
    }

    @Test func isolatedSlowGapCompletesOnlyTheAcceptedIntervals() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8, 1.8, 2.0], into: &engine)
        let first = engine.latestCompletedSegment!
        checkEqual(first.kpm!, 300, accuracy: 1e-8)
        checkEqual(first.endTime, 0.8)
        type([2.2, 2.4, 2.6], into: &engine)
        engine.advance(to: 5.61)
        let second = engine.latestCompletedSegment!
        checkEqual(second.intervals, 4)
        checkEqual(second.seconds, 0.8, accuracy: 1e-8)
        checkEqual(engine.snapshot(now: 5.61).confirmed.keys, 10)
        checkEqual(engine.snapshot(now: 5.61).confirmed.intervals, 8)
        checkEqual(engine.snapshot(now: 5.61).confirmed.seconds, 1.6, accuracy: 1e-8)
    }

    @Test func unresolvedCandidatesDoNotMoveCompletionEndpointOrDenominator() {
        var engine = StatisticsEngine(timeZone: utc)
        type([0, 0.2, 0.4, 0.6, 0.8, 1.8], into: &engine)
        checkNil(engine.latestCompletedSegment)
        engine.advance(to: 4.81)
        let completed = engine.latestCompletedSegment!
        checkEqual(completed.endTime, 0.8)
        checkEqual(completed.seconds, 0.8, accuracy: 1e-9)
        checkEqual(completed.kpm!, 300, accuracy: 1e-8)
        checkTrue(!engine.completionPending)
    }

    @Test func completedCPMUsesWholeCommitCoverageAndIncludesEditingTime() {
        var engine = StatisticsEngine(timeZone: utc)
        let characters = [10, 0, 2, 0, 3]
        for (index, time) in [0.0, 0.2, 0.4, 0.6, 0.8].enumerated() {
            _ = engine.record(event(time, category: index == 3 ? .editing : .composition,
                                    language: "zh", characters: characters[index]))
        }
        engine.interrupt()
        let completed = engine.latestCompletedSegment!
        checkEqual(completed.cpm!, 375, accuracy: 1e-8)
        checkEqual(completed.ratedCharacters, 5)
        checkEqual(completed.characterIntervals, 4)
        checkEqual(completed.characterSeconds, 0.8, accuracy: 1e-9)
        checkEqual(engine.snapshot(now: 1).confirmed.characters, 15)
    }

    @Test func probableCompletionNeverAcquiresCharacterCoverage() {
        var engine = StatisticsEngine(timeZone: utc)
        for time in [0.0, 0.2, 0.4, 0.6, 0.8] {
            _ = engine.record(event(time, language: "zh", evidence: .probable, source: .global, characters: 50))
        }
        engine.interrupt()
        let completed = engine.latestCompletedSegment!
        checkEqual(completed.evidence, .probable)
        checkEqual(completed.kpm!, 300, accuracy: 1e-8)
        checkNil(completed.cpm)
        checkEqual(completed.characterSeconds, 0)
        checkEqual(completed.ratedCharacters, 0)
    }
}
