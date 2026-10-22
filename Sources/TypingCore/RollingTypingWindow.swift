import Foundation

public struct RollingTypingSnapshot: Sendable, Equatable {
    public let intervals: Double
    public let seconds: Double
    public let kpm: Double?
    public var estimatedWPM: Double? { kpm.map { $0 / 5 } }
    /// False only while bounded-capacity eviction has omitted recent samples.
    public let isComplete: Bool
    /// The next interval leaves the window at this monotonic time. A caller
    /// can use a one-shot wake-up while idle instead of polling continuously.
    public let nextExpiry: Double?
}

/// Session-only average over accepted intervals intersecting the last ten
/// minutes. The denominator is observed typing time, never ten wall minutes.
/// Commands, idle gaps and context changes have already been segmented out.
/// Intervals crossing the window boundary contribute proportional numerator
/// weight and their complete overlapping duration. No text or key IDs are kept.
public struct RollingTypingWindow: Sendable {
    private struct Timing: Sendable { let start: Double; let end: Double }
    public let duration: Double
    public let capacity: Int
    private var timings: [Timing] = []
    private var head = 0
    private var omittedThrough: Double?
    public var intervalCount: Int { timings.count - head }

    public init(duration: Double = 600, capacity: Int = 32_768) {
        self.duration = duration.isFinite && duration > 0 ? duration : 600
        self.capacity = max(4, min(capacity, 65_536))
    }

    /// All recorded languages share the same operation-based WPM scale.
    /// Confirmed adapter data remains outside this global estimate.
    public mutating func record(_ accepted: [AcceptedTypingInterval], at now: Double) {
        guard now.isFinite else { return }
        expire(at: now)
        for interval in accepted where interval.evidence == .probable {
            let start = interval.startTime, end = interval.endTime
            guard start.isFinite, end.isFinite, end > start, end > now - duration else { continue }
            // Segmentation emits chronologically ordered, non-overlapping
            // intervals. Ignore duplicate or malformed external batches.
            if let last = timings.last, end <= last.end || start < last.end { continue }
            if intervalCount == capacity {
                let discard = max(1, capacity / 4)
                omittedThrough = max(omittedThrough ?? -.infinity, timings[head + discard - 1].end)
                head += discard
            }
            // Compact only at capacity, keeping append/prune work amortized
            // and the backing allocation strictly bounded.
            if timings.count == capacity && head > 0 {
                timings.removeFirst(head); head = 0
            }
            timings.append(Timing(start: start, end: end))
        }
    }

    public mutating func snapshot(at now: Double) -> RollingTypingSnapshot {
        guard now.isFinite else {
            return RollingTypingSnapshot(intervals: 0, seconds: 0, kpm: nil, isComplete: false, nextExpiry: nil)
        }
        expire(at: now)
        let cutoff = now - duration
        var intervals = 0.0, seconds = 0.0
        for timing in timings[head...] {
            let overlap = min(timing.end, now) - max(timing.start, cutoff)
            if overlap > 0 {
                intervals += overlap / (timing.end - timing.start)
                seconds += overlap
            }
        }
        let complete = omittedThrough == nil
        let kpm = complete && intervals >= 4 && seconds >= 0.5 ? 60 * intervals / seconds : nil
        var expiry = head < timings.count ? timings[head].end + duration : nil
        if let omittedThrough { expiry = min(expiry ?? .infinity, omittedThrough + duration) }
        return RollingTypingSnapshot(intervals: intervals, seconds: seconds,
                                     kpm: kpm, isComplete: complete, nextExpiry: expiry)
    }

    public mutating func reset() {
        timings.removeAll(keepingCapacity: true); head = 0; omittedThrough = nil
    }

    private mutating func expire(at now: Double) {
        let cutoff = now - duration
        while head < timings.count && timings[head].end <= cutoff { head += 1 }
        if head == timings.count { timings.removeAll(keepingCapacity: true); head = 0 }
        if let omittedThrough, omittedThrough <= cutoff { self.omittedThrough = nil }
    }
}
