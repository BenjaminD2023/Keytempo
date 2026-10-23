import Foundation
import CSQLite
import TypingCore

public struct StoredAggregate: Sendable {
    public var day: String
    public var timezone: String
    public var rule: String
    public var evidence: String
    public var keys: Int = 0
    public var edits: Int = 0
    public var composition: Int = 0
    public var intervals: Double = 0
    public var seconds: Double = 0
    public var newIntervals: Double = 0
    public var newSeconds: Double = 0
    public var english: Int = 0
    public var chinese: Int = 0
    public var language: String
    public var characters: Int = 0
    public var ratedCharacters: Double = 0
    public var characterSeconds: Double = 0
    public var characterIntervals: Double = 0
    public var id: String { [day, timezone, rule, evidence, language].joined(separator: "|") }
    public init(day: String, timezone: String, rule: String, evidence: String, language: String = "und") {
        self.day = day; self.timezone = timezone; self.rule = rule; self.evidence = evidence
        self.language = language
    }
    public mutating func merge(_ other: StoredAggregate) {
        keys += other.keys; edits += other.edits; composition += other.composition
        intervals += other.intervals; seconds += other.seconds
        newIntervals += other.newIntervals; newSeconds += other.newSeconds
        english += other.english; chinese += other.chinese
        characters += other.characters; ratedCharacters += other.ratedCharacters; characterSeconds += other.characterSeconds
        characterIntervals += other.characterIntervals
    }
}

public enum StoreError: LocalizedError {
    case sqlite(String)
    case unsupportedVersion(Int32)
    case resultLimit(Int)
    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): return message
        case let .unsupportedVersion(version): return "统计数据库版本 \(version) 高于此版本支持的版本 3，请使用较新版本的 Keytempo。"
        case let .resultLimit(limit): return "查询超过 \(limit) 条记录，请缩小时间范围。"
        }
    }
}

/// Serialized by a lock for testability; application calls disk methods on its utility queue.
public final class AggregateStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let legacyColumns = ["day", "timezone", "rule", "evidence", "keys", "edits", "composition", "intervals", "seconds", "new_intervals", "new_seconds", "english", "chinese"]
    private static let columns = legacyColumns + ["language", "characters", "rated_characters", "character_seconds", "character_intervals"]
    private static let createDaily = """
        CREATE TABLE daily (
          day TEXT NOT NULL, timezone TEXT NOT NULL, rule TEXT NOT NULL, evidence TEXT NOT NULL,
          keys INTEGER NOT NULL, edits INTEGER NOT NULL, composition INTEGER NOT NULL,
          intervals REAL NOT NULL, seconds REAL NOT NULL, new_intervals REAL NOT NULL, new_seconds REAL NOT NULL,
          english INTEGER NOT NULL, chinese INTEGER NOT NULL,
          language TEXT NOT NULL, characters INTEGER NOT NULL, rated_characters REAL NOT NULL, character_seconds REAL NOT NULL, character_intervals REAL NOT NULL,
          PRIMARY KEY(day, timezone, rule, evidence, language));
        """
    private static let hourlyColumns = ["bucket_start", "bucket_end", "timezone", "rule", "application_id", "keys", "intervals", "seconds", "squared_interval_seconds"]
    private static let sessionColumns = ["id", "start_time", "end_time", "timezone", "rule", "keys", "intervals", "seconds", "squared_interval_seconds", "end_reason"]
    private static let createActivity = """
        CREATE TABLE activity_hourly (
          bucket_start REAL NOT NULL, bucket_end REAL NOT NULL,
          timezone TEXT NOT NULL, rule TEXT NOT NULL, application_id TEXT NOT NULL,
          keys INTEGER NOT NULL CHECK(typeof(keys)='integer' AND keys>=0),
          intervals REAL NOT NULL CHECK(intervals>=0 AND intervals<=1e12),
          seconds REAL NOT NULL CHECK(seconds>=0 AND seconds<=1e12),
          squared_interval_seconds REAL NOT NULL CHECK(squared_interval_seconds>=0 AND squared_interval_seconds<=1e15),
          PRIMARY KEY(bucket_start,timezone,rule,application_id));
        CREATE INDEX activity_hourly_range ON activity_hourly(bucket_start);
        CREATE TABLE activity_sessions (
          id TEXT NOT NULL PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL,
          timezone TEXT NOT NULL, rule TEXT NOT NULL,
          keys INTEGER NOT NULL CHECK(typeof(keys)='integer' AND keys>=0),
          intervals REAL NOT NULL CHECK(intervals>=0 AND intervals<=1e12),
          seconds REAL NOT NULL CHECK(seconds>=0 AND seconds<=1e12),
          squared_interval_seconds REAL NOT NULL CHECK(squared_interval_seconds>=0 AND squared_interval_seconds<=1e15),
          end_reason TEXT);
        CREATE INDEX activity_sessions_range ON activity_sessions(start_time,end_time);
        """
    public let url: URL
    public init(url: URL, now: Date = Date(), timeZone: TimeZone = .current) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw StoreError.sqlite("无法打开统计数据库")
        }
        do {
            sqlite3_busy_timeout(db, 1500)
            // Reject a newer database before changing its journal or schema settings.
            let version = try schemaVersion()
            guard version <= 3 else { throw StoreError.unsupportedVersion(version) }
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")
            try prepareSchema()
            try prune(now: now, timeZone: timeZone)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> StoreError { .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库不可用") }
    private func bind(_ value: String, at index: Int32, statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func schemaVersion() throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(statement, 0)
    }
    private func tableLayout(_ table: String) throws -> (columns: [String], primaryKey: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var columns: [String] = [], primaryKey: [(Int32, String)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let name = String(cString: sqlite3_column_text(statement, 1))
            columns.append(name)
            let order = sqlite3_column_int(statement, 5)
            if order > 0 { primaryKey.append((order, name)) }
        }
        return (columns, primaryKey.sorted { $0.0 < $1.0 }.map { $0.1 })
    }
    private func validateActivityLayout() throws {
        let hourly = try tableLayout("activity_hourly"), sessions = try tableLayout("activity_sessions")
        guard hourly.columns == Self.hourlyColumns,
              hourly.primaryKey == ["bucket_start", "timezone", "rule", "application_id"],
              sessions.columns == Self.sessionColumns, sessions.primaryKey == ["id"] else {
            throw StoreError.sqlite("活动统计数据库结构不匹配，已保留原有数据。")
        }
    }
    /// The table rebuild and version update commit together; failure leaves v1 intact.
    private func prepareSchema() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try schemaVersion(), layout = try tableLayout("daily")
            guard version <= 3 else { throw StoreError.unsupportedVersion(version) }
            let legacyKey = ["day", "timezone", "rule", "evidence"]
            if version == 0 && layout.columns.isEmpty {
                try execute(Self.createDaily)
            } else if (version == 0 || version == 1) && layout.columns == Self.legacyColumns && layout.primaryKey == legacyKey {
                try execute("ALTER TABLE daily RENAME TO keytempo_daily_v1_migration")
                try execute(Self.createDaily)
                let legacy = Self.legacyColumns.joined(separator: ",")
                try execute("INSERT INTO daily (\(Self.columns.joined(separator: ","))) SELECT \(legacy),'und',0,0,0,0 FROM keytempo_daily_v1_migration")
                try execute("DROP TABLE keytempo_daily_v1_migration")
            } else if !(2...3).contains(version) || layout.columns != Self.columns || layout.primaryKey != legacyKey + ["language"] {
                throw StoreError.sqlite("统计数据库结构与版本 \(version) 不匹配，已保留原有数据。")
            }
            if version < 3 { try execute(Self.createActivity) }
            try validateActivityLayout()
            try execute("CREATE INDEX IF NOT EXISTS daily_range ON daily(day); PRAGMA user_version=3; COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func save(_ rows: [StoredAggregate], activity: ActivityBatch = .init()) throws {
        guard !rows.isEmpty || !activity.hourly.isEmpty || !activity.sessions.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = """
            INSERT INTO daily (\(Self.columns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(day,timezone,rule,evidence,language) DO UPDATE SET
            keys=keys+excluded.keys,edits=edits+excluded.edits,composition=composition+excluded.composition,
            intervals=intervals+excluded.intervals,seconds=seconds+excluded.seconds,
            new_intervals=new_intervals+excluded.new_intervals,new_seconds=new_seconds+excluded.new_seconds,
            english=english+excluded.english,chinese=chinese+excluded.chinese,
            characters=characters+excluded.characters,rated_characters=rated_characters+excluded.rated_characters,
            character_seconds=character_seconds+excluded.character_seconds,character_intervals=character_intervals+excluded.character_intervals
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
            defer { sqlite3_finalize(statement) }
            for row in rows {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                for (i, value) in [row.day, row.timezone, row.rule, row.evidence].enumerated() { bind(value, at: Int32(i + 1), statement: statement) }
                for (i, value) in [row.keys, row.edits, row.composition].enumerated() { sqlite3_bind_int64(statement, Int32(i + 5), Int64(value)) }
                for (i, value) in [row.intervals, row.seconds, row.newIntervals, row.newSeconds].enumerated() { sqlite3_bind_double(statement, Int32(i + 8), value) }
                sqlite3_bind_int64(statement, 12, Int64(row.english)); sqlite3_bind_int64(statement, 13, Int64(row.chinese))
                bind(row.language, at: 14, statement: statement)
                sqlite3_bind_int64(statement, 15, Int64(row.characters))
                sqlite3_bind_double(statement, 16, row.ratedCharacters); sqlite3_bind_double(statement, 17, row.characterSeconds)
                sqlite3_bind_double(statement, 18, row.characterIntervals)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try saveActivity(activity)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func validate(_ totals: RhythmTotals) throws {
        let n = totals.intervals, seconds = totals.seconds, squared = totals.squaredIntervalSeconds
        guard totals.keys >= 0, n.isFinite, seconds.isFinite, squared.isFinite,
              (0...1e12).contains(n), (0...1e12).contains(seconds), (0...1e15).contains(squared),
              n == 0 ? seconds == 0 && squared == 0 : seconds > 0 && squared > 0 else {
            throw StoreError.sqlite("活动统计包含无效数值，未保存本次事务。")
        }
        // Moments must describe a possible nonnegative interval distribution.
        let sumSquared = seconds * seconds
        guard squared * n + max(1, sumSquared) * 1e-9 >= sumSquared else {
            throw StoreError.sqlite("活动统计的节奏样本不一致，未保存本次事务。")
        }
    }
    private func validateMetadata(timezone: String, rule: String) throws {
        guard !timezone.isEmpty, timezone.utf8.count <= 255, !rule.isEmpty, rule.utf8.count <= 512,
              !timezone.contains("\0"), !rule.contains("\0") else {
            throw StoreError.sqlite("活动统计元数据无效，未保存本次事务。")
        }
    }
    private func bindTotals(_ totals: RhythmTotals, statement: OpaquePointer, startingAt index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(totals.keys))
        sqlite3_bind_double(statement, index + 1, totals.intervals)
        sqlite3_bind_double(statement, index + 2, totals.seconds)
        sqlite3_bind_double(statement, index + 3, totals.squaredIntervalSeconds)
    }
    /// Called inside save's daily/activity transaction. Hourly values are
    /// additive deltas; session values are complete checkpoints, never deltas.
    private func saveActivity(_ activity: ActivityBatch) throws {
        guard activity.hourly.count <= 4096, activity.sessions.count <= 512 else {
            throw StoreError.sqlite("活动统计批次超过容量，未保存本次事务。")
        }
        let hourlySQL = """
            INSERT INTO activity_hourly (\(Self.hourlyColumns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(bucket_start,timezone,rule,application_id) DO UPDATE SET
            bucket_end=excluded.bucket_end,keys=keys+excluded.keys,
            intervals=intervals+excluded.intervals,seconds=seconds+excluded.seconds,
            squared_interval_seconds=squared_interval_seconds+excluded.squared_interval_seconds
            """
        var hourly: OpaquePointer?
        guard sqlite3_prepare_v2(db, hourlySQL, -1, &hourly, nil) == SQLITE_OK, let hourly else { throw failure() }
        defer { sqlite3_finalize(hourly) }
        for row in activity.hourly {
            try validate(row.totals); try validateMetadata(timezone: row.timezone, rule: row.rule)
            let start = row.bucketStart.timeIntervalSince1970, end = row.bucketEnd.timeIntervalSince1970
            guard start.isFinite, end.isFinite, end > start, end - start <= 10800,
                  row.applicationID.utf8.count <= 255, !row.applicationID.contains("\0") else {
                throw StoreError.sqlite("小时统计范围或应用标识无效，未保存本次事务。")
            }
            sqlite3_reset(hourly); sqlite3_clear_bindings(hourly)
            sqlite3_bind_double(hourly, 1, start); sqlite3_bind_double(hourly, 2, end)
            bind(row.timezone, at: 3, statement: hourly); bind(row.rule, at: 4, statement: hourly)
            bind(row.applicationID, at: 5, statement: hourly); bindTotals(row.totals, statement: hourly, startingAt: 6)
            guard sqlite3_step(hourly) == SQLITE_DONE else { throw failure() }
        }
        let sessionSQL = """
            INSERT INTO activity_sessions (\(Self.sessionColumns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET start_time=MIN(activity_sessions.start_time,excluded.start_time),end_time=excluded.end_time,keys=excluded.keys,
            intervals=excluded.intervals,seconds=excluded.seconds,squared_interval_seconds=excluded.squared_interval_seconds,
            end_reason=COALESCE(excluded.end_reason,activity_sessions.end_reason)
            WHERE excluded.end_time>=activity_sessions.end_time AND excluded.keys>=activity_sessions.keys
              AND excluded.intervals>=activity_sessions.intervals AND excluded.seconds>=activity_sessions.seconds
              AND excluded.squared_interval_seconds>=activity_sessions.squared_interval_seconds
            """
        var session: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionSQL, -1, &session, nil) == SQLITE_OK, let session else { throw failure() }
        defer { sqlite3_finalize(session) }
        for row in activity.sessions {
            try validate(row.totals); try validateMetadata(timezone: row.timezone, rule: row.rule)
            let start = row.start.timeIntervalSince1970, end = row.end.timeIntervalSince1970
            guard !row.id.isEmpty, row.id.utf8.count <= 255, !row.id.contains("\0"), start.isFinite, end.isFinite,
                  end >= start, row.endReason.map({ $0.utf8.count <= 255 && !$0.contains("\0") }) ?? true else {
                throw StoreError.sqlite("输入会话元数据无效，未保存本次事务。")
            }
            try validateSessionIdentity(row)
            sqlite3_reset(session); sqlite3_clear_bindings(session)
            bind(row.id, at: 1, statement: session)
            sqlite3_bind_double(session, 2, start); sqlite3_bind_double(session, 3, end)
            bind(row.timezone, at: 4, statement: session); bind(row.rule, at: 5, statement: session)
            bindTotals(row.totals, statement: session, startingAt: 6)
            if let reason = row.endReason { bind(reason, at: 10, statement: session) } else { sqlite3_bind_null(session, 10) }
            guard sqlite3_step(session) == SQLITE_DONE else { throw failure() }
        }
    }
    private func validateSessionIdentity(_ row: TypingSession) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT start_time,timezone,rule,end_time,keys,intervals,seconds,squared_interval_seconds FROM activity_sessions WHERE id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(row.id, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return }
        guard result == SQLITE_ROW else { throw failure() }
        guard String(cString: sqlite3_column_text(statement, 1)) == row.timezone,
              String(cString: sqlite3_column_text(statement, 2)) == row.rule else {
            throw StoreError.sqlite("输入会话标识重复但时区或统计方式不同，未保存本次事务。")
        }
        // Candidate intervals can be confirmed after a midnight point-session
        // checkpoint was saved, extending that same session back to midnight.
        // A later start is accepted only for an older retry; its lower totals
        // make the upsert a no-op, so it cannot truncate the saved span.
        if row.start.timeIntervalSince1970 > sqlite3_column_double(statement, 0) {
            let end = sqlite3_column_double(statement, 3), totals = readTotals(statement, startingAt: 4)
            let older = row.end.timeIntervalSince1970 <= end && row.totals.keys <= totals.keys &&
                row.totals.intervals <= totals.intervals && row.totals.seconds <= totals.seconds &&
                row.totals.squaredIntervalSeconds <= totals.squaredIntervalSeconds &&
                (row.end.timeIntervalSince1970 < end || row.totals != totals)
            guard older else { throw StoreError.sqlite("输入会话的新检查点不能向后移动起点，未保存本次事务。") }
        }
    }
    private func readTotals(_ statement: OpaquePointer, startingAt index: Int32) -> RhythmTotals {
        RhythmTotals(keys: Int(sqlite3_column_int64(statement, index)), intervals: sqlite3_column_double(statement, index + 1),
                     seconds: sqlite3_column_double(statement, index + 2), squaredIntervalSeconds: sqlite3_column_double(statement, index + 3))
    }
    private func validateRange(_ since: Date, _ until: Date) throws {
        guard since.timeIntervalSince1970.isFinite, until.timeIntervalSince1970.isFinite, since < until else {
            throw StoreError.sqlite("活动查询时间范围无效。")
        }
    }
    /// Half-open bucket-start range. Separate app rows are returned only when
    /// explicitly requested. A capped query fails rather than hiding lost rows.
    public func queryHourly(since: Date, until: Date, includeApplications: Bool = false) throws -> [HourlyActivity] {
        try validateRange(since, until)
        lock.lock(); defer { lock.unlock() }
        let limit = includeApplications ? 5000 : 100000
        let appFilter = includeApplications ? "" : " AND application_id=''"
        let sql = "SELECT \(Self.hourlyColumns.joined(separator: ",")) FROM activity_hourly WHERE bucket_start>=? AND bucket_start<?\(appFilter) ORDER BY bucket_start,timezone,rule,application_id LIMIT \(limit + 1)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970); sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        var rows: [HourlyActivity] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(HourlyActivity(bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                       bucketEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                       timezone: String(cString: sqlite3_column_text(statement, 2)), rule: String(cString: sqlite3_column_text(statement, 3)),
                                       applicationID: String(cString: sqlite3_column_text(statement, 4)), totals: readTotals(statement, startingAt: 5)))
            if rows.count > limit { throw StoreError.resultLimit(limit) }
        }
        return rows
    }
    /// Session spans overlap the half-open query. A single-key point session at
    /// the lower bound is included; a preceding session ending there is not.
    public func querySessions(since: Date, until: Date) throws -> [TypingSession] {
        try validateRange(since, until)
        lock.lock(); defer { lock.unlock() }
        let limit = 5000
        let sql = "SELECT \(Self.sessionColumns.joined(separator: ",")) FROM activity_sessions WHERE start_time<? AND (end_time>? OR (start_time=end_time AND start_time>=?)) ORDER BY start_time,id LIMIT \(limit + 1)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, until.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970); sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        var rows: [TypingSession] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append(TypingSession(id: String(cString: sqlite3_column_text(statement, 0)),
                                      start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                      end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                      timezone: String(cString: sqlite3_column_text(statement, 3)), rule: String(cString: sqlite3_column_text(statement, 4)),
                                      totals: readTotals(statement, startingAt: 5),
                                      endReason: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 9))))
            if rows.count > limit { throw StoreError.resultLimit(limit) }
        }
        return rows
    }
    /// Earliest retained hourly bucket, not an inferred start from old daily data.
    public func activityCoverageStart() throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(bucket_start) FROM activity_hourly WHERE application_id=''", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
    public func clearAppActivity() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { try execute("DELETE FROM activity_hourly WHERE application_id<>''; COMMIT;") }
        catch { try? execute("ROLLBACK"); throw error }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }
    private func deleteBefore(_ time: Double, table: String, column: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE \(column)<?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, time)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func deleteSessionsBefore(_ time: Double) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM activity_sessions WHERE end_time<=? AND start_time<?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, time); sqlite3_bind_double(statement, 2, time)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func query(since: String, until: String = "9999-12-31") throws -> [StoredAggregate] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(Self.columns.joined(separator: ",")) FROM daily WHERE day>=? AND day<=? ORDER BY day,rule,evidence,language LIMIT 50000", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(since, at: 1, statement: statement); bind(until, at: 2, statement: statement)
        func string(_ i: Int32) -> String { String(cString: sqlite3_column_text(statement, i)) }
        var rows: [StoredAggregate] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            var row = StoredAggregate(day: string(0), timezone: string(1), rule: string(2), evidence: string(3), language: string(13))
            row.keys = Int(sqlite3_column_int64(statement, 4)); row.edits = Int(sqlite3_column_int64(statement, 5)); row.composition = Int(sqlite3_column_int64(statement, 6))
            row.intervals = sqlite3_column_double(statement, 7); row.seconds = sqlite3_column_double(statement, 8)
            row.newIntervals = sqlite3_column_double(statement, 9); row.newSeconds = sqlite3_column_double(statement, 10)
            row.english = Int(sqlite3_column_int64(statement, 11)); row.chinese = Int(sqlite3_column_int64(statement, 12))
            row.characters = Int(sqlite3_column_int64(statement, 14)); row.ratedCharacters = sqlite3_column_double(statement, 15)
            row.characterSeconds = sqlite3_column_double(statement, 16)
            row.characterIntervals = sqlite3_column_double(statement, 17)
            rows.append(row)
        }
        return rows
    }
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM daily; DELETE FROM activity_hourly; DELETE FROM activity_sessions; COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
        try execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
    private func prune(now: Date, timeZone: TimeZone) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let cutoff = calendar.date(byAdding: .year, value: -5, to: now)!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM daily WHERE day<?", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        bind(formatter.string(from: cutoff), at: 1, statement: statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try execute("DELETE FROM daily WHERE rowid IN (SELECT rowid FROM daily ORDER BY day DESC LIMIT -1 OFFSET 50000)")
        let instant = calendar.startOfDay(for: cutoff).timeIntervalSince1970
        try deleteBefore(instant, table: "activity_hourly", column: "bucket_start")
        try deleteSessionsBefore(instant)
        try execute("DELETE FROM activity_hourly WHERE rowid IN (SELECT rowid FROM activity_hourly ORDER BY bucket_start DESC,(application_id='') DESC LIMIT -1 OFFSET 300000)")
        try execute("DELETE FROM activity_sessions WHERE rowid IN (SELECT rowid FROM activity_sessions ORDER BY end_time DESC,id LIMIT -1 OFFSET 100000)")
    }
    public static func csv(_ rows: [StoredAggregate]) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "day,timezone,rule,evidence,manual_keys,editing_operations,composition_operations,observed_intervals,observed_seconds,new_input_intervals,new_input_seconds,english_committed_characters,chinese_committed_scalars,language,characters,rated_characters,character_seconds,character_intervals,kpm,estimated_wpm,character_cpm\n"
        return header + rows.map { row in
            let kpm = row.intervals.isFinite && row.seconds.isFinite && row.intervals >= 4 && row.seconds >= 0.5 ? 60 * row.intervals / row.seconds : nil
            let cpm = row.characterIntervals.isFinite && row.ratedCharacters.isFinite && row.characterSeconds.isFinite && row.characterIntervals >= 4 && row.ratedCharacters > 0 && row.characterSeconds >= 0.5 ? 60 * row.ratedCharacters / row.characterSeconds : nil
            func number(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String($0) : nil } ?? "" }
            return [quote(row.day), quote(row.timezone), quote(row.rule), quote(row.evidence), String(row.keys), String(row.edits), String(row.composition), String(row.intervals), String(row.seconds), String(row.newIntervals), String(row.newSeconds), String(row.english), String(row.chinese), quote(row.language), String(row.characters), String(row.ratedCharacters), String(row.characterSeconds), String(row.characterIntervals), number(kpm), number(TypingRate.estimatedWPM(fromKPM: kpm)), number(cpm)].joined(separator: ",")
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}
