import Testing
import Foundation
import TypingCore
import TypingStore
import CSQLite

final class ActivityStoreTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let hour = Date(timeIntervalSince1970: 1_792_713_600)
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ActivityStoreTests-\(UUID().uuidString)").appendingPathComponent("test.sqlite")
    }
    private func totals(_ keys: Int = 5) -> RhythmTotals {
        RhythmTotals(keys: keys, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.16)
    }
    private func hourly(app: String = "", at date: Date? = nil) -> HourlyActivity {
        let start = date ?? hour
        return HourlyActivity(bucketStart: start, bucketEnd: start.addingTimeInterval(3600), timezone: "GMT", rule: "v4", applicationID: app, totals: totals())
    }
    private func session(_ id: String = "one", at date: Date? = nil, endReason: String? = nil) -> TypingSession {
        let start = date ?? hour.addingTimeInterval(10)
        return TypingSession(id: id, start: start, end: start.addingTimeInterval(0.8), timezone: "GMT", rule: "v4", totals: totals(), endReason: endReason)
    }
    private func execute(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite("fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }
    private func scalar(_ sql: String, at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StoreError.sqlite("fixture read") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.sqlite("fixture prepare") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.sqlite("fixture scalar") }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    @Test func v2MigrationPreservesEveryDailyColumnAndDoesNotInventFineGrainedHistory() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try execute("""
            CREATE TABLE daily (
              day TEXT NOT NULL,timezone TEXT NOT NULL,rule TEXT NOT NULL,evidence TEXT NOT NULL,
              keys INTEGER NOT NULL,edits INTEGER NOT NULL,composition INTEGER NOT NULL,
              intervals REAL NOT NULL,seconds REAL NOT NULL,new_intervals REAL NOT NULL,new_seconds REAL NOT NULL,
              english INTEGER NOT NULL,chinese INTEGER NOT NULL,language TEXT NOT NULL,characters INTEGER NOT NULL,
              rated_characters REAL NOT NULL,character_seconds REAL NOT NULL,character_intervals REAL NOT NULL,
              PRIMARY KEY(day,timezone,rule,evidence,language));
            INSERT INTO daily VALUES('2026-10-23','Asia/Shanghai','v4','probable',17,3,2,12.5,3.25,7.5,1.75,9,2,'zh',7,6.5,1.2,4.5);
            CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('preserved'); PRAGMA user_version=2;
            """, at: url)
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let row = try #require(db.query(since: "0000").first)
        #expect(row.day == "2026-10-23" && row.timezone == "Asia/Shanghai" && row.rule == "v4" && row.evidence == "probable" && row.language == "zh")
        #expect(row.keys == 17 && row.edits == 3 && row.composition == 2)
        #expect(row.intervals == 12.5 && row.seconds == 3.25 && row.newIntervals == 7.5 && row.newSeconds == 1.75)
        #expect(row.english == 9 && row.chinese == 2 && row.characters == 7 && row.ratedCharacters == 6.5 && row.characterSeconds == 1.2 && row.characterIntervals == 4.5)
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.activityCoverageStart() == nil)
        #expect(try scalar("PRAGMA user_version", at: url) == "6")
        #expect(try scalar("SELECT value FROM unrelated", at: url) == "preserved")
    }

    @Test func activityRoundTripsWithAdditiveHoursAndIdempotentSessionCheckpoints() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = session()
        do {
            let db = try AggregateStore(url: url, now: hour, timeZone: utc)
            try db.save([], activity: ActivityBatch(hourly: [hourly()], sessions: [first]))
            try db.save([], activity: ActivityBatch(hourly: [hourly()], sessions: [first]))
            var later = first
            later.end = later.end.addingTimeInterval(0.8); later.totals.merge(totals()); later.endReason = "pause"
            try db.save([], activity: ActivityBatch(sessions: [later]))
            try db.save([], activity: ActivityBatch(sessions: [first]))
        }
        let reopened = try AggregateStore(url: url, now: hour, timeZone: utc)
        let row = try #require(reopened.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).first)
        #expect(row.totals.keys == 10 && row.totals.intervals == 8 && row.totals.seconds == 1.6 && row.totals.squaredIntervalSeconds == 0.32)
        let saved = try #require(reopened.querySessions(since: hour, until: hour.addingTimeInterval(3600)).first)
        #expect(saved.totals.keys == 10 && saved.totals.intervals == 8 && saved.endReason == "pause")
        #expect(try reopened.activityCoverageStart() == hour)
    }

    @Test func analyticsFailureRollsBackDailyAndHourlyWritesTogether() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        try execute("CREATE TRIGGER fail_activity BEFORE INSERT ON activity_sessions WHEN NEW.id='broken' BEGIN SELECT RAISE(ABORT,'fixture'); END;", at: url)
        var daily = StoredAggregate(day: "2026-10-23", timezone: "GMT", rule: "v4", evidence: "probable"); daily.keys = 5
        #expect(throws: (any Error).self) { try db.save([daily], activity: ActivityBatch(hourly: [self.hourly()], sessions: [self.session("broken")])) }
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        try db.save([daily], activity: ActivityBatch(hourly: [hourly()], sessions: [session()]))
        #expect(try db.query(since: "0000").first?.keys == 5)
    }

    @Test func appBreakdownIsExplicitlyQueriedAndCanBeErasedWithoutOtherStatistics() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        try db.save([], activity: ActivityBatch(hourly: [hourly(), hourly(app: "org.example.Editor")], sessions: [session()]))
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).count == 1)
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true).count == 2)
        try db.clearAppActivity()
        let rows = try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true)
        #expect(rows.count == 1 && rows[0].applicationID.isEmpty)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).count == 1)
        try db.clear()
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.activityCoverageStart() == nil)
    }

    @Test func hourAndSessionRangesUseHalfOpenBoundariesIncludingIsolatedKeys() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let next = hour.addingTimeInterval(3600)
        let point = TypingSession(id: "point", start: hour, end: hour, timezone: "GMT", rule: "v4", totals: RhythmTotals(keys: 1), endReason: "idle")
        let prior = TypingSession(id: "prior", start: hour.addingTimeInterval(-1), end: hour, timezone: "GMT", rule: "v4", totals: totals(), endReason: "day")
        try db.save([], activity: ActivityBatch(hourly: [hourly(), hourly(at: next)], sessions: [point, prior, session("next", at: next)]))
        #expect(try db.queryHourly(since: hour, until: next).count == 1)
        #expect(try db.querySessions(since: hour, until: next).map(\.id) == ["point"])
        #expect(throws: (any Error).self) { try db.queryHourly(since: next, until: self.hour) }
    }

    @Test func invalidAnalyticsAndConflictingSessionIdentityNeverPartiallySave() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        try db.save([], activity: ActivityBatch(sessions: [session()]))
        var conflict = session(); conflict.rule = "different-rule"
        #expect(throws: (any Error).self) { try db.save([], activity: ActivityBatch(hourly: [self.hourly()], sessions: [conflict])) }
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        for invalid in [RhythmTotals(keys: -1), RhythmTotals(keys: 1, intervals: .infinity), RhythmTotals(keys: 5, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.01)] {
            var row = hourly(); row.totals = invalid
            #expect(throws: (any Error).self) { try db.save([], activity: ActivityBatch(hourly: [row])) }
        }
    }

    @Test func midnightBackfillCanExpandPersistedSessionStartAndOlderRetriesCannotTruncateIt() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = ISO8601DateFormatter().date(from: "2026-10-23T23:59:59Z")!.addingTimeInterval(0.8)
        let midnight = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
        var engine = StatisticsEngine(config: SegmentationConfig(minimumGap: 0.1, coldStartGap: 0.1), timeZone: utc)
        var tracker = ActivityTracker(timeZone: utc)
        var pointCheckpoint: TypingSession?
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            for time in [0.0, 0.4, 0.8, 1.2] {
                let input = ClassifiedInput(time: time, date: base.addingTimeInterval(time), context: 1,
                                            category: .textEntry, evidence: .probable, source: .global, language: "mul")
                let batch = tracker.record(input: input, result: engine.recordWithIntervals(input), rule: engine.config.ruleID)
                try db.save([], activity: batch)
                if time == 0.4 { pointCheckpoint = tracker.currentSession }
            }
            let prior = try #require(pointCheckpoint)
            #expect(prior.start > midnight)
            try db.save([], activity: ActivityBatch(sessions: [prior]))
            let saved = try #require(db.querySessions(since: midnight, until: midnight.addingTimeInterval(3600)).first)
            #expect(saved.id == prior.id && saved.start == midnight && saved.totals.keys == 3)
            #expect(abs(saved.totals.seconds - 1) < 1e-6)
            var invalid = saved; invalid.start = invalid.start.addingTimeInterval(0.1)
            #expect(throws: (any Error).self) { try db.save([], activity: ActivityBatch(sessions: [invalid])) }
            try db.save([], activity: tracker.finish(reason: "paused"))
        }
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        let sessions = try db.querySessions(since: base.addingTimeInterval(-1), until: midnight.addingTimeInterval(3600))
        #expect(sessions.count == 2 && sessions.reduce(0) { $0 + $1.totals.keys } == 4)
        #expect(sessions.last?.start == midnight && sessions.last?.endReason == "paused")
        let hours = try db.queryHourly(since: base.addingTimeInterval(-3600), until: midnight.addingTimeInterval(3600))
        let totals = hours.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
        #expect(totals.keys == 4 && abs(totals.intervals - 3) < 1e-6 && abs(totals.seconds - 1.2) < 1e-6)
    }

    @Test func migrationCollisionRollsBackAndFutureVersionSixIsRejected() throws {
        for newer in [false, true] {
            let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            // Build a valid fixture first, then simulate an older/newer declaration.
            do { _ = try AggregateStore(url: url, now: hour, timeZone: utc) }
            if newer {
                try execute("PRAGMA user_version=7", at: url)
                #expect(throws: (any Error).self) { try AggregateStore(url: url, now: self.hour, timeZone: self.utc) }
                #expect(try scalar("PRAGMA user_version", at: url) == "7")
            } else {
                try execute("PRAGMA user_version=2", at: url)
                #expect(throws: (any Error).self) { try AggregateStore(url: url, now: self.hour, timeZone: self.utc) }
                #expect(try scalar("PRAGMA user_version", at: url) == "2")
                #expect(try scalar("SELECT COUNT(*) FROM activity_sessions", at: url) == "0")
            }
        }
    }

    @Test func analyticsPruneUsesFiveCalendarYearsWithoutDeletingBoundaryDay() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 12))!
        let old = calendar.date(from: DateComponents(year: 2019, month: 2, day: 28, hour: 12))!
        let boundary = calendar.date(from: DateComponents(year: 2019, month: 3, day: 1))!
        do {
            let db = try AggregateStore(url: url, now: now, timeZone: utc)
            try db.save([], activity: ActivityBatch(hourly: [hourly(at: old), hourly(at: boundary)], sessions: [session("old", at: old), session("boundary", at: boundary)]))
        }
        let db = try AggregateStore(url: url, now: now, timeZone: utc)
        #expect(try db.queryHourly(since: old.addingTimeInterval(-3600), until: now).map(\.bucketStart) == [boundary])
        #expect(try db.querySessions(since: old.addingTimeInterval(-3600), until: now).map(\.id) == ["boundary"])
    }

    @Test func boundedQueriesReportOverflowRatherThanSilentlyDroppingActivity() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let epoch = hour.timeIntervalSince1970
        try execute("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5001)
            INSERT INTO activity_hourly (bucket_start,bucket_end,timezone,rule,application_id,keys,intervals,seconds,squared_interval_seconds) SELECT \(epoch),\(epoch + 3600),'GMT','v4','app.'||x,1,0,0,0 FROM n;
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5001)
            INSERT INTO activity_sessions (id,start_time,end_time,timezone,rule,keys,intervals,seconds,squared_interval_seconds,end_reason) SELECT 'session.'||x,\(epoch),\(epoch),'GMT','v4',1,0,0,0,'idle' FROM n;
            """, at: url)
        do {
            _ = try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true)
            Issue.record("An app-inclusive query silently truncated its overflow")
        } catch StoreError.resultLimit(let limit) { #expect(limit == 5000) }
        do {
            _ = try db.querySessions(since: hour, until: hour.addingTimeInterval(3600))
            Issue.record("A session query silently truncated its overflow")
        } catch StoreError.resultLimit(let limit) { #expect(limit == 5000) }
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
    }
}
