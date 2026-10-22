import Testing
import Foundation
@testable import TypingCore

final class MetadataClassifierTests {
    func classify(_ key: Int64, command: Bool = false, control: Bool = false,
                  synthetic: Bool = false, editable: Bool = true,
                  inputMethod: Bool = false, valid: Bool = true) -> (InputCategory, Evidence) {
        MetadataClassifier.classify(key: key, command: command, control: control,
                                    synthetic: synthetic, editable: editable,
                                    inputMethod: inputMethod, valid: valid)
    }

    @Test func testSameWDependsOnContext() {
        checkEqual(classify(13).0, .textEntry)
        checkEqual(classify(13).1, .probable)
        checkEqual(classify(13, editable: false).0, .unknown)
        checkEqual(classify(13, valid: false).0, .unknown)
    }

    @Test func testTextHasNoDictionaryOrSemanticFilter() {
        for key: Int64 in [0, 18, 24, 27, 30, 33, 44, 50, 49] {
            checkEqual(classify(key).0, .textEntry)
            checkEqual(classify(key).1, .probable)
        }
    }

    @Test func testCommandControlAndKnownSynthesisNeverManual() {
        for key: Int64 in [0, 1, 8, 9, 13, 15] {
            checkEqual(classify(key, command: true).0, .command)
            checkEqual(classify(key, control: true).0, .command)
            checkEqual(classify(key, synthetic: true).0, .generated)
        }
    }

    @Test func testCommonShortcutsStayExcludedAcrossContextsAndIME() {
        // Copy/paste/cut/select-all/undo/save/open, app switching, submit and
        // modified navigation/deletion must never become printable-key counts.
        let commandKeys: [Int64] = [8, 9, 7, 0, 6, 1, 31, 48, 36, 51, 123]
        // Common Emacs-style editor controls and system Control shortcuts.
        let controlKeys: [Int64] = [0, 14, 45, 35, 40, 32, 48, 51]
        for editable in [false, true] {
            for inputMethod in [false, true] {
                for valid in [false, true] {
                    for key in commandKeys {
                        let result = classify(key, command: true, editable: editable,
                                              inputMethod: inputMethod, valid: valid)
                        checkEqual(result.0, .command, "Command key \(key)")
                        checkEqual(result.1, .unknown)
                    }
                    for key in controlKeys {
                        let result = classify(key, control: true, editable: editable,
                                              inputMethod: inputMethod, valid: valid)
                        checkEqual(result.0, .command, "Control key \(key)")
                        checkEqual(result.1, .unknown)
                    }
                }
            }
        }
    }

    @Test func testClassifiedShortcutBreaksTimingAndNeverIncreasesKeys() {
        for command in [false, true] {
            for shortcut: Int64 in [0, 8, 9, 48, 51, 123] {
                var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
                let base = Date(timeIntervalSince1970: 1_767_225_600)
                for (time, key, isShortcut): (Double, Int64, Bool) in [
                    (0, 13, false), (0.2, 13, false), (0.3, shortcut, true),
                    (0.4, 13, false), (0.6, 13, false)
                ] {
                    let result = classify(key, command: isShortcut && command,
                                          control: isShortcut && !command)
                    let deltas = engine.record(ClassifiedInput(
                        time: time, date: base.addingTimeInterval(time), context: 1,
                        category: result.0, evidence: result.1, source: .global))
                    if isShortcut { checkTrue(deltas.isEmpty) }
                }
                let result = engine.snapshot(now: 0.6).probable
                checkEqual(result.keys, 4)
                checkEqual(result.edits, 0)
                checkEqual(result.intervals, 2)
                checkEqual(result.seconds, 0.4, accuracy: 1e-8)
                checkEqual(result.rawKPM!, 300, accuracy: 1e-6)
            }
        }
    }

    @Test func testGlobalReturnTabAndIMESelectionStayUncertain() {
        for key: Int64 in [36, 48, 76] { checkEqual(classify(key).0, .unknown) }
        for key: Int64 in [49, 18, 19, 123, 124, 125, 126] {
            checkEqual(classify(key, inputMethod: true).0, .unknown)
        }
        // Pinyin keystrokes remain a context-filtered estimate; no Chinese chars are inferred.
        checkEqual(classify(0, inputMethod: true).1, .probable)
    }

    @Test func testNavigationFunctionKeysAndDeletion() {
        for key: Int64 in [53, 115, 119, 116, 121, 123, 124, 125, 126, 122, 120] {
            checkEqual(classify(key).0, .navigation)
        }
        for key: Int64 in [51, 117] {
            checkEqual(classify(key).0, .editing)
            checkEqual(classify(key).1, .probable)
            checkEqual(classify(key, editable: false).0, .unknown)
        }
    }
}
