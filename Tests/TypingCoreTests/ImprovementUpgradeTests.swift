import Foundation
import Testing
@testable import TypingCore

struct ImprovementUpgradeTests {
    private let oldRule = "adaptive-v4-no-space-ime-quality-on-max3.0"
    private let newRule = "adaptive-v5-no-space-ime-quality-on-max3.0"
    private let zone = TimeZone(secondsFromGMT: 0)!
    private func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: 1_767_225_600 + Double(day - 1) * 86_400)
    }
    private func day(_ index: Int, wpm: Double, seconds: Double) -> ImprovementDay {
        ImprovementDay(day: String(format: "2026-01-%02d", index), speedIntervals: wpm * seconds / 12, seconds: seconds)
    }
    private func context(_ rule: String) -> ImprovementContext {
        ImprovementContext(language: "en", inputMethod: "fixture",
                           measurementPolicy: RewardProgressionPolicy.improvementMeasurementPolicy(rule),
                           evidencePolicy: "global-probable-v1")
    }
    private func calibrated() -> ImprovementTracker {
        var tracker = ImprovementTracker()
        for index in 1...5 { _ = tracker.completedDay(context: context(oldRule), day: day(index, wpm: 40, seconds: 720)) }
        for index in 6...7 { _ = tracker.completedDay(context: context(oldRule), day: day(index, wpm: 48, seconds: 600)) }
        return tracker
    }

    @Test func improvementAliasOnlyMapsTheKnownSamplerOnlyUpgradeAndPreservesAllSettings() {
        checkEqual(RewardProgressionPolicy.improvementMeasurementPolicy(newRule), oldRule)
        checkEqual(RewardProgressionPolicy.improvementMeasurementPolicy(oldRule), oldRule)
        let changed = "adaptive-v5-no-space-ime-quality-off-max4.0-keyboard-fallback"
        checkEqual(RewardProgressionPolicy.improvementMeasurementPolicy(changed),
                   "adaptive-v4-no-space-ime-quality-off-max4.0-keyboard-fallback")
        for rule in ["fixture", "adaptive-v50-no-space", "adaptive-v6-no-space", "prefix-adaptive-v5-no-space"] {
            checkEqual(RewardProgressionPolicy.improvementMeasurementPolicy(rule), rule)
        }
        // The general context initializer retains its explicit caller policy.
        let direct = ImprovementContext(language: "en", inputMethod: "fixture", measurementPolicy: newRule,
                                        evidencePolicy: "global-probable-v1")
        checkEqual(direct.measurementPolicy, newRule)
    }

    @Test func upgradedRewardEngineCompletesTheExistingBaselineAndAwardsTheNextMilestoneOnce() throws {
        let base = date(8), oldContext = context(oldRule), upgradedContext = context(newRule)
        var state = RewardEngine(coverageStart: base, progressionTimeZone: zone).state
        state.improvement = calibrated()
        let before = state.improvement.tracks[oldContext.id]!
        checkEqual(before.speedBaseline, 40)
        checkEqual(before.speedWindow.count, 2)
        var rewards = try RewardEngine(restoring: state, now: base)
        var statistics = StatisticsEngine(config: .init(ruleID: newRule), timeZone: zone)
        for index in 0...2_400 {
            let time = Double(index) * 0.25
            let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                        category: .textEntry, evidence: .probable, source: .global, language: "en")
            rewards.record(input: input, result: statistics.recordWithIntervals(input), context: upgradedContext,
                           pendingIntervalCount: statistics.pendingProbableIntervals)
        }
        rewards.advance(to: date(9))
        checkNil(rewards.error)
        let after = rewards.state.improvement.tracks[oldContext.id]!
        checkTrue(!after.suspended)
        checkEqual(after.context, before.context)
        checkEqual(after.speedBaseline, before.speedBaseline)
        checkEqual(after.speedBaselineDay, before.speedBaselineDay)
        checkEqual(after.speedMilestone, 4)
        checkEqual(rewards.state.xpProgress.improvementXP, 20)
        checkEqual(rewards.unpersistedAwards.filter { $0.kind == "improvement-speed" }.count, 1)
        let write = rewards.checkpoint(at: date(9))
        var restored = try RewardEngine(restoring: write.state, now: date(9))
        restored.advance(to: date(10))
        checkEqual(restored.state.xpProgress.improvementXP, 20)
        checkTrue(restored.unpersistedAwards.filter { $0.kind == "improvement-speed" }.isEmpty)
    }

    @Test func genuineCountingChangesStillSuspendTheExistingBaselineWithoutResettingIt() {
        var tracker = calibrated()
        let original = tracker.tracks[context(oldRule).id]!
        let changed = context("adaptive-v5-no-space-ime-quality-off-max3.0")
        checkTrue(tracker.completedDay(context: changed, day: day(8, wpm: 48, seconds: 600)).isEmpty)
        let after = tracker.tracks[changed.id]!
        checkTrue(after.suspended)
        checkEqual(after.context, original.context)
        checkEqual(after.speedBaseline, original.speedBaseline)
        checkEqual(after.speedMilestone, original.speedMilestone)
    }
}
