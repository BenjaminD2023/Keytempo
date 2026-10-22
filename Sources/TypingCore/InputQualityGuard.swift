import Foundation

/// These are conservative metadata heuristics, not proof of intent, random
/// content or automation. No characters or ordered physical-key history exist
/// in this guard. OS autorepeat and known synthetic sources are separate rules.
public enum SuspectedInputReason: String, Sendable, Equatable {
    case repeatedKey
    case simultaneousBurst
}

public struct InputQualityResult: Sendable {
    public let accepted: [ClassifiedInput]
    public let excluded: Int
    public let reason: SuspectedInputReason?
    public let deadline: Double?
}

/// Keeps at most 24 content-free event summaries until the next different key
/// or a one-shot idle deadline. A detected repeat/burst can therefore exclude
/// its buffered onset as well as its tail, without retroactively changing rates.
/// Ordinary short repeats, editing and IME candidate operations are retained.
/// Arbitrary random text and unmarked macros with human-like metadata cannot be
/// reliably recognized. Callers must expose this limitation and an off switch.
public struct InputQualityGuard: Sendable {
    public static let idleDelay = 0.5
    public static let capacity = 24
    private enum Mode: Sendable { case repeatedKey, burst, blockedRepeat, blockedBurst }
    private var mode = Mode.repeatedKey
    private var pending = [ClassifiedInput]()
    // Only one current key and an unordered 128-bit set; never a key sequence.
    private var currentKey: Int64?
    private var keysLow: UInt64 = 0
    private var keysHigh: UInt64 = 0
    private var nearSimultaneousGaps = 0
    private var firstTime: Double?
    private var lastTime: Double?
    private var context: UInt64?
    private var language: String?

    public init() { pending.reserveCapacity(Self.capacity) }
    public var bufferedCount: Int { pending.count }
    public var deadline: Double? { pending.isEmpty ? nil : lastTime.map { $0 + Self.idleDelay } }

    /// Flush before an interruption (command, focus change, unknown context,
    /// pause, loss, settings change). Valid short prefixes must not disappear.
    public mutating func flush() -> InputQualityResult {
        let accepted = pending
        reset()
        return InputQualityResult(accepted: accepted, excluded: 0, reason: nil, deadline: nil)
    }

    /// One-shot scheduling is owned by the caller; this method adds no time to
    /// any input interval and returns the original event timestamps unchanged.
    public mutating func flushIfDue(now: Double) -> InputQualityResult {
        if let deadline, now >= deadline { return flush() }
        return result()
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        mode = .repeatedKey; currentKey = nil
        keysLow = 0; keysHigh = 0; nearSimultaneousGaps = 0
        firstTime = nil; lastTime = nil; context = nil; language = nil
    }

    public mutating func observe(_ input: ClassifiedInput, physicalKey: Int64) -> InputQualityResult {
        // Only global probable text-entry operations are eligible. Deletion,
        // candidate selection and real adapter events cannot become spam merely
        // because their physical keys repeat.
        guard input.source == .global, input.evidence == .probable,
              input.category == .textEntry, input.time.isFinite, input.time >= 0,
              physicalKey >= 0, physicalKey < 128 else {
            let accepted = flush().accepted + [input]
            return result(accepted: accepted)
        }
        let gap = lastTime.map { input.time - $0 }
        if context != input.context || language != input.language ||
            gap.map({ $0 <= 0 || $0 >= Self.idleDelay }) == true {
            let accepted = flush().accepted
            begin(input, key: physicalKey)
            return result(accepted: accepted)
        }
        guard let gap else {
            begin(input, key: physicalKey)
            return result()
        }

        if mode == .blockedRepeat {
            if physicalKey == currentKey {
                lastTime = input.time
                return result(excluded: 1, reason: .repeatedKey)
            }
            reset(); begin(input, key: physicalKey)
            return result()
        }
        if mode == .blockedBurst {
            if gap <= 0.03 {
                lastTime = input.time
                return result(excluded: 1, reason: .simultaneousBurst)
            }
            reset(); begin(input, key: physicalKey)
            return result()
        }

        if mode == .repeatedKey && physicalKey != currentKey {
            if gap <= 0.008 { mode = .burst }
            else {
                let accepted = flush().accepted
                begin(input, key: physicalKey)
                return result(accepted: accepted)
            }
        }
        if mode == .burst && (gap > 0.03 || input.time - (firstTime ?? input.time) > 0.2) {
            let accepted = flush().accepted
            begin(input, key: physicalKey)
            return result(accepted: accepted)
        }
        pending.append(input)
        lastTime = input.time
        rememberUnorderedKey(physicalKey)
        if gap <= 0.008 { nearSimultaneousGaps += 1 }

        // Twelve manual presses of one physical key in three seconds are only
        // SUSPECTED repetition. A normal short repeat is never silently lost.
        if mode == .repeatedKey, pending.count >= 12,
           input.time - (firstTime ?? input.time) <= 3 {
            let count = pending.count
            pending.removeAll(keepingCapacity: true)
            mode = .blockedRepeat
            return result(excluded: count, reason: .repeatedKey)
        }
        // Neither speed nor regular rhythm alone is a rejection criterion:
        // require sustained extreme density AND multi-key near-simultaneous
        // clusters. This may catch mashing/unmarked burst injection, not all macros.
        if mode == .burst, pending.count >= 16,
           input.time - (firstTime ?? input.time) <= 0.2,
           nearSimultaneousGaps >= 8, keysLow.nonzeroBitCount + keysHigh.nonzeroBitCount >= 4 {
            let count = pending.count
            pending.removeAll(keepingCapacity: true)
            mode = .blockedBurst
            return result(excluded: count, reason: .simultaneousBurst)
        }
        if pending.count == Self.capacity { return flush() }
        return result()
    }

    private mutating func begin(_ input: ClassifiedInput, key: Int64) {
        pending.append(input)
        currentKey = key; firstTime = input.time; lastTime = input.time
        context = input.context; language = input.language
        rememberUnorderedKey(key)
    }

    private mutating func rememberUnorderedKey(_ key: Int64) {
        if key < 64 { keysLow |= UInt64(1) << UInt64(key) }
        else { keysHigh |= UInt64(1) << UInt64(key - 64) }
    }

    private func result(accepted: [ClassifiedInput] = [], excluded: Int = 0,
                        reason: SuspectedInputReason? = nil) -> InputQualityResult {
        InputQualityResult(accepted: accepted, excluded: excluded, reason: reason, deadline: deadline)
    }
}
