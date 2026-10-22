import Foundation

public enum HistoryGranularity: String, Sendable {
    case day, week, month

    public static func forHistoryDays(_ days: Int) -> Self {
        days <= 90 ? .day : days <= 366 ? .week : .month
    }
}

/// Inclusive local calendar dates. Anniversary-based ranges include both the
/// anniversary and today, matching the store's five-calendar-year retention.
public struct HistoryDateRange: Equatable, Sendable {
    public let startDay: String
    public let endDay: String
    public let dayCount: Int
    public var isValid: Bool { dayCount > 0 }

    public static func days(_ count: Int, endingOn date: Date = Date(), timeZone: TimeZone = .current) -> Self {
        let calendar = HistoryAggregation.calendar(timeZone)
        guard let end = validEnd(date, calendar: calendar),
              let cutoff = calendar.date(byAdding: .year, value: -5, to: end),
              let requested = calendar.date(byAdding: .day, value: -(max(1, min(1828, count)) - 1), to: end) else { return invalid }
        return make(start: max(cutoff, requested), end: end, calendar: calendar)
    }

    public static func years(_ count: Int, endingOn date: Date = Date(), timeZone: TimeZone = .current) -> Self {
        let calendar = HistoryAggregation.calendar(timeZone)
        guard let end = validEnd(date, calendar: calendar),
              let start = calendar.date(byAdding: .year, value: -max(1, min(5, count)), to: end) else { return invalid }
        return make(start: start, end: end, calendar: calendar)
    }

    private static var invalid: Self { Self(startDay: "", endDay: "", dayCount: 0) }
    private static func validEnd(_ date: Date, calendar: Calendar) -> Date? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let end = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: end)
        return (6...9999).contains(year) ? end : nil
    }
    private static func make(start: Date, end: Date, calendar: Calendar) -> Self {
        guard let count = calendar.dateComponents([.day], from: start, to: end).day, (0..<1828).contains(count) else { return invalid }
        return Self(startDay: HistoryAggregation.dayKey(start, calendar: calendar),
                    endDay: HistoryAggregation.dayKey(end, calendar: calendar), dayCount: count + 1)
    }
}

/// Storage-independent daily metadata. A row's date remains attributed to its
/// original local day; timezone identifiers are retained rather than reinterpreted.
public struct HistoryMetricRow: Sendable {
    public var day: String
    public var language: String
    public var evidence: Evidence
    public var rule: String
    public var timezone: String
    public var keys: Int
    public var edits: Int
    public var composition: Int
    public var characters: Int
    public var intervals: Double
    public var seconds: Double
    public var ratedCharacters: Double
    public var characterIntervals: Double
    public var characterSeconds: Double

    public init(day: String, language: String, evidence: Evidence, rule: String, timezone: String,
                keys: Int = 0, edits: Int = 0, composition: Int = 0, characters: Int = 0,
                intervals: Double = 0, seconds: Double = 0, ratedCharacters: Double = 0,
                characterIntervals: Double = 0, characterSeconds: Double = 0) {
        self.day = day; self.language = language; self.evidence = evidence
        self.rule = rule; self.timezone = timezone
        self.keys = keys; self.edits = edits; self.composition = composition; self.characters = characters
        self.intervals = intervals; self.seconds = seconds; self.ratedCharacters = ratedCharacters
        self.characterIntervals = characterIntervals; self.characterSeconds = characterSeconds
    }
}

/// One calendar bucket, language and evidence lane. Rates use the sums of
/// observed numerators and durations, never an average of already rounded rates.
public struct HistoryAggregate: Sendable {
    public let periodStart: String
    public let periodEnd: String
    public let language: String
    public let evidence: Evidence
    public private(set) var rules: Set<String> = []
    public private(set) var timezones: Set<String> = []
    public private(set) var keys = 0
    public private(set) var edits = 0
    public private(set) var composition = 0
    public private(set) var characters = 0
    public private(set) var intervals = 0.0
    public private(set) var seconds = 0.0
    public private(set) var ratedCharacters = 0.0
    public private(set) var characterIntervals = 0.0
    public private(set) var characterSeconds = 0.0
    /// Counts from malformed numeric rows are excluded; their presence makes
    /// speed unavailable instead of silently reporting a precise partial rate.
    public private(set) var rejectedRows = 0
    public var hasMixedRules: Bool { rules.count > 1 }
    public var kpm: Double? { rate(intervals, seconds, minimumIntervals: intervals) }
    public var estimatedWPM: Double? {
        TypingRate.primaryUnit(forLanguage: language) == .wpm ? TypingRate.estimatedWPM(fromKPM: kpm) : nil
    }
    public var cpm: Double? {
        evidence == .confirmed ? rate(ratedCharacters, characterSeconds, minimumIntervals: characterIntervals) : nil
    }

    private func rate(_ numerator: Double, _ duration: Double, minimumIntervals: Double) -> Double? {
        guard rejectedRows == 0, !hasMixedRules, minimumIntervals >= 4, duration >= 0.5, numerator > 0 else { return nil }
        let value = 60 * (numerator / duration)
        return value.isFinite ? value : nil
    }

    fileprivate mutating func merge(_ row: HistoryMetricRow) {
        rules.insert(row.rule); timezones.insert(row.timezone)
        let counts = [row.keys, row.edits, row.composition, row.characters]
        let values = [row.intervals, row.seconds, row.ratedCharacters, row.characterIntervals, row.characterSeconds]
        let nextCounts = zip([keys, edits, composition, characters], counts).map { $0.addingReportingOverflow($1) }
        let nextValues = zip([intervals, seconds, ratedCharacters, characterIntervals, characterSeconds], values).map(+)
        guard !row.rule.isEmpty, counts.allSatisfy({ $0 >= 0 }),
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              nextCounts.allSatisfy({ !$0.overflow }), nextValues.allSatisfy(\.isFinite) else {
            rejectedRows += 1
            return
        }
        keys = nextCounts[0].partialValue; edits = nextCounts[1].partialValue
        composition = nextCounts[2].partialValue; characters = nextCounts[3].partialValue
        intervals = nextValues[0]; seconds = nextValues[1]; ratedCharacters = nextValues[2]
        characterIntervals = nextValues[3]; characterSeconds = nextValues[4]
    }
}

public enum HistoryAggregation {
    private struct Bounds { let start: String; let end: String }
    private struct Key: Hashable { let start: String; let language: String; let evidence: String }

    /// Sparse output: absent periods remain absent, not invented zero-rate data.
    /// Weeks start on Monday; boundary periods are clipped to the inclusive
    /// selected range. Date parsing is cached once per distinct daily key.
    /// Callers bound their source query (the app's store permits 50,000 rows).
    /// Malformed dates and unknown evidence are excluded because no reliable
    /// period/effective lane can be assigned; numeric rejections remain visible.
    public static func aggregate(_ rows: [HistoryMetricRow], granularity: HistoryGranularity,
                                 timeZone: TimeZone, startDay: String? = nil, endDay: String? = nil) -> [HistoryAggregate] {
        let calendar = calendar(timeZone)
        if let startDay, parseDay(startDay, calendar: calendar) == nil { return [] }
        if let endDay, parseDay(endDay, calendar: calendar) == nil { return [] }
        if let startDay, let endDay, startDay > endDay { return [] }
        var dates: [String: Bounds] = [:]
        var invalidDates = Set<String>()
        var grouped: [Key: HistoryAggregate] = [:]
        for row in rows {
            guard row.evidence != .unknown, !row.language.isEmpty,
                  startDay.map({ row.day >= $0 }) ?? true,
                  endDay.map({ row.day <= $0 }) ?? true else { continue }
            let bounds: Bounds
            if let cached = dates[row.day] { bounds = cached }
            else {
                guard !invalidDates.contains(row.day), let date = parseDay(row.day, calendar: calendar) else {
                    invalidDates.insert(row.day); continue
                }
                let component: Calendar.Component = granularity == .day ? .day : granularity == .week ? .weekOfYear : .month
                guard let interval = calendar.dateInterval(of: component, for: date),
                      let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: interval.end) else { continue }
                let first = dayKey(interval.start, calendar: calendar)
                let last = dayKey(inclusiveEnd, calendar: calendar)
                bounds = Bounds(start: startDay.map { max(first, $0) } ?? first,
                                end: endDay.map { min(last, $0) } ?? last)
                dates[row.day] = bounds
            }
            let key = Key(start: bounds.start, language: row.language, evidence: row.evidence.rawValue)
            var bucket = grouped[key] ?? HistoryAggregate(periodStart: bounds.start, periodEnd: bounds.end,
                                                          language: row.language, evidence: row.evidence)
            bucket.merge(row)
            grouped[key] = bucket
        }
        return grouped.values.sorted {
            if $0.periodStart != $1.periodStart { return $0.periodStart < $1.periodStart }
            if $0.language != $1.language { return $0.language < $1.language }
            return $0.evidence.rawValue < $1.evidence.rawValue
        }
    }

    fileprivate static func calendar(_ timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        value.locale = Locale(identifier: "en_US_POSIX")
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }
    fileprivate static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private static func parseDay(_ day: String, calendar: Calendar) -> Date? {
        guard day.utf8.count == 10 else { return nil }
        let bytes = Array(day.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              [0,1,2,3,5,6,8,9].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        func number(_ positions: [Int]) -> Int { positions.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) } }
        let year = number([0,1,2,3]), month = number([5,6]), value = number([8,9])
        guard year >= 1, let date = calendar.date(from: DateComponents(year: year, month: month, day: value, hour: 12)),
              dayKey(date, calendar: calendar) == day else { return nil }
        return date
    }
}
