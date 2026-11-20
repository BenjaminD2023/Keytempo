import Foundation

/// A calendar-day aggregate. Rules identify the counting method, not an app or
/// input language. No missing day is synthesized as a zero-speed observation.
public struct TypingProgressDay: Sendable, Equatable, Identifiable {
    public let date: Date
    public let totals: RhythmTotals
    public let rules: Set<String>
    public var id: Date { date }

    public init(date: Date, totals: RhythmTotals, rules: Set<String>) {
        self.date = date; self.totals = totals; self.rules = rules
    }

    public var isQualifying: Bool {
        totals.isValid && totals.intervals >= TypingProgress.minimumDailyIntervals
            && totals.seconds >= TypingProgress.minimumDailySeconds
    }
    public var wpm: Double? { isQualifying && hasKnownRule ? totals.wpm : nil }
    public var consistency: Double? { isQualifying && hasKnownRule ? totals.consistency : nil }

    fileprivate var hasKnownRule: Bool { rules.count == 1 && rules.first?.isEmpty == false }
    fileprivate var isActive: Bool {
        totals.keys > 0 || totals.intervals > 0 || totals.seconds > 0 || totals.rateConsistency.count > 0
    }
}

public enum TypingProgressReadiness: String, Sendable, Equatable {
    case ready
    case insufficientEvidence
    case incompatibleRules
    case invalidData
}

/// Seven calendar days, with an exclusive end. Practice quantities cover every
/// valid day; rateTotals pool only days with enough measured rhythm to compare.
public struct TypingProgressPeriod: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let totals: RhythmTotals
    public let rateTotals: RhythmTotals
    public let activeDays: Int
    public let qualifyingDays: Int
    public let consistencyDays: Int
    public let rules: Set<String>
    public let speedReadiness: TypingProgressReadiness
    public let consistencyReadiness: TypingProgressReadiness

    public var isReady: Bool { speedReadiness == .ready }
    public var wpm: Double? { isReady ? rateTotals.wpm : nil }
    public var consistency: Double? { consistencyReadiness == .ready ? rateTotals.consistency : nil }
    /// Completed one-second rate samples; older history can have rhythm timing
    /// without these samples. Display this coverage beside consistency.
    public var consistencySampleSeconds: Int { rateTotals.rateConsistency.count }
}

public struct TypingProgressTrendSample: Sendable, Equatable, Identifiable {
    /// Start of the final completed day in this trailing seven-day window.
    public let date: Date
    public let period: TypingProgressPeriod
    public let wpm: Double
    public let consistency: Double?
    public var id: Date { date }
}

/// Descriptive personal progress, rather than an accuracy or standardized skill
/// score. Rates use pooled intervals / observed seconds, never daily averages.
public struct TypingProgress: Sendable, Equatable {
    public static let minimumDailyIntervals = 20.0
    public static let minimumDailySeconds = 30.0
    public static let minimumQualifyingDays = 3
    public static let minimumPeriodSeconds = 300.0

    public let recent: TypingProgressPeriod
    public let previous: TypingProgressPeriod
    public let speedReadiness: TypingProgressReadiness
    public let consistencyReadiness: TypingProgressReadiness
    public let speedChangeWPM: Double?
    public let speedChangePercent: Double?
    public let consistencyChangePoints: Double?
    /// Valid, observed, completed days through the selected day, in date order.
    /// A mixed-rule day remains inspectable, but its daily rate is unavailable.
    public let dailyData: [TypingProgressDay]
    public let trend: [TypingProgressTrendSample]

    /// A historical selected day is included. Selecting today or a future day
    /// ends at today's midnight: the partial current day is always excluded.
    /// Calendar additions, rather than 86,400-second offsets, preserve DST days.
    /// Supply historyStart as the source query's earliest loaded calendar day.
    /// Trend windows must be fully inside that history; an invalid boundary
    /// suppresses trends. This boundary does not change the comparison periods.
    public static func analyze(days: [TypingProgressDay], through selectedDate: Date,
                               now: Date = Date(), calendar: Calendar = .current,
                               historyStart: Date? = nil) -> Self {
        let validBounds = safeDate(now) && safeDate(selectedDate)
        let historyDay = historyStart.flatMap { safeDate($0) ? calendar.startOfDay(for: $0) : nil }
        let validHistoryBound = historyStart == nil || historyDay != nil
        let today = calendar.startOfDay(for: safeDate(now) ? now : Date(timeIntervalSince1970: 0))
        let selected = calendar.startOfDay(for: validBounds ? selectedDate : today)
        let nextSelected = calendar.date(byAdding: .day, value: 1, to: selected) ?? today
        let end = min(today, nextSelected)
        let recentStart = calendar.date(byAdding: .day, value: -7, to: end) ?? end
        let previousStart = calendar.date(byAdding: .day, value: -7, to: recentStart) ?? recentStart

        var grouped: [Date: TypingProgressDay] = [:]
        for day in days where safeDate(day.date) {
            let date = calendar.startOfDay(for: day.date)
            guard date < end else { continue }
            if let prior = grouped[date] {
                var totals = prior.totals
                totals.merge(day.totals)
                grouped[date] = TypingProgressDay(date: date, totals: totals, rules: prior.rules.union(day.rules))
            } else {
                grouped[date] = TypingProgressDay(date: date, totals: day.totals, rules: day.rules)
            }
        }
        let normalized = grouped.values.sorted { $0.date < $1.date }
        let recent = period(days: normalized, start: recentStart, end: end, invalidBounds: !validBounds)
        let previous = period(days: normalized, start: previousStart, end: recentStart, invalidBounds: !validBounds)
        let speedReadiness = comparisonReadiness(recent, previous, consistency: false)
        let consistencyReadiness = comparisonReadiness(recent, previous, consistency: true)
        let speedChange = speedReadiness == .ready ? recent.wpm.flatMap { current in previous.wpm.map { current - $0 } } : nil
        let percent = speedChange.flatMap { change in
            previous.wpm.flatMap { $0 > 0 ? 100 * change / $0 : nil }
        }
        let consistencyChange = consistencyReadiness == .ready ? recent.consistency.flatMap { current in
            previous.consistency.map { current - $0 }
        } : nil

        // The input is normally a short history. Restrict each trailing window
        // to observed days without inventing samples for absent calendar dates.
        let dailyData = normalized.filter { $0.totals.isValid }
        var trend: [TypingProgressTrendSample] = []
        if validBounds && validHistoryBound {
            for day in dailyData {
                guard let sampleEnd = calendar.date(byAdding: .day, value: 1, to: day.date),
                      let sampleStart = calendar.date(byAdding: .day, value: -7, to: sampleEnd) else { continue }
                if let historyDay, sampleStart < historyDay { continue }
                let summary = period(days: normalized, start: sampleStart, end: sampleEnd)
                if let wpm = summary.wpm {
                    trend.append(TypingProgressTrendSample(date: day.date, period: summary,
                                                          wpm: wpm, consistency: summary.consistency))
                }
            }
        }
        return Self(recent: recent, previous: previous, speedReadiness: speedReadiness,
                    consistencyReadiness: consistencyReadiness, speedChangeWPM: speedChange,
                    speedChangePercent: percent?.isFinite == true ? percent : nil,
                    consistencyChangePoints: consistencyChange, dailyData: dailyData, trend: trend)
    }

    private static func safeDate(_ date: Date) -> Bool {
        // Foundation calendars cannot represent arbitrarily large finite Dates.
        let value = date.timeIntervalSince1970
        return value.isFinite && abs(value) <= 253_402_300_799
    }

    private static func period(days: [TypingProgressDay], start: Date, end: Date,
                               invalidBounds: Bool = false) -> TypingProgressPeriod {
        let included = days.filter { $0.date >= start && $0.date < end }
        var totals = RhythmTotals(), rates = RhythmTotals()
        var activeDays = 0, qualifyingDays = 0, consistencyDays = 0
        var rules = Set<String>(), unknownRule = false
        var invalid = invalidBounds
        for day in included {
            guard day.totals.isValid else { invalid = true; continue }
            totals.merge(day.totals)
            if day.isActive {
                activeDays += 1
                rules.formUnion(day.rules)
                if !day.hasKnownRule { unknownRule = true }
            }
            if day.isQualifying {
                rates.merge(day.totals); qualifyingDays += 1
                if day.totals.consistency != nil { consistencyDays += 1 }
            }
        }
        invalid = invalid || !totals.isValid || !rates.isValid
        let speedReadiness: TypingProgressReadiness
        if invalid { speedReadiness = .invalidData }
        else if unknownRule || rules.count > 1 { speedReadiness = .incompatibleRules }
        else if qualifyingDays < minimumQualifyingDays || rates.seconds < minimumPeriodSeconds || rates.wpm == nil {
            speedReadiness = .insufficientEvidence
        } else { speedReadiness = .ready }
        let consistencyReadiness: TypingProgressReadiness = speedReadiness != .ready ? speedReadiness
            : consistencyDays >= minimumQualifyingDays && rates.consistency != nil ? .ready : .insufficientEvidence
        return TypingProgressPeriod(start: start, end: end, totals: totals, rateTotals: rates,
                                    activeDays: activeDays, qualifyingDays: qualifyingDays,
                                    consistencyDays: consistencyDays, rules: rules,
                                    speedReadiness: speedReadiness, consistencyReadiness: consistencyReadiness)
    }

    private static func comparisonReadiness(_ recent: TypingProgressPeriod, _ previous: TypingProgressPeriod,
                                           consistency: Bool) -> TypingProgressReadiness {
        let statuses = consistency ? [recent.consistencyReadiness, previous.consistencyReadiness]
            : [recent.speedReadiness, previous.speedReadiness]
        if statuses.contains(.invalidData) { return .invalidData }
        if statuses.contains(.incompatibleRules)
            || (!recent.rules.isEmpty && !previous.rules.isEmpty && recent.rules != previous.rules) {
            return .incompatibleRules
        }
        return statuses.allSatisfy { $0 == .ready } ? .ready : .insufficientEvidence
    }
}
