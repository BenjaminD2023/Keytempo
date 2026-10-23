import Foundation

/// Sufficient timing statistics, not an event log. Fractional interval counts
/// preserve an observed interval when it crosses a calendar boundary.
public struct RhythmTotals: Codable, Sendable, Equatable {
    public var keys: Int
    public var intervals: Double
    public var seconds: Double
    public var squaredIntervalSeconds: Double

    public init(keys: Int = 0, intervals: Double = 0, seconds: Double = 0, squaredIntervalSeconds: Double = 0) {
        self.keys = keys; self.intervals = intervals; self.seconds = seconds
        self.squaredIntervalSeconds = squaredIntervalSeconds
    }

    public var isValid: Bool {
        keys >= 0 && [intervals, seconds, squaredIntervalSeconds].allSatisfy { $0.isFinite && $0 >= 0 }
    }
    public var wpm: Double? {
        guard isValid, intervals >= 4, seconds >= 0.5 else { return nil }
        let value = 12 * intervals / seconds
        return value.isFinite ? value : nil
    }
    /// Population variation of accepted intervals, including normal editing and
    /// composition. No spelling, accuracy or intention is inferred.
    public var coefficientOfVariation: Double? {
        guard isValid, intervals >= TypingScore.minimumIntervals,
              seconds >= TypingScore.minimumSeconds else { return nil }
        let mean = seconds / intervals
        let secondMoment = squaredIntervalSeconds / intervals
        let variance = secondMoment - mean * mean
        let tolerance = max(1e-12, secondMoment * 1e-10)
        guard mean > 0, variance >= -tolerance else { return nil }
        let value = sqrt(max(0, variance)) / mean
        return value.isFinite ? value : nil
    }
    public var consistency: Double? { coefficientOfVariation.map { 100 / (1 + $0) } }
    public var score: TypingScore? {
        guard let wpm, let consistency else { return nil }
        return TypingScore(wpm: wpm, consistency: consistency, typingSeconds: seconds, keys: keys)
    }

    public mutating func merge(_ other: Self) {
        let sum = keys.addingReportingOverflow(other.keys)
        guard isValid, other.isValid, !sum.overflow else {
            // An invalid aggregate must not look like a valid partial sample.
            intervals = .nan; seconds = .nan; squaredIntervalSeconds = .nan
            return
        }
        keys = sum.partialValue
        intervals += other.intervals; seconds += other.seconds
        squaredIntervalSeconds += other.squaredIntervalSeconds
    }
}

/// A transparent, versioned personal practice index, not a standardized skill
/// or accuracy assessment. Equal weights give activity half of the overall score.
public struct TypingScore: Codable, Sendable, Equatable {
    public static let version = "practice-v1"
    public static let speedReferenceWPM = 100.0
    public static let durationReferenceSeconds = 1_800.0
    public static let volumeReferenceKeys = 10_000.0
    public static let minimumIntervals = 20.0
    public static let minimumSeconds = 2.0

    public let value: Double
    public let speed: Double
    public let consistency: Double
    public let duration: Double
    public let volume: Double

    public init(wpm: Double, consistency: Double, typingSeconds: Double, keys: Int) {
        func component(_ value: Double) -> Double { value.isFinite ? min(100, max(0, value)) : 0 }
        speed = component(100 * wpm / Self.speedReferenceWPM)
        self.consistency = component(consistency)
        duration = component(100 * typingSeconds / Self.durationReferenceSeconds)
        volume = component(100 * Double(keys) / Self.volumeReferenceKeys)
        value = (speed + self.consistency + duration + volume) / 4
    }
}

public struct HourlyActivity: Codable, Sendable, Equatable, Identifiable {
    public var bucketStart: Date
    public var bucketEnd: Date
    public var timezone: String
    public var rule: String
    /// Empty means combined activity. Nonempty identifiers are opt-in metadata.
    public var applicationID: String
    public var totals: RhythmTotals
    public var id: String { "\(bucketStart.timeIntervalSince1970)|\(timezone)|\(rule)|\(applicationID)" }

    public init(bucketStart: Date, bucketEnd: Date, timezone: String, rule: String,
                applicationID: String = "", totals: RhythmTotals = .init()) {
        self.bucketStart = bucketStart; self.bucketEnd = bucketEnd
        self.timezone = timezone; self.rule = rule; self.applicationID = applicationID; self.totals = totals
    }
}

public struct TypingSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var timezone: String
    public var rule: String
    public var totals: RhythmTotals
    /// nil is the current in-process session. Persistence does not imply a
    /// session is still active after the app relaunches.
    public var endReason: String?

    public init(id: String = UUID().uuidString, start: Date, end: Date, timezone: String,
                rule: String, totals: RhythmTotals = .init(), endReason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.timezone = timezone
        self.rule = rule; self.totals = totals; self.endReason = endReason
    }
}

public struct ActivityBatch: Codable, Sendable, Equatable {
    /// Add these deltas exactly once. Sessions below are replacement snapshots.
    public var hourly: [HourlyActivity]
    public var sessions: [TypingSession]
    public init(hourly: [HourlyActivity] = [], sessions: [TypingSession] = []) {
        self.hourly = hourly; self.sessions = sessions
    }
    public var isEmpty: Bool { hourly.isEmpty && sessions.isEmpty }
}

/// Constant-memory aggregation of already classified global input. It never
/// learns continuity, generates intervals or retains text/physical key names.
public struct ActivityTracker: Sendable {
    public let sessionGap: Double
    public private(set) var timeZone: TimeZone
    public private(set) var currentSession: TypingSession?
    private var lastInputTime: Double?
    private var lastInputDate: Date?
    // At most one previous-day session is needed for the engine's bounded
    // three-interval slow-rhythm backfill around midnight.
    private var previousDaySession: TypingSession?
    private var applicationCollectionStart: Double?

    public init(sessionGap: Double = 300, timeZone: TimeZone = .current) {
        self.sessionGap = sessionGap.isFinite ? min(3_600, max(60, sessionGap)) : 300
        self.timeZone = timeZone
    }

    /// The app can schedule one cancelable idle close rather than polling.
    public var sessionDeadline: Double? { lastInputTime.map { $0 + sessionGap } }
    public mutating func finishIfIdle(at time: Double) -> ActivityBatch {
        guard time.isFinite, let sessionDeadline, time >= sessionDeadline else { return .init() }
        return finish(reason: "inactivity")
    }

    public mutating func resetApplicationAttribution() { applicationCollectionStart = nil }

    public mutating func finish(reason: String) -> ActivityBatch {
        guard var session = currentSession else {
            lastInputTime = nil; lastInputDate = nil; previousDaySession = nil
            applicationCollectionStart = nil
            return .init()
        }
        session.endReason = String(reason.prefix(80))
        currentSession = nil; previousDaySession = nil
        lastInputTime = nil; lastInputDate = nil; applicationCollectionStart = nil
        return ActivityBatch(sessions: [session])
    }

    public mutating func setTimeZone(_ timeZone: TimeZone) -> ActivityBatch {
        guard self.timeZone != timeZone else { return .init() }
        let batch = finish(reason: "timezoneChanged")
        self.timeZone = timeZone
        return batch
    }

    public mutating func record(input: ClassifiedInput, result: StatisticsRecordResult, rule: String,
                                applicationID: String? = nil, perAppEnabled: Bool = false) -> ActivityBatch {
        guard input.source == .global, input.evidence == .probable, input.category.isEffective,
              input.time.isFinite, input.date.timeIntervalSince1970.isFinite,
              !rule.isEmpty, rule.utf8.count <= 512,
              result.deltas.filter({ $0.evidence == .probable }).reduce(0, { $0 + $1.keys }) == 1 else { return .init() }
        // The statistics engine normally handles duplicates. This additional
        // monotonic guard prevents an accidental delivery retry being counted twice.
        if let lastInputTime, input.time <= lastInputTime { return .init() }

        var outputSessions: [String: TypingSession] = [:]
        var hourly: [String: HourlyActivity] = [:]
        let wallChanged = lastInputTime.flatMap { priorTime in
            lastInputDate.map { abs(input.date.timeIntervalSince($0) - (input.time - priorTime)) > 1 }
        } ?? false
        let expired = lastInputTime.map { input.time - $0 >= sessionGap } ?? false
        if wallChanged || expired || currentSession.map({ $0.rule != rule }) ?? false {
            let reason = wallChanged ? "clockChanged" : expired ? "inactivity" : "ruleChanged"
            for session in finish(reason: reason).sessions { outputSessions[session.id] = session }
        }

        if perAppEnabled {
            if applicationCollectionStart == nil { applicationCollectionStart = input.time }
        } else { applicationCollectionStart = nil }
        let app = perAppEnabled ? Self.safeApplicationID(applicationID) : nil
        let calendar = self.calendar
        // At most three intervals can be returned by the segmentation engine.
        // Reject malformed oversized results rather than allocating an event history.
        let intervals = !wallChanged && result.acceptedIntervals.count <= 3 ? result.acceptedIntervals : []
        for interval in intervals.sorted(by: { $0.startTime < $1.startTime }) {
            let duration = interval.endTime - interval.startTime
            guard interval.evidence == .probable, interval.ruleID == rule,
                  interval.startTime.isFinite, interval.endTime.isFinite,
                  duration > 0, duration <= 10, interval.endTime <= input.time + 1e-6,
                  interval.startTime >= input.time - 30 - 1e-6 else { continue }
            let start = input.date.addingTimeInterval(interval.startTime - input.time)
            let end = input.date.addingTimeInterval(interval.endTime - input.time)
            let mappedDuration = end.timeIntervalSince(start)
            guard mappedDuration > 0 else { continue }
            var cursor = start
            for _ in 0..<4 where cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                let sliceEnd = min(end, hour.end)
                // Date loses sub-microsecond precision at modern epochs. Use
                // it only to locate boundaries; preserve the exact observed
                // monotonic duration and one full interval across all slices.
                let fromFraction = cursor == start ? 0 : cursor.timeIntervalSince(start) / mappedDuration
                let toFraction = sliceEnd == end ? 1 : sliceEnd.timeIntervalSince(start) / mappedDuration
                let fraction = toFraction - fromFraction, seconds = duration * fraction
                let totals = RhythmTotals(intervals: fraction, seconds: seconds,
                                          squaredIntervalSeconds: duration * duration * fraction)
                addHour(totals, date: cursor, applicationID: "", rule: rule, into: &hourly)
                addSession(totals, start: cursor, end: sliceEnd, rule: rule, output: &outputSessions)
                if let app, let collectionStart = applicationCollectionStart {
                    let allowedStart = max(interval.startTime, collectionStart)
                    let allowedDate = input.date.addingTimeInterval(allowedStart - input.time)
                    let appStart = max(cursor, allowedDate)
                    if appStart < sliceEnd {
                        let appFromFraction = appStart == start ? 0 : appStart.timeIntervalSince(start) / mappedDuration
                        let appFraction = toFraction - appFromFraction
                        let appSeconds = duration * appFraction
                        addHour(RhythmTotals(intervals: appFraction, seconds: appSeconds,
                                             squaredIntervalSeconds: duration * duration * appFraction),
                                date: appStart, applicationID: app, rule: rule, into: &hourly)
                    }
                }
                cursor = sliceEnd
            }
        }

        addHour(RhythmTotals(keys: 1), date: input.date, applicationID: "", rule: rule, into: &hourly)
        if let app { addHour(RhythmTotals(keys: 1), date: input.date, applicationID: app, rule: rule, into: &hourly) }
        addSession(RhythmTotals(keys: 1), start: input.date, end: input.date, rule: rule, output: &outputSessions)
        lastInputTime = input.time; lastInputDate = input.date
        if let currentSession { outputSessions[currentSession.id] = currentSession }
        return ActivityBatch(hourly: hourly.values.sorted { $0.id < $1.id },
                             sessions: outputSessions.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start })
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = timeZone
        return value
    }
    private func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    private static func safeApplicationID(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty, identifier.utf8.count <= 255,
              !identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return identifier
    }
    private func addHour(_ totals: RhythmTotals, date: Date, applicationID: String, rule: String,
                         into rows: inout [String: HourlyActivity]) {
        guard let bounds = calendar.dateInterval(of: .hour, for: date) else { return }
        var row = HourlyActivity(bucketStart: bounds.start, bucketEnd: bounds.end,
                                 timezone: timeZone.identifier, rule: rule, applicationID: applicationID)
        if let existing = rows[row.id] { row = existing }
        row.totals.merge(totals); rows[row.id] = row
    }
    private mutating func addSession(_ totals: RhythmTotals, start: Date, end: Date, rule: String,
                                    output: inout [String: TypingSession]) {
        let targetDay = day(start)
        if let currentSession, targetDay < day(currentSession.start) {
            var previous = previousDaySession.flatMap { day($0.start) == targetDay && $0.rule == rule ? $0 : nil }
                ?? TypingSession(start: start, end: end, timezone: timeZone.identifier, rule: rule, endReason: "dayBoundary")
            previous.totals.merge(totals); previous.start = min(previous.start, start); previous.end = max(previous.end, end)
            previousDaySession = previous; output[previous.id] = previous
            return
        }
        if var current = currentSession, targetDay != day(current.start) {
            current.endReason = "dayBoundary"; previousDaySession = current
            output[current.id] = current; self.currentSession = nil
        }
        var current = currentSession ?? TypingSession(start: start, end: end, timezone: timeZone.identifier, rule: rule)
        current.start = min(current.start, start); current.end = max(current.end, end)
        current.totals.merge(totals); currentSession = current
    }
}
