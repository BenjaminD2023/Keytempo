import Foundation

/// The daily index and XP have no product ceiling. Numeric overflow remains an
/// unavailable result, never a wrapped balance or an invented high score.
public enum DailyRewardPolicy {
    public static let id = "daily-rewards-v1"
    public static let score = "daily-score-v3"
    public static let xp = "daily-xp-v2"
    public static let levels = "levels-v2-150"
    public static let legacyScale = 150
    public static let maximumPendingDays = 1_830
    public static let maximumPendingReceipts = 8_192
}

public enum DailyRewardScore {
    public static func value(wpm: Double, consistency: Double, typingSeconds: Double, keys: Int) -> Int? {
        guard wpm.isFinite, wpm > 0, consistency.isFinite, (0...100).contains(consistency),
              typingSeconds.isFinite, typingSeconds >= 0, keys >= 0 else { return nil }
        let practice = typingSeconds / 60 + Double(keys) / 300
        guard practice > 0 else { return nil }
        let value = (150 * sqrt(practice) * sqrt(wpm / 50) * exp((consistency - 75) / 100)).rounded()
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }

    public static func value(totals: RhythmTotals) -> Int? {
        guard totals.isValid, totals.intervals >= 20, totals.seconds >= 2,
              let wpm = totals.wpm, let consistency = totals.consistency else { return nil }
        return value(wpm: wpm, consistency: consistency, typingSeconds: totals.seconds, keys: totals.keys)
    }
}

public enum DailyLevelSchedule {
    public static func costToNextLevel(_ level: Int) -> Int? {
        LevelSchedule.costToNextLevel(level).flatMap(scale)
    }
    public static func threshold(for level: Int) -> Int? {
        LevelSchedule.threshold(for: level).flatMap(scale)
    }
    private static func scale(_ value: Int) -> Int? {
        let result = value.multipliedReportingOverflow(by: DailyRewardPolicy.legacyScale)
        return result.overflow ? nil : result.partialValue
    }
}

/// Dividing only for the piecewise level lookup retains every new-unit XP in
/// progressXP. The conversion itself preserves the previous level exactly.
public struct DailyLevelProgress: Codable, Sendable, Equatable {
    public let level: Int, totalXP: Int, levelThreshold: Int, progressXP: Int, requiredXP: Int, remainingXP: Int
    public let nextThreshold: Int?
    public init?(totalXP: Int) {
        guard totalXP >= 0, let old = LevelProgress(totalXP: totalXP / DailyRewardPolicy.legacyScale),
              let threshold = DailyLevelSchedule.threshold(for: old.level),
              let cost = DailyLevelSchedule.costToNextLevel(old.level) else { return nil }
        self.totalXP = totalXP; level = old.level; levelThreshold = threshold; requiredXP = cost
        progressXP = totalXP - threshold; remainingXP = cost - progressXP
        nextThreshold = DailyLevelSchedule.threshold(for: old.level + 1)
    }
}

private func dailyRewardDayValid(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1...9999).contains(year) else { return false }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
    let roundtrip = calendar.dateComponents([.year, .month, .day], from: date)
    return roundtrip.year == year && roundtrip.month == month && roundtrip.day == day
}

public struct DailyRewardDay: Codable, Sendable, Equatable, Identifiable {
    public var day: String
    public var totals: RhythmTotals
    public var rule: String?
    public var mixedRules: Bool
    public var sealed: Bool
    public var id: String { day }
    public init(day: String, totals: RhythmTotals = .init(), rule: String? = nil, mixedRules: Bool = false, sealed: Bool = false) {
        self.day = day; self.totals = totals; self.rule = rule; self.mixedRules = mixedRules; self.sealed = sealed
    }
    public var score: Int? { mixedRules ? nil : DailyRewardScore.value(totals: totals) }
    public var preliminary: Bool { totals.seconds < 300 || totals.keys < 1_000 }
    public var isValid: Bool {
        dailyRewardDayValid(day) && totals.isValid &&
        (rule.map { !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true)
    }
}

/// Immutable financial receipt. Seen/animation acknowledgements are separate
/// store records, so showing or skipping a receipt never awards XP again.
public struct DailySettlementReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String, day: String, policy: String
    public var settledAt: Date
    public var score: Int?
    public var ordinaryXP: Int, improvementXP: Int, beforeXP: Int, afterXP: Int, levelBefore: Int, levelAfter: Int
    public var totals: RhythmTotals
    public var rule: String?
    public var mixedRules: Bool
    public init(id: String, day: String, settledAt: Date, score: Int?, ordinaryXP: Int, improvementXP: Int,
                beforeXP: Int, afterXP: Int, totals: RhythmTotals, rule: String? = nil, mixedRules: Bool = false,
                policy: String = DailyRewardPolicy.score) {
        self.id = id; self.day = day; self.settledAt = settledAt; self.score = score
        self.ordinaryXP = ordinaryXP; self.improvementXP = improvementXP; self.beforeXP = beforeXP; self.afterXP = afterXP
        self.totals = totals; self.rule = rule; self.mixedRules = mixedRules; self.policy = policy
        levelBefore = DailyLevelProgress(totalXP: beforeXP)?.level ?? 0
        levelAfter = DailyLevelProgress(totalXP: afterXP)?.level ?? 0
    }
    public var totalXPBefore: Int { beforeXP }
    public var totalXPAfter: Int { afterXP }
    public var xp: Int {
        let result = ordinaryXP.addingReportingOverflow(improvementXP)
        return result.overflow ? -1 : result.partialValue
    }
    public var dailyRewardDay: DailyRewardDay { .init(day: day, totals: totals, rule: rule, mixedRules: mixedRules, sealed: true) }
    public var asDay: DailyRewardDay { dailyRewardDay }
    public var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 256, dailyRewardDay.isValid, policy == DailyRewardPolicy.score,
              settledAt.timeIntervalSince1970.isFinite, score == dailyRewardDay.score,
              ordinaryXP == (score ?? 0), ordinaryXP >= 0, improvementXP >= 0,
              improvementXP.isMultiple(of: RewardProgressionPolicy.improvementMilestoneXP * DailyRewardPolicy.legacyScale),
              beforeXP >= 0, afterXP >= beforeXP, xp >= 0,
              DailyLevelProgress(totalXP: beforeXP)?.level == levelBefore,
              DailyLevelProgress(totalXP: afterXP)?.level == levelAfter else { return false }
        let sum = beforeXP.addingReportingOverflow(xp)
        return !sum.overflow && sum.partialValue == afterXP
    }
}

public typealias DailyRewardReceipt = DailySettlementReceipt

public struct DailyRewardState: Codable, Sendable, Equatable {
    public var revision: Int64 = 0
    public var policy = DailyRewardPolicy.id
    public var coverageStart: Date, progressionTimezone: String, currentDay: String, lineage: String
    public var settledThroughDay: String?
    public var migratedLegacyXP: Int, totalXP: Int, observedLegacyImprovementXP: Int, pendingImprovementXP: Int = 0
    /// Only open/uncommitted days. Finalized history and unseen receipts are
    /// paged from SQLite instead of retained in an ever-growing memory array.
    public var days: [String: DailyRewardDay]
    public init(coverageStart: Date, progressionTimezone: String, currentDay: String, migratedLegacyXP: Int = 0,
                observedLegacyImprovementXP: Int = 0, lineage: String = UUID().uuidString) {
        self.coverageStart = coverageStart; self.progressionTimezone = progressionTimezone; self.currentDay = currentDay
        self.migratedLegacyXP = migratedLegacyXP; totalXP = migratedLegacyXP
        self.observedLegacyImprovementXP = observedLegacyImprovementXP; self.lineage = lineage
        days = [currentDay: .init(day: currentDay)]
    }
    public var current: DailyRewardDay? { days[currentDay] }
    public var isValid: Bool {
        revision >= 0 && policy == DailyRewardPolicy.id && coverageStart.timeIntervalSince1970.isFinite &&
        TimeZone(identifier: progressionTimezone) != nil && dailyRewardDayValid(currentDay) &&
        !lineage.isEmpty && lineage.utf8.count <= 128 && migratedLegacyXP >= 0 && migratedLegacyXP.isMultiple(of: DailyRewardPolicy.legacyScale) &&
        totalXP >= migratedLegacyXP && DailyLevelProgress(totalXP: totalXP) != nil &&
        observedLegacyImprovementXP >= 0 && observedLegacyImprovementXP.isMultiple(of: RewardProgressionPolicy.improvementMilestoneXP) &&
        pendingImprovementXP >= 0 && pendingImprovementXP.isMultiple(of: RewardProgressionPolicy.improvementMilestoneXP * DailyRewardPolicy.legacyScale) &&
        (settledThroughDay.map { dailyRewardDayValid($0) && $0 < currentDay } ?? true) &&
        days.count <= DailyRewardPolicy.maximumPendingDays && days[currentDay] != nil &&
        days.allSatisfy { key, value in
            key == value.day && key <= currentDay && (settledThroughDay.map { key > $0 } ?? true) && value.isValid &&
            (key == currentDay ? !value.sealed : value.sealed)
        }
    }
}

public struct DailyRewardWrite: Codable, Sendable, Equatable {
    public var state: DailyRewardState
    public var receipts: [DailySettlementReceipt]
    public init(state: DailyRewardState, receipts: [DailySettlementReceipt] = []) { self.state = state; self.receipts = receipts }
}

public enum DailyRewardError: Error, Equatable { case invalidState, invalidInput, capacity }

/// Metadata-only coordinator. Day closure, XP commitment and presentation
/// acknowledgement are deliberately independent operations.
public struct DailyRewardEngine: Sendable {
    public private(set) var state: DailyRewardState
    public private(set) var error: DailyRewardError?
    public private(set) var hasPendingChanges = false
    private var tracker: ActivityTracker
    private var pendingReceipts: [DailySettlementReceipt] = []
    private var lastInputTime: Double?, chainStartTime: Double?
    public var unpersistedReceipts: [DailySettlementReceipt] { pendingReceipts }
    private var zone: TimeZone { TimeZone(identifier: state.progressionTimezone)! }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }

    public init(coverageStart: Date = Date(), legacyTotalXP: Int = 0, legacyImprovementXP: Int = 0,
                progressionTimeZone: TimeZone = .current) {
        let safeDate = coverageStart.timeIntervalSince1970.isFinite ? coverageStart : Date(timeIntervalSince1970: 0)
        let day = Self.day(safeDate, zone: progressionTimeZone)
        let converted = legacyTotalXP.multipliedReportingOverflow(by: DailyRewardPolicy.legacyScale)
        state = .init(coverageStart: coverageStart, progressionTimezone: progressionTimeZone.identifier, currentDay: day,
                      migratedLegacyXP: converted.overflow ? 0 : converted.partialValue, observedLegacyImprovementXP: legacyImprovementXP)
        tracker = ActivityTracker(timeZone: progressionTimeZone)
        if converted.overflow { error = .capacity }
        else if legacyTotalXP < legacyImprovementXP || !state.isValid { error = .invalidState }
        hasPendingChanges = error == nil
    }

    /// A relaunch ends timing continuity and seals past dates, but does not
    /// assume that relaunching while awake means a rest/settlement occurred.
    public init(restoring: DailyRewardState, now: Date) throws {
        guard restoring.isValid else { throw DailyRewardError.invalidState }
        state = restoring; tracker = ActivityTracker(timeZone: TimeZone(identifier: restoring.progressionTimezone)!)
        advance(to: now)
    }

    private static func day(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private func day(_ date: Date) -> String { Self.day(date, zone: zone) }
    private func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public mutating func record(input: ClassifiedInput, result: StatisticsRecordResult, rule: String) {
        guard error == nil, input.time.isFinite, input.date.timeIntervalSince1970.isFinite,
              input.source == .global, input.evidence == .probable, input.category.isEffective,
              result.deltas.filter({ $0.evidence == .probable }).reduce(0, { $0 + $1.keys }) == 1,
              lastInputTime.map({ input.time > $0 }) ?? true else { return }
        guard result.acceptedIntervals.count <= 3, !rule.isEmpty, rule.utf8.count <= 512 else { error = .invalidInput; return }
        var transaction = self
        transaction.process(input: input, result: result, rule: rule)
        if transaction.error == nil { self = transaction } else { error = transaction.error }
    }

    private mutating func process(input: ClassifiedInput, result: StatisticsRecordResult, rule: String) {
        var input = input
        // Reward days do not move backward with the wall clock. Map a rolled
        // back local date into the still-open logical day, retaining time of day.
        if day(input.date) < state.currentDay, let start = date(state.currentDay) {
            let oldStart = calendar.startOfDay(for: input.date)
            let shift = calendar.dateComponents([.day], from: oldStart, to: start).day ?? 0
            if let corrected = calendar.date(byAdding: .day, value: shift, to: input.date) { input.date = corrected }
        }
        advance(to: input.date)
        guard error == nil else { return }
        let intervals = chainStartTime.map { start in result.acceptedIntervals.filter { $0.startTime >= start } } ?? []
        let qualified = StatisticsRecordResult(deltas: result.deltas, acceptedIntervals: intervals)
        let batch = tracker.record(input: input, result: qualified, rule: rule, perAppEnabled: false)
        guard batch.hourly.count <= 32 else { error = .capacity; return }
        for hour in batch.hourly where hour.applicationID.isEmpty {
            let key = day(hour.bucketStart)
            if let closed = state.settledThroughDay, key <= closed { continue }
            var value = state.days[key] ?? DailyRewardDay(day: key, sealed: key < state.currentDay)
            if let existing = value.rule, existing != rule { value.mixedRules = true }
            if value.rule == nil { value.rule = rule }
            value.totals.merge(hour.totals)
            guard value.isValid else { error = .invalidInput; return }
            if state.days[key] == nil, state.days.count >= DailyRewardPolicy.maximumPendingDays { error = .capacity; return }
            state.days[key] = value
        }
        if chainStartTime == nil { chainStartTime = input.time }
        lastInputTime = input.time; hasPendingChanges = true
    }

    public mutating func advance(to date: Date) {
        guard error == nil else { return }
        guard date.timeIntervalSince1970.isFinite else { error = .invalidInput; return }
        let next = day(date)
        guard dailyRewardDayValid(next) else { error = .invalidInput; return }
        guard next > state.currentDay else { return }
        guard state.days.count < DailyRewardPolicy.maximumPendingDays else { error = .capacity; return }
        state.days[state.currentDay]?.sealed = true
        state.currentDay = next; state.days[next] = DailyRewardDay(day: next)
        hasPendingChanges = true
    }

    public mutating func interrupt(at date: Date, reason: String = "boundary") {
        guard error == nil else { return }
        _ = tracker.finish(reason: reason)
        chainStartTime = nil
        advance(to: date)
    }

    /// Legacy improvement uses persistent completed-day calibration and claim
    /// high-water marks. Ordinary old time/key XP is deliberately not mirrored.
    public mutating func observeLegacyImprovement(total: Int) {
        guard error == nil else { return }
        guard total >= state.observedLegacyImprovementXP,
              total.isMultiple(of: RewardProgressionPolicy.improvementMilestoneXP) else { error = .invalidInput; return }
        let delta = total - state.observedLegacyImprovementXP
        guard delta > 0 else { return }
        let converted = delta.multipliedReportingOverflow(by: DailyRewardPolicy.legacyScale)
        let pending = state.pendingImprovementXP.addingReportingOverflow(converted.partialValue)
        guard !converted.overflow, !pending.overflow else { error = .capacity; return }
        state.observedLegacyImprovementXP = total; state.pendingImprovementXP = pending.partialValue; hasPendingChanges = true
    }

    /// Called only after a real rest boundary or confirmed startup catch-up.
    /// Midday sleep cannot commit the still-open current reward day.
    public mutating func settleEndedDays(at date: Date) {
        guard error == nil else { return }
        var transaction = self
        transaction.interrupt(at: date, reason: "daily-settlement")
        guard transaction.error == nil else { error = transaction.error; return }
        let ended = transaction.state.days.keys.filter { $0 < transaction.state.currentDay }.sorted()
        for key in ended {
            guard let value = transaction.state.days[key] else { continue }
            let improvement = key == ended.last ? transaction.state.pendingImprovementXP : 0
            let ordinary = value.score ?? 0
            if value.totals.keys > 0 || value.totals.seconds > 0 || improvement > 0 {
                guard transaction.pendingReceipts.count < DailyRewardPolicy.maximumPendingReceipts else { error = .capacity; return }
                let award = ordinary.addingReportingOverflow(improvement)
                let balance = transaction.state.totalXP.addingReportingOverflow(award.partialValue)
                guard !award.overflow, !balance.overflow else { error = .capacity; return }
                let receipt = DailySettlementReceipt(id: transaction.state.lineage + ":" + key, day: key, settledAt: date,
                    score: value.score, ordinaryXP: ordinary, improvementXP: improvement, beforeXP: transaction.state.totalXP,
                    afterXP: balance.partialValue, totals: value.totals, rule: value.rule, mixedRules: value.mixedRules)
                guard receipt.isValid else { error = .invalidState; return }
                transaction.pendingReceipts.append(receipt); transaction.state.totalXP = receipt.afterXP
            }
            transaction.state.days.removeValue(forKey: key)
            transaction.state.settledThroughDay = key
            if improvement > 0 { transaction.state.pendingImprovementXP = 0 }
            transaction.hasPendingChanges = true
        }
        guard transaction.state.isValid else { error = .invalidState; return }
        self = transaction
    }

    /// A disk checkpoint does not settle or break the input sampler.
    public mutating func checkpoint(at date: Date = Date()) -> DailyRewardWrite {
        advance(to: date)
        guard error == nil, state.isValid else { if error == nil { error = .invalidState }; return .init(state: state) }
        guard state.revision < Int64.max else { error = .capacity; return .init(state: state) }
        state.revision += 1
        let write = DailyRewardWrite(state: state, receipts: pendingReceipts)
        pendingReceipts.removeAll(keepingCapacity: true); hasPendingChanges = false
        return write
    }
}
