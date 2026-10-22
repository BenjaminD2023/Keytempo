import Foundation
import Testing
@testable import TypingCore

struct ProbableCompositionTrackerTests {
    private let base = Date(timeIntervalSince1970: 1_767_225_600)

    private func classify(_ key: Int64, at time: Double, tracker: inout ProbableCompositionTracker,
                          context: UInt64 = 1, command: Bool = false, control: Bool = false,
                          shift: Bool = false, option: Bool = false, synthetic: Bool = false,
                          repeated: Bool = false, editable: Bool = true,
                          inputMethod: Bool = true, valid: Bool = true) -> ProbableInputDecision {
        tracker.classify(key: key, time: time, contextVersion: context, command: command, control: control,
                         shift: shift, option: option, synthetic: synthetic, repeated: repeated,
                         editable: editable, inputMethod: inputMethod, valid: valid)
    }

    @Test func plainPinyinLettersPermitEstimatedCandidateNavigationAndSelection() {
        var tracker = ProbableCompositionTracker()
        checkEqual(classify(0, at: 0, tracker: &tracker), .classified(.textEntry, .probable))
        checkTrue(tracker.isActive)
        checkEqual(classify(125, at: 0.2, tracker: &tracker), .classified(.composition, .probable))
        checkTrue(tracker.isActive)
        checkEqual(classify(124, at: 0.4, tracker: &tracker), .classified(.composition, .probable))
        checkEqual(classify(18, at: 0.6, tracker: &tracker), .classified(.composition, .probable))
        checkTrue(!tracker.isActive)
        checkEqual(classify(36, at: 0.8, tracker: &tracker), .classified(.unknown, .unknown))
    }

    @Test func returnCountsOnlyInsideTheShortLivedIMEHypothesis() {
        for selection: Int64 in [36, 76] {
            var tracker = ProbableCompositionTracker()
            checkEqual(classify(selection, at: 0, tracker: &tracker), .classified(.unknown, .unknown))
            _ = classify(13, at: 0.2, tracker: &tracker)
            checkEqual(classify(selection, at: 0.4, tracker: &tracker), .classified(.composition, .probable))
            checkTrue(!tracker.isActive)
            checkEqual(classify(selection, at: 0.6, tracker: &tracker), .classified(.unknown, .unknown))
        }
    }

    @Test func selectionWithoutCompositionEvidenceRemainsUncertain() {
        for key: Int64 in [18, 19, 123, 124, 125, 126, 36, 76, 48] {
            var tracker = ProbableCompositionTracker()
            checkEqual(classify(key, at: 0, tracker: &tracker), .classified(.unknown, .unknown))
        }
        var tracker = ProbableCompositionTracker()
        _ = classify(0, at: 0, tracker: &tracker, inputMethod: false)
        checkTrue(!tracker.isActive)
        checkEqual(classify(36, at: 0.2, tracker: &tracker, inputMethod: false), .classified(.unknown, .unknown))
    }

    @Test func shiftAndOptionCharactersStayTextAndDoNotPretendToSelectCandidates() {
        for modifiers in [(true, false), (false, true), (true, true)] {
            var tracker = ProbableCompositionTracker()
            _ = classify(0, at: 0, tracker: &tracker)
            checkEqual(classify(18, at: 0.2, tracker: &tracker, shift: modifiers.0, option: modifiers.1), .classified(.textEntry, .probable))
            checkTrue(!tracker.isActive)
            checkEqual(classify(36, at: 0.4, tracker: &tracker), .classified(.unknown, .unknown))
            checkEqual(classify(14, at: 0.6, tracker: &tracker, shift: modifiers.0, option: modifiers.1), .classified(.textEntry, .probable))
            checkTrue(!tracker.isActive)
        }
    }

    @Test func shortcutsSynthesisRepeatAndInvalidContextsResetTheHypothesis() {
        for interruption in 0..<7 {
            var tracker = ProbableCompositionTracker()
            _ = classify(0, at: 0, tracker: &tracker)
            _ = classify(18, at: 0.2, tracker: &tracker,
                         command: interruption == 0, control: interruption == 1,
                         synthetic: interruption == 2, repeated: interruption == 3,
                         editable: interruption != 4, inputMethod: interruption != 5,
                         valid: interruption != 6)
            checkTrue(!tracker.isActive)
            checkEqual(classify(36, at: 0.4, tracker: &tracker), .classified(.unknown, .unknown))
        }
        var tracker = ProbableCompositionTracker()
        _ = classify(0, at: 0, tracker: &tracker)
        tracker.reset() // Pause, language policy, buffer loss and focus notifications.
        checkEqual(classify(36, at: 0.2, tracker: &tracker), .classified(.unknown, .unknown))
    }

    @Test func contextChangesExpiryAndInvalidTimestampsNeverReuseCandidateState() {
        for eventTime in [3.01, -0.1, Double.nan, Double.infinity] {
            var tracker = ProbableCompositionTracker()
            _ = classify(0, at: 0, tracker: &tracker)
            checkEqual(classify(36, at: eventTime, tracker: &tracker), .classified(.unknown, .unknown))
            checkTrue(!tracker.isActive)
        }
        var tracker = ProbableCompositionTracker()
        _ = classify(0, at: 0, tracker: &tracker)
        checkEqual(classify(36, at: 0.2, tracker: &tracker, context: 2), .classified(.unknown, .unknown))
        checkTrue(!tracker.isActive)
        _ = classify(0, at: 0.4, tracker: &tracker)
        checkEqual(classify(36, at: 0.3, tracker: &tracker), .classified(.unknown, .unknown))
    }

    @Test func validSpacesAreIgnoredAndCloseOnlyTheIMEHypothesis() {
        for ime in [false, true] {
            var tracker = ProbableCompositionTracker()
            _ = classify(0, at: 0, tracker: &tracker, inputMethod: ime)
            checkEqual(classify(49, at: 0.2, tracker: &tracker, inputMethod: ime), .ignoredSpace)
            checkTrue(!tracker.isActive)
            checkEqual(classify(36, at: 0.4, tracker: &tracker, inputMethod: ime), .classified(.unknown, .unknown))
        }
    }

    @Test func shortcutAndUntrustedSpacesStillInterruptInsteadOfBeingSilentlyIgnored() {
        for interruption in 0..<6 {
            var tracker = ProbableCompositionTracker()
            _ = classify(0, at: 0, tracker: &tracker)
            let result = classify(49, at: 0.2, tracker: &tracker,
                                  command: interruption == 0, control: interruption == 1,
                                  synthetic: interruption == 2, repeated: interruption == 3,
                                  editable: interruption != 4, valid: interruption != 5)
            checkTrue(result != .ignoredSpace)
            checkTrue(!tracker.isActive)
        }
    }

    @Test func excludingSpaceKeepsTheWholeObservedTimeBetweenAcceptedOperations() {
        for ime in [false, true] {
            var tracker = ProbableCompositionTracker()
            var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
            let operations: [(Double, Int64)] = [(0,0), (0.2,45), (0.4,49), (0.6,13), (0.8,14), (1.0,15)]
            for (time, key) in operations {
                let decision = classify(key, at: time, tracker: &tracker, inputMethod: ime)
                if case let .classified(category, evidence) = decision {
                    _ = engine.record(ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                                     category: category, evidence: evidence, source: .global,
                                                     language: ime ? "zh" : "en"))
                }
            }
            let measured = engine.snapshot(now: 1).probable
            checkEqual(measured.keys, 5)
            checkEqual(measured.intervals, 4)
            checkEqual(measured.seconds, 1, accuracy: 1e-9)
            checkEqual(measured.rhythmKPM!, 240, accuracy: 1e-6)
            checkEqual(measured.characters, 0)
            checkNil(measured.characterCPM)
        }
    }

    @Test func candidateOperationsIncreaseEstimatedKPMWithoutInventingCharacters() {
        var tracker = ProbableCompositionTracker()
        var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
        for (index, key) in [Int64(0), 45, 125, 124, 36].enumerated() {
            let time = Double(index) * 0.2
            let decision = classify(key, at: time, tracker: &tracker)
            guard case let .classified(category, evidence) = decision else { continue }
            _ = engine.record(ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                             category: category, evidence: evidence, source: .global, language: "zh"))
        }
        let measured = engine.snapshot(now: 0.8).probable
        checkEqual(measured.keys, 5)
        checkEqual(measured.composition, 3)
        checkEqual(measured.intervals, 4)
        checkEqual(measured.seconds, 0.8, accuracy: 1e-9)
        checkEqual(measured.rhythmKPM!, 300, accuracy: 1e-6)
        checkEqual(measured.characters, 0)
        checkNil(measured.characterCPM)
        checkEqual(engine.snapshot(now: 0.8).confirmed.keys, 0)
    }
}
