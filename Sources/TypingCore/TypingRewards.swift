import Foundation

private func rewardClose(_ lhs: Double, _ rhs: Double) -> Bool {
    lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= max(1e-8, max(abs(lhs), abs(rhs)) * 1e-10)
}
private func rewardDayValid(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
    return (1...9999).contains(year) && (1...12).contains(month) && (1...31).contains(day)
}
private func rewardMomentsValid(_ count: Double, _ seconds: Double, _ squared: Double) -> Bool {
    guard [count, seconds, squared].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
    if count == 0 { return seconds == 0 && squared == 0 }
    let second = squared / count, mean = seconds / count
    return second - mean * mean >= -max(1e-12, second * 1e-10)
}

public enum TypingRewardPolicy {
    public static let score = "score-v2"
    public static let blockKeys = 100
    public static let timeScale = 3600.0
    public static let volumeScale = 15000.0
    public static let baseScale = 60.0
    public static let minimumSpeedIntervals = 20.0
    public static let minimumConsistencyIntervals = 20.0
    public static let minimumFragmentIntervals = 10.0
    public static let minimumFragmentSamples = 2
    public static let minimumConsistencySamples = 10
    public static let minimumSeconds = 2.0
}

public struct RewardComponents: Codable, Sendable, Equatable {
    public var time: Double, volume: Double, speedBonus: Double, consistencyBonus: Double
    public init(time: Double = 0, volume: Double = 0, speedBonus: Double = 0, consistencyBonus: Double = 0) {
        self.time = time; self.volume = volume; self.speedBonus = speedBonus; self.consistencyBonus = consistencyBonus
    }
    public var total: Double { time + volume + speedBonus + consistencyBonus }
    public var base: Double { time + volume }
    public var isValid: Bool { [time, volume, speedBonus, consistencyBonus, total].allSatisfy { $0.isFinite && $0 >= 0 } }
    public mutating func merge(_ other: Self) { time += other.time; volume += other.volume; speedBonus += other.speedBonus; consistencyBonus += other.consistencyBonus }
    public func scaled(by fraction: Double) -> Self { .init(time: time * fraction, volume: volume * fraction, speedBonus: speedBonus * fraction, consistencyBonus: consistencyBonus * fraction) }
}
public struct RewardXP: Codable, Sendable, Equatable {
    public var time: Int, volume: Int, improvement: Int
    public init(time: Int = 0, volume: Int = 0, improvement: Int = 0) { self.time = time; self.volume = volume; self.improvement = improvement }
    public var total: Int { let a = time.addingReportingOverflow(volume); let b = a.partialValue.addingReportingOverflow(improvement); return a.overflow || b.overflow ? -1 : b.partialValue }
    public var isValid: Bool { time >= 0 && volume >= 0 && improvement >= 0 && total >= 0 }
    public mutating func merge(_ other: Self) {
        let t = time.addingReportingOverflow(other.time), v = volume.addingReportingOverflow(other.volume), i = improvement.addingReportingOverflow(other.improvement)
        guard isValid, other.isValid, !t.overflow, !v.overflow, !i.overflow else { time = -1; return }
        time = t.partialValue; volume = v.partialValue; improvement = i.partialValue
        if total < 0 { time = -1 }
    }
    init(_ award: XPAward?) { self.init(time: award?.time ?? 0, volume: award?.volume ?? 0, improvement: award?.improvement ?? 0) }
}
public struct RewardAttribution: Codable, Sendable, Equatable {
    public var day: String, hour: Date, sessionID: String?
    public var components: RewardComponents, xp: RewardXP
    public init(day: String, hour: Date, sessionID: String? = nil, components: RewardComponents = .init(), xp: RewardXP = .init()) {
        self.day = day; self.hour = hour; self.sessionID = sessionID; self.components = components; self.xp = xp
    }
    var key: String { day + "|" + String(hour.timeIntervalSince1970) + "|" + (sessionID ?? "") }
    public var isValid: Bool { rewardDayValid(day) && hour.timeIntervalSince1970.isFinite && (sessionID?.utf8.count ?? 0) <= 128 && components.isValid && xp.isValid }
}
public struct RewardAward: Codable, Sendable, Equatable, Identifiable {
    public var id: String, date: Date, day: String, policy: String, kind: String, blockID: String?
    public var claimID: String?
    public var components: RewardComponents, xpSources: RewardXP, attributions: [RewardAttribution]
    public init(id: String, date: Date, day: String, policy: String = TypingRewardPolicy.score, kind: String, blockID: String? = nil,
                components: RewardComponents = .init(), xpSources: RewardXP = .init(), attributions: [RewardAttribution] = [], claimID: String? = nil) {
        self.id = id; self.date = date; self.day = day; self.policy = policy; self.kind = kind; self.blockID = blockID
        self.components = components; self.xpSources = xpSources; self.attributions = attributions; self.claimID = claimID
    }
    public var score: Double { components.total }
    public var xp: Int { xpSources.total }
    public var source: String { kind }
    public var attributedHour: Date? { attributions.count == 1 ? attributions[0].hour : nil }
    public var sessionID: String? { attributions.count == 1 ? attributions[0].sessionID : nil }
    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && date.timeIntervalSince1970.isFinite && rewardDayValid(day) &&
        policy == TypingRewardPolicy.score && kind.utf8.count <= 80 && components.isValid && xpSources.isValid &&
        (claimID?.utf8.count ?? 0) <= 1024 && attributions.count <= 128 && attributions.allSatisfy(\.isValid)
    }
}
public struct RewardQuality: Codable, Sendable, Equatable {
    public var intervals = 0.0, seconds = 0.0, weightedCVSquared = 0.0
    public var samples = 0
    public init() {}
    public var isValid: Bool { [intervals, seconds, weightedCVSquared].allSatisfy { $0.isFinite && $0 >= 0 } && samples >= 0 && rewardClose(seconds, Double(samples)) }
    public var consistency: Double? {
        guard intervals >= 20, seconds >= 2, samples >= 10 else { return nil }
        return RewardConsistency.percentage(coefficientOfVariation: sqrt(weightedCVSquared / intervals)).map { $0 / 100 }
    }
    mutating func merge(_ other: Self) {
        let count = samples.addingReportingOverflow(other.samples)
        guard isValid, other.isValid, !count.overflow else { samples = -1; return }
        intervals += other.intervals; seconds += other.seconds; weightedCVSquared += other.weightedCVSquared; samples = count.partialValue
    }
}
public struct RewardRunFragment: Codable, Sendable, Equatable {
    public var context: ImprovementContext
    public var intervals = 0.0, seconds = 0.0, squaredSeconds = 0.0
    public var rates = RateConsistencyTotals()
    public init(context: ImprovementContext) { self.context = context }
    public var isValid: Bool { rewardMomentsValid(intervals, seconds, squaredSeconds) && rates.isValid && Double(rates.count) <= seconds + 1e-8 && Double(rates.intervals) <= intervals + 1e-8 }
    public var quality: RewardQuality? {
        guard isValid, intervals >= 10, rates.count >= 2, rates.intervals > 0, rates.sum > 0 else { return nil }
        let n = Double(rates.count), mean = rates.sum / n, second = rates.squaredSum / n
        let variance = second - mean * mean
        guard variance >= -max(1e-12, second * 1e-10) else { return nil }
        let cvSquared = max(0, variance) / (mean * mean)
        guard cvSquared.isFinite else { return nil }
        var value = RewardQuality(); value.intervals = Double(rates.intervals); value.seconds = n
        value.weightedCVSquared = value.intervals * cvSquared; value.samples = rates.count
        return value
    }
}
public struct RewardContextDay: Codable, Sendable, Equatable {
    public var context: ImprovementContext
    public var speedIntervals = 0.0, seconds = 0.0
    public var quality = RewardQuality()
    public init(context: ImprovementContext) { self.context = context }
    var dayEvidence: (String) -> ImprovementDay { { day in ImprovementDay(day: day, speedIntervals: speedIntervals, seconds: seconds,
        consistencyIntervals: quality.intervals, consistencySeconds: quality.seconds, weightedCVSquared: quality.weightedCVSquared, consistencySamples: quality.samples) } }
    public var isValid: Bool { context.isValid && speedIntervals.isFinite && speedIntervals >= 0 && seconds.isFinite && seconds >= 0 && quality.isValid && quality.intervals <= speedIntervals + 1e-8 && quality.seconds <= seconds + 1e-8 }
}
public struct RewardDayBudget: Codable, Sendable, Equatable {
    public var day: String
    public var seconds = 0.0, keys = 0
    public var components = RewardComponents(), xp = RewardXP()
    public var contexts: [String: RewardContextDay] = [:]
    public var completed = false
    public init(day: String) { self.day = day }
    public var isValid: Bool {
        rewardDayValid(day) && seconds.isFinite && seconds >= 0 && keys >= 0 && components.isValid && xp.isValid && contexts.count <= 64 && contexts.values.allSatisfy(\.isValid) &&
        rewardClose(components.time, 60 * log1p(seconds / 3600)) && rewardClose(components.volume, 60 * log1p(Double(keys) / 15000)) &&
        components.speedBonus <= 0.25 * components.base + 1e-8 && components.consistencyBonus <= 0.15 * components.base + 1e-8
    }
}
public struct RewardBlockState: Codable, Sendable, Equatable, Identifiable {
    public var id: String, day: String, measurementPolicy: String, evidencePolicy: String
    public var keys = 0
    public var base = RewardComponents()
    public var speedIntervals = 0.0, speedSeconds = 0.0, squaredSeconds = 0.0
    public var quality = RewardQuality()
    public var fragment: RewardRunFragment?
    public var attributions: [RewardAttribution] = []
    public init(id: String, day: String, measurementPolicy: String, evidencePolicy: String) {
        self.id = id; self.day = day; self.measurementPolicy = measurementPolicy; self.evidencePolicy = evidencePolicy
    }
    public var isFull: Bool { keys >= 100 }
    public var isValid: Bool {
        !id.isEmpty && rewardDayValid(day) && keys >= 0 && keys <= 100 && base.isValid && base.speedBonus == 0 && base.consistencyBonus == 0 &&
        rewardMomentsValid(speedIntervals, speedSeconds, squaredSeconds) && quality.isValid && quality.intervals <= speedIntervals + 1e-8 && quality.seconds <= speedSeconds + 1e-8 &&
        (fragment?.isValid ?? true) && attributions.count <= 128 && attributions.allSatisfy(\.isValid)
    }
}
public struct RewardState: Codable, Sendable, Equatable {
    public var revision: Int64 = 0
    public var coverageStart: Date, progressionTimezone: String, currentDay: String
    public var lifetimeScore = RewardComponents()
    public var xpProgress = XPProgress(), improvement = ImprovementTracker()
    public var days: [String: RewardDayBudget] = [:], blocks: [RewardBlockState] = []
    public var lineage: String, nextAward: Int64 = 0, nextBlock: Int64 = 0
    public var scorePolicy = TypingRewardPolicy.score
    public init(coverageStart: Date, progressionTimezone: String, currentDay: String, lineage: String = UUID().uuidString) {
        self.coverageStart = coverageStart; self.progressionTimezone = progressionTimezone; self.currentDay = currentDay; self.lineage = lineage
        days[currentDay] = RewardDayBudget(day: currentDay)
    }
    public var pendingBlockKeys: Int { blocks.reduce(0) { $0 + $1.keys } }
    public var pendingBlockCount: Int { blocks.count }
    /// Ordinary engine transactions mutate only explicitly tracked days. All
    /// other retained history was validated on construction or a boundary.
    fileprivate func isValid(affectedDays: Set<String>) -> Bool {
        revision >= 0 && nextAward >= 0 && nextBlock >= 0 && !lineage.isEmpty && lineage.utf8.count <= 128 &&
        coverageStart.timeIntervalSince1970.isFinite && TimeZone(identifier: progressionTimezone) != nil && rewardDayValid(currentDay) &&
        scorePolicy == TypingRewardPolicy.score && lifetimeScore.isValid && xpProgress.isValid && days.count <= 30 &&
        days[currentDay] != nil && affectedDays.allSatisfy { key in
            guard let budget = days[key] else { return false }
            return key == budget.day && key <= currentDay && budget.isValid
        } && blocks.count <= 4 && blocks.allSatisfy(\.isValid) && Set(blocks.map(\.id)).count == blocks.count &&
        blocks.allSatisfy { days[$0.day] != nil && !days[$0.day]!.completed && $0.keys <= days[$0.day]!.keys } &&
        lifetimeScore.speedBonus <= 0.25 * lifetimeScore.base + 1e-8 && lifetimeScore.consistencyBonus <= 0.15 * lifetimeScore.base + 1e-8
    }
    public var isValid: Bool { isValid(affectedDays: Set(days.keys)) && improvement.isValid }
}
public struct RewardWrite: Codable, Sendable, Equatable {
    public var state: RewardState, awards: [RewardAward]
    public init(state: RewardState, awards: [RewardAward]) { self.state = state; self.awards = awards }
}
public enum RewardError: Error, Equatable { case invalidState, capacity, invalidInput }

/// One canonical stream, outside the keyboard callback. Checkpoints contain
/// aggregates only. Four transient endpoint-to-block assignments reconcile the
/// measurement engine's at-most-three delayed intervals; none are Codable.
public struct RewardEngine: Sendable {
    public private(set) var state: RewardState
    public private(set) var hasPendingChanges = false
    public private(set) var error: RewardError?
    private struct Endpoint: Sendable { let time: Double, date: Date, block: String, context: ImprovementContext, session: String? }
    private var endpoints: [Endpoint] = []
    private var samplers: [String: RateConsistencySampler] = [:]
    private var fragmentEnds: [String: Double] = [:]
    private var pending: [RewardAward] = []
    private var coalescing: [String: Int] = [:]
    private var lastInput: Double?, lastIntervalEnd: Double?
    private var activeContext: ImprovementContext?, activeControl: UInt64?
    private var pendingIntervals = 0
    private var affectedDays: Set<String> = []
    private var requiresFullValidation = false
    private var hasIncompleteDays = false
    public var unpersistedAwards: [RewardAward] { pending }
    private var zone: TimeZone { TimeZone(identifier: state.progressionTimezone)! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }

    public init(coverageStart: Date = Date(), progressionTimeZone: TimeZone = .current) {
        let day = Self.day(coverageStart, zone: progressionTimeZone)
        state = RewardState(coverageStart: coverageStart, progressionTimezone: progressionTimeZone.identifier, currentDay: day)
        hasPendingChanges = true
    }
    public init(restoring: RewardState, now: Date) throws {
        guard restoring.isValid else { throw RewardError.invalidState }
        state = restoring
        hasIncompleteDays = restoring.days.contains { $0.key < restoring.currentDay && !$0.value.completed }
        // Persisted open fragment moments are usable evidence, but an event
        // chain and unfinished rate bin never bridge a process restart.
        interrupt(at: now, reason: "relaunch")
        advance(to: now)
    }
    private static func day(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func day(_ date: Date) -> String { Self.day(date, zone: zone) }
    private func hour(_ date: Date) -> Date { calendar.dateInterval(of: .hour, for: date)?.start ?? date }
    private mutating func fail(_ value: RewardError) { error = value }
    private mutating func beginTransaction() { affectedDays.removeAll(keepingCapacity: true); requiresFullValidation = false }
    private var transactionIsValid: Bool { requiresFullValidation ? state.isValid : state.isValid(affectedDays: affectedDays) }

    public mutating func record(input: ClassifiedInput, result: StatisticsRecordResult, context: ImprovementContext,
                                sessionID: String? = nil, pendingIntervalCount: Int = 0) {
        guard error == nil else { return }
        var transaction = self
        transaction.beginTransaction()
        transaction.process(input: input, result: result, context: context, sessionID: sessionID, pendingIntervalCount: pendingIntervalCount)
        if transaction.error == nil, transaction.transactionIsValid { self = transaction }
        else { error = transaction.error ?? .invalidState }
    }
    private mutating func process(input: ClassifiedInput, result: StatisticsRecordResult, context: ImprovementContext,
                                 sessionID: String?, pendingIntervalCount: Int) {
        guard error == nil else { return }
        guard input.source == .global, input.evidence == .probable, input.category.isEffective,
              input.time.isFinite, input.date.timeIntervalSince1970.isFinite,
              result.deltas.filter({ $0.evidence == .probable }).reduce(0, { $0 + $1.keys }) == 1 else { return }
        let clockBoundary = lastInput.map { input.time <= $0 } ?? false
        guard (0...2).contains(pendingIntervalCount), result.acceptedIntervals.count <= 3,
              (sessionID?.utf8.count ?? 0) <= 128 else { fail(.invalidInput); return }
        if let previous = activeContext,
           previous.measurementPolicy != context.measurementPolicy || previous.evidencePolicy != context.evidencePolicy {
            requiresFullValidation = true
        }
        if clockBoundary || activeContext != context || activeControl != input.context {
            // The canonical engine already deduplicates operations. Equal or
            // reversed clocks end timing; they must not erase an accepted key.
            closeFragments(); endpoints.removeAll(); samplers.removeAll(); fragmentEnds.removeAll(); lastIntervalEnd = nil
        }
        activeContext = context; activeControl = input.context
        advanceDay(to: input.date)
        let keyDay = max(state.currentDay, day(input.date))
        // Incompatible semantics settle their old block; language/method/app
        // switches only end fragments and never reset daily budgets.
        let incompatible = state.blocks.filter { $0.day == keyDay && ($0.measurementPolicy != context.measurementPolicy || $0.evidencePolicy != context.evidencePolicy) }.map(\.id)
        if !incompatible.isEmpty { requiresFullValidation = true }
        for id in incompatible { settle(id, at: input.date, reason: "policy-boundary") }
        guard let blockID = currentBlock(day: keyDay, context: context) else { return }
        if let index = state.blocks.firstIndex(where: { $0.id == blockID }) { state.blocks[index].keys += 1 }
        let endpoint = Endpoint(time: input.time, date: input.date, block: blockID, context: context, session: sessionID)
        endpoints.append(endpoint)
        if endpoints.count > 4 { endpoints.removeFirst(endpoints.count - 4) }
        credit(seconds: 0, keys: 1, day: keyDay, date: input.date, blockID: blockID, context: context, session: sessionID, adjustment: false)
        if !clockBoundary {
            for interval in result.acceptedIntervals.sorted(by: { $0.startTime < $1.startTime }) {
                consume(interval, input: input)
            }
        }
        lastInput = input.time; pendingIntervals = pendingIntervalCount
        let unresolved = Set(endpoints.suffix(pendingIntervalCount).map(\.block))
        let safe = state.blocks.filter { ($0.isFull || $0.day < state.currentDay) && !unresolved.contains($0.id) }.map(\.id)
        for id in safe { settle(id, at: input.date, reason: "block-settlement") }
        completeDays(at: input.date)
        hasPendingChanges = true
    }

    private mutating func currentBlock(day: String, context: ImprovementContext) -> String? {
        if let block = state.blocks.last(where: { $0.day == day && !$0.isFull && $0.measurementPolicy == context.measurementPolicy && $0.evidencePolicy == context.evidencePolicy }) { return block.id }
        guard state.blocks.count < 4, state.nextBlock < Int64.max else { fail(.capacity); return nil }
        state.nextBlock += 1
        let id = state.lineage + ":b:" + String(state.nextBlock)
        state.blocks.append(RewardBlockState(id: id, day: day, measurementPolicy: context.measurementPolicy, evidencePolicy: context.evidencePolicy))
        return id
    }
    private mutating func advanceDay(to date: Date) {
        let next = day(date)
        guard next > state.currentDay else { return }
        state.currentDay = next
        if state.days[next] == nil { state.days[next] = RewardDayBudget(day: next) }
        // Pending adaptive evidence can postpone yesterday's completion. It
        // must not postpone pruning unrelated, already completed history and
        // temporarily create an invalid thirty-first retained budget.
        pruneCompletedDays()
        hasIncompleteDays = true; requiresFullValidation = true
        hasPendingChanges = true
    }
    public mutating func advance(to date: Date) {
        guard error == nil else { return }
        var transaction = self; transaction.beginTransaction(); transaction.advanceResolved(to: date)
        if transaction.error == nil, transaction.transactionIsValid { self = transaction }
        else { error = transaction.error ?? .invalidState }
    }
    private mutating func advanceResolved(to date: Date) {
        guard error == nil, date.timeIntervalSince1970.isFinite else { return }
        advanceDay(to: date)
        if pendingIntervals == 0 {
            for id in state.blocks.filter({ $0.day < state.currentDay }).map(\.id) { settle(id, at: date, reason: "day-settlement") }
            completeDays(at: date)
        }
    }
    public mutating func interrupt(at date: Date, reason: String = "boundary") {
        guard error == nil else { return }
        var transaction = self; transaction.beginTransaction(); transaction.interruptResolved(at: date, reason: reason)
        if transaction.error == nil, transaction.transactionIsValid { self = transaction }
        else { error = transaction.error ?? .invalidState }
    }
    private mutating func interruptResolved(at date: Date, reason: String) {
        guard error == nil else { return }
        closeFragments(); endpoints.removeAll(); samplers.removeAll(); fragmentEnds.removeAll()
        activeContext = nil; activeControl = nil; lastInput = nil; lastIntervalEnd = nil; pendingIntervals = 0
        let policyBoundary = reason == "settingsChanged" || reason == "policy-boundary"
        if policyBoundary { requiresFullValidation = true }
        for id in state.blocks.filter({ $0.isFull || $0.day < state.currentDay || policyBoundary }).map(\.id) { settle(id, at: date, reason: reason) }
        completeDays(at: date)
    }
    /// Snapshotting never breaks a live run or changes block boundaries.
    public mutating func checkpoint(at date: Date = Date()) -> RewardWrite {
        advance(to: date)
        guard error == nil else { return RewardWrite(state: state, awards: []) }
        guard state.isValid else { fail(.invalidState); return RewardWrite(state: state, awards: []) }
        guard state.revision < Int64.max else { fail(.capacity); return RewardWrite(state: state, awards: []) }
        state.revision += 1
        let write = RewardWrite(state: state, awards: pending)
        pending.removeAll(keepingCapacity: true); coalescing.removeAll(keepingCapacity: true)
        hasPendingChanges = false
        return write
    }

    private mutating func consume(_ interval: AcceptedTypingInterval, input: ClassifiedInput) {
        let duration = interval.endTime - interval.startTime
        guard interval.evidence == .probable, duration.isFinite, duration > 0, duration <= 10,
              interval.endTime <= input.time + 1e-6, interval.startTime >= input.time - 30,
              lastIntervalEnd.map({ interval.endTime > $0 }) ?? true else { return }
        lastIntervalEnd = interval.endTime
        let target = endpoints.first { abs($0.time - interval.endTime) <= max(1e-9, interval.endTime.ulp * 2) }
        let startEndpoint = endpoints.first { abs($0.time - interval.startTime) <= max(1e-9, interval.startTime.ulp * 2) }
        let context = target?.context ?? activeContext!
        let startDate = input.date.addingTimeInterval(interval.startTime - input.time)
        let endDate = input.date.addingTimeInterval(interval.endTime - input.time)
        let mapped = endDate.timeIntervalSince(startDate)
        guard mapped > 0 else { return }
        var cursor = startDate
        for _ in 0..<4 where cursor < endDate {
            guard let range = calendar.dateInterval(of: .hour, for: cursor), range.end > cursor else { break }
            let end = min(endDate, range.end)
            let fraction = end == endDate && cursor == startDate ? 1 : end.timeIntervalSince(cursor) / mapped
            let seconds = duration * fraction
            let rawDay = day(cursor)
            let rewardDay = state.days[rawDay] != nil ? rawDay : state.currentDay
            let candidate = target == nil || state.days[rewardDay]!.completed ? nil : (target.flatMap { id in state.blocks.first { $0.id == id.block && $0.day == rewardDay }?.id }
                ?? startEndpoint.flatMap { id in state.blocks.first { $0.id == id.block && $0.day == rewardDay }?.id })
            credit(seconds: seconds, keys: 0, day: rewardDay, date: cursor, blockID: candidate, context: context, session: target?.session, adjustment: candidate == nil, earnedDate: input.date)
            if let candidate, let index = state.blocks.firstIndex(where: { $0.id == candidate }) {
                state.blocks[index].speedIntervals += fraction; state.blocks[index].speedSeconds += seconds
                state.blocks[index].squaredSeconds += duration * duration * fraction
            }
            var budget = state.days[rewardDay]!
            if !budget.completed, context.isValid, budget.contexts[context.id] == nil && budget.contexts.count < 64 { budget.contexts[context.id] = RewardContextDay(context: context) }
            if !budget.completed, context.isValid, var evidence = budget.contexts[context.id], evidence.context == context {
                evidence.speedIntervals += fraction; evidence.seconds += seconds; budget.contexts[context.id] = evidence
            }
            state.days[rewardDay] = budget
            affectedDays.insert(rewardDay)
            cursor = end
        }
        // A canonical block begins at its actual first key; never synthesize
        // a key where a calendar split or block boundary cut an interval.
        if let target, let startEndpoint, target.block == startEndpoint.block,
           let index = state.blocks.firstIndex(where: { $0.id == target.block }),
           state.blocks[index].day == day(startDate), state.blocks[index].day == day(endDate) {
            recordFragment(interval, block: target.block, context: context, weight: 1)
        } else if let old = startEndpoint, let target, old.block != target.block,
                  day(startDate) != day(endDate), state.blocks.contains(where: { $0.id == old.block }) {
            // The future accepted endpoint proves the old day's portion.
            // Finish only whole bins ending at/before midnight, retaining the
            // original interval weight/moment for the old run fragment.
            if let boundary = calendar.dateInterval(of: .day, for: startDate)?.end {
                let fraction = min(1, max(0, boundary.timeIntervalSince(startDate) / mapped))
                let stop = interval.startTime + duration * fraction
                recordFragment(interval, block: old.block, context: context, weight: fraction, sampleStop: stop)
            }
            closeFragment(old.block)
        } else if let id = startEndpoint?.block { closeFragment(id) }
    }
    private mutating func recordFragment(_ interval: AcceptedTypingInterval, block id: String,
                                        context: ImprovementContext, weight: Double, sampleStop: Double? = nil) {
        let duration = interval.endTime - interval.startTime
        if fragmentEnds[id].map({ abs($0 - interval.startTime) > max(1e-9, interval.startTime.ulp * 2) }) ?? false { closeFragment(id) }
        if let index = state.blocks.firstIndex(where: { $0.id == id }), state.blocks[index].fragment?.context != context { closeFragment(id) }
        guard let index = state.blocks.firstIndex(where: { $0.id == id }) else { return }
        if state.blocks[index].fragment == nil { state.blocks[index].fragment = RewardRunFragment(context: context) }
        state.blocks[index].fragment!.intervals += weight
        state.blocks[index].fragment!.seconds += duration * weight
        state.blocks[index].fragment!.squaredSeconds += duration * duration * weight
        var sampler = samplers[id] ?? RateConsistencySampler()
        for sample in sampler.record(interval) where sampleStop.map({ sample.endTime <= $0 + max(1e-9, $0.ulp * 2) }) ?? true {
            state.blocks[index].fragment!.rates.merge(sample.totals)
        }
        samplers[id] = sampler; fragmentEnds[id] = interval.endTime
    }
    private mutating func credit(seconds: Double, keys: Int, day: String, date: Date, blockID: String?, context: ImprovementContext, session: String?, adjustment: Bool, earnedDate: Date? = nil) {
        guard seconds.isFinite, seconds >= 0, keys >= 0, var budget = state.days[day], budget.keys <= Int.max - keys else { fail(.invalidInput); return }
        let component = RewardComponents(time: 60 * log1p(seconds / (3600 + budget.seconds)), volume: 60 * log1p(Double(keys) / (15000 + Double(budget.keys))))
        guard component.isValid, let xpAward = state.xpProgress.add(seconds: seconds, keys: keys) else { fail(.capacity); return }
        let earnedXP = RewardXP(xpAward)
        let xp = day == state.currentDay ? earnedXP : RewardXP()
        budget.seconds += seconds; budget.keys += keys; budget.components.merge(component); budget.xp.merge(xp)
        state.days[day] = budget; state.lifetimeScore.merge(component)
        affectedDays.insert(day)
        if day != state.currentDay, earnedXP.total > 0 {
            state.days[state.currentDay]?.xp.merge(earnedXP)
            affectedDays.insert(state.currentDay)
            let when = earnedDate ?? date
            let row = RewardAttribution(day: state.currentDay, hour: hour(when), xp: earnedXP)
            award(date: when, day: state.currentDay, kind: "practice-xp", block: nil, components: .init(), xp: earnedXP, attributions: [row], coalesce: true)
        }
        let attribution = RewardAttribution(day: day, hour: hour(date), sessionID: session, components: component, xp: xp)
        if let blockID, let index = state.blocks.firstIndex(where: { $0.id == blockID }) {
            state.blocks[index].base.merge(component)
            mergeAttribution(attribution, into: &state.blocks[index].attributions)
        }
        award(date: date, day: day, kind: adjustment ? "late-adjustment" : "base", block: blockID, components: component, xp: xp, attributions: [attribution], coalesce: true)
    }
    private func mergeAttribution(_ row: RewardAttribution, into rows: inout [RewardAttribution]) {
        if let i = rows.firstIndex(where: { $0.key == row.key }) { rows[i].components.merge(row.components); rows[i].xp.merge(row.xp) }
        else if rows.count < 128 { rows.append(row) }
    }
    private mutating func closeFragments() { for id in state.blocks.map(\.id) { closeFragment(id) } }
    private mutating func closeFragment(_ id: String) {
        guard let index = state.blocks.firstIndex(where: { $0.id == id }), let fragment = state.blocks[index].fragment else { return }
        if let quality = fragment.quality {
            state.blocks[index].quality.merge(quality)
            let day = state.blocks[index].day
            if var budget = state.days[day] {
                if fragment.context.isValid, budget.contexts[fragment.context.id] == nil && budget.contexts.count < 64 { budget.contexts[fragment.context.id] = RewardContextDay(context: fragment.context) }
                if fragment.context.isValid, var evidence = budget.contexts[fragment.context.id], evidence.context == fragment.context { evidence.quality.merge(quality); budget.contexts[fragment.context.id] = evidence }
                state.days[day] = budget
                affectedDays.insert(day)
            }
        }
        state.blocks[index].fragment = nil; samplers.removeValue(forKey: id); fragmentEnds.removeValue(forKey: id)
        hasPendingChanges = true
    }
    private mutating func settle(_ id: String, at date: Date, reason: String) {
        closeFragment(id)
        guard let index = state.blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = state.blocks.remove(at: index), k = Double(block.keys)
        var bonus = RewardComponents()
        if k > 0, block.speedIntervals >= 20, block.speedSeconds >= 2 {
            let wpm = 12 * block.speedIntervals / block.speedSeconds
            let speed = min(1, log1p(wpm / 50) / log1p(160.0 / 50))
            let q = min(1, block.speedIntervals / 40) * min(1, block.speedIntervals / k)
            bonus.speedBonus = 0.25 * block.base.base * q * speed
        }
        if k > 0, let consistency = block.quality.consistency {
            let q = min(1, block.quality.intervals / 40) * min(1, block.quality.intervals / k)
            bonus.consistencyBonus = 0.15 * block.base.base * q * consistency
        }
        guard bonus.isValid else { fail(.invalidState); return }
        state.lifetimeScore.merge(bonus); state.days[block.day]?.components.merge(bonus)
        affectedDays.insert(block.day)
        let allocations = block.attributions.compactMap { original -> RewardAttribution? in
            guard block.base.base > 0 else { return nil }
            return RewardAttribution(day: original.day, hour: original.hour, sessionID: original.sessionID,
                                     components: bonus.scaled(by: original.components.base / block.base.base))
        }
        if bonus.total > 0 { award(date: date, day: block.day, kind: "quality", block: id, components: bonus, xp: .init(), attributions: allocations, coalesce: false) }
        hasPendingChanges = true
    }
    private mutating func completeDays(at date: Date) {
        guard hasIncompleteDays, pendingIntervals == 0 else { return }
        for day in state.days.keys.sorted() where day < state.currentDay && !state.days[day]!.completed && !state.blocks.contains(where: { $0.day == day }) {
            requiresFullValidation = true
            let budget = state.days[day]!
            for evidence in budget.contexts.values.sorted(by: { $0.context.id < $1.context.id }) {
                for milestone in state.improvement.completedDay(context: evidence.context, day: evidence.dayEvidence(day)) {
                    guard let xpAward = state.xpProgress.addImprovementXP(milestone.xp) else { fail(.capacity); return }
                    let xp = RewardXP(xpAward)
                    state.days[state.currentDay]?.xp.merge(xp)
                    let attribution = RewardAttribution(day: state.currentDay, hour: hour(date), xp: xp)
                    award(date: date, day: state.currentDay, kind: "improvement-" + milestone.metric.rawValue,
                          block: nil, components: .init(), xp: xp, attributions: [attribution], coalesce: false, claimID: milestone.id)
                }
            }
            state.days[day]?.completed = true
        }
        pruneCompletedDays()
        hasIncompleteDays = state.days.contains { $0.key < state.currentDay && !$0.value.completed }
    }
    private mutating func pruneCompletedDays() {
        guard state.days.count > 30 else { return }
        let removable = state.days.keys.sorted().filter { $0 != state.currentDay && state.days[$0]!.completed }
        for key in removable.prefix(state.days.count - 30) { state.days.removeValue(forKey: key) }
    }
    private mutating func award(date: Date, day: String, kind: String, block: String?, components: RewardComponents, xp: RewardXP, attributions: [RewardAttribution], coalesce: Bool, claimID: String? = nil) {
        guard components.total > 0 || xp.total > 0 else { return }
        let key = kind + "|" + (block ?? "") + "|" + (attributions.first?.key ?? day)
        if coalesce, let index = coalescing[key] {
            pending[index].components.merge(components); pending[index].xpSources.merge(xp)
            for row in attributions { mergeAttribution(row, into: &pending[index].attributions) }
            return
        }
        guard state.nextAward < Int64.max, pending.count < 8192 else { fail(.capacity); return }
        state.nextAward += 1
        let identity = kind == "quality" ? (block! + ":quality") : (state.lineage + ":a:" + String(state.nextAward))
        let row = RewardAward(id: identity, date: date, day: day, kind: kind,
                              blockID: block, components: components, xpSources: xp, attributions: attributions, claimID: claimID)
        if coalesce { coalescing[key] = pending.count }
        pending.append(row)
    }
}
