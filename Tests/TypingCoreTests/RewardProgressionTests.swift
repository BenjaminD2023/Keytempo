import Foundation
import Testing
@testable import TypingCore

struct RewardProgressionTests {
    private let context = ImprovementContext(language: "en", inputMethod: "com.apple.keylayout.ABC",
                                              measurementPolicy: "accepted-v1", evidencePolicy: "global-probable-v1")
    private func dayName(_ index: Int) -> String {
        let base = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        return String(ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(index) * 86_400)).prefix(10))
    }
    private func cv(for consistency: Double) -> Double {
        var low = 0.0, high = 10.0
        for _ in 0..<100 {
            let middle = (low + high) / 2
            if RewardConsistency.percentage(coefficientOfVariation: middle)! > consistency { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
    private func day(_ index: Int, wpm: Double = 40, seconds: Double = 720,
                     consistency: Double? = nil, consistencySeconds: Double? = nil) -> ImprovementDay {
        let intervals = wpm * seconds / 12
        let coveredSeconds = consistency.map { _ in consistencySeconds ?? seconds } ?? 0
        let coveredIntervals = wpm * coveredSeconds / 12
        let variation = consistency.map { coveredIntervals * pow(cv(for: $0), 2) } ?? 0
        return ImprovementDay(day: dayName(index), speedIntervals: intervals, seconds: seconds,
                              consistencyIntervals: coveredIntervals, consistencySeconds: coveredSeconds,
                              weightedCVSquared: variation, consistencySamples: consistency == nil ? 0 : Int(coveredSeconds))
    }
    private func calibrated(wpm: Double = 40, consistency: Double? = nil) -> ImprovementTracker {
        var tracker = ImprovementTracker()
        for index in 0..<5 { checkTrue(tracker.completedDay(context: context, day: day(index, wpm: wpm, consistency: consistency)).isEmpty) }
        return tracker
    }

    @Test func xpThresholdsUseAcceptedCountersAndRetainWholeRemainders() throws {
        var xp = XPProgress()
        checkEqual(xp.add(seconds: 299, keys: 1_999)!.total, 0)
        checkEqual(xp.remainderSeconds, 299); checkEqual(xp.remainderKeys, 1_999)
        checkEqual(xp.add(seconds: 1, keys: 1)!, XPAward(time: 1, volume: 1, total: 2))
        checkEqual(xp.remainderSeconds, 0); checkEqual(xp.remainderKeys, 0)

        var carry = XPProgress()
        _ = carry.add(seconds: 180, keys: 1_500)
        carry = try JSONDecoder().decode(XPProgress.self, from: JSONEncoder().encode(carry))
        for _ in 0..<10 { checkEqual(carry.add(seconds: 0, keys: 0)!.total, 0) }
        let tomorrow = carry.add(seconds: 120, keys: 500)!
        checkEqual(tomorrow.time, 1); checkEqual(tomorrow.volume, 1); checkEqual(carry.totalXP, 2)
        checkEqual(carry.eligibleSeconds, 300); checkEqual(carry.eligibleKeys, 2_000)
    }

    @Test func allIndependentXPEarningExamplesAndMultipleCrossingsAreExact() {
        for (seconds, keys, expected) in [(1_800.0, 5_000, 8), (3_600, 10_000, 17),
                                           (3_600, 20_000, 22), (7_200, 20_000, 34)] {
            var xp = XPProgress()
            checkEqual(xp.add(seconds: seconds, keys: keys)!.total, expected)
            checkEqual(xp.totalXP, expected)
        }
        var xp = XPProgress()
        _ = xp.add(seconds: 3_600, keys: 10_000)
        checkEqual(xp.addImprovementXP(10)!.improvement, 10)
        checkEqual(xp.totalXP, 27)
        var isolated = XPProgress()
        checkEqual(isolated.add(seconds: 0, keys: 1)!.total, 0)
        checkEqual(isolated.eligibleSeconds, 0); checkEqual(isolated.remainderKeys, 1)
    }

    @Test func xpIntegerPartitioningDoesNotChangeAwardsOrDependOnSpeed() {
        var combined = XPProgress(), split = XPProgress(), random: UInt64 = 0x1234
        var seconds = 0.0, keys = 0, awarded = 0
        for _ in 0..<300 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let dt = Double((random >> 32) % 181), dk = Int(random % 1_301)
            seconds += dt; keys += dk
            awarded += split.add(seconds: dt, keys: dk)!.total
        }
        _ = combined.add(seconds: seconds, keys: keys)
        checkEqual(split, combined); checkEqual(awarded, combined.totalXP)
        // No score, WPM, consistency, calendar, or session enters this API.
        checkEqual(combined.timeXP, Int(seconds) / 300)
        checkEqual(combined.volumeXP, keys / 2_000)
    }

    @Test func invalidXPAndOverflowAreAtomicNoOps() throws {
        var xp = XPProgress()
        _ = xp.add(seconds: 300, keys: 2_000)
        let before = xp
        for (seconds, keys) in [(-1.0, 0), (.infinity, 0), (.nan, 0), (0, -1)] {
            checkNil(xp.add(seconds: seconds, keys: keys)); checkEqual(xp, before)
        }
        checkNil(xp.addImprovementXP(1)); checkNil(xp.addImprovementXP(-5))
        checkEqual(xp, before)
        var large = XPProgress()
        checkTrue(large.add(seconds: 0, keys: Int.max) != nil)
        let largeBefore = large
        checkNil(large.add(seconds: 0, keys: 1)); checkEqual(large, largeBefore)
        checkNil(large.add(seconds: Double.greatestFiniteMagnitude, keys: 0)); checkEqual(large, largeBefore)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(xp)) as! [String: Any]
        object["timeXP"] = 99
        var corrupt = try JSONDecoder().decode(XPProgress.self, from: JSONSerialization.data(withJSONObject: object))
        checkTrue(!corrupt.isValid); checkNil(corrupt.add(seconds: 300, keys: 2_000))
    }

    @Test func exactLevelMilestonesAndEveryBoundaryRemainWholeNumbers() {
        for (level, threshold) in [(1, 0), (2, 10), (3, 20), (4, 30), (5, 50), (10, 200),
                                   (20, 500), (30, 1_000), (40, 2_000), (50, 3_000), (60, 5_000)] {
            checkEqual(LevelSchedule.threshold(for: level), threshold)
            checkEqual(LevelProgress(totalXP: threshold)!.level, level)
        }
        for level in 2...100 {
            let threshold = LevelSchedule.threshold(for: level)!
            checkEqual(LevelProgress(totalXP: threshold - 1)!.level, level - 1)
            let exact = LevelProgress(totalXP: threshold)!
            checkEqual(exact.level, level); checkEqual(exact.progressXP, 0)
            checkEqual(LevelProgress(totalXP: threshold + 1)!.progressXP, 1)
            checkEqual(exact.requiredXP, LevelSchedule.costToNextLevel(level)!)
        }
        let progress = LevelProgress(totalXP: 520)!
        checkEqual(progress.level, 20); checkEqual(progress.progressXP, 20)
        checkEqual(progress.requiredXP, 50); checkEqual(progress.remainingXP, 30)
        let maximum = LevelProgress(totalXP: Int.max)!
        checkEqual(maximum.requiredXP, 200)
        checkEqual(maximum.levelThreshold + maximum.progressXP, Int.max)
        checkTrue((0..<200).contains(maximum.progressXP)); checkNil(maximum.nextThreshold)
        checkNil(LevelProgress(totalXP: -1)); checkNil(LevelSchedule.threshold(for: 0))
        checkNil(LevelSchedule.threshold(for: Int.max))
    }

    @Test func calibrationRequiresBothCompletedDayAndMeasuredMinuteGates() {
        var tracker = ImprovementTracker()
        for index in 0..<4 { checkTrue(tracker.completedDay(context: context, day: day(index, seconds: 900)).isEmpty) }
        checkNil(tracker.tracks[context.id]!.speedBaseline)
        checkEqual(tracker.tracks[context.id]!.speedCalibration.seconds, 3_600)
        _ = tracker.completedDay(context: context, day: day(4, seconds: 300))
        checkEqual(tracker.tracks[context.id]!.speedBaseline, 40)
        checkTrue(tracker.tracks[context.id]!.speedWindow.isEmpty)

        var short = ImprovementTracker()
        for index in 0..<5 { _ = short.completedDay(context: context, day: day(index, seconds: 600)) }
        checkNil(short.tracks[context.id]!.speedBaseline)
        _ = short.completedDay(context: context, day: day(5, seconds: 600))
        checkEqual(short.tracks[context.id]!.speedBaseline, 40)
    }

    @Test func speedAndConsistencyCalibrateIndependentlyAndUnknownNeverMeansZero() {
        var unknown = calibrated()
        checkEqual(unknown.tracks[context.id]!.speedBaseline, 40)
        checkNil(unknown.tracks[context.id]!.consistencyBaseline)
        for index in 5..<10 { _ = unknown.completedDay(context: context, day: day(index, consistency: 70)) }
        checkEqual(unknown.tracks[context.id]!.consistencyBaseline!, 70, accuracy: 1e-8)
        checkTrue(unknown.tracks[context.id]!.consistencyWindow.isEmpty)

        var partial = ImprovementTracker()
        for index in 0..<5 {
            _ = partial.completedDay(context: context, day: day(index, consistency: 70, consistencySeconds: 360))
        }
        checkEqual(partial.tracks[context.id]!.speedBaseline, 40)
        checkNil(partial.tracks[context.id]!.consistencyBaseline)
        checkEqual(partial.tracks[context.id]!.consistencyCalibration.seconds, 1_800)
        for index in 5..<10 {
            _ = partial.completedDay(context: context, day: day(index, consistency: 70, consistencySeconds: 360))
        }
        checkEqual(partial.tracks[context.id]!.consistencyBaseline!, 70, accuracy: 1e-8)
    }

    @Test func verifiedRelativeGainsRewardEqualMilestonesAtDifferentStartingSpeeds() {
        for baseline in [40.0, 100.0] {
            var tracker = calibrated(wpm: baseline)
            for index in 5..<7 { checkTrue(tracker.completedDay(context: context, day: day(index, wpm: baseline * 1.1, seconds: 600)).isEmpty) }
            let awards = tracker.completedDay(context: context, day: day(7, wpm: baseline * 1.1, seconds: 600))
            checkEqual(awards.count, 1)
            checkEqual(awards[0].metric, .speed); checkEqual(awards[0].firstMilestone, 1)
            checkEqual(awards[0].milestone, 2); checkEqual(awards[0].xp, 10)
            checkEqual(tracker.tracks[context.id]!.speedBaseline, baseline)
        }
    }

    @Test func verificationRejectsShortSpikesAndRequiresThreeIndependentDailyEstimates() {
        var short = calibrated()
        for index in 5..<8 { checkTrue(short.completedDay(context: context, day: day(index, wpm: 80, seconds: 300)).isEmpty) }
        checkEqual(short.tracks[context.id]!.speedMilestone, 0)
        var fewDaily = calibrated()
        for (index, speed) in [(5, 44.0), (6, 44.0), (7, 40.0)] {
            checkTrue(fewDaily.completedDay(context: context, day: day(index, wpm: speed, seconds: 600)).isEmpty)
        }
        checkEqual(fewDaily.tracks[context.id]!.speedMilestone, 0)
        var oneSpike = calibrated()
        for (index, speed) in [(5, 1_000.0), (6, 40.0), (7, 40.0)] {
            checkTrue(oneSpike.completedDay(context: context, day: day(index, wpm: speed, seconds: 600)).isEmpty)
        }
    }

    @Test func monkeytypeConsistencyImprovementAwardsAbsoluteFivePointSteps() {
        var tracker = calibrated(consistency: 70)
        for index in 5..<7 { checkTrue(tracker.completedDay(context: context, day: day(index, seconds: 600, consistency: 80)).isEmpty) }
        let awards = tracker.completedDay(context: context, day: day(7, seconds: 600, consistency: 80))
        checkEqual(awards.count, 1); checkEqual(awards[0].metric, .consistency)
        checkEqual(awards[0].milestone, 2); checkEqual(awards[0].xp, 10)
        checkEqual(tracker.tracks[context.id]!.consistencyBaseline!, 70, accuracy: 1e-8)
        checkEqual(RewardConsistency.percentage(coefficientOfVariation: 0.5)!, 50.1042832075367, accuracy: 1e-9)
        let tooFewBins = ImprovementDay(day: dayName(0), speedIntervals: 100, seconds: 300,
                                       consistencyIntervals: 100, consistencySeconds: 300, weightedCVSquared: 0, consistencySamples: 9)
        checkNil(tooFewBins.consistency)
        var excellent = calibrated(wpm: 160, consistency: 100)
        for index in 5..<15 { checkTrue(excellent.completedDay(context: context, day: day(index, wpm: 160, consistency: 100)).isEmpty) }
        checkEqual(excellent.tracks[context.id]!.consistencyMilestone, 0)
        var nearCeiling = calibrated(consistency: 97)
        for index in 5..<8 { checkTrue(nearCeiling.completedDay(context: context, day: day(index, seconds: 600, consistency: 100)).isEmpty) }
    }

    @Test func multipleMetricMilestonesAwardAllNewStepsExactlyOnce() {
        var tracker = calibrated(consistency: 70)
        for index in 5..<7 { _ = tracker.completedDay(context: context, day: day(index, wpm: 60, seconds: 600, consistency: 80)) }
        let awards = tracker.completedDay(context: context, day: day(7, wpm: 60, seconds: 600, consistency: 80))
        checkEqual(awards.count, 2)
        checkEqual(awards.first { $0.metric == .speed }!.milestone, 10)
        checkEqual(awards.first { $0.metric == .speed }!.xp, 50)
        checkEqual(awards.first { $0.metric == .consistency }!.xp, 10)
        checkEqual(Set(awards.map(\.id)).count, 2)
        checkTrue(tracker.completedDay(context: context, day: day(8, wpm: 60, seconds: 600, consistency: 80)).isEmpty)
    }

    @Test func claimsSurviveRetriesRestartsRegressionRecoveryAndBoundedWindowPruning() throws {
        var tracker = calibrated()
        for index in 5..<7 { _ = tracker.completedDay(context: context, day: day(index, wpm: 44, seconds: 600)) }
        let awarded = tracker.completedDay(context: context, day: day(7, wpm: 44, seconds: 600))
        checkEqual(awarded[0].xp, 10)
        checkTrue(tracker.completedDay(context: context, day: day(7, wpm: 44, seconds: 600)).isEmpty)
        tracker = try JSONDecoder().decode(ImprovementTracker.self, from: JSONEncoder().encode(tracker))
        for index in 8..<18 { checkTrue(tracker.completedDay(context: context, day: day(index, wpm: 30)).isEmpty) }
        for index in 18..<30 { checkTrue(tracker.completedDay(context: context, day: day(index, wpm: 44)).isEmpty) }
        checkEqual(tracker.tracks[context.id]!.speedMilestone, 2)
        checkEqual(tracker.tracks[context.id]!.speedWindow.count, 7)
        checkEqual(tracker.tracks[context.id]!.speedBaseline, 40)
        checkTrue(tracker.isValid)
    }

    @Test func contextsAreNormalizedIsolatedAndPolicyChangesConservativelySuspendTheLineage() throws {
        let same = ImprovementContext(language: "EN_us", inputMethod: " COM.APPLE.KEYLAYOUT.ABC ",
                                      measurementPolicy: context.measurementPolicy, evidencePolicy: context.evidencePolicy)
        checkEqual(same, context)
        let chinese = ImprovementContext(language: "zh-Hans", inputMethod: "com.apple.inputmethod.SCIM.ITABC",
                                         measurementPolicy: context.measurementPolicy, evidencePolicy: context.evidencePolicy)
        var tracker = calibrated()
        checkTrue(tracker.completedDay(context: chinese, day: day(5, wpm: 200)).isEmpty)
        checkNil(tracker.tracks[chinese.id]!.speedBaseline)
        checkEqual(tracker.tracks[context.id]!.speedBaseline, 40)
        let changed = ImprovementContext(language: "en", inputMethod: context.inputMethod,
                                         measurementPolicy: "changed-counting", evidencePolicy: context.evidencePolicy)
        checkEqual(changed.id, context.id)
        checkTrue(tracker.completedDay(context: changed, day: day(6, wpm: 200)).isEmpty)
        checkTrue(tracker.tracks[context.id]!.suspended)
        tracker = try JSONDecoder().decode(ImprovementTracker.self, from: JSONEncoder().encode(tracker))
        for index in 7..<20 { checkTrue(tracker.completedDay(context: context, day: day(index, wpm: 200)).isEmpty) }
        checkEqual(tracker.tracks[context.id]!.speedBaseline, 40)
    }

    @Test func malformedEvidenceAndContextCapacityCannotCreateAwards() {
        var tracker = ImprovementTracker()
        let badDate = ImprovementDay(day: "2026-02-30", speedIntervals: 2_400, seconds: 720)
        let badMoment = ImprovementDay(day: dayName(0), speedIntervals: 2_400, seconds: 720,
                                      consistencyIntervals: 2_400, consistencySeconds: 720, weightedCVSquared: .nan, consistencySamples: 720)
        for value in [badDate, badMoment, ImprovementDay(day: dayName(0), speedIntervals: -1, seconds: 720)] {
            checkTrue(!value.isValid); checkTrue(tracker.completedDay(context: context, day: value).isEmpty)
        }
        checkTrue(tracker.tracks.isEmpty)
        for index in 0..<RewardProgressionPolicy.maximumContexts {
            let value = ImprovementContext(language: "en", inputMethod: "source.\(index)", measurementPolicy: "v1", evidencePolicy: "v1")
            _ = tracker.completedDay(context: value, day: day(0))
        }
        checkEqual(tracker.tracks.count, RewardProgressionPolicy.maximumContexts)
        checkTrue(tracker.completedDay(context: context, day: day(0)).isEmpty)
        checkEqual(tracker.tracks.count, RewardProgressionPolicy.maximumContexts)
        checkTrue(tracker.isValid)
    }

    @Test func persistedPolicyVersionsAndFrozenBaselineSummariesAreValidated() throws {
        let xp = XPProgress()
        checkEqual(xp.policyID, "xp-v1"); checkEqual(xp.levelsPolicyID, "levels-v1")
        var xpObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(xp)) as! [String: Any]
        xpObject["policyID"] = "incompatible-future-xp"
        var incompatible = try JSONDecoder().decode(XPProgress.self, from: JSONSerialization.data(withJSONObject: xpObject))
        checkTrue(!incompatible.isValid); checkNil(incompatible.add(seconds: 300, keys: 2_000))

        let tracker = calibrated()
        checkEqual(tracker.policyID, "improvement-v1")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tracker)) as! [String: Any]
        var tracks = object["tracks"] as! [String: Any]
        var track = tracks[context.id] as! [String: Any]
        track["speedBaseline"] = 1
        tracks[context.id] = track; object["tracks"] = tracks
        var corrupt = try JSONDecoder().decode(ImprovementTracker.self, from: JSONSerialization.data(withJSONObject: object))
        checkTrue(!corrupt.isValid)
        checkTrue(corrupt.completedDay(context: context, day: day(5, wpm: 200)).isEmpty)
    }
}
