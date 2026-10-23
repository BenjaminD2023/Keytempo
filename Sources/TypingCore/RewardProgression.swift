import Foundation

/// Versioned earning/evidence defaults. Changes must not revalue earned awards.
public enum RewardProgressionPolicy {
    public static let xpID = "xp-v1"
    public static let improvementID = "improvement-v1"
    public static let levelsID = "levels-v1"
    public static let secondsPerXP = 300.0
    public static let keysPerXP = 2_000
    public static let improvementMilestoneXP = 5
    public static let qualifyingDaySeconds = 300.0
    public static let calibrationDays = 5
    public static let calibrationSeconds = 3_600.0
    public static let verificationDays = 3
    public static let verificationSeconds = 1_800.0
    public static let windowDays = 7
    public static let maximumContexts = 64
}

/// Monkeytype's Kogasa mapping applied to normalized per-run rate variation.
/// Preserve internal precision; the presentation layer chooses display rounding.
public enum RewardConsistency {
    public static func percentage(coefficientOfVariation cov: Double) -> Double? {
        guard cov.isFinite, cov >= 0 else { return nil }
        let squared = cov * cov
        return min(100, max(0, 100 * (1 - tanh(cov + cov * squared / 3 + cov * squared * squared / 5))))
    }
}

public struct XPAward: Codable, Sendable, Equatable {
    public let time: Int
    public let volume: Int
    public let improvement: Int
    public let total: Int
    public init(time: Int = 0, volume: Int = 0, improvement: Int = 0, total: Int) {
        self.time = time; self.volume = volume; self.improvement = improvement; self.total = total
    }
}

/// Independent lifetime practice counters. Failed updates are atomic no-ops.
/// Only already accepted, measured time and accepted keys belong here.
public struct XPProgress: Codable, Sendable, Equatable {
    public private(set) var policyID = RewardProgressionPolicy.xpID
    public private(set) var levelsPolicyID = RewardProgressionPolicy.levelsID
    public private(set) var eligibleSeconds = 0.0
    public private(set) var eligibleKeys = 0
    public private(set) var timeXP = 0
    public private(set) var volumeXP = 0
    public private(set) var improvementXP = 0
    public private(set) var totalXP = 0
    public init() {}

    public var remainderSeconds: Double { eligibleSeconds - Double(timeXP) * RewardProgressionPolicy.secondsPerXP }
    public var remainderKeys: Int { eligibleKeys % RewardProgressionPolicy.keysPerXP }
    public var isValid: Bool {
        guard policyID == RewardProgressionPolicy.xpID, levelsPolicyID == RewardProgressionPolicy.levelsID,
              eligibleSeconds.isFinite, eligibleSeconds >= 0, eligibleKeys >= 0,
              timeXP >= 0, volumeXP >= 0, improvementXP >= 0, totalXP >= 0,
              improvementXP % RewardProgressionPolicy.improvementMilestoneXP == 0,
              Self.timeAwards(eligibleSeconds) == timeXP,
              eligibleKeys / RewardProgressionPolicy.keysPerXP == volumeXP else { return false }
        let base = timeXP.addingReportingOverflow(volumeXP)
        let total = base.partialValue.addingReportingOverflow(improvementXP)
        return !base.overflow && !total.overflow && total.partialValue == totalXP
    }

    @discardableResult public mutating func add(seconds: Double, keys: Int) -> XPAward? {
        guard isValid, seconds.isFinite, seconds >= 0, keys >= 0 else { return nil }
        let nextSeconds = eligibleSeconds + seconds, nextKeys = eligibleKeys.addingReportingOverflow(keys)
        guard nextSeconds.isFinite, !nextKeys.overflow, let nextTimeXP = Self.timeAwards(nextSeconds) else { return nil }
        let nextVolumeXP = nextKeys.partialValue / RewardProgressionPolicy.keysPerXP
        let time = nextTimeXP - timeXP, volume = nextVolumeXP - volumeXP
        let award = time.addingReportingOverflow(volume), total = totalXP.addingReportingOverflow(award.partialValue)
        guard time >= 0, volume >= 0, !award.overflow, !total.overflow else { return nil }
        eligibleSeconds = nextSeconds; eligibleKeys = nextKeys.partialValue
        timeXP = nextTimeXP; volumeXP = nextVolumeXP; totalXP = total.partialValue
        return XPAward(time: time, volume: volume, total: award.partialValue)
    }

    @discardableResult public mutating func addImprovementXP(_ xp: Int) -> XPAward? {
        guard isValid, xp >= 0, xp % RewardProgressionPolicy.improvementMilestoneXP == 0 else { return nil }
        let improvement = improvementXP.addingReportingOverflow(xp), total = totalXP.addingReportingOverflow(xp)
        guard !improvement.overflow, !total.overflow else { return nil }
        improvementXP = improvement.partialValue; totalXP = total.partialValue
        return XPAward(improvement: xp, total: xp)
    }

    private static func timeAwards(_ seconds: Double) -> Int? {
        let whole = floor(seconds / RewardProgressionPolicy.secondsPerXP)
        guard whole.isFinite, whole >= 0, whole < Double(Int.max) else { return nil }
        return Int(whole)
    }
}

public enum LevelSchedule {
    public static let policyID = RewardProgressionPolicy.levelsID
    public static func costToNextLevel(_ level: Int) -> Int? {
        guard level >= 1 else { return nil }
        switch level {
        case 1...3: return 10
        case 4: return 20
        case 5...19: return 30
        case 20...29: return 50
        case 30...49: return 100
        default: return 200
        }
    }
    public static func threshold(for level: Int) -> Int? {
        guard level >= 1 else { return nil }
        let start: Int, base: Int, cost: Int
        switch level {
        case 1...4: (start, base, cost) = (1, 0, 10)
        case 5...20: (start, base, cost) = (5, 50, 30)
        case 21...30: (start, base, cost) = (20, 500, 50)
        case 31...50: (start, base, cost) = (30, 1_000, 100)
        default: (start, base, cost) = (50, 3_000, 200)
        }
        let increment = (level - start).multipliedReportingOverflow(by: cost)
        let total = base.addingReportingOverflow(increment.partialValue)
        return increment.overflow || total.overflow ? nil : total.partialValue
    }
}

/// Constant-time lookup; nextThreshold is nil only if its integer would overflow.
public struct LevelProgress: Codable, Sendable, Equatable {
    public let level: Int
    public let totalXP: Int
    public let levelThreshold: Int
    public let nextThreshold: Int?
    public let progressXP: Int
    public let requiredXP: Int
    public let remainingXP: Int
    public init?(totalXP: Int) {
        guard totalXP >= 0 else { return nil }
        let start: Int, base: Int, cost: Int
        switch totalXP {
        case 0..<30: (start, base, cost) = (1, 0, 10)
        case 30..<50: (start, base, cost) = (4, 30, 20)
        case 50..<500: (start, base, cost) = (5, 50, 30)
        case 500..<1_000: (start, base, cost) = (20, 500, 50)
        case 1_000..<3_000: (start, base, cost) = (30, 1_000, 100)
        default: (start, base, cost) = (50, 3_000, 200)
        }
        level = start + (totalXP - base) / cost
        guard let threshold = LevelSchedule.threshold(for: level) else { return nil }
        self.totalXP = totalXP; levelThreshold = threshold; requiredXP = cost
        progressXP = totalXP - threshold; remainingXP = cost - progressXP
        nextThreshold = LevelSchedule.threshold(for: level + 1)
    }
}

/// No application identity participates in improvement. Policies are compared
/// separately so a new measurement version cannot mint a fresh award lineage.
public struct ImprovementContext: Codable, Sendable, Equatable, Hashable {
    public let language: String
    public let inputMethod: String
    public let measurementPolicy: String
    public let evidencePolicy: String
    public init(language: String, inputMethod: String, measurementPolicy: String, evidencePolicy: String) {
        self.language = InputLanguagePolicy.normalize(language)
        self.inputMethod = inputMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.measurementPolicy = measurementPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidencePolicy = evidencePolicy.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public init(language: String, inputMethodID: String?, usesInputMethod: Bool?, measurementPolicy: String,
                evidencePolicy: String = "global-probable-v1") {
        // The source/mode identifier is the stable non-content context. A nil
        // identifier remains unsupported rather than sharing an invented track.
        self.init(language: language, inputMethod: inputMethodID ?? "", measurementPolicy: measurementPolicy,
                  evidencePolicy: evidencePolicy)
    }
    public var id: String { "\(language.utf8.count):\(language)|\(inputMethod.utf8.count):\(inputMethod)" }
    public var isValid: Bool {
        language != "und" && language == InputLanguagePolicy.normalize(language)
            && Self.safe(inputMethod, limit: 255) && inputMethod == inputMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && Self.safe(measurementPolicy, limit: 512) && Self.safe(evidencePolicy, limit: 128)
    }
    private static func safe(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Completed compatible-context day; weightedCVSquared is Σ(nr * CVr²)
/// over qualifying uninterrupted fragments, never pooled raw interval variance.
public struct ImprovementDay: Codable, Sendable, Equatable {
    public let day: String
    public let speedIntervals: Double
    public let seconds: Double
    public let consistencyIntervals: Double
    public let consistencySeconds: Double
    public let weightedCVSquared: Double
    public let consistencySamples: Int
    public init(day: String, speedIntervals: Double, seconds: Double, consistencyIntervals: Double = 0,
                consistencySeconds: Double = 0, weightedCVSquared: Double = 0, consistencySamples: Int = 0) {
        self.day = day; self.speedIntervals = speedIntervals; self.seconds = seconds
        self.consistencyIntervals = consistencyIntervals; self.consistencySeconds = consistencySeconds
        self.weightedCVSquared = weightedCVSquared
        self.consistencySamples = consistencySamples
    }
    public var isValid: Bool {
        guard Self.validDay(day), consistencySamples >= 0, [speedIntervals, seconds, consistencyIntervals, consistencySeconds, weightedCVSquared]
            .allSatisfy({ $0.isFinite && $0 >= 0 }),
              (speedIntervals == 0) == (seconds == 0),
              (consistencyIntervals == 0) == (consistencySeconds == 0),
              consistencyIntervals <= speedIntervals + 1e-9, consistencySeconds <= seconds + 1e-9 else { return false }
        return consistencyIntervals > 0 || weightedCVSquared == 0
    }
    public var wpm: Double? {
        guard isValid, speedIntervals > 0, seconds > 0 else { return nil }
        let value = 12 * speedIntervals / seconds
        return value.isFinite && value > 0 ? value : nil
    }
    public var consistency: Double? {
        guard isValid, consistencySamples >= 10, consistencyIntervals >= 20, consistencySeconds >= 2 else { return nil }
        return RewardConsistency.percentage(coefficientOfVariation: sqrt(weightedCVSquared / consistencyIntervals))
    }
    fileprivate static func validDay(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.utf8.count == 10, pieces.count == 3, pieces.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }), pieces[0].count == 4,
              pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), year >= 1 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == parts
    }
}

public enum ImprovementMetric: String, Codable, Sendable { case speed, consistency }

/// One atomic, uniquely named range of newly verified milestones.
public struct ImprovementAward: Codable, Sendable, Equatable {
    public let id: String
    public let context: ImprovementContext
    public let metric: ImprovementMetric
    public let firstMilestone: Int
    public let milestone: Int
    public let xp: Int
}

public struct ImprovementCalibration: Codable, Sendable, Equatable {
    public fileprivate(set) var qualifyingDays = 0
    public fileprivate(set) var seconds = 0.0
    public fileprivate(set) var intervals = 0.0
    public fileprivate(set) var weightedCVSquared = 0.0
    public var isValid: Bool {
        guard qualifyingDays >= 0, [seconds, intervals, weightedCVSquared].allSatisfy({ $0.isFinite && $0 >= 0 }),
              (seconds == 0) == (intervals == 0) else { return false }
        return qualifyingDays == 0 ? seconds == 0 && intervals == 0 && weightedCVSquared == 0 : seconds > 0 && intervals > 0
    }
    fileprivate mutating func add(seconds: Double, intervals: Double, weightedCVSquared: Double = 0) -> Bool {
        let count = qualifyingDays.addingReportingOverflow(1)
        let time = self.seconds + seconds, weights = self.intervals + intervals, variation = self.weightedCVSquared + weightedCVSquared
        guard !count.overflow, [time, weights, variation].allSatisfy(\.isFinite) else { return false }
        qualifyingDays = count.partialValue; self.seconds = time; self.intervals = weights; self.weightedCVSquared = variation
        return true
    }
    fileprivate var ready: Bool {
        qualifyingDays >= RewardProgressionPolicy.calibrationDays && seconds >= RewardProgressionPolicy.calibrationSeconds
    }
}

public struct ImprovementTrack: Codable, Sendable, Equatable {
    public let context: ImprovementContext
    public fileprivate(set) var suspended = false
    public fileprivate(set) var lastCompletedDay: String?
    public fileprivate(set) var speedCalibration = ImprovementCalibration()
    public fileprivate(set) var consistencyCalibration = ImprovementCalibration()
    public fileprivate(set) var speedBaseline: Double?
    public fileprivate(set) var consistencyBaseline: Double?
    public fileprivate(set) var speedBaselineDay: String?
    public fileprivate(set) var consistencyBaselineDay: String?
    public fileprivate(set) var speedMilestone = 0
    public fileprivate(set) var consistencyMilestone = 0
    public fileprivate(set) var speedWindow: [ImprovementDay] = []
    public fileprivate(set) var consistencyWindow: [ImprovementDay] = []
    public var isValid: Bool {
        guard context.isValid, speedCalibration.isValid, consistencyCalibration.isValid,
              speedMilestone >= 0, consistencyMilestone >= 0,
              lastCompletedDay.map(ImprovementDay.validDay) ?? true,
              speedBaselineDay.map(ImprovementDay.validDay) ?? true,
              consistencyBaselineDay.map(ImprovementDay.validDay) ?? true,
              (speedBaseline == nil) == (speedBaselineDay == nil),
              (consistencyBaseline == nil) == (consistencyBaselineDay == nil),
              speedBaseline.map({ $0.isFinite && $0 > 0 }) ?? true,
              consistencyBaseline.map({ $0.isFinite && $0 >= 0 && $0 <= 100 }) ?? true,
              speedMilestone <= Int.max / RewardProgressionPolicy.improvementMilestoneXP,
              consistencyMilestone <= 20,
              speedBaseline != nil || speedMilestone == 0,
              consistencyBaseline != nil || consistencyMilestone == 0,
              speedBaselineDay.map({ baseline in lastCompletedDay.map { baseline <= $0 } ?? false }) ?? true,
              consistencyBaselineDay.map({ baseline in lastCompletedDay.map { baseline <= $0 } ?? false }) ?? true,
              speedBaseline == nil || speedCalibration.ready,
              consistencyBaseline == nil || consistencyCalibration.ready else { return false }
        if let baseline = speedBaseline {
            let expected = 12 * speedCalibration.intervals / speedCalibration.seconds
            guard expected.isFinite, abs(baseline - expected) <= max(1, expected) * 1e-12 else { return false }
        }
        if let baseline = consistencyBaseline {
            guard let expected = RewardConsistency.percentage(coefficientOfVariation:
                sqrt(consistencyCalibration.weightedCVSquared / consistencyCalibration.intervals)),
                  abs(baseline - expected) <= 1e-10 else { return false }
        }
        return Self.validWindow(speedWindow, after: speedBaselineDay, through: lastCompletedDay)
            && Self.validWindow(consistencyWindow, after: consistencyBaselineDay, through: lastCompletedDay)
    }
    fileprivate init(context: ImprovementContext) { self.context = context }
    private static func validWindow(_ values: [ImprovementDay], after baselineDay: String?, through end: String?) -> Bool {
        guard values.count <= RewardProgressionPolicy.windowDays else { return false }
        var previous = baselineDay
        for value in values {
            guard value.isValid, value.seconds >= RewardProgressionPolicy.qualifyingDaySeconds,
                  let prior = previous, value.day > prior, let end, value.day <= end else { return false }
            previous = value.day
        }
        return true
    }
}

/// Frozen baselines and seven qualifying-day windows; no text, event history,
/// app identifiers, or unbounded claim list. High-water marks outlive retention.
public struct ImprovementTracker: Codable, Sendable, Equatable {
    public private(set) var policyID = RewardProgressionPolicy.improvementID
    public private(set) var tracks: [String: ImprovementTrack] = [:]
    public init() {}
    public var isValid: Bool {
        policyID == RewardProgressionPolicy.improvementID && tracks.count <= RewardProgressionPolicy.maximumContexts
            && tracks.allSatisfy { $0.key == $0.value.context.id && $0.value.isValid }
    }

    @discardableResult public mutating func completedDay(context: ImprovementContext, day: ImprovementDay) -> [ImprovementAward] {
        guard isValid, context.isValid, day.isValid else { return [] }
        if tracks[context.id] == nil, tracks.count >= RewardProgressionPolicy.maximumContexts { return [] }
        var track = tracks[context.id] ?? ImprovementTrack(context: context)
        guard track.context.measurementPolicy == context.measurementPolicy,
              track.context.evidencePolicy == context.evidencePolicy else {
            track.suspended = true; tracks[context.id] = track; return []
        }
        guard !track.suspended, track.lastCompletedDay.map({ day.day > $0 }) ?? true else { return [] }
        track.lastCompletedDay = day.day
        guard day.seconds >= RewardProgressionPolicy.qualifyingDaySeconds else { tracks[context.id] = track; return [] }
        let hadSpeedBaseline = track.speedBaseline != nil, hadConsistencyBaseline = track.consistencyBaseline != nil
        if !hadSpeedBaseline, day.wpm != nil {
            guard track.speedCalibration.add(seconds: day.seconds, intervals: day.speedIntervals) else { return [] }
            if track.speedCalibration.ready {
                track.speedBaseline = 12 * track.speedCalibration.intervals / track.speedCalibration.seconds
                track.speedBaselineDay = day.day
            }
        }
        if !hadConsistencyBaseline, day.consistency != nil {
            guard track.consistencyCalibration.add(seconds: day.consistencySeconds, intervals: day.consistencyIntervals,
                                                   weightedCVSquared: day.weightedCVSquared) else { return [] }
            if track.consistencyCalibration.ready {
                track.consistencyBaseline = RewardConsistency.percentage(coefficientOfVariation:
                    sqrt(track.consistencyCalibration.weightedCVSquared / track.consistencyCalibration.intervals))
                track.consistencyBaselineDay = day.day
            }
        }
        if hadSpeedBaseline { Self.append(day, to: &track.speedWindow) }
        if hadConsistencyBaseline { Self.append(day, to: &track.consistencyWindow) }
        var awards: [ImprovementAward] = []
        if let baseline = track.speedBaseline {
            if let award = Self.verify(context: context, metric: .speed, baseline: baseline,
                                       window: track.speedWindow, highWater: &track.speedMilestone) { awards.append(award) }
        }
        if let baseline = track.consistencyBaseline {
            if let award = Self.verify(context: context, metric: .consistency, baseline: baseline,
                                       window: track.consistencyWindow, highWater: &track.consistencyMilestone) { awards.append(award) }
        }
        guard track.isValid else { return [] }
        tracks[context.id] = track
        return awards
    }

    private static func append(_ day: ImprovementDay, to window: inout [ImprovementDay]) {
        if window.count == RewardProgressionPolicy.windowDays { window.removeFirst() }
        window.append(day)
    }
    private static func verify(context: ImprovementContext, metric: ImprovementMetric, baseline: Double,
                               window: [ImprovementDay], highWater: inout Int) -> ImprovementAward? {
        let valid = window.filter { metric == .speed ? $0.wpm != nil : $0.consistency != nil }
        guard valid.count >= RewardProgressionPolicy.verificationDays else { return nil }
        let seconds = valid.reduce(0) { $0 + (metric == .speed ? $1.seconds : $1.consistencySeconds) }
        guard seconds.isFinite, seconds >= RewardProgressionPolicy.verificationSeconds else { return nil }
        let intervals = valid.reduce(0) { $0 + (metric == .speed ? $1.speedIntervals : $1.consistencyIntervals) }
        let variation = valid.reduce(0) { $0 + $1.weightedCVSquared }
        guard let pooled = metric == .speed ? Optional(12 * intervals / seconds) :
            RewardConsistency.percentage(coefficientOfVariation: sqrt(variation / intervals)) else { return nil }
        guard let pooledStep = step(for: pooled, baseline: baseline, metric: metric) else { return nil }
        let daily = valid.compactMap { step(for: metric == .speed ? $0.wpm! : $0.consistency!, baseline: baseline, metric: metric) }.sorted(by: >)
        guard daily.count >= RewardProgressionPolicy.verificationDays else { return nil }
        let milestone = min(pooledStep, daily[RewardProgressionPolicy.verificationDays - 1])
        guard milestone > highWater else { return nil }
        let count = milestone - highWater, xp = count.multipliedReportingOverflow(by: RewardProgressionPolicy.improvementMilestoneXP)
        guard !xp.overflow else { return nil }
        let first = highWater + 1
        highWater = milestone
        return ImprovementAward(id: "\(RewardProgressionPolicy.improvementID)|\(context.id)|\(metric.rawValue)|\(first)-\(milestone)",
                                context: context, metric: metric, firstMilestone: first, milestone: milestone, xp: xp.partialValue)
    }
    private static func step(for estimate: Double, baseline: Double, metric: ImprovementMetric) -> Int? {
        guard estimate.isFinite, estimate >= 0, baseline.isFinite,
              metric == .speed ? baseline > 0 : baseline >= 0 else { return nil }
        let improvement = metric == .speed ? (estimate / baseline - 1) / 0.05 : (min(100, estimate) - baseline) / 5
        // A tiny tolerance only compensates aggregate floating-point roundoff.
        let value = floor(max(0, improvement) + 1e-10)
        guard value.isFinite, value < Double(Int.max / RewardProgressionPolicy.improvementMilestoneXP) else { return nil }
        let step = Int(value)
        if metric == .consistency {
            // A floating-point tolerance must never create a threshold beyond
            // the metric's actual 100-point ceiling.
            return min(step, Int(floor(max(0, 100 - baseline) / 5 + 1e-10)))
        }
        return step
    }
}
