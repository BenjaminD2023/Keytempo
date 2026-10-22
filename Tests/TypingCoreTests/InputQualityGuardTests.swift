import Foundation
import Testing
@testable import TypingCore

struct InputQualityGuardTests {
    private let date = Date(timeIntervalSince1970: 1_767_225_600)
    private func input(_ time: Double, category: InputCategory = .textEntry,
                       context: UInt64 = 1, language: String = "en",
                       evidence: Evidence = .probable, source: InputSource = .global) -> ClassifiedInput {
        ClassifiedInput(time: time, date: date.addingTimeInterval(time), context: context,
                        category: category, evidence: evidence, source: source, language: language)
    }

    @Test func ordinaryEnglishCodeAndPinyinPreserveOriginalTimesAndWeightedRate() {
        for language in ["en", "zh", "ja"] {
            var quality = InputQualityGuard()
            var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
            var accepted = [ClassifiedInput]()
            for (index, key) in [Int64(0), 45, 14, 30, 30].enumerated() {
                let result = quality.observe(input(Double(index) * 0.2, language: language), physicalKey: key)
                checkEqual(result.excluded, 0)
                accepted += result.accepted
            }
            checkEqual(accepted.count, 3, "last two short repeats are buffered")
            checkEqual(quality.flushIfDue(now: 1.29).accepted.count, 0)
            accepted += quality.flushIfDue(now: 1.3).accepted
            checkEqual(accepted.map(\.time), (0..<5).map { Double($0) * 0.2 })
            for event in accepted { _ = engine.record(event) }
            let snapshot = engine.snapshot(now: 60).probable
            checkEqual(snapshot.keys, 5)
            checkEqual(snapshot.intervals, 4)
            checkEqual(snapshot.seconds, 0.8, accuracy: 1e-9)
            checkEqual(snapshot.rhythmKPM!, 300, accuracy: 1e-8)
        }
    }

    @Test func longFastSameKeyRunDropsItsEntireOnsetAndTailWithoutTimingBridge() {
        var quality = InputQualityGuard()
        var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
        var excluded = 0
        func consume(_ result: InputQualityResult) {
            for event in result.accepted { _ = engine.record(event) }
            if result.excluded > 0 { engine.interrupt() }
            excluded += result.excluded
        }
        consume(quality.observe(input(0), physicalKey: 0))
        consume(quality.observe(input(0.2), physicalKey: 1))
        consume(quality.flush())
        for index in 0..<40 {
            consume(quality.observe(input(0.4 + Double(index) * 0.05), physicalKey: 13))
            checkLessThanOrEqual(quality.bufferedCount, InputQualityGuard.capacity)
        }
        checkEqual(excluded, 40, "no first-eleven-key leak")
        consume(quality.observe(input(2.6), physicalKey: 2))
        consume(quality.observe(input(2.8), physicalKey: 3))
        consume(quality.flush())
        let measured = engine.snapshot(now: 60).probable
        checkEqual(measured.keys, 4)
        checkEqual(measured.intervals, 2)
        checkEqual(measured.seconds, 0.4, accuracy: 1e-9)
        checkEqual(measured.rawKPM!, 300, accuracy: 1e-8)
    }

    @Test func shortRepeatsPunctuationAndSlowSustainedRepeatsAreRetained() {
        // Genuine short letter/punctuation runs, code operators, and slow
        // repeated operations do not cross the conservative suspicion threshold.
        for key: Int64 in [0, 27, 30, 44, 18] {
            var quality = InputQualityGuard()
            var count = 0
            for index in 0..<11 {
                let result = quality.observe(input(Double(index) * 0.1), physicalKey: key)
                count += result.accepted.count
                checkEqual(result.excluded, 0)
            }
            count += quality.flush().accepted.count
            checkEqual(count, 11)
        }
        var quality = InputQualityGuard()
        var count = 0
        for index in 0..<80 {
            let result = quality.observe(input(Double(index) * 0.4), physicalKey: 0)
            count += result.accepted.count
            checkEqual(result.excluded, 0)
            checkLessThanOrEqual(quality.bufferedCount, InputQualityGuard.capacity)
        }
        count += quality.flush().accepted.count
        checkEqual(count, 80)
    }

    @Test func repeatedChineseCandidateAndDeletionKeysRemainEditingComposition() {
        for category in [InputCategory.composition, .editing] {
            var quality = InputQualityGuard()
            var accepted = 0
            for index in 0..<100 {
                let result = quality.observe(input(Double(index) * 0.01, category: category, language: "zh"), physicalKey: category == .editing ? 51 : 125)
                accepted += result.accepted.count
                checkEqual(result.excluded, 0)
                checkEqual(quality.bufferedCount, 0)
            }
            checkEqual(accepted, 100)
        }
    }

    @Test func multiSignalNearSimultaneousBurstDropsAllBufferedEventsAndRecovers() {
        var quality = InputQualityGuard()
        var excluded = 0
        var accepted = 0
        for index in 0..<80 {
            let result = quality.observe(input(Double(index) * 0.002), physicalKey: Int64(index % 8))
            excluded += result.excluded
            accepted += result.accepted.count
            if result.excluded > 0 { checkEqual(result.reason, .simultaneousBurst) }
        }
        checkEqual(excluded, 80)
        checkEqual(accepted, 0)
        checkNil(quality.deadline)
        let resumed = quality.observe(input(1), physicalKey: 0)
        checkEqual(resumed.excluded, 0)
        checkEqual(quality.flushIfDue(now: 1.5).accepted.map(\.time), [1])
    }

    @Test func fastRegularTypingAndTwoKeyPatternsAloneNeverProveAutomation() {
        for gap in [0.01, 0.02, 0.05, 0.1] {
            var quality = InputQualityGuard()
            var accepted = 0
            for index in 0..<200 {
                let result = quality.observe(input(Double(index) * gap), physicalKey: Int64(index % 20))
                checkEqual(result.excluded, 0)
                accepted += result.accepted.count
            }
            accepted += quality.flush().accepted.count
            checkEqual(accepted, 200)
        }
        // "hahaha"-like alternation is not semantically judged, even when the
        // metadata is extremely fast. Multi-key cluster evidence is missing.
        var quality = InputQualityGuard()
        var accepted = 0
        for index in 0..<200 {
            let result = quality.observe(input(Double(index) * 0.002), physicalKey: Int64(index % 2))
            checkEqual(result.excluded, 0)
            accepted += result.accepted.count
        }
        accepted += quality.flush().accepted.count
        checkEqual(accepted, 200)
    }

    @Test func pausesContextLanguageAndInterruptionFlushValidShortPrefixes() {
        for boundary in 0..<4 {
            var quality = InputQualityGuard()
            _ = quality.observe(input(0), physicalKey: 0)
            _ = quality.observe(input(0.1), physicalKey: 0)
            let result: InputQualityResult
            switch boundary {
            case 0: result = quality.observe(input(0.6), physicalKey: 0)
            case 1: result = quality.observe(input(0.2, context: 2), physicalKey: 0)
            case 2: result = quality.observe(input(0.2, language: "zh"), physicalKey: 0)
            default: result = quality.flush()
            }
            checkEqual(result.accepted.map(\.time), [0, 0.1])
            checkEqual(result.excluded, 0)
        }
        for category in [InputCategory.command, .navigation, .generated, .unknown] {
            var quality = InputQualityGuard()
            _ = quality.observe(input(0), physicalKey: 0)
            let result = quality.observe(input(0.1, category: category, evidence: .unknown), physicalKey: 0)
            checkEqual(result.accepted.map(\.category), [.textEntry, category])
            checkEqual(quality.bufferedCount, 0)
        }
    }

    @Test func independentPausedRunsCannotAccumulateIntoFalseSpam() {
        var quality = InputQualityGuard()
        var accepted = 0
        for run in 0..<30 {
            for index in 0..<8 {
                let result = quality.observe(input(Double(run) * 3 + Double(index) * 0.1), physicalKey: 0)
                accepted += result.accepted.count
                checkEqual(result.excluded, 0)
            }
            accepted += quality.flushIfDue(now: Double(run) * 3 + 1.2).accepted.count
        }
        accepted += quality.flush().accepted.count
        checkEqual(accepted, 240)
    }

    @Test func confirmedAdapterAndInvalidMetadataAreNeverBufferedAsSuspectedSpam() {
        for category in [InputCategory.textEntry, .composition] {
            var quality = InputQualityGuard()
            for index in 0..<40 {
                let result = quality.observe(input(Double(index) * 0.01, category: category, evidence: .confirmed, source: .adapter), physicalKey: 0)
                checkEqual(result.accepted.count, 1)
                checkEqual(result.excluded, 0)
            }
        }
        var quality = InputQualityGuard()
        _ = quality.observe(input(0), physicalKey: 0)
        let result = quality.observe(input(-1), physicalKey: 0)
        checkEqual(result.accepted.map(\.time), [0, -1])
        checkNil(result.deadline)
    }

    @Test func reversedOrDuplicateEventClockCannotExtendARepetitionHypothesis() {
        for nextStart in [0.0, 10.5] {
            var quality = InputQualityGuard()
            var accepted = [ClassifiedInput]()
            for index in 0..<6 {
                let result = quality.observe(input(10 + Double(index) * 0.1), physicalKey: 0)
                accepted += result.accepted
                checkEqual(result.excluded, 0)
            }
            for index in 0..<6 {
                let result = quality.observe(input(nextStart + Double(index) * 0.1), physicalKey: 0)
                accepted += result.accepted
                checkEqual(result.excluded, 0)
            }
            accepted += quality.flush().accepted
            checkEqual(accepted.count, 12)
            checkEqual(accepted[5].time, 10.5)
            checkEqual(accepted[6].time, nextStart)
        }
    }
}
