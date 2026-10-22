import Foundation
import Testing
@testable import TypingCore

final class CharacterStatisticsTests {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let utc = TimeZone(secondsFromGMT: 0)!
    var config: SegmentationConfig { SegmentationConfig(minimumIntervals: 2, minimumSeconds: 0.1) }

    func input(_ time: Double, characters: Int?, language: String = "zh-Hans",
               category: InputCategory = .composition, evidence: Evidence = .confirmed,
               source: InputSource = .adapter, date: Date? = nil) -> ClassifiedInput {
        ClassifiedInput(time: time, date: date ?? base.addingTimeInterval(time), context: 1,
                        category: category, evidence: evidence, source: source,
                        language: language, committedCharacters: characters)
    }

    @Test func testChineseBatchUsesEntireCommitAndObservedProcessTime() {
        var engine = StatisticsEngine(config: config, timeZone: utc)
        var deltas = [DailyDelta]()
        for (time, characters) in [(0.0, 0), (0.2, 0), (0.4, 2)] {
            deltas += engine.record(input(time, characters: characters))
        }
        let result = engine.snapshot(now: 0.4).confirmed
        checkEqual(result.keys, 3)
        checkEqual(result.characters, 2)
        checkEqual(result.characterCoveredKeys, 3)
        checkEqual(result.characterIntervals, 2)
        checkEqual(result.ratedCharacters, 2)
        checkEqual(result.characterSeconds, 0.4, accuracy: 1e-8)
        checkEqual(result.characterCPM!, 300, accuracy: 1e-6)
        checkEqual(result.recentCharacterCPM!, 300, accuracy: 1e-6)
        checkEqual(result.recentLanguage, "zh-Hans")
        checkTrue(deltas.allSatisfy { $0.language == "zh-Hans" })
        checkEqual(deltas.reduce(0) { $0 + $1.characters }, 2)
        checkEqual(deltas.reduce(0) { $0 + $1.ratedCharacters }, 2)
    }

    @Test func testFirstCommitCountsButCannotInventCharacterRate() {
        let oneInterval = SegmentationConfig(minimumIntervals: 1, minimumSeconds: 0.1)
        var engine = StatisticsEngine(config: oneInterval, timeZone: utc)
        _ = engine.record(input(0, characters: 3))
        let first = engine.snapshot(now: 0).confirmed
        checkEqual(first.characters, 3)
        checkEqual(first.ratedCharacters, 0)
        checkEqual(first.characterSeconds, 0)
        checkNil(first.characterCPM)
        checkNil(first.recentCharacterCPM)
        _ = engine.record(input(0.2, characters: 1))
        let next = engine.snapshot(now: 0.2).confirmed
        checkEqual(next.characters, 4)
        checkEqual(next.ratedCharacters, 1)
        checkEqual(next.characterCPM!, 300, accuracy: 1e-6)
    }

    @Test func testEditingTimeRemainsInCharacterProcessRate() {
        var engine = StatisticsEngine(config: config, timeZone: utc)
        _ = engine.record(input(0, characters: 0))
        _ = engine.record(input(0.2, characters: 2))
        _ = engine.record(input(0.4, characters: 0, category: .editing))
        _ = engine.record(input(0.6, characters: 2))
        let result = engine.snapshot(now: 0.6).confirmed
        checkEqual(result.characters, 4)
        checkEqual(result.edits, 1)
        checkEqual(result.characterIntervals, 3)
        checkEqual(result.characterSeconds, 0.6, accuracy: 1e-8)
        checkEqual(result.characterCPM!, 400, accuracy: 1e-6)
    }

    @Test func testExcludedOperationsNeverCountCharactersOrBridgeTiming() {
        for category in [InputCategory.command, .navigation, .generated, .unknown] {
            var engine = StatisticsEngine(config: config, timeZone: utc)
            _ = engine.record(input(0, characters: 0))
            _ = engine.record(input(0.2, characters: 1))
            checkTrue(engine.record(input(0.3, characters: 100, category: category)).isEmpty)
            _ = engine.record(input(0.4, characters: 2))
            _ = engine.record(input(0.6, characters: 3))
            let result = engine.snapshot(now: 0.6).confirmed
            checkEqual(result.keys, 4)
            checkEqual(result.characters, 6)
            checkEqual(result.ratedCharacters, 4)
            checkEqual(result.characterIntervals, 2)
            checkEqual(result.characterSeconds, 0.4, accuracy: 1e-8)
            checkEqual(result.characterCPM!, 600, accuracy: 1e-6)
        }
    }

    @Test func testUncoveredAndInvalidCountsNeverMasqueradeAsObservedZero() {
        for unavailable: Int? in [nil, -1] {
            var engine = StatisticsEngine(config: config, timeZone: utc)
            _ = engine.record(input(0, characters: 0))
            _ = engine.record(input(0.2, characters: unavailable))
            _ = engine.record(input(0.4, characters: 2))
            _ = engine.record(input(0.6, characters: 3))
            let result = engine.snapshot(now: 0.6).confirmed
            checkEqual(result.characters, 5)
            checkEqual(result.characterCoveredKeys, 3)
            checkEqual(result.intervals, 3)
            checkEqual(result.characterIntervals, 1)
            checkEqual(result.ratedCharacters, 3)
            checkEqual(result.characterSeconds, 0.2, accuracy: 1e-8)
            checkNil(result.characterCPM) // One covered interval is insufficient.
        }
        var probable = StatisticsEngine(config: config, timeZone: utc)
        for time in [0.0, 0.2, 0.4] {
            _ = probable.record(input(time, characters: 5, evidence: .probable, source: .global))
        }
        let result = probable.snapshot(now: 0.4).probable
        checkEqual(result.keys, 3)
        checkEqual(result.characters, 0)
        checkEqual(result.characterCoveredKeys, 0)
        checkEqual(result.characterIntervals, 0)
        checkNil(result.characterCPM)
    }

    @Test func testLanguageChangeResetsSegmentAndModelEvenWhenContextIsReused() {
        var engine = StatisticsEngine(config: config, timeZone: utc)
        for time in [0.0, 0.1, 0.2, 0.3, 0.4] {
            _ = engine.record(input(time, characters: 1))
        }
        checkEqual(engine.snapshot(now: 0.4).sampleCount, 4)
        let english = engine.record(input(0.6, characters: 1, language: "en", category: .textEntry))
        let boundary = engine.snapshot(now: 0.6)
        checkEqual(boundary.sampleCount, 0)
        checkEqual(boundary.confirmed.characterIntervals, 4)
        checkEqual(boundary.confirmed.recentLanguage, "en")
        checkNil(boundary.confirmed.recentCharacterCPM)
        checkTrue(english.allSatisfy { $0.language == "en" && $0.characterSeconds == 0 })
        _ = engine.record(input(0.8, characters: 1, language: "en", category: .textEntry))
        _ = engine.record(input(1, characters: 1, language: "en", category: .textEntry))
        let recent = engine.snapshot(now: 1).confirmed
        checkEqual(recent.characters, 8)
        checkEqual(recent.recentCharacterCPM!, 300, accuracy: 1e-6)
    }

    @Test func testCharacterIntervalsNeverCrossSourcesOrEvidence() {
        let oneInterval = SegmentationConfig(minimumIntervals: 1, minimumSeconds: 0.1)
        var engine = StatisticsEngine(config: oneInterval, timeZone: utc)
        _ = engine.record(input(0, characters: 0))
        _ = engine.record(input(0.2, characters: 1, source: .global))
        checkEqual(engine.snapshot(now: 0.2).confirmed.characterIntervals, 0)
        _ = engine.record(input(0.4, characters: 2, source: .global))
        checkEqual(engine.snapshot(now: 0.4).confirmed.characterIntervals, 1)
        _ = engine.record(input(0.6, characters: 50, evidence: .probable, source: .global))
        _ = engine.record(input(0.8, characters: 3))
        let result = engine.snapshot(now: 0.8)
        checkEqual(result.confirmed.characters, 6)
        checkEqual(result.confirmed.ratedCharacters, 2)
        checkEqual(result.confirmed.characterIntervals, 1)
        checkEqual(result.probable.characters, 0)
        checkNil(result.confirmed.recentCharacterCPM)
    }

    @Test func testCharacterRateFreezesWithoutNewEvents() {
        var engine = StatisticsEngine(config: config, timeZone: utc)
        _ = engine.record(input(0, characters: 0))
        _ = engine.record(input(0.2, characters: 0))
        _ = engine.record(input(0.4, characters: 5))
        let initial = engine.snapshot(now: 0.4).confirmed
        for time in [5.4, 30.4, 60_000] {
            engine.advance(to: time)
            let result = engine.snapshot(now: time)
            checkEqual(result.confirmed, initial)
            checkEqual(result.phase, .idle)
        }
    }

    @Test func testSlowerCandidateBackfillRatesEachCommitExactlyOnce() {
        var engine = StatisticsEngine(config: config, timeZone: utc)
        var deltas = [DailyDelta]()
        for time in [0.0, 0.1, 0.2, 0.3, 0.4] {
            deltas += engine.record(input(time, characters: 1))
        }
        deltas += engine.record(input(1.2, characters: 2))
        deltas += engine.record(input(2, characters: 3))
        checkEqual(engine.snapshot(now: 2).confirmed.characters, 10)
        checkEqual(engine.snapshot(now: 2).confirmed.ratedCharacters, 4)
        let backfill = engine.record(input(2.8, characters: 5))
        deltas += backfill
        let result = engine.snapshot(now: 2.8).confirmed
        checkEqual(result.characters, 15)
        checkEqual(result.ratedCharacters, 14)
        checkEqual(result.characterIntervals, 7)
        checkEqual(result.characterSeconds, 2.8, accuracy: 1e-8)
        checkEqual(deltas.reduce(0) { $0 + $1.characters }, 15)
        checkEqual(deltas.reduce(0) { $0 + $1.ratedCharacters }, 14)
        checkEqual(backfill.reduce(0) { $0 + $1.characters }, 5)
        checkEqual(backfill.reduce(0) { $0 + $1.ratedCharacters }, 10)
        checkEqual(backfill.reduce(0) { $0 + $1.characterSeconds }, 2.4, accuracy: 1e-8)
    }

    @Test func testCrossMidnightSplitsCharacterRateButKeepsActualCommitDay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
        var engine = StatisticsEngine(config: config, timeZone: utc)
        _ = engine.record(input(0, characters: 0, date: midnight.addingTimeInterval(-0.1)))
        let deltas = engine.record(input(0.2, characters: 5, date: midnight.addingTimeInterval(0.1)))
        let intervals = deltas.filter { $0.characterSeconds > 0 }
        checkEqual(intervals.map(\.day), ["2026-10-22", "2026-10-23"])
        checkEqual(intervals[0].ratedCharacters, 2.5, accuracy: 1e-6)
        checkEqual(intervals[0].characterIntervals, 0.5, accuracy: 1e-6)
        checkEqual(intervals.reduce(0) { $0 + $1.ratedCharacters }, 5, accuracy: 1e-6)
        checkEqual(intervals.reduce(0) { $0 + $1.characterSeconds }, 0.2, accuracy: 1e-6)
        checkEqual(deltas.filter { $0.day == "2026-10-22" }.reduce(0) { $0 + $1.characters }, 0)
        checkEqual(deltas.filter { $0.day == "2026-10-23" }.reduce(0) { $0 + $1.characters }, 5)
    }

    @Test func testLegacyDeltaDecodesWithUnknownLanguageAndNoCharacterCoverage() throws {
        let legacy = """
        {"day":"2026-10-22","timezoneID":"UTC","ruleID":"adaptive-v1","evidence":"confirmed",\
        "keys":3,"edits":0,"composition":0,"intervals":2,"seconds":0.4,"newIntervals":2,"newSeconds":0.4}
        """
        let delta = try JSONDecoder().decode(DailyDelta.self, from: Data(legacy.utf8))
        checkEqual(delta.language, "und")
        checkEqual(delta.characters, 0)
        checkEqual(delta.ratedCharacters, 0)
        checkEqual(delta.characterSeconds, 0)
        checkEqual(delta.characterIntervals, 0)
    }
}
