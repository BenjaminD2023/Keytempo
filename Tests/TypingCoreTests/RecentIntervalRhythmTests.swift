import Testing
@testable import TypingCore

struct RecentIntervalRhythmTests {
    @Test func mixedSegmentRhythmsAreWeightedByTheirActualIntervals() {
        var rhythm = RecentIntervalRhythm()
        rhythm.record(intervals: 4, seconds: 0.4)
        checkNil(rhythm.kpm)
        rhythm.record(intervals: 4, seconds: 2)
        checkEqual(rhythm.kpm!, 200, accuracy: 1e-9)
        checkEqual(rhythm.intervals, 8)
        checkEqual(rhythm.seconds, 2.4, accuracy: 1e-9)
        // Reading an idle snapshot has no clock and cannot add a pause.
        for _ in 0..<100 { checkEqual(rhythm.kpm!, 200, accuracy: 1e-9) }
        checkEqual(rhythm.seconds, 2.4, accuracy: 1e-9)
    }
    @Test func windowEvictsOldBatchesAndRemainsBounded() {
        var rhythm = RecentIntervalRhythm()
        for _ in 0..<128 { rhythm.record(intervals: 1, seconds: 0.1) }
        for _ in 0..<128 { rhythm.record(intervals: 1, seconds: 0.5) }
        checkEqual(rhythm.batchCount, 128)
        checkEqual(rhythm.intervals, 128)
        checkEqual(rhythm.seconds, 64, accuracy: 1e-9)
        checkEqual(rhythm.kpm!, 120, accuracy: 1e-9)
    }
    @Test func fractionalDaySplitsAndBackfillKeepTheirWeights() {
        var rhythm = RecentIntervalRhythm()
        rhythm.record(intervals: 0.25, seconds: 0.05)
        rhythm.record(intervals: 0.75, seconds: 0.15)
        rhythm.record(intervals: 3, seconds: 0.6)
        checkEqual(rhythm.intervals, 4)
        checkEqual(rhythm.seconds, 0.8, accuracy: 1e-9)
        checkEqual(rhythm.kpm!, 300, accuracy: 1e-9)
        checkEqual(rhythm.batchCount, 3)
    }
    @Test func invalidBatchesCannotChangeMeasuredTimeOrCount() {
        var rhythm = RecentIntervalRhythm()
        rhythm.record(intervals: 4, seconds: 0.8)
        for pair in [(0.0, 1.0), (1, 0), (-1, 1), (1, -1), (.nan, 1), (1, .infinity)] {
            checkTrue(!rhythm.record(intervals: pair.0, seconds: pair.1))
        }
        checkEqual(rhythm.batchCount, 1)
        checkEqual(rhythm.intervals, 4)
        checkEqual(rhythm.seconds, 0.8)
        checkEqual(rhythm.kpm!, 300, accuracy: 1e-9)
    }
    @Test func resetRemovesOldSamplesAndRestoresInsufficientState() {
        var rhythm = RecentIntervalRhythm()
        rhythm.record(intervals: 4, seconds: 0.8)
        rhythm.reset()
        checkEqual(rhythm.batchCount, 0)
        checkEqual(rhythm.intervals, 0)
        checkEqual(rhythm.seconds, 0)
        checkNil(rhythm.kpm)
        rhythm.record(intervals: 1, seconds: 0.5)
        checkNil(rhythm.kpm)
    }
}
