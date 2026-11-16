import Foundation
import Testing
@testable import TypingCore

struct RateConsistencyTests {
    private func interval(_ start: Double, _ end: Double, rule: String = "fixture", language: String = "mul",
                          evidence: Evidence = .probable) -> AcceptedTypingInterval {
        AcceptedTypingInterval(startTime: start, endTime: end, evidence: evidence, language: language, ruleID: rule)
    }
    private func samples(_ times: [Double], mode: RateConsistencySamplingMode = .legacyKeyBins) -> [RateConsistencySample] {
        var sampler = RateConsistencySampler(mode: mode), output: [RateConsistencySample] = []
        for (start, end) in zip(times, times.dropFirst()) { output += sampler.record(interval(start, end)) }
        return output
    }
    private func totals(_ samples: [RateConsistencySample]) -> RateConsistencyTotals {
        samples.reduce(into: RateConsistencyTotals()) { $0.merge($1.totals) }
    }

    @Test func kogasaUsesPopulationRateVariationAndMatchesReferenceValues() {
        for (cov, expected) in [(0.0, 100.0), (0.25, 75.0), (0.5, 50.1), (1.0, 8.9)] {
            let summary = RateConsistencyTotals(count: 10, intervals: 20, sum: 600,
                                               squaredSum: 10 * (3_600 + pow(60 * cov, 2)))
            checkEqual(summary.coefficientOfVariation!, cov, accuracy: 1e-9)
            checkEqual(summary.consistency!, expected, accuracy: 1e-9)
        }
    }

    @Test func steadyRatesDoNotRequireUniformInterKeyTiming() {
        let steady = samples((0...50).map { Double($0) * 0.2 })
        var uneven: [Double] = []
        for second in 0..<10 { uneven += [0.0, 0.01, 0.15, 0.7, 0.9].map { Double(second) + $0 } }
        uneven.append(10)
        let unevenSamples = samples(uneven)
        checkEqual(steady.count, 10); checkEqual(unevenSamples.count, 10)
        checkEqual(steady.map { $0.totals.sum }, Array(repeating: 60, count: 10))
        checkEqual(totals(unevenSamples), totals(steady))
        checkEqual(totals(steady).intervals, 49)
        checkEqual(totals(steady).consistency!, 100)
    }

    @Test func changingPerSecondThroughputChangesConsistency() {
        var times: [Double] = []
        for second in 0..<10 {
            let count = second.isMultiple(of: 2) ? 3 : 7
            times += (0..<count).map { Double(second) + Double($0) / Double(count) }
        }
        times.append(10)
        let values = samples(times), summary = totals(values)
        checkEqual(values.map { $0.totals.sum }, [36, 84, 36, 84, 36, 84, 36, 84, 36, 84])
        checkEqual(summary.coefficientOfVariation!, 0.4, accuracy: 1e-9)
        checkTrue(summary.consistency! < 100)
    }

    @Test func completeInteriorZeroSecondsCountButStoppingNeverAddsSamples() {
        var sampler = RateConsistencySampler()
        let covered = sampler.record(interval(0, 3))
        checkEqual(covered.map { $0.endTime }, [1, 2, 3])
        checkEqual(covered.map { $0.totals.sum }, [12, 0, 0])
        checkEqual(totals(covered).intervals, 0)
        checkTrue(covered.allSatisfy { $0.totals.isValid })
        sampler.reset()
        // Closing/resetting has no output and cannot pad the final bucket.
        let next = sampler.record(interval(100, 100.9))
        checkTrue(next.isEmpty)
        checkEqual(totals(covered).count, 3)
        checkNil(totals(covered).consistency)
    }

    @Test func gapsDiscardPartialSecondsInsteadOfJoiningOrFillingThem() {
        var sampler = RateConsistencySampler()
        checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
        checkTrue(sampler.record(interval(100, 100.4)).isEmpty)
        let completed = sampler.record(interval(100.4, 101))
        checkEqual(completed.count, 1)
        checkEqual(completed[0].endTime, 101)
        checkEqual(completed[0].totals.sum, 24)
        checkEqual(completed[0].totals.intervals, 1)
    }

    @Test func ruleLanguageAndEvidenceBoundariesCannotShareABucket() {
        for change in ["rule", "language", "evidence"] {
            var sampler = RateConsistencySampler()
            checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
            if change == "evidence" {
                checkTrue(sampler.record(interval(0.6, 0.9, evidence: .confirmed)).isEmpty)
                let result = sampler.record(interval(0.9, 1.9))
                checkEqual(result.count, 1); checkEqual(result[0].totals.sum, 12)
            } else {
                let result = sampler.record(interval(0.6, 1.6, rule: change == "rule" ? "new" : "fixture",
                                                     language: change == "language" ? "zh" : "mul"))
                checkEqual(result.count, 1)
                checkEqual(result[0].endTime, 1.6, accuracy: 1e-9)
                checkEqual(result[0].totals.sum, 12)
            }
        }
    }

    @Test func duplicateAndOverlappingIntervalsCannotDoubleCountThePrefix() {
        var sampler = RateConsistencySampler()
        checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
        checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
        checkTrue(sampler.record(interval(0.4, 0.8)).isEmpty)
        let complete = sampler.record(interval(0.6, 1))
        checkEqual(complete.count, 1)
        checkEqual(complete[0].totals.sum, 24)
        checkEqual(complete[0].totals.intervals, 1)
    }

    @Test func adaptiveBackfillProducesTheSameProvenSamplesAsImmediateAcceptance() {
        let base = Date(timeIntervalSince1970: 1_792_756_800)
        func run(_ config: SegmentationConfig) -> ([RateConsistencySample], [Int]) {
            var engine = StatisticsEngine(config: config, timeZone: TimeZone(secondsFromGMT: 0)!)
            var sampler = RateConsistencySampler(), output: [RateConsistencySample] = [], accepted: [Int] = []
            for time in [0.0, 0.4, 0.8, 1.2] {
                let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                            category: .composition, evidence: .probable, source: .global, language: "zh")
                let result = engine.recordWithIntervals(input)
                accepted.append(result.acceptedIntervals.count)
                for interval in result.acceptedIntervals { output += sampler.record(interval) }
            }
            return (output, accepted)
        }
        let delayed = run(SegmentationConfig(minimumGap: 0.1, coldStartGap: 0.1))
        let immediate = run(SegmentationConfig())
        checkEqual(delayed.1, [0, 0, 0, 3])
        checkEqual(delayed.0.map { $0.endTime }, immediate.0.map { $0.endTime })
        checkEqual(totals(delayed.0), totals(immediate.0))
        checkEqual(delayed.0.count, 1); checkEqual(delayed.0[0].totals.sum, 36)
    }

    @Test func engineCommandsBreakSamplingWithoutDonatingTheirElapsedTime() {
        let base = Date(timeIntervalSince1970: 1_792_756_800)
        var engine = StatisticsEngine(), sampler = RateConsistencySampler(), output: [RateConsistencySample] = []
        let events: [(Double, InputCategory)] = [(0, .textEntry), (0.2, .textEntry), (0.4, .editing), (0.5, .command),
                                                 (1, .composition), (1.2, .composition), (1.4, .composition),
                                                 (1.6, .composition), (1.8, .composition), (2, .composition)]
        for (time, category) in events {
            let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                        category: category, evidence: category == .command ? .unknown : .probable,
                                        source: .global, language: "mul")
            for interval in engine.recordWithIntervals(input).acceptedIntervals { output += sampler.record(interval) }
        }
        checkEqual(output.count, 1)
        checkEqual(output[0].endTime, 2)
        checkEqual(output[0].totals.sum, 60)
    }

    @Test func largeMonotonicTimestampsKeepOneSecondBinsAndBoundedOutput() {
        let origin = 1_000_000_000.125
        let values = samples((0...50).map { origin + Double($0) * 0.2 })
        checkEqual(values.count, 10)
        checkEqual(values.last!.endTime, origin + 10)
        checkEqual(totals(values).consistency!, 100)
        var sampler = RateConsistencySampler()
        let longest = sampler.record(interval(origin, origin + 10))
        checkEqual(longest.count, 10)
        checkTrue(sampler.record(interval(origin + 10, origin + 21)).isEmpty)
        checkTrue(sampler.record(interval(1e16, 1e16 + 2)).isEmpty)
    }

    @Test func insufficientLegacyMissingAndMalformedMomentsNeverLookPerfect() {
        checkTrue(RateConsistencyTotals(count: 1).isValid)
        checkTrue(RateConsistencyTotals(count: 10, intervals: 49, sum: 600, squaredSum: 36_000).isValid)
        for value in [RateConsistencyTotals(), RateConsistencyTotals(count: 9, intervals: 45, sum: 540, squaredSum: 32_400),
                      RateConsistencyTotals(count: 10, intervals: 19, sum: 600, squaredSum: 36_000),
                      RateConsistencyTotals(count: 10, intervals: 20),
                      RateConsistencyTotals(count: -1), RateConsistencyTotals(count: 1, sum: .infinity),
                      RateConsistencyTotals(count: 10, intervals: 20, sum: 600, squaredSum: 1),
                      RateConsistencyTotals(intervals: 1)] {
            checkNil(value.consistency)
        }
        var overflow = RateConsistencyTotals(count: Int.max, intervals: Int.max, sum: 1, squaredSum: 1)
        overflow.merge(RateConsistencyTotals(count: 1, intervals: 1, sum: 12, squaredSum: 144))
        checkTrue(!overflow.isValid); checkNil(overflow.consistency)
        var sampler = RateConsistencySampler()
        for bad in [interval(0, .infinity), interval(.nan, 1), interval(1, 0), interval(0, 0), interval(0, 11)] {
            checkTrue(sampler.record(bad).isEmpty)
        }
    }

    @Test func mergingRateMomentsRecomputesRatherThanAveragesConsistency() {
        var combined = RateConsistencyTotals(count: 10, intervals: 40, sum: 600, squaredSum: 36_000)
        let slower = RateConsistencyTotals(count: 10, intervals: 20, sum: 240, squaredSum: 5_760)
        checkEqual(combined.consistency!, 100); checkEqual(slower.consistency!, 100)
        combined.merge(slower)
        checkEqual(combined.count, 20); checkEqual(combined.intervals, 60)
        checkEqual(combined.sum, 840); checkEqual(combined.squaredSum, 41_760)
        checkTrue(combined.consistency! < 100)
    }

    @Test func continuousRatesRemoveBinQuantizationForUniformNonIntegralCadences() {
        for origin in [0.0, 0.125, 1_000_000_000.125] {
            for gap in [0.2, 0.4, 0.8, 1.2, 2.0] {
                let values = samples((0...80).map { origin + Double($0) * gap }, mode: .continuousRate)
                let summary = totals(values)
                checkTrue(summary.count >= 10)
                checkTrue(summary.intervals >= 20)
                checkEqual(summary.consistency!, 100)
                for sample in values { checkEqual(sample.totals.sum, 12 / gap, accuracy: 1e-4) }
            }
        }
    }

    @Test func continuousRatesWeightEachCoveredPieceAndStillDetectSpeedChanges() {
        let times = (0...25).map { Double($0) * 0.2 } + (1...25).map { 5 + Double($0) * 0.4 }
        let values = samples(times, mode: .continuousRate)
        checkEqual(values.count, 15)
        for sample in values.prefix(5) { checkEqual(sample.totals.sum, 60, accuracy: 1e-9) }
        for sample in values.suffix(10) { checkEqual(sample.totals.sum, 30, accuracy: 1e-9) }
        checkTrue(totals(values).consistency! < 100)

        var sampler = RateConsistencySampler(mode: .continuousRate)
        checkTrue(sampler.record(interval(0, 0.8)).isEmpty)
        let crossed = sampler.record(interval(0.8, 1.6))
        checkEqual(crossed.count, 1)
        checkEqual(crossed[0].totals.sum, 15, accuracy: 1e-9)
        checkEqual(crossed[0].totals.intervals, 1)
        let next = sampler.record(interval(1.6, 2.4))
        checkEqual(next.count, 1)
        checkEqual(next[0].totals.sum, 15, accuracy: 1e-9)
        checkEqual(next[0].totals.intervals, 1)
    }

    @Test func continuousRateSpanningSecondsCountsEachObservedIntervalOnlyOnce() {
        var sampler = RateConsistencySampler(mode: .continuousRate)
        let values = sampler.record(interval(0, 3))
        checkEqual(values.map { $0.endTime }, [1, 2, 3])
        checkEqual(values.map { $0.totals.sum }, [4, 4, 4])
        checkEqual(values.map { $0.totals.intervals }, [0, 0, 1])
        checkTrue(values.allSatisfy { $0.totals.isValid })
        checkNil(totals(values).consistency)
        sampler.reset()
        let longest = sampler.record(interval(100, 110))
        checkEqual(longest.count, 10)
        checkEqual(totals(longest).intervals, 1)
        checkTrue(sampler.record(interval(110, 121)).isEmpty)
    }

    @Test func continuousRatesRejectDuplicateCoverageAndNeverPadAnIdleTail() {
        var sampler = RateConsistencySampler(mode: .continuousRate)
        checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
        checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
        checkTrue(sampler.record(interval(0.4, 0.8)).isEmpty)
        let completed = sampler.record(interval(0.6, 1))
        checkEqual(completed.count, 1)
        checkEqual(completed[0].totals.sum, 24, accuracy: 1e-9)
        checkEqual(completed[0].totals.intervals, 2)
        checkTrue(sampler.record(interval(1, 1.5)).isEmpty)
        // The next proven chain drops the unfinished half second and idle gap.
        checkTrue(sampler.record(interval(100, 100.4)).isEmpty)
        let afterIdle = sampler.record(interval(100.4, 101))
        checkEqual(afterIdle.count, 1)
        checkEqual(afterIdle[0].endTime, 101)
        checkEqual(afterIdle[0].totals.sum, 24, accuracy: 1e-9)
        sampler.reset()
        checkTrue(sampler.mode == .continuousRate)
        checkTrue(sampler.record(interval(200, 200.9)).isEmpty)
        checkEqual(completed.count + afterIdle.count, 2)
    }

    @Test func continuousRateRuleLanguageAndEvidenceBoundariesDiscardOnlyTheTail() {
        for change in ["rule", "language", "evidence"] {
            var sampler = RateConsistencySampler(mode: .continuousRate)
            checkTrue(sampler.record(interval(0, 0.6)).isEmpty)
            if change == "evidence" {
                checkTrue(sampler.record(interval(0.6, 0.9, evidence: .confirmed)).isEmpty)
                let values = sampler.record(interval(0.9, 1.9))
                checkEqual(values.count, 1)
                checkEqual(values[0].totals.sum, 12, accuracy: 1e-9)
            } else {
                let values = sampler.record(interval(0.6, 1.6, rule: change == "rule" ? "new" : "fixture",
                                                     language: change == "language" ? "zh" : "mul"))
                checkEqual(values.count, 1)
                checkEqual(values[0].endTime, 1.6, accuracy: 1e-9)
                checkEqual(values[0].totals.sum, 12, accuracy: 1e-9)
            }
        }
    }

    @Test func continuousAdaptiveBackfillMatchesImmediateCoveredRateSamples() {
        let base = Date(timeIntervalSince1970: 1_792_756_800)
        func run(_ config: SegmentationConfig) -> [RateConsistencySample] {
            var engine = StatisticsEngine(config: config, timeZone: TimeZone(secondsFromGMT: 0)!)
            var sampler = RateConsistencySampler(mode: .continuousRate), output: [RateConsistencySample] = []
            for time in [0.0, 0.4, 0.8, 1.2] {
                let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                            category: .composition, evidence: .probable, source: .global, language: "zh")
                for interval in engine.recordWithIntervals(input).acceptedIntervals { output += sampler.record(interval) }
            }
            return output
        }
        let delayed = run(SegmentationConfig(minimumGap: 0.1, coldStartGap: 0.1))
        let immediate = run(SegmentationConfig())
        checkEqual(delayed.map { $0.endTime }, immediate.map { $0.endTime })
        checkEqual(totals(delayed), totals(immediate))
        checkEqual(delayed.count, 1)
        checkEqual(delayed[0].totals.sum, 30, accuracy: 1e-9)
        checkEqual(delayed[0].totals.intervals, 2)
    }

    @Test func newMeasurementRuleOptsIntoContinuousRatesWhileLegacyDefaultIsStable() {
        checkTrue(RateConsistencySampler().mode == .legacyKeyBins)
        checkTrue(RateConsistencySamplingMode.forMeasurementRule("adaptive-v4-no-space") == .legacyKeyBins)
        checkTrue(RateConsistencySamplingMode.forMeasurementRule("fixture") == .legacyKeyBins)
        checkTrue(RateConsistencySamplingMode.forMeasurementRule("adaptive-v5-no-space") == .continuousRate)
        let times = (0...80).map { Double($0) * 0.4 }
        let legacy = samples(times), continuous = samples(times, mode: .continuousRate)
        checkEqual(legacy.prefix(2).map { $0.totals.sum }, [36, 24])
        checkTrue(totals(legacy).consistency! < 100)
        checkEqual(totals(continuous).consistency!, 100)
    }

    @Test func activityRuleSwitchSelectsContinuousRatesForGlobalAndApplicationRows() {
        let base = Date(timeIntervalSince1970: 1_792_756_800)
        var tracker = ActivityTracker(timeZone: TimeZone(secondsFromGMT: 0)!)
        var rows: [HourlyActivity] = []
        for (offset, rule) in [(0.0, "adaptive-v4-no-space"), (100.0, "adaptive-v5-no-space")] {
            var engine = StatisticsEngine(config: SegmentationConfig(ruleID: rule), timeZone: TimeZone(secondsFromGMT: 0)!)
            for index in 0...80 {
                let time = offset + Double(index) * 0.4
                let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                            category: .textEntry, evidence: .probable, source: .global, language: "en")
                rows += tracker.record(input: input, result: engine.recordWithIntervals(input), rule: rule,
                                       applicationID: "local.editor", perAppEnabled: true).hourly
            }
        }
        for app in ["", "local.editor"] {
            let legacy = rows.filter { $0.rule.hasPrefix("adaptive-v4-") && $0.applicationID == app }
                .reduce(into: RateConsistencyTotals()) { $0.merge($1.totals.rateConsistency) }
            let current = rows.filter { $0.rule.hasPrefix("adaptive-v5-") && $0.applicationID == app }
                .reduce(into: RateConsistencyTotals()) { $0.merge($1.totals.rateConsistency) }
            checkTrue(legacy.consistency! < 100)
            checkEqual(current.consistency!, 100)
        }
    }

    @Test func legacyRewardEvidenceDoesNotAdoptContinuousRatesFromANewRuleName() {
        let base = Date(timeIntervalSince1970: 1_792_756_800), zone = TimeZone(secondsFromGMT: 0)!
        func quality(rule: String) -> RewardQuality {
            var engine = StatisticsEngine(config: SegmentationConfig(ruleID: rule), timeZone: zone)
            var rewards = RewardEngine(coverageStart: base, progressionTimeZone: zone)
            let context = ImprovementContext(language: "en", inputMethod: "fixture", measurementPolicy: rule,
                                             evidencePolicy: "global-probable-v1")
            for index in 0..<100 {
                let time = Double(index) * 0.4
                let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                            category: .textEntry, evidence: .probable, source: .global, language: "en")
                rewards.record(input: input, result: engine.recordWithIntervals(input), context: context,
                               pendingIntervalCount: engine.pendingProbableIntervals)
            }
            return rewards.state.days[rewards.state.currentDay]!.contexts[context.id]!.quality
        }
        let legacy = quality(rule: "adaptive-v4-no-space"), newRule = quality(rule: "adaptive-v5-no-space")
        checkTrue(legacy.consistency! < 1)
        checkEqual(newRule, legacy)
    }
}
