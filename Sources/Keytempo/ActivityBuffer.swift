import Foundation
import TypingCore

/// Aggregate rows only; this buffer never retains input events or key names.
struct ActivityBuffer {
    var hourly: [String: HourlyActivity] = [:]
    var sessions: [String: TypingSession] = [:]
    var isEmpty: Bool { hourly.isEmpty && sessions.isEmpty }
    var count: Int { hourly.count + sessions.count }
    var batch: ActivityBatch { ActivityBatch(hourly: Array(hourly.values), sessions: Array(sessions.values)) }

    mutating func merge(_ batch: ActivityBatch) {
        for row in batch.hourly {
            if var prior = hourly[row.id] {
                prior.totals.merge(row.totals); hourly[row.id] = prior
            } else { hourly[row.id] = row }
        }
        for row in batch.sessions {
            if let prior = sessions[row.id] {
                // A failed, older checkpoint must not replace newer live totals.
                if row.totals.keys < prior.totals.keys { continue }
                if row.totals.keys == prior.totals.keys && row.end < prior.end { continue }
                if row.end == prior.end && row.totals == prior.totals && prior.endReason != nil && row.endReason == nil { continue }
            }
            sessions[row.id] = row
        }
    }
    mutating func removeApplications() { hourly = hourly.filter { $0.value.applicationID.isEmpty } }
    mutating func removeAll() { hourly.removeAll(keepingCapacity: true); sessions.removeAll(keepingCapacity: true) }
}

struct ActivityScoreDay: Identifiable, Equatable {
    let day: Date
    let totals: RhythmTotals
    let hasMixedRules: Bool
    var id: Date { day }
}
