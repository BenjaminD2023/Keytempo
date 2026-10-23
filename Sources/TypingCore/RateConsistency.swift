import Foundation

/// Sufficient statistics for completed one-second operation-rate samples.
/// No input text, key names or individual timing sequence is retained here.
public struct RateConsistencyTotals: Codable, Sendable, Equatable {
    public var count: Int
    public var intervals: Int
    public var sum: Double
    public var squaredSum: Double

    public init(count: Int = 0, intervals: Int = 0, sum: Double = 0, squaredSum: Double = 0) {
        self.count = count; self.intervals = intervals
        self.sum = sum; self.squaredSum = squaredSum
    }

    public var isValid: Bool {
        guard count >= 0, intervals >= 0, sum.isFinite, squaredSum.isFinite,
              sum >= 0, squaredSum >= 0 else { return false }
        if count == 0 { return intervals == 0 && sum == 0 && squaredSum == 0 }
        let mean = sum / Double(count), secondMoment = squaredSum / Double(count)
        let variance = secondMoment - mean * mean
        return variance.isFinite && variance >= -max(1e-12, secondMoment * 1e-10)
    }

    /// Population variation of sampled operation rates, not inter-key gaps.
    /// The coverage threshold is a Keytempo heuristic, not a Monkeytype norm.
    public var coefficientOfVariation: Double? {
        guard isValid, count >= 10, intervals >= 20 else { return nil }
        let mean = sum / Double(count)
        guard mean > 0 else { return nil }
        let variance = max(0, squaredSum / Double(count) - mean * mean)
        let value = sqrt(variance) / mean
        return value.isFinite ? value : nil
    }

    public var consistency: Double? {
        guard let cov = coefficientOfVariation else { return nil }
        // Monkeytype's Kogasa mapping, pinned reference:
        // monkeytypegame/monkeytype@128e4029048f72d3a8106941c4c4602f60c51b24
        // packages/util/src/numbers.ts, kogasa(). The operation-rate source
        // and idle boundaries differ, so this is Monkeytype-style consistency.
        let squared = cov * cov
        let transformed = 100 * (1 - tanh(cov + cov * squared / 3 + cov * squared * squared / 5))
        return (min(100, max(0, transformed)) * 100).rounded() / 100
    }

    public mutating func merge(_ other: Self) {
        let sampleCount = count.addingReportingOverflow(other.count)
        let intervalCount = intervals.addingReportingOverflow(other.intervals)
        guard isValid, other.isValid, !sampleCount.overflow, !intervalCount.overflow else {
            sum = .nan; squaredSum = .nan
            return
        }
        count = sampleCount.partialValue; intervals = intervalCount.partialValue
        sum += other.sum; squaredSum += other.squaredSum
    }
}

/// A transient completed sample. Its end is an observed, covered boundary,
/// never a timer deadline or an extrapolation beyond the last accepted event.
public struct RateConsistencySample: Sendable {
    public let endTime: Double
    public let totals: RateConsistencyTotals

    public init(endTime: Double, totals: RateConsistencyTotals) {
        self.endTime = endTime; self.totals = totals
    }
}

/// Constant-memory, event-driven sampling of proven interval chains. Deriving
/// events from accepted interval endpoints lets adaptive backfill arrive in
/// order without keeping a speculative per-key history or freezing it early.
public struct RateConsistencySampler: Sendable {
    private var lastEnd: Double?
    private var boundary: Double?
    private var language: String?
    private var rule: String?
    private var keys = 0
    private var intervalCount = 0

    public init() {}

    public mutating func reset() {
        lastEnd = nil; boundary = nil; language = nil; rule = nil
        keys = 0; intervalCount = 0
    }

    public mutating func record(_ interval: AcceptedTypingInterval) -> [RateConsistencySample] {
        let start = interval.startTime, end = interval.endTime
        let duration = end - start
        guard start.isFinite, end.isFinite, duration > 0, duration <= 10,
              interval.evidence == .probable, !interval.ruleID.isEmpty,
              interval.ruleID.utf8.count <= 512, interval.language.utf8.count <= 64 else {
            reset(); return []
        }
        // Duplicate/overlapping delivery cannot manufacture keys or samples.
        // Keep the valid prefix available for a subsequent genuinely new end.
        if let lastEnd, end <= lastEnd || (start < lastEnd && !Self.sameInstant(start, lastEnd)) { return [] }
        let continuing = lastEnd.map { Self.sameInstant(start, $0) } ?? false
        if !continuing || language != interval.language || rule != interval.ruleID {
            reset()
            let next = start + 1
            guard next.isFinite, next > start else { return [] }
            boundary = next; language = interval.language; rule = interval.ruleID
            // The chain's first key has no preceding measurable interval.
            keys = 1
        }

        var completed: [RateConsistencySample] = []
        completed.reserveCapacity(2)
        // Duration is bounded above, so at most ten complete seconds can be
        // proved by one accepted interval. Zero-key interior seconds count.
        for _ in 0..<10 {
            guard let boundary, end > boundary || Self.sameInstant(end, boundary) else { break }
            let rate = 12 * Double(keys)
            completed.append(RateConsistencySample(endTime: boundary,
                totals: RateConsistencyTotals(count: 1, intervals: intervalCount,
                                              sum: rate, squaredSum: rate * rate)))
            let next = boundary + 1
            guard next.isFinite, next > boundary else { reset(); return [] }
            self.boundary = next; keys = 0; intervalCount = 0
        }
        guard let boundary, end < boundary && !Self.sameInstant(end, boundary) else {
            // This can only follow malformed/unrepresentable clock input.
            reset(); return []
        }
        let keyCount = keys.addingReportingOverflow(1)
        let observedCount = intervalCount.addingReportingOverflow(1)
        guard !keyCount.overflow, !observedCount.overflow else { reset(); return [] }
        keys = keyCount.partialValue; intervalCount = observedCount.partialValue
        lastEnd = end
        return completed
    }

    /// Allow only floating-point representation error at shared endpoints;
    /// actual segment gaps must never become sampled coverage.
    private static func sameInstant(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == rhs || abs(lhs - rhs) <= 2 * max(lhs.ulp, rhs.ulp)
    }
}
