import Testing
import Foundation
import TypingCore
import TypingStore
import CSQLite

final class RateConsistencyStoreTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let hour = Date(timeIntervalSince1970: 1_792_713_600)
    private let dailyColumns = "day,timezone,rule,evidence,keys,edits,composition,intervals,seconds,new_intervals,new_seconds,english,chinese,language,characters,rated_characters,character_seconds,character_intervals"
    private let hourlyColumns = "bucket_start,bucket_end,timezone,rule,application_id,keys,intervals,seconds,squared_interval_seconds"
    private let sessionColumns = "id,start_time,end_time,timezone,rule,keys,intervals,seconds,squared_interval_seconds,end_reason"

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RateConsistencyStoreTests-\(UUID().uuidString)").appendingPathComponent("test.sqlite")
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
    private func snapshot(_ table: String, columns: String, at url: URL) throws -> String {
        let expression = columns.split(separator: ",").map { "quote(\($0))" }.joined(separator: "||'|'||")
        return try scalar("SELECT \(expression) FROM \(table)", at: url)
    }
    private func seedV3(at url: URL) throws {
        let epoch = hour.timeIntervalSince1970
        try execute("""
            CREATE TABLE daily (
              day TEXT NOT NULL,timezone TEXT NOT NULL,rule TEXT NOT NULL,evidence TEXT NOT NULL,
              keys INTEGER NOT NULL,edits INTEGER NOT NULL,composition INTEGER NOT NULL,
              intervals REAL NOT NULL,seconds REAL NOT NULL,new_intervals REAL NOT NULL,new_seconds REAL NOT NULL,
              english INTEGER NOT NULL,chinese INTEGER NOT NULL,language TEXT NOT NULL,characters INTEGER NOT NULL,
              rated_characters REAL NOT NULL,character_seconds REAL NOT NULL,character_intervals REAL NOT NULL,
              PRIMARY KEY(day,timezone,rule,evidence,language));
            INSERT INTO daily VALUES('2026-10-23','Asia/Shanghai','legacy-rule','probable',17,3,2,12.5,3.25,7.5,1.75,9,2,'zh',7,6.5,1.2,4.5);
            CREATE TABLE activity_hourly (
              bucket_start REAL NOT NULL,bucket_end REAL NOT NULL,timezone TEXT NOT NULL,rule TEXT NOT NULL,application_id TEXT NOT NULL,
              keys INTEGER NOT NULL,intervals REAL NOT NULL,seconds REAL NOT NULL,squared_interval_seconds REAL NOT NULL,
              PRIMARY KEY(bucket_start,timezone,rule,application_id));
            INSERT INTO activity_hourly VALUES(\(epoch),\(epoch + 3600),'GMT','legacy-rule','',40,39,7.8,1.56);
            CREATE TABLE activity_sessions (
              id TEXT NOT NULL PRIMARY KEY,start_time REAL NOT NULL,end_time REAL NOT NULL,timezone TEXT NOT NULL,rule TEXT NOT NULL,
              keys INTEGER NOT NULL,intervals REAL NOT NULL,seconds REAL NOT NULL,squared_interval_seconds REAL NOT NULL,end_reason TEXT);
            INSERT INTO activity_sessions VALUES('legacy-session',\(epoch + 1),\(epoch + 8.8),'GMT','legacy-rule',40,39,7.8,1.56,'paused');
            CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('keep');
            PRAGMA user_version=3;
            """, at: url)
    }
    private func totals(_ rate: RateConsistencyTotals) -> RhythmTotals {
        var totals = RhythmTotals(keys: 61, intervals: 60, seconds: 12, squaredIntervalSeconds: 2.4)
        totals.rateConsistency = rate
        return totals
    }
    private func hourly(_ rate: RateConsistencyTotals, app: String = "") -> HourlyActivity {
        HourlyActivity(bucketStart: hour, bucketEnd: hour.addingTimeInterval(3600), timezone: "GMT", rule: "rule", applicationID: app, totals: totals(rate))
    }
    private func session(_ rate: RateConsistencyTotals, reason: String? = nil) -> TypingSession {
        TypingSession(id: "session", start: hour, end: hour.addingTimeInterval(12), timezone: "GMT", rule: "rule", totals: totals(rate), endReason: reason)
    }
    private func daily() -> StoredAggregate {
        var row = StoredAggregate(day: "2026-10-23", timezone: "GMT", rule: "rule", evidence: "probable")
        row.keys = 1
        return row
    }

    @Test func v3MigrationAddsEmptyRateMomentsWithoutRebuildingOrRelabelingLegacyData() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try seedV3(at: url)
        let before = try [snapshot("daily", columns: dailyColumns, at: url), snapshot("activity_hourly", columns: hourlyColumns, at: url), snapshot("activity_sessions", columns: sessionColumns, at: url)]
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        #expect(try snapshot("daily", columns: dailyColumns, at: url) == before[0])
        #expect(try snapshot("activity_hourly", columns: hourlyColumns, at: url) == before[1])
        #expect(try snapshot("activity_sessions", columns: sessionColumns, at: url) == before[2])
        #expect(try scalar("PRAGMA user_version", at: url) == "5")
        #expect(try scalar("SELECT value FROM unrelated", at: url) == "keep")
        let hours = try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600))
        let sessions = try db.querySessions(since: hour, until: hour.addingTimeInterval(3600))
        for totals in hours.map(\.totals) + sessions.map(\.totals) {
            #expect(totals.rateConsistency == RateConsistencyTotals())
            #expect(totals.rateConsistency.consistency == nil)
            #expect(totals.keys == 40 && totals.intervals == 39 && totals.seconds == 7.8 && totals.squaredIntervalSeconds == 1.56)
        }
        #expect(hours.first?.rule == "legacy-rule" && sessions.first?.rule == "legacy-rule")
        #expect(try scalar("SELECT sql FROM sqlite_master WHERE name='daily'", at: url).contains("PRIMARY KEY(day,timezone,rule,evidence,language)"))
    }

    @Test func ratesRoundTripAndHourlyMergingUsesAllSamplesWhileSessionBackfillIsAbsolute() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let slow = RateConsistencyTotals(count: 10, intervals: 20, sum: 600, squaredSum: 36_000)
        let fast = RateConsistencyTotals(count: 20, intervals: 40, sum: 2_400, squaredSum: 288_000)
        let combined = RateConsistencyTotals(count: 30, intervals: 60, sum: 3_000, squaredSum: 324_000)
        var withZero = combined; withZero.count += 1
        do {
            let db = try AggregateStore(url: url, now: hour, timeZone: utc)
            try db.save([], activity: ActivityBatch(hourly: [hourly(slow)], sessions: [session(slow)]))
            // Same key count/end, but later confirmation adds rate samples.
            try db.save([], activity: ActivityBatch(hourly: [hourly(fast)], sessions: [session(combined, reason: "paused")]))
            try db.save([], activity: ActivityBatch(sessions: [session(slow)]))
            try db.save([], activity: ActivityBatch(sessions: [session(withZero)]))
            try db.save([], activity: ActivityBatch(sessions: [session(combined)]))
            var changes = [withZero, withZero, withZero, withZero]
            changes[0].count += 1; changes[1].intervals += 1
            changes[2].sum += 1; changes[3].squaredSum += 1
            for rate in changes {
                var laterStart = session(rate); laterStart.start = laterStart.start.addingTimeInterval(0.1)
                #expect(throws: (any Error).self) { try db.save([], activity: ActivityBatch(sessions: [laterStart])) }
            }
        }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let row = try #require(db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).first)
        #expect(row.totals.rateConsistency == combined)
        #expect(abs((row.totals.rateConsistency.coefficientOfVariation ?? 0) - sqrt(0.08)) < 1e-12)
        #expect((row.totals.rateConsistency.consistency ?? 100) < 100)
        let saved = try #require(db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).first)
        #expect(saved.totals.keys == 61 && saved.totals.rateConsistency == withZero && saved.endReason == "paused")
    }

    @Test func rateMomentFailureRollsBackDailyHourlyAndSessionUpdatesTogether() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rate = RateConsistencyTotals(count: 10, intervals: 20, sum: 600, squaredSum: 36_000)
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        try db.save([], activity: ActivityBatch(hourly: [hourly(rate)], sessions: [session(rate)]))
        try execute("CREATE TRIGGER fail_rate BEFORE INSERT ON activity_sessions WHEN NEW.id='broken' BEGIN SELECT RAISE(ABORT,'fixture'); END;", at: url)
        var broken = session(rate); broken.id = "broken"
        #expect(throws: (any Error).self) { try db.save([self.daily()], activity: ActivityBatch(hourly: [self.hourly(rate)], sessions: [broken])) }
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).first?.totals.rateConsistency == rate)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).map(\.id) == ["session"])
    }

    @Test func malformedRateMomentsNeverPartiallySaveAndZeroRateBinsRemainValid() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let invalid = [
            RateConsistencyTotals(count: -1), RateConsistencyTotals(count: 1, intervals: -1),
            RateConsistencyTotals(intervals: 1), RateConsistencyTotals(sum: 1),
            RateConsistencyTotals(count: 1, sum: .infinity), RateConsistencyTotals(count: 1, sum: .nan),
            RateConsistencyTotals(count: 1, sum: -1), RateConsistencyTotals(count: 1, squaredSum: -1),
            RateConsistencyTotals(count: 2, sum: 4, squaredSum: 1), RateConsistencyTotals(count: 2, squaredSum: 1),
            RateConsistencyTotals(count: 1, sum: 1, squaredSum: 2),
            RateConsistencyTotals(count: 1_000_000_000_001), RateConsistencyTotals(count: 1, intervals: 1_000_000_000_001),
            RateConsistencyTotals(count: 1, sum: 1e16, squaredSum: 1e18),
            RateConsistencyTotals(count: 1, sum: 1e15, squaredSum: 1e19)
        ]
        for rate in invalid {
            #expect(throws: (any Error).self) { try db.save([self.daily()], activity: ActivityBatch(hourly: [self.hourly(.init()), self.hourly(rate, app: "org.example.Editor")])) }
            #expect(try db.query(since: "0000").isEmpty)
            #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true).isEmpty)
        }
        let zero = RateConsistencyTotals(count: 10)
        try db.save([], activity: ActivityBatch(hourly: [hourly(zero)], sessions: [session(zero)]))
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).first?.totals.rateConsistency == zero)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).first?.totals.rateConsistency.consistency == nil)
    }

    @Test func additiveRateCounterOverflowRollsBackTheWholeTransaction() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        let maximum = RateConsistencyTotals(count: 1_000_000_000_000)
        try db.save([], activity: ActivityBatch(hourly: [hourly(maximum)]))
        #expect(throws: (any Error).self) { try db.save([self.daily()], activity: ActivityBatch(hourly: [self.hourly(.init(count: 1))])) }
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600)).first?.totals.rateConsistency == maximum)
    }

    @Test func perAppClearAndFullClearEraseRateMomentsWithTheirRows() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rate = RateConsistencyTotals(count: 10, intervals: 20, sum: 600, squaredSum: 36_000)
        let db = try AggregateStore(url: url, now: hour, timeZone: utc)
        try db.save([daily()], activity: ActivityBatch(hourly: [hourly(rate), hourly(rate, app: "org.example.Editor")], sessions: [session(rate)]))
        try db.clearAppActivity()
        let rows = try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true)
        #expect(rows.count == 1 && rows[0].applicationID.isEmpty && rows[0].totals.rateConsistency == rate)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).first?.totals.rateConsistency == rate)
        #expect(try db.query(since: "0000").count == 1)
        try db.clear()
        #expect(try db.queryHourly(since: hour, until: hour.addingTimeInterval(3600), includeApplications: true).isEmpty)
        #expect(try db.querySessions(since: hour, until: hour.addingTimeInterval(3600)).isEmpty)
        #expect(try db.query(since: "0000").isEmpty)
    }

    @Test func invalidV3LayoutAndFutureV6LeaveSchemaAndDataUntouched() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try seedV3(at: url)
        try execute("ALTER TABLE activity_hourly ADD COLUMN rate_sample_count INTEGER NOT NULL DEFAULT 0", at: url)
        #expect(throws: (any Error).self) { try AggregateStore(url: url, now: self.hour, timeZone: self.utc) }
        #expect(try scalar("PRAGMA user_version", at: url) == "3")
        #expect(try scalar("SELECT COUNT(*) FROM pragma_table_info('activity_sessions')", at: url) == "10")
        #expect(try scalar("SELECT keys FROM activity_hourly", at: url) == "40")
        let future = location(); defer { try? FileManager.default.removeItem(at: future.deletingLastPathComponent()) }
        try execute("CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('keep'); PRAGMA user_version=6", at: future)
        let mode = try scalar("PRAGMA journal_mode", at: future)
        #expect(throws: (any Error).self) { try AggregateStore(url: future, now: self.hour, timeZone: self.utc) }
        #expect(try scalar("PRAGMA user_version", at: future) == "6")
        #expect(try scalar("PRAGMA journal_mode", at: future) == mode)
        #expect(try scalar("SELECT value FROM future_data", at: future) == "keep")
    }
}
