import Foundation

/// A bounded weighted view of accepted interval batches. It does not infer
/// continuity, inspect input language or add time; callers supply only intervals
/// already accepted by the segmentation engine, with evidence kept separate.
public struct RecentIntervalRhythm: Sendable {
    private struct Batch: Sendable { let intervals: Double; let seconds: Double }
    public let capacity: Int
    private var batches: [Batch] = []
    public private(set) var intervals = 0.0
    public private(set) var seconds = 0.0
    public var batchCount: Int { batches.count }
    public var kpm: Double? {
        guard intervals >= 4, seconds >= 0.5 else { return nil }
        let value = 60 * (intervals / seconds)
        return value.isFinite ? value : nil
    }
    public init(capacity: Int = 128) { self.capacity = max(1, min(256, capacity)) }
    @discardableResult public mutating func record(intervals: Double, seconds: Double) -> Bool {
        guard intervals.isFinite, seconds.isFinite, intervals > 0, seconds > 0 else { return false }
        let oldest = batches.count == capacity ? batches.first : nil
        let nextIntervals = self.intervals - (oldest?.intervals ?? 0) + intervals
        let nextSeconds = self.seconds - (oldest?.seconds ?? 0) + seconds
        guard nextIntervals.isFinite, nextSeconds.isFinite else { return false }
        if oldest != nil { batches.removeFirst() }
        batches.append(Batch(intervals: intervals, seconds: seconds))
        self.intervals = nextIntervals
        self.seconds = nextSeconds
        return true
    }
    public mutating func reset() {
        batches.removeAll(keepingCapacity: true)
        intervals = 0; seconds = 0
    }
}
