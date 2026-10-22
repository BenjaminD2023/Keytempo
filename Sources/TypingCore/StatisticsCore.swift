import Foundation

public enum InputCategory: String, Codable, Sendable, CaseIterable {
    case textEntry, composition, editing, command, navigation, generated, unknown
    public var isEffective: Bool { self == .textEntry || self == .composition || self == .editing }
}

public enum Evidence: String, Codable, Sendable, CaseIterable { case confirmed, probable, unknown }
public enum InputSource: String, Codable, Sendable { case global, adapter }
public enum TypingPhase: String, Codable, Sendable { case idle, candidate, typing }

/// Contains metadata only. `operationID` must identify the same physical operation across sources.
public struct ClassifiedInput: Sendable {
    public var time: Double
    public var date: Date
    public var context: UInt64
    public var category: InputCategory
    public var evidence: Evidence
    public var source: InputSource
    public var operationID: UInt64?
    public var language: String
    /// nil means output coverage is unavailable; zero is an observed operation
    /// with no committed characters (for example composition or deletion).
    public var committedCharacters: Int?
    public init(time: Double, date: Date, context: UInt64, category: InputCategory,
                evidence: Evidence, source: InputSource, operationID: UInt64? = nil,
                language: String = "und", committedCharacters: Int? = nil) {
        self.time = time; self.date = date; self.context = context
        self.category = category; self.evidence = evidence; self.source = source
        self.operationID = operationID
        self.language = language; self.committedCharacters = committedCharacters
    }
}

public struct SegmentationConfig: Codable, Sendable, Equatable {
    public var minimumGap: Double
    public var maximumGap: Double
    public var coldStartGap: Double
    public var sampleCapacity: Int
    public var minimumIntervals: Int
    public var minimumSeconds: Double
    public var ruleID: String
    public init(minimumGap: Double = 0.65, maximumGap: Double = 3,
                coldStartGap: Double = 1.5, sampleCapacity: Int = 128,
                minimumIntervals: Int = 4, minimumSeconds: Double = 0.5,
                ruleID: String = "adaptive-v1") {
        self.minimumGap = max(0.1, min(minimumGap, 3))
        self.maximumGap = max(self.minimumGap, min(maximumGap, 10))
        self.coldStartGap = min(self.maximumGap, max(self.minimumGap, coldStartGap))
        self.sampleCapacity = min(256, max(16, sampleCapacity))
        self.minimumIntervals = max(1, minimumIntervals)
        self.minimumSeconds = max(0.001, minimumSeconds)
        self.ruleID = ruleID
    }
}

/// Intervals crossing midnight are proportionally split, including their numerator weight.
/// Thus totals remain exactly n−1 while each day's rate has a matching denominator.
public struct DailyDelta: Codable, Sendable, Equatable {
    public var day: String
    public var timezoneID: String
    public var ruleID: String
    public var evidence: Evidence
    public var keys: Int
    public var edits: Int
    public var composition: Int
    public var intervals: Double
    public var seconds: Double
    public var newIntervals: Double
    public var newSeconds: Double
    public var language: String
    public var characters: Int
    public var ratedCharacters: Double
    public var characterSeconds: Double
    public var characterIntervals: Double
    public init(day: String, timezoneID: String, ruleID: String, evidence: Evidence,
                keys: Int = 0, edits: Int = 0, composition: Int = 0,
                intervals: Double = 0, seconds: Double = 0,
                newIntervals: Double = 0, newSeconds: Double = 0,
                language: String = "und", characters: Int = 0,
                ratedCharacters: Double = 0, characterSeconds: Double = 0,
                characterIntervals: Double = 0) {
        self.day = day; self.timezoneID = timezoneID; self.ruleID = ruleID; self.evidence = evidence
        self.keys = keys; self.edits = edits; self.composition = composition
        self.intervals = intervals; self.seconds = seconds
        self.newIntervals = newIntervals; self.newSeconds = newSeconds
        self.language = language; self.characters = characters
        self.ratedCharacters = ratedCharacters; self.characterSeconds = characterSeconds
        self.characterIntervals = characterIntervals
    }

    private enum CodingKeys: String, CodingKey {
        case day, timezoneID, ruleID, evidence, keys, edits, composition
        case intervals, seconds, newIntervals, newSeconds
        case language, characters, ratedCharacters, characterSeconds, characterIntervals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(String.self, forKey: .day)
        timezoneID = try values.decode(String.self, forKey: .timezoneID)
        ruleID = try values.decode(String.self, forKey: .ruleID)
        evidence = try values.decode(Evidence.self, forKey: .evidence)
        keys = try values.decode(Int.self, forKey: .keys)
        edits = try values.decode(Int.self, forKey: .edits)
        composition = try values.decode(Int.self, forKey: .composition)
        intervals = try values.decode(Double.self, forKey: .intervals)
        seconds = try values.decode(Double.self, forKey: .seconds)
        newIntervals = try values.decode(Double.self, forKey: .newIntervals)
        newSeconds = try values.decode(Double.self, forKey: .newSeconds)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "und"
        characters = try values.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        ratedCharacters = try values.decodeIfPresent(Double.self, forKey: .ratedCharacters) ?? 0
        characterSeconds = try values.decodeIfPresent(Double.self, forKey: .characterSeconds) ?? 0
        characterIntervals = try values.decodeIfPresent(Double.self, forKey: .characterIntervals) ?? 0
    }
}

public struct MetricSnapshot: Sendable, Equatable {
    /// Effective operations, including composition and editing; not produced characters.
    public var keys: Int = 0
    public var edits: Int = 0
    public var composition: Int = 0
    public var intervals: Double = 0
    public var seconds: Double = 0
    public var newIntervals: Double = 0
    public var newSeconds: Double = 0
    public var rhythmKPM: Double?
    public var rawKPM: Double?
    public var recentRhythmKPM: Double?
    public var newInputKPM: Double?
    /// Commits include a segment's first operation, even though it has no
    /// preceding measured duration and therefore contributes no rate numerator.
    public var characters: Int = 0
    public var characterCoveredKeys: Int = 0
    public var characterIntervals: Double = 0
    public var ratedCharacters: Double = 0
    public var characterSeconds: Double = 0
    public var characterCPM: Double?
    public var recentCharacterCPM: Double?
    public var recentLanguage: String = "und"
    public init() {}
}

public struct EngineSnapshot: Sendable, Equatable {
    public var confirmed: MetricSnapshot
    public var probable: MetricSnapshot
    public var phase: TypingPhase
    public var threshold: Double
    public var median: Double?
    public var mad: Double?
    public var sampleCount: Int
    public var pendingCount: Int
    public var lastEventTime: Double?
    public var deduplicationCount: Int
}

/// The accepted intervals of one finished burst. This is a bounded presentation
/// snapshot; cumulative accounting remains in DailyDelta and MetricSnapshot.
public struct CompletedTypingSegment: Sendable, Equatable {
    public fileprivate(set) var revision: UInt64
    public var language: String
    public var evidence: Evidence
    public var kpm: Double?
    public var cpm: Double?
    public var intervals: Double
    public var seconds: Double
    public var characterIntervals: Double
    public var ratedCharacters: Double
    public var characterSeconds: Double
    public var endTime: Double
    public var endDate: Date
}

private struct IntervalSummary: Sendable {
    let start: ClassifiedInput
    let end: ClassifiedInput
    var seconds: Double { end.time - start.time }
    var isNewInput: Bool { start.category == .textEntry && end.category == .textEntry }
    var hasCharacterCoverage: Bool {
        start.evidence == .confirmed && end.evidence == .confirmed &&
        start.language == end.language && start.committedCharacters != nil &&
        end.committedCharacters != nil
    }
    /// An IME's entire end-event commit belongs to its observed process
    /// interval. The n−1 operation correction is never applied to characters.
    var ratedCharacters: Double { hasCharacterCoverage ? Double(end.committedCharacters!) : 0 }
}

private struct RhythmModel: Sendable {
    var samples: [Double] = []
    func summary(config: SegmentationConfig) -> (Double?, Double?, Double) {
        guard samples.count >= 3 else { return (nil, nil, config.coldStartGap) }
        let m = Self.median(samples)
        let d = Self.median(samples.map { abs($0 - m) })
        return (m, d, min(config.maximumGap, max(config.minimumGap, max(3 * m, m + 6 * d))))
    }
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), n = sorted.count
        return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
    }
    mutating func add(_ value: Double, config: SegmentationConfig) {
        if samples.count >= config.sampleCapacity { samples.removeFirst() }
        samples.append(value)
    }
}

private struct Lane: Sendable {
    var totals = MetricSnapshot()
    var model = RhythmModel()
    var previous: ClassifiedInput?
    var pending: [IntervalSummary] = []
    var segmentIntervals = 0.0
    var segmentSeconds = 0.0
    var segmentCharacterIntervals = 0.0
    var segmentRatedCharacters = 0.0
    var segmentCharacterSeconds = 0.0
    var phase = TypingPhase.idle
    var segmentEnd: ClassifiedInput?
    var segmentFinalized = false
    var completed: CompletedTypingSegment?

    mutating func interrupt(config: SegmentationConfig) {
        finishSegment(config: config)
        previous = nil; pending.removeAll(keepingCapacity: true); phase = .idle
    }

    mutating func resetSegment(config: SegmentationConfig) {
        finishSegment(config: config)
        segmentIntervals = 0; segmentSeconds = 0; phase = .candidate
        segmentCharacterIntervals = 0; segmentRatedCharacters = 0; segmentCharacterSeconds = 0
        segmentEnd = nil; segmentFinalized = false
    }

    mutating func finishSegment(config: SegmentationConfig) {
        guard !segmentFinalized, let end = segmentEnd, segmentIntervals > 0 else { return }
        completed = CompletedTypingSegment(
            revision: 0, language: end.language, evidence: end.evidence,
            kpm: segmentIntervals >= Double(config.minimumIntervals) && segmentSeconds >= config.minimumSeconds ? 60 * segmentIntervals / segmentSeconds : nil,
            cpm: segmentCharacterIntervals >= Double(config.minimumIntervals) && segmentCharacterSeconds >= config.minimumSeconds && segmentRatedCharacters > 0 ? 60 * segmentRatedCharacters / segmentCharacterSeconds : nil,
            intervals: segmentIntervals, seconds: segmentSeconds,
            characterIntervals: segmentCharacterIntervals, ratedCharacters: segmentRatedCharacters,
            characterSeconds: segmentCharacterSeconds, endTime: end.time, endDate: end.date)
        segmentFinalized = true
    }

    mutating func accept(_ interval: IntervalSummary, config: SegmentationConfig,
                         timeZone: TimeZone) -> [DailyDelta] {
        let dt = interval.seconds
        segmentEnd = interval.end
        segmentFinalized = false
        totals.intervals += 1; totals.seconds += dt
        segmentIntervals += 1; segmentSeconds += dt
        if interval.hasCharacterCoverage {
            totals.characterIntervals += 1; totals.ratedCharacters += interval.ratedCharacters
            totals.characterSeconds += dt
            segmentCharacterIntervals += 1; segmentRatedCharacters += interval.ratedCharacters
            segmentCharacterSeconds += dt
        }
        if interval.isNewInput { totals.newIntervals += 1; totals.newSeconds += dt }
        model.add(dt, config: config)
        phase = segmentIntervals >= 2 ? .typing : .candidate
        return Self.intervalDeltas(interval, config: config, timeZone: timeZone)
    }

    mutating func record(_ event: ClassifiedInput, config: SegmentationConfig,
                         timeZone: TimeZone) -> [DailyDelta] {
        totals.recentLanguage = event.language
        totals.keys += 1
        if event.category == .editing { totals.edits += 1 }
        if event.category == .composition { totals.composition += 1 }
        if let characters = event.committedCharacters {
            totals.characters += characters
            totals.characterCoveredKeys += 1
        }
        var result = [DailyDelta(day: dayKey(event.date, timeZone), timezoneID: timeZone.identifier,
                                 ruleID: config.ruleID, evidence: event.evidence, keys: 1,
                                 edits: event.category == .editing ? 1 : 0,
                                 composition: event.category == .composition ? 1 : 0,
                                 language: event.language, characters: event.committedCharacters ?? 0)]
        defer { previous = event }
        guard let prior = previous else { resetSegment(config: config); return result }
        let dt = event.time - prior.time
        // Duration is monotonic. A wall-clock correction cannot move a prior interval to another date.
        guard dt > 0, abs(event.date.timeIntervalSince(prior.date) - dt) <= 1 else {
            pending.removeAll(keepingCapacity: true); resetSegment(config: config); return result
        }
        let interval = IntervalSummary(start: prior, end: event)
        let threshold = model.summary(config: config).2
        if dt <= threshold {
            // One isolated slow gap does not connect the surrounding bursts.
            if !pending.isEmpty { pending.removeAll(keepingCapacity: true); resetSegment(config: config) }
            result += accept(interval, config: config, timeZone: timeZone)
        } else if dt <= config.maximumGap {
            // Bounded shadow candidate allows a stable slower rhythm to retrain the model.
            // Three similar intervals are required; timing is backfilled at the original timestamps.
            if let last = pending.last, !(0.6...1.67).contains(dt / last.seconds) {
                pending.removeAll(keepingCapacity: true)
            }
            pending.append(interval)
            phase = .candidate
            if pending.count == 3 {
                let values = pending.map(\.seconds)
                let m = RhythmModel.median(values)
                let relativeMAD = RhythmModel.median(values.map { abs($0 - m) }) / m
                if relativeMAD <= 0.25 {
                    model.samples.removeAll(keepingCapacity: true)
                    resetSegment(config: config)
                    for candidate in pending { result += accept(candidate, config: config, timeZone: timeZone) }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending.removeFirst()
                }
            }
        } else {
            pending.removeAll(keepingCapacity: true); resetSegment(config: config)
        }
        return result
    }

    func snapshot(config: SegmentationConfig) -> MetricSnapshot {
        var result = totals
        result.rawKPM = totals.seconds > 0 ? 60 * totals.intervals / totals.seconds : nil
        result.rhythmKPM = totals.intervals >= Double(config.minimumIntervals) && totals.seconds >= config.minimumSeconds ? result.rawKPM : nil
        result.recentRhythmKPM = segmentIntervals >= Double(config.minimumIntervals) && segmentSeconds >= config.minimumSeconds ? 60 * segmentIntervals / segmentSeconds : nil
        result.newInputKPM = totals.newIntervals >= Double(config.minimumIntervals) && totals.newSeconds >= config.minimumSeconds ? 60 * totals.newIntervals / totals.newSeconds : nil
        result.characterCPM = totals.characterIntervals >= Double(config.minimumIntervals) && totals.characterSeconds >= config.minimumSeconds && totals.ratedCharacters > 0 ? 60 * totals.ratedCharacters / totals.characterSeconds : nil
        result.recentCharacterCPM = segmentCharacterIntervals >= Double(config.minimumIntervals) && segmentCharacterSeconds >= config.minimumSeconds && segmentRatedCharacters > 0 ? 60 * segmentRatedCharacters / segmentCharacterSeconds : nil
        return result
    }

    static func intervalDeltas(_ interval: IntervalSummary, config: SegmentationConfig,
                               timeZone: TimeZone) -> [DailyDelta] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let dt = interval.seconds
        var cursor = interval.start.date
        // Map elapsed monotonic time to the start event's wall date. No timer adds a tail.
        var remaining = dt
        var result: [DailyDelta] = []
        while remaining > 0 {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { break }
            let untilMidnight = day.end.timeIntervalSince(cursor)
            let duration = min(remaining, untilMidnight)
            guard duration > 0 else { break }
            result.append(DailyDelta(day: dayKey(cursor, timeZone), timezoneID: timeZone.identifier,
                                     ruleID: config.ruleID, evidence: interval.end.evidence,
                                     intervals: duration / dt, seconds: duration,
                                     newIntervals: interval.isNewInput ? duration / dt : 0,
                                     newSeconds: interval.isNewInput ? duration : 0,
                                     language: interval.end.language,
                                     ratedCharacters: interval.ratedCharacters * duration / dt,
                                     characterSeconds: interval.hasCharacterCoverage ? duration : 0,
                                     characterIntervals: interval.hasCharacterCoverage ? duration / dt : 0))
            remaining -= duration
            cursor = day.end
        }
        return result
    }
}

private func dayKey(_ date: Date, _ timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Single-owner, deterministic aggregation core. Run on one serial queue outside event callbacks.
/// Bounded state: 2×256 rhythm samples, 2×3 candidate intervals, 256 dedup IDs, two last events.
public struct StatisticsEngine: Sendable {
    public private(set) var config: SegmentationConfig
    public private(set) var timeZone: TimeZone
    public private(set) var latestCompletedSegment: CompletedTypingSegment?
    private var confirmed = Lane()
    private var probable = Lane()
    private var activeContext: UInt64?
    private var activeEvidence: Evidence?
    private var activeSource: InputSource?
    private var activeLanguage: String?
    private var lastEventTime: Double?
    private var recentIDs: [UInt64] = []
    private var idSet: Set<UInt64> = []
    private var duplicateCount = 0
    private var completionRevision: UInt64 = 0

    /// Keep a bounded UI wake-up until the last accepted segment can no longer
    /// be reinterpreted by the adaptive slower-rhythm candidate buffer.
    public var completionPending: Bool {
        guard activeEvidence != nil else { return false }
        let lane = activeEvidence == .confirmed ? confirmed : probable
        return lane.segmentEnd != nil && !lane.segmentFinalized
    }
    public var completionDeadline: Double? {
        guard completionPending, let lastEventTime else { return nil }
        return lastEventTime + config.maximumGap
    }

    public init(config: SegmentationConfig = SegmentationConfig(), timeZone: TimeZone = .current) {
        self.config = config; self.timeZone = timeZone
    }

    public mutating func record(_ input: ClassifiedInput) -> [DailyDelta] {
        if let id = input.operationID {
            if idSet.contains(id) { duplicateCount += 1; return [] }
            if recentIDs.count == 256 { idSet.remove(recentIDs.removeFirst()) }
            recentIDs.append(id); idSet.insert(id)
        }
        guard input.time.isFinite, input.date.timeIntervalSince1970.isFinite,
              input.category.isEffective, input.evidence != .unknown else { interrupt(); return [] }
        if activeContext != input.context || activeEvidence != input.evidence || activeSource != input.source || activeLanguage != input.language {
            interrupt()
            // Context-specific samples prevent a previous editor/IME rhythm from classifying a new one.
            confirmed.model = RhythmModel(); probable.model = RhythmModel()
        }
        activeContext = input.context; activeEvidence = input.evidence; activeSource = input.source
        activeLanguage = input.language
        lastEventTime = input.time
        var coveredInput = input
        // A probable global event cannot establish output coverage. Invalid
        // negative counts become uncovered without inventing a zero commit.
        if input.evidence != .confirmed || (input.committedCharacters.map { $0 < 0 } ?? false) {
            coveredInput.committedCharacters = nil
        }
        let deltas: [DailyDelta]
        if input.evidence == .confirmed { deltas = confirmed.record(coveredInput, config: config, timeZone: timeZone) }
        else { deltas = probable.record(coveredInput, config: config, timeZone: timeZone) }
        collectCompletions()
        return deltas
    }

    public mutating func interrupt() {
        confirmed.interrupt(config: config); probable.interrupt(config: config)
        collectCompletions()
        activeContext = nil; activeEvidence = nil; activeSource = nil
        activeLanguage = nil
    }

    /// Changes UI phase only. Never changes counts, intervals, durations, or measured speeds.
    public mutating func advance(to now: Double) {
        guard now.isFinite, let lastEventTime else { return }
        let lane = activeEvidence == .confirmed ? confirmed : probable
        if now - lastEventTime > lane.model.summary(config: config).2 {
            if activeEvidence == .confirmed { confirmed.phase = .idle } else { probable.phase = .idle }
        }
        // The adaptive threshold can expand while three slower intervals are
        // being learned. Waiting to the absolute continuity bound prevents a
        // displayed completed burst from being prematurely split by UI ticks.
        // No waiting time enters either metric's denominator.
        if now - lastEventTime > config.maximumGap {
            if activeEvidence == .confirmed { confirmed.finishSegment(config: config) }
            else if activeEvidence == .probable { probable.finishSegment(config: config) }
            collectCompletions()
        }
    }

    private mutating func collectCompletions() {
        let finished = [confirmed.completed, probable.completed].compactMap { $0 }.sorted { $0.endTime < $1.endTime }
        confirmed.completed = nil; probable.completed = nil
        for var segment in finished {
            completionRevision &+= 1
            segment.revision = completionRevision
            latestCompletedSegment = segment
        }
    }

    public mutating func updateTimeZone(_ zone: TimeZone) {
        guard zone != timeZone else { return }
        interrupt(); timeZone = zone
    }

    public mutating func updateConfig(_ config: SegmentationConfig) {
        guard self.config != config else { return }
        interrupt(); self.config = config
        confirmed.model = RhythmModel(); probable.model = RhythmModel()
    }

    public func snapshot(now: Double) -> EngineSnapshot {
        let lane = activeEvidence == .confirmed ? confirmed : probable
        let summary = lane.model.summary(config: config)
        var phase = lane.phase
        if activeEvidence == nil || (lastEventTime.map { now - $0 > summary.2 } ?? true) { phase = .idle }
        return EngineSnapshot(confirmed: confirmed.snapshot(config: config), probable: probable.snapshot(config: config),
                              phase: phase, threshold: summary.2, median: summary.0, mad: summary.1,
                              sampleCount: lane.model.samples.count, pendingCount: lane.pending.count,
                              lastEventTime: lastEventTime, deduplicationCount: duplicateCount)
    }
}
