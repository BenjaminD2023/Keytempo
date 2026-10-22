import Foundation
import Testing
@testable import TypingCore

struct TypingRateTests {
    @Test func primaryUnitsUseSourceLanguageAndKeepUnknownExplicit() {
        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "th", "lo", "km", "my"] {
            checkEqual(TypingRate.primaryUnit(forLanguage: language), .cpm)
        }
        for language in ["en", "fr", "de", "vi"] { checkEqual(TypingRate.primaryUnit(forLanguage: language), .wpm) }
        checkEqual(TypingRate.primaryUnit(forLanguage: "und"), .unknown)
        checkEqual(TypingRate.primaryUnit(forLanguage: ""), .unknown)
    }
    @Test func estimateUsesWeightedIntervalsAndStaysFrozenWhenIdle() {
        var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        // Two bursts: four 0.1-second and four 0.5-second intervals.
        for time in [0.0, 0.1, 0.2, 0.3, 0.4, 10, 10.5, 11, 11.5, 12] {
            _ = engine.record(ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                             category: .textEntry, evidence: .confirmed, source: .adapter))
        }
        checkEqual(TypingRate.estimatedWPM(fromKPM: engine.snapshot(now: 12).confirmed.rhythmKPM)!, 40, accuracy: 1e-8)
        engine.advance(to: 60)
        checkEqual(TypingRate.estimatedWPM(fromKPM: engine.snapshot(now: 60).confirmed.rhythmKPM)!, 40, accuracy: 1e-8)
    }

    @Test func estimatePreservesInsufficientOrInvalidData() {
        checkNil(TypingRate.estimatedWPM(fromKPM: nil))
        checkNil(TypingRate.estimatedWPM(fromKPM: .nan))
        checkNil(TypingRate.estimatedWPM(fromKPM: .infinity))
        checkNil(TypingRate.estimatedWPM(fromKPM: -1))
        checkEqual(TypingRate.estimatedWPM(fromKPM: 300), 60)
    }
}
