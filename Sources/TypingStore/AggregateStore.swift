import Foundation
import CSQLite
import TypingCore
import CryptoKit

public struct StoredAggregate: Codable, Sendable, Equatable {
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

/// Durable earned contributions by scoring day. Earlier activity history has
/// no row here unless the new reward system actually covered that day.
public struct StoredRewardDay: Sendable, Equatable, Identifiable {
    public var day: String
    public var components: RewardComponents
    public var xp: RewardXP
    public var id: String { day }
    public init(day: String, components: RewardComponents = .init(), xp: RewardXP = .init()) {
        self.day = day; self.components = components; self.xp = xp
    }
}

public enum StoreError: LocalizedError {
    case sqlite(String)
    case unsupportedVersion(Int32)
    case resultLimit(Int)
    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): return message
        case let .unsupportedVersion(version): return "统计数据库版本 \(version) 高于此版本支持的版本 6，请使用较新版本的 Keytempo。"
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
    private static let legacyHourlyColumns = ["bucket_start", "bucket_end", "timezone", "rule", "application_id", "keys", "intervals", "seconds", "squared_interval_seconds"]
    private static let legacySessionColumns = ["id", "start_time", "end_time", "timezone", "rule", "keys", "intervals", "seconds", "squared_interval_seconds", "end_reason"]
    private static let rateColumns = ["rate_sample_count", "rate_interval_count", "rate_sum", "rate_squared_sum"]
    private static let hourlyColumns = legacyHourlyColumns + rateColumns
    private static let sessionColumns = legacySessionColumns + rateColumns
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
    private static let rewardValueColumns = ["time_points", "volume_points", "speed_bonus", "consistency_bonus", "time_xp", "volume_xp", "improvement_xp"]
    private static let createRewards = """
        CREATE TABLE reward_checkpoint (
          id INTEGER NOT NULL PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=1),
          state_json TEXT NOT NULL CHECK(length(state_json)<=2097152),state_hash TEXT NOT NULL);
        CREATE TABLE reward_batches (
          id TEXT NOT NULL PRIMARY KEY,payload_hash TEXT NOT NULL,revision INTEGER,committed_at REAL NOT NULL);
        CREATE TABLE reward_awards (
          id TEXT NOT NULL PRIMARY KEY,batch_id TEXT NOT NULL,revision INTEGER NOT NULL,
          awarded_at REAL NOT NULL,day TEXT NOT NULL,policy TEXT NOT NULL,kind TEXT NOT NULL,award_json TEXT NOT NULL);
        CREATE INDEX reward_awards_date ON reward_awards(awarded_at,id);
        CREATE INDEX reward_awards_day ON reward_awards(day,policy,kind);
        CREATE TABLE reward_claims (
          id TEXT NOT NULL PRIMARY KEY,award_hash TEXT NOT NULL,revision INTEGER NOT NULL);
        CREATE TABLE reward_improvement_claims (
          claim_id TEXT NOT NULL PRIMARY KEY,award_id TEXT NOT NULL,award_hash TEXT NOT NULL,revision INTEGER NOT NULL);
        CREATE TABLE reward_attributions (
          award_id TEXT NOT NULL,ordinal INTEGER NOT NULL,hour REAL NOT NULL,session_id TEXT,attribution_json TEXT NOT NULL,
          PRIMARY KEY(award_id,ordinal));
        CREATE INDEX reward_attributions_hour ON reward_attributions(hour,award_id);
        CREATE INDEX reward_attributions_session ON reward_attributions(session_id,hour);
        CREATE TABLE reward_daily (
          day TEXT NOT NULL PRIMARY KEY,
          time_points REAL NOT NULL CHECK(time_points>=0 AND time_points<=1e15),
          volume_points REAL NOT NULL CHECK(volume_points>=0 AND volume_points<=1e15),
          speed_bonus REAL NOT NULL CHECK(speed_bonus>=0 AND speed_bonus<=1e15),
          consistency_bonus REAL NOT NULL CHECK(consistency_bonus>=0 AND consistency_bonus<=1e15),
          time_xp INTEGER NOT NULL CHECK(typeof(time_xp)='integer' AND time_xp>=0),
          volume_xp INTEGER NOT NULL CHECK(typeof(volume_xp)='integer' AND volume_xp>=0),
          improvement_xp INTEGER NOT NULL CHECK(typeof(improvement_xp)='integer' AND improvement_xp>=0));
        """
    private static let createDailyRewards = """
        CREATE TABLE IF NOT EXISTS daily_reward_checkpoint (
          id INTEGER NOT NULL PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=1),
          state_json TEXT NOT NULL CHECK(length(state_json)<=4194304),state_hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS daily_reward_receipts (
          id TEXT NOT NULL PRIMARY KEY,day TEXT NOT NULL UNIQUE,settled_at REAL NOT NULL,
          receipt_json TEXT NOT NULL CHECK(length(receipt_json)<=65536),receipt_hash TEXT NOT NULL,seen_at REAL);
        CREATE INDEX IF NOT EXISTS daily_reward_receipts_pending ON daily_reward_receipts(seen_at,day,id);
        CREATE TABLE IF NOT EXISTS daily_reward_claims (
          id TEXT NOT NULL PRIMARY KEY,day TEXT NOT NULL UNIQUE,receipt_hash TEXT NOT NULL);
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
            guard version <= 6 else { throw StoreError.unsupportedVersion(version) }
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
    private func validateActivityLayout(includingRateMoments: Bool = true) throws {
        let hourly = try tableLayout("activity_hourly"), sessions = try tableLayout("activity_sessions")
        guard hourly.columns == (includingRateMoments ? Self.hourlyColumns : Self.legacyHourlyColumns),
              hourly.primaryKey == ["bucket_start", "timezone", "rule", "application_id"],
              sessions.columns == (includingRateMoments ? Self.sessionColumns : Self.legacySessionColumns), sessions.primaryKey == ["id"] else {
            throw StoreError.sqlite("活动统计数据库结构不匹配，已保留原有数据。")
        }
    }
    private func addRateMomentColumns() throws {
        // Defaults explicitly mark the absence of historical rate samples.
        // Existing interval moments cannot be converted into these samples.
        for table in ["activity_hourly", "activity_sessions"] {
            try execute("""
                ALTER TABLE \(table) ADD COLUMN rate_sample_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(rate_sample_count)='integer' AND rate_sample_count>=0 AND rate_sample_count<=1e12);
                ALTER TABLE \(table) ADD COLUMN rate_interval_count INTEGER NOT NULL DEFAULT 0 CHECK(typeof(rate_interval_count)='integer' AND rate_interval_count>=0 AND rate_interval_count<=1e12);
                ALTER TABLE \(table) ADD COLUMN rate_sum REAL NOT NULL DEFAULT 0 CHECK(rate_sum>=0 AND rate_sum<=1e15);
                ALTER TABLE \(table) ADD COLUMN rate_squared_sum REAL NOT NULL DEFAULT 0 CHECK(rate_squared_sum>=0 AND rate_squared_sum<=1e18);
                """)
        }
    }
    private func validateRewardLayout() throws {
        let expected: [(String, [String], [String])] = [
            ("reward_checkpoint", ["id", "revision", "state_json", "state_hash"], ["id"]),
            ("reward_batches", ["id", "payload_hash", "revision", "committed_at"], ["id"]),
            ("reward_awards", ["id", "batch_id", "revision", "awarded_at", "day", "policy", "kind", "award_json"], ["id"]),
            ("reward_claims", ["id", "award_hash", "revision"], ["id"]),
            ("reward_improvement_claims", ["claim_id", "award_id", "award_hash", "revision"], ["claim_id"]),
            ("reward_attributions", ["award_id", "ordinal", "hour", "session_id", "attribution_json"], ["award_id", "ordinal"]),
            ("reward_daily", ["day"] + Self.rewardValueColumns, ["day"])
        ]
        for (table, columns, key) in expected {
            let layout = try tableLayout(table)
            guard layout.columns == columns, layout.primaryKey == key else {
                throw StoreError.sqlite("奖励数据库结构不匹配，已保留原有数据。")
            }
        }
    }
    private func validateDailyRewardLayout() throws {
        let expected: [(String, [String], [String])] = [
            ("daily_reward_checkpoint", ["id", "revision", "state_json", "state_hash"], ["id"]),
            ("daily_reward_receipts", ["id", "day", "settled_at", "receipt_json", "receipt_hash", "seen_at"], ["id"]),
            ("daily_reward_claims", ["id", "day", "receipt_hash"], ["id"])
        ]
        for (table, columns, key) in expected {
            let layout = try tableLayout(table)
            guard layout.columns == columns, layout.primaryKey == key else {
                throw StoreError.sqlite("每日结算数据库结构不匹配，已保留原有数据。")
            }
        }
    }
    /// The table rebuild and version update commit together; failure leaves v1 intact.
    private func prepareSchema() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try schemaVersion(), layout = try tableLayout("daily")
            guard version <= 6 else { throw StoreError.unsupportedVersion(version) }
            let legacyKey = ["day", "timezone", "rule", "evidence"]
            if version == 0 && layout.columns.isEmpty {
                try execute(Self.createDaily)
            } else if (version == 0 || version == 1) && layout.columns == Self.legacyColumns && layout.primaryKey == legacyKey {
                try execute("ALTER TABLE daily RENAME TO keytempo_daily_v1_migration")
                try execute(Self.createDaily)
                let legacy = Self.legacyColumns.joined(separator: ",")
                try execute("INSERT INTO daily (\(Self.columns.joined(separator: ","))) SELECT \(legacy),'und',0,0,0,0 FROM keytempo_daily_v1_migration")
                try execute("DROP TABLE keytempo_daily_v1_migration")
            } else if !(2...6).contains(version) || layout.columns != Self.columns || layout.primaryKey != legacyKey + ["language"] {
                throw StoreError.sqlite("统计数据库结构与版本 \(version) 不匹配，已保留原有数据。")
            }
            if version < 3 { try execute(Self.createActivity) }
            if version < 4 {
                try validateActivityLayout(includingRateMoments: false)
                try addRateMomentColumns()
            }
            try validateActivityLayout()
            if version < 5 { try execute(Self.createRewards) }
            try validateRewardLayout()
            if version < 6 { try execute(Self.createDailyRewards) }
            try validateDailyRewardLayout()
            try execute("CREATE INDEX IF NOT EXISTS daily_range ON daily(day); PRAGMA user_version=6; COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func save(_ rows: [StoredAggregate], activity: ActivityBatch = .init(), progression: RewardWrite? = nil,
                     dailyRewards: DailyRewardWrite? = nil, batchID: String? = nil) throws {
        guard !rows.isEmpty || !activity.isEmpty || progression != nil || dailyRewards != nil || batchID != nil else { return }
        guard (progression == nil && dailyRewards == nil) || batchID != nil else { throw StoreError.sqlite("奖励检查点缺少稳定批次标识。") }
        if let batchID { try validateIdentifier(batchID) }
        let fingerprint = try batchID.map { _ in try batchFingerprint(rows: rows, activity: activity, progression: progression, dailyRewards: dailyRewards) }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if let batchID, let fingerprint, try committedBatch(batchID, fingerprint: fingerprint) {
                try execute("COMMIT"); return
            }
            let rewardSave = try progression.map { try prepareRewardSave($0) }
            let dailyRewardSave = try dailyRewards.map { try prepareDailyRewardSave($0) }
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
            if let progression, let rewardSave, let batchID { try saveRewards(progression, prepared: rewardSave, batchID: batchID) }
            if let dailyRewards, let dailyRewardSave { try saveDailyRewards(dailyRewards, prepared: dailyRewardSave) }
            if let batchID, let fingerprint { try saveBatchReceipt(batchID, fingerprint: fingerprint, revision: progression?.state.revision ?? dailyRewards?.state.revision) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private struct BatchPayload: Encodable {
        let rows: [StoredAggregate]
        let activity: ActivityBatch
        let progression: RewardWrite?
        let dailyRewards: DailyRewardWrite?
    }
    private struct PreparedRewardSave {
        let stateJSON: String
        let newAwards: [(RewardAward, String)]
    }
    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else { throw StoreError.sqlite("无法编码本地统计。") }
        return json
    }
    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func batchFingerprint(rows: [StoredAggregate], activity: ActivityBatch, progression: RewardWrite?, dailyRewards: DailyRewardWrite?) throws -> String {
        let ordered = ActivityBatch(hourly: activity.hourly.sorted { $0.id < $1.id }, sessions: activity.sessions.sorted { $0.id < $1.id })
        return digest(try encodedJSON(BatchPayload(rows: rows.sorted { $0.id < $1.id }, activity: ordered, progression: progression, dailyRewards: dailyRewards)))
    }
    private func validateIdentifier(_ value: String, maximum: Int = 255) throws {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StoreError.sqlite("奖励标识无效，未保存本次事务。")
        }
    }
    private func validateRewardDay(_ day: String) throws {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else {
            throw StoreError.sqlite("奖励日期无效，未保存本次事务。")
        }
    }
    private func committedBatch(_ id: String, fingerprint: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload_hash FROM reward_batches WHERE id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { throw failure() }
        guard String(cString: sqlite3_column_text(statement, 0)) == fingerprint else {
            throw StoreError.sqlite("同一统计批次不能使用不同内容，已保留原有数据。")
        }
        return true
    }
    private func saveBatchReceipt(_ id: String, fingerprint: String, revision: Int64?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO reward_batches(id,payload_hash,revision,committed_at) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, statement: statement); bind(fingerprint, at: 2, statement: statement)
        if let revision { sqlite3_bind_int64(statement, 3, revision) } else { sqlite3_bind_null(statement, 3) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func componentValues(_ components: RewardComponents) -> [Double] {
        [components.time, components.volume, components.speedBonus, components.consistencyBonus]
    }
    private func xpValues(_ xp: RewardXP) -> [Int] { [xp.time, xp.volume, xp.improvement] }
    private func validateRewardValues(_ components: RewardComponents, _ xp: RewardXP) throws {
        guard componentValues(components).allSatisfy({ $0.isFinite && (0...1e15).contains($0) }),
              xpValues(xp).allSatisfy({ $0 >= 0 }) else { throw StoreError.sqlite("奖励金额或经验值无效，未保存本次事务。") }
        let first = xp.time.addingReportingOverflow(xp.volume)
        let total = first.partialValue.addingReportingOverflow(xp.improvement)
        guard !first.overflow, !total.overflow else { throw StoreError.sqlite("经验值超出范围，未保存本次事务。") }
    }
    private func closeEnough(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= max(1, max(abs(lhs), abs(rhs))) * 1e-10
    }
    private func awardClaim(_ id: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT award_hash FROM reward_claims WHERE id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return String(cString: sqlite3_column_text(statement, 0))
    }
    private func improvementClaimOwner(_ id: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT award_id FROM reward_improvement_claims WHERE claim_id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }; guard result == SQLITE_ROW else { throw failure() }
        return String(cString: sqlite3_column_text(statement, 0))
    }
    private func prepareRewardSave(_ write: RewardWrite) throws -> PreparedRewardSave {
        let state = write.state
        guard state.isValid, state.coverageStart.timeIntervalSince1970.isFinite, state.revision >= 1,
              write.awards.count <= 8192, TimeZone(identifier: state.progressionTimezone) != nil else {
            throw StoreError.sqlite("奖励检查点无效，未保存本次事务。")
        }
        let previous = try readRewardState()
        let next = (previous?.revision ?? 0).addingReportingOverflow(1)
        guard !next.overflow, state.revision == next.partialValue else {
            throw StoreError.sqlite("奖励检查点版本不连续，未保存本次事务。")
        }
        if let previous {
            guard previous.coverageStart == state.coverageStart, previous.progressionTimezone == state.progressionTimezone,
                  previous.lineage == state.lineage, previous.scorePolicy == state.scorePolicy,
                  state.currentDay >= previous.currentDay, state.nextAward >= previous.nextAward, state.nextBlock >= previous.nextBlock,
                  state.xpProgress.eligibleKeys >= previous.xpProgress.eligibleKeys,
                  state.xpProgress.eligibleSeconds >= previous.xpProgress.eligibleSeconds else {
                throw StoreError.sqlite("奖励覆盖范围或累计输入不能回退，未保存本次事务。")
            }
            for (day, old) in previous.days {
                guard let newer = state.days[day] else { continue }
                guard newer.keys >= old.keys, newer.seconds >= old.seconds,
                      zip(componentValues(newer.components), componentValues(old.components)).allSatisfy({ $0.0 >= $0.1 }),
                      zip(xpValues(newer.xp), xpValues(old.xp)).allSatisfy({ $0.0 >= $0.1 }), !old.completed || newer.completed else {
                    throw StoreError.sqlite("每日奖励预算不能重置，未保存本次事务。")
                }
            }
            for (id, old) in previous.improvement.tracks {
                guard let newer = state.improvement.tracks[id], newer.context == old.context,
                      newer.speedMilestone >= old.speedMilestone, newer.consistencyMilestone >= old.consistencyMilestone,
                      !old.suspended || newer.suspended,
                      old.speedBaseline == nil || (newer.speedBaseline == old.speedBaseline && newer.speedBaselineDay == old.speedBaselineDay),
                      old.consistencyBaseline == nil || (newer.consistencyBaseline == old.consistencyBaseline && newer.consistencyBaselineDay == old.consistencyBaselineDay) else {
                    throw StoreError.sqlite("进步基线或已领取里程碑不能重置，未保存本次事务。")
                }
            }
        }
        let stateJSON = try encodedJSON(state)
        guard stateJSON.utf8.count <= 2_097_152 else { throw StoreError.sqlite("奖励检查点超过容量，未保存本次事务。") }
        var points = [Double](repeating: 0, count: 4), xp = [Int](repeating: 0, count: 3)
        var newAwards: [(RewardAward, String)] = [], seen: [String: String] = [:], seenClaims = Set<String>()
        var attributionCount = 0
        for award in write.awards {
            try validateIdentifier(award.id); try validateIdentifier(award.policy); try validateIdentifier(award.kind)
            try validateRewardDay(award.day); try validateRewardValues(award.components, award.xpSources)
            if let blockID = award.blockID { try validateIdentifier(blockID) }
            if let claimID = award.claimID { try validateIdentifier(claimID, maximum: 1024) }
            guard award.date.timeIntervalSince1970.isFinite, award.attributions.count <= 512 else {
                throw StoreError.sqlite("奖励归属信息无效，未保存本次事务。")
            }
            attributionCount += award.attributions.count
            guard attributionCount <= 65_536 else { throw StoreError.sqlite("奖励批次超过容量，未保存本次事务。") }
            var attributedPoints = [Double](repeating: 0, count: 4), attributedXP = [Int](repeating: 0, count: 3)
            for attribution in award.attributions {
                try validateRewardDay(attribution.day); try validateRewardValues(attribution.components, attribution.xp)
                guard attribution.hour.timeIntervalSince1970.isFinite else { throw StoreError.sqlite("奖励时间归属无效。") }
                if let sessionID = attribution.sessionID { try validateIdentifier(sessionID) }
                for (index, value) in componentValues(attribution.components).enumerated() { attributedPoints[index] += value }
                for (index, value) in xpValues(attribution.xp).enumerated() {
                    let sum = attributedXP[index].addingReportingOverflow(value)
                    guard !sum.overflow else { throw StoreError.sqlite("经验值归属超出范围。") }
                    attributedXP[index] = sum.partialValue
                }
            }
            guard zip(attributedPoints, componentValues(award.components)).allSatisfy({ closeEnough($0.0, $0.1) }),
                  attributedXP == xpValues(award.xpSources) else { throw StoreError.sqlite("奖励归属与总额不一致，未保存本次事务。") }
            let json = try encodedJSON(award), hash = digest(json)
            let priorClaim = try awardClaim(award.id)
            if let prior = seen[award.id] ?? priorClaim {
                guard prior == hash else { throw StoreError.sqlite("奖励标识已用于不同内容，未保存本次事务。") }
                continue
            }
            if let claimID = award.claimID {
                guard seenClaims.insert(claimID).inserted, try improvementClaimOwner(claimID) == nil else {
                    throw StoreError.sqlite("此进步里程碑已领取，未保存本次事务。")
                }
            }
            seen[award.id] = hash; newAwards.append((award, json))
            for (index, value) in componentValues(award.components).enumerated() { points[index] += value }
            for (index, value) in xpValues(award.xpSources).enumerated() {
                let sum = xp[index].addingReportingOverflow(value)
                guard !sum.overflow else { throw StoreError.sqlite("经验值批次超出范围。") }; xp[index] = sum.partialValue
            }
        }
        let previousPoints = previous.map { componentValues($0.lifetimeScore) } ?? [Double](repeating: 0, count: 4)
        let currentPoints = componentValues(state.lifetimeScore)
        let previousXP = previous.map { [$0.xpProgress.timeXP, $0.xpProgress.volumeXP, $0.xpProgress.improvementXP] } ?? [0, 0, 0]
        let currentXP = [state.xpProgress.timeXP, state.xpProgress.volumeXP, state.xpProgress.improvementXP]
        for index in 0..<4 {
            guard currentPoints[index] >= previousPoints[index], closeEnough(previousPoints[index] + points[index], currentPoints[index]) else {
                throw StoreError.sqlite("奖励总额与新增明细不一致，未保存本次事务。")
            }
        }
        for index in 0..<3 {
            let total = previousXP[index].addingReportingOverflow(xp[index])
            guard !total.overflow, total.partialValue == currentXP[index] else { throw StoreError.sqlite("经验值总额与新增明细不一致。") }
        }
        return PreparedRewardSave(stateJSON: stateJSON, newAwards: newAwards)
    }
    private func saveRewards(_ write: RewardWrite, prepared: PreparedRewardSave, batchID: String) throws {
        let dailySQL = """
            INSERT INTO reward_daily(day,\(Self.rewardValueColumns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(day) DO UPDATE SET time_points=time_points+excluded.time_points,volume_points=volume_points+excluded.volume_points,
            speed_bonus=speed_bonus+excluded.speed_bonus,consistency_bonus=consistency_bonus+excluded.consistency_bonus,
            time_xp=time_xp+excluded.time_xp,volume_xp=volume_xp+excluded.volume_xp,improvement_xp=improvement_xp+excluded.improvement_xp
            """
        for (award, json) in prepared.newAwards {
            var ledger: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO reward_awards(id,batch_id,revision,awarded_at,day,policy,kind,award_json) VALUES(?,?,?,?,?,?,?,?)", -1, &ledger, nil) == SQLITE_OK,
                  let ledger else { throw failure() }
            defer { sqlite3_finalize(ledger) }
            bind(award.id, at: 1, statement: ledger); bind(batchID, at: 2, statement: ledger)
            sqlite3_bind_int64(ledger, 3, write.state.revision); sqlite3_bind_double(ledger, 4, award.date.timeIntervalSince1970)
            bind(award.day, at: 5, statement: ledger); bind(award.policy, at: 6, statement: ledger)
            bind(award.kind, at: 7, statement: ledger); bind(json, at: 8, statement: ledger)
            guard sqlite3_step(ledger) == SQLITE_DONE else { throw failure() }
            var claim: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO reward_claims(id,award_hash,revision) VALUES(?,?,?)", -1, &claim, nil) == SQLITE_OK,
                  let claim else { throw failure() }
            defer { sqlite3_finalize(claim) }
            bind(award.id, at: 1, statement: claim); bind(digest(json), at: 2, statement: claim); sqlite3_bind_int64(claim, 3, write.state.revision)
            guard sqlite3_step(claim) == SQLITE_DONE else { throw failure() }
            if let claimID = award.claimID {
                var improvement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO reward_improvement_claims(claim_id,award_id,award_hash,revision) VALUES(?,?,?,?)", -1, &improvement, nil) == SQLITE_OK,
                      let improvement else { throw failure() }
                defer { sqlite3_finalize(improvement) }
                bind(claimID, at: 1, statement: improvement); bind(award.id, at: 2, statement: improvement)
                bind(digest(json), at: 3, statement: improvement); sqlite3_bind_int64(improvement, 4, write.state.revision)
                guard sqlite3_step(improvement) == SQLITE_DONE else { throw failure() }
            }
            var daily: OpaquePointer?
            guard sqlite3_prepare_v2(db, dailySQL, -1, &daily, nil) == SQLITE_OK, let daily else { throw failure() }
            defer { sqlite3_finalize(daily) }
            bind(award.day, at: 1, statement: daily)
            for (index, value) in componentValues(award.components).enumerated() { sqlite3_bind_double(daily, Int32(index + 2), value) }
            for (index, value) in xpValues(award.xpSources).enumerated() { sqlite3_bind_int64(daily, Int32(index + 6), Int64(value)) }
            guard sqlite3_step(daily) == SQLITE_DONE else { throw failure() }
            for (ordinal, attribution) in award.attributions.enumerated() {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO reward_attributions(award_id,ordinal,hour,session_id,attribution_json) VALUES(?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw failure() }
                defer { sqlite3_finalize(statement) }
                bind(award.id, at: 1, statement: statement); sqlite3_bind_int64(statement, 2, Int64(ordinal))
                sqlite3_bind_double(statement, 3, attribution.hour.timeIntervalSince1970)
                if let id = attribution.sessionID { bind(id, at: 4, statement: statement) } else { sqlite3_bind_null(statement, 4) }
                bind(try encodedJSON(attribution), at: 5, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
        }
        var checkpoint: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO reward_checkpoint(id,revision,state_json,state_hash) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,state_json=excluded.state_json,state_hash=excluded.state_hash", -1, &checkpoint, nil) == SQLITE_OK,
              let checkpoint else { throw failure() }
        defer { sqlite3_finalize(checkpoint) }
        sqlite3_bind_int64(checkpoint, 1, write.state.revision); bind(prepared.stateJSON, at: 2, statement: checkpoint)
        bind(digest(prepared.stateJSON), at: 3, statement: checkpoint)
        guard sqlite3_step(checkpoint) == SQLITE_DONE else { throw failure() }
    }
    private func readRewardState() throws -> RewardState? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT revision,state_json,state_hash FROM reward_checkpoint WHERE id=1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        let json = String(cString: sqlite3_column_text(statement, 1))
        guard json.utf8.count <= 2_097_152, digest(json) == String(cString: sqlite3_column_text(statement, 2)),
              let data = json.data(using: .utf8) else { throw StoreError.sqlite("奖励检查点校验失败，已保留原有数据。") }
        let state = try JSONDecoder().decode(RewardState.self, from: data)
        guard state.isValid, state.revision == sqlite3_column_int64(statement, 0) else { throw StoreError.sqlite("奖励检查点已损坏，已保留原有数据。") }
        return state
    }
    public func loadRewardState() throws -> RewardState? {
        lock.lock(); defer { lock.unlock() }
        return try readRewardState()
    }

    // The daily score is a provisional performance index, not an earned
    // balance. Only immutable settlement receipts advance this checkpoint's
    // XP. Presentation acknowledgements live in a separate column and never
    // mutate either the checkpoint or its receipt payload.
    private struct PreparedDailyRewardSave {
        let stateJSON: String
        let receipts: [(DailySettlementReceipt, String, String)]
    }
    private func readDailyRewardState() throws -> DailyRewardState? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT revision,state_json,state_hash FROM daily_reward_checkpoint WHERE id=1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        let json = String(cString: sqlite3_column_text(statement, 1))
        guard json.utf8.count <= 4_194_304, digest(json) == String(cString: sqlite3_column_text(statement, 2)) else {
            throw StoreError.sqlite("每日结算检查点校验失败，已保留原有数据。")
        }
        let state = try JSONDecoder().decode(DailyRewardState.self, from: Data(json.utf8))
        guard state.isValid, state.revision == sqlite3_column_int64(statement, 0), state.revision >= 1 else {
            throw StoreError.sqlite("每日结算检查点无效，已保留原有数据。")
        }
        return state
    }
    public func loadDailyRewardState() throws -> DailyRewardState? {
        lock.lock(); defer { lock.unlock() }
        return try readDailyRewardState()
    }
    private func dailyRewardClaim(id: String) throws -> (day: String, hash: String)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT day,receipt_hash FROM daily_reward_claims WHERE id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; bind(id, at: 1, statement: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return (String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1)))
    }
    private func prepareDailyRewardSave(_ write: DailyRewardWrite) throws -> PreparedDailyRewardSave {
        let state = write.state
        guard state.isValid, state.revision >= 1, write.receipts.count <= 8192 else {
            throw StoreError.sqlite("每日结算检查点无效，未保存本次事务。")
        }
        let previous = try readDailyRewardState()
        let revision = (previous?.revision ?? 0).addingReportingOverflow(1)
        guard !revision.overflow, state.revision == revision.partialValue else {
            throw StoreError.sqlite("每日结算检查点版本不连续，未保存本次事务。")
        }
        if let previous {
            guard state.coverageStart == previous.coverageStart, state.lineage == previous.lineage,
                  state.progressionTimezone == previous.progressionTimezone,
                  state.migratedLegacyXP == previous.migratedLegacyXP,
                  state.currentDay >= previous.currentDay, state.totalXP >= previous.totalXP,
                  state.observedLegacyImprovementXP >= previous.observedLegacyImprovementXP,
                  previous.settledThroughDay == nil || (state.settledThroughDay != nil && state.settledThroughDay! >= previous.settledThroughDay!) else {
                throw StoreError.sqlite("每日结算覆盖范围或已入账经验值不能回退，未保存本次事务。")
            }
            for (day, old) in previous.days {
                guard let newer = state.days[day] else {
                    guard state.settledThroughDay.map({ day <= $0 }) == true else {
                        throw StoreError.sqlite("待结算的输入日期不能丢弃，未保存本次事务。")
                    }
                    continue
                }
                guard newer.totals.keys >= old.totals.keys, newer.totals.seconds >= old.totals.seconds,
                      newer.totals.intervals >= old.totals.intervals,
                      newer.totals.squaredIntervalSeconds >= old.totals.squaredIntervalSeconds,
                      newer.totals.rateConsistency.count >= old.totals.rateConsistency.count,
                      newer.totals.rateConsistency.intervals >= old.totals.rateConsistency.intervals,
                      newer.totals.rateConsistency.sum >= old.totals.rateConsistency.sum,
                      newer.totals.rateConsistency.squaredSum >= old.totals.rateConsistency.squaredSum,
                      !old.sealed || newer.sealed, !old.mixedRules || newer.mixedRules else {
                    throw StoreError.sqlite("每日输入证据不能回退或重新开启已结束日期，未保存本次事务。")
                }
            }
        }
        let stateJSON = try encodedJSON(state)
        guard stateJSON.utf8.count <= 4_194_304 else { throw StoreError.sqlite("每日结算检查点超过容量。") }
        var receipts: [(DailySettlementReceipt, String, String)] = []
        var seen: [String: String] = [:], seenDays = Set<String>()
        for receipt in write.receipts.sorted(by: { ($0.day, $0.id) < ($1.day, $1.id) }) {
            try validateIdentifier(receipt.id); try validateRewardDay(receipt.day)
            guard receipt.isValid, receipt.day < state.currentDay else {
                throw StoreError.sqlite("每日结算凭据无效，未保存本次事务。")
            }
            let json = try encodedJSON(receipt), hash = digest(json)
            guard json.utf8.count <= 65_536 else { throw StoreError.sqlite("每日结算凭据超过容量。") }
            if let prior = seen[receipt.id] {
                guard prior == hash else { throw StoreError.sqlite("每日结算标识已用于不同内容。") }
                continue
            }
            seen[receipt.id] = hash
            if let prior = try dailyRewardClaim(id: receipt.id) {
                guard prior.day == receipt.day, prior.hash == hash else { throw StoreError.sqlite("每日结算标识已用于不同内容。") }
                continue
            }
            guard seenDays.insert(receipt.day).inserted,
                  previous?.settledThroughDay == nil || receipt.day > previous!.settledThroughDay!,
                  state.settledThroughDay != nil && receipt.day <= state.settledThroughDay! else {
                throw StoreError.sqlite("同一日期不能重复结算，未保存本次事务。")
            }
            receipts.append((receipt, json, hash))
        }
        var balance = previous?.totalXP ?? state.migratedLegacyXP
        for (receipt, _, _) in receipts {
            let award = receipt.ordinaryXP.addingReportingOverflow(receipt.improvementXP)
            let after = balance.addingReportingOverflow(award.partialValue)
            guard !award.overflow, !after.overflow, receipt.beforeXP == balance, receipt.afterXP == after.partialValue else {
                throw StoreError.sqlite("结算凭据与累计经验值不一致，未保存本次事务。")
            }
            balance = after.partialValue
        }
        guard balance == state.totalXP else {
            throw StoreError.sqlite("已入账经验值必须对应唯一的结算凭据，未保存本次事务。")
        }
        if let previous {
            var awardedImprovement = 0
            for (receipt, _, _) in receipts {
                let sum = awardedImprovement.addingReportingOverflow(receipt.improvementXP)
                guard !sum.overflow else { throw StoreError.sqlite("进步奖励超出范围。") }
                awardedImprovement = sum.partialValue
            }
            let newlyObserved = (state.observedLegacyImprovementXP - previous.observedLegacyImprovementXP)
                .multipliedReportingOverflow(by: DailyRewardPolicy.legacyScale)
            let expected = previous.pendingImprovementXP.addingReportingOverflow(newlyObserved.partialValue)
            let actual = state.pendingImprovementXP.addingReportingOverflow(awardedImprovement)
            guard !newlyObserved.overflow, !expected.overflow, !actual.overflow, actual.partialValue == expected.partialValue else {
                throw StoreError.sqlite("进步奖励必须对应已验证的新增里程碑，未保存本次事务。")
            }
        }
        return PreparedDailyRewardSave(stateJSON: stateJSON, receipts: receipts)
    }
    private func saveDailyRewards(_ write: DailyRewardWrite, prepared: PreparedDailyRewardSave) throws {
        for (receipt, json, hash) in prepared.receipts {
            var claim: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO daily_reward_claims(id,day,receipt_hash) VALUES(?,?,?)", -1, &claim, nil) == SQLITE_OK,
                  let claim else { throw failure() }
            defer { sqlite3_finalize(claim) }
            bind(receipt.id, at: 1, statement: claim); bind(receipt.day, at: 2, statement: claim); bind(hash, at: 3, statement: claim)
            guard sqlite3_step(claim) == SQLITE_DONE else { throw failure() }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO daily_reward_receipts(id,day,settled_at,receipt_json,receipt_hash,seen_at) VALUES(?,?,?,?,?,NULL)", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure() }
            defer { sqlite3_finalize(statement) }
            bind(receipt.id, at: 1, statement: statement); bind(receipt.day, at: 2, statement: statement)
            sqlite3_bind_double(statement, 3, receipt.settledAt.timeIntervalSince1970)
            bind(json, at: 4, statement: statement); bind(hash, at: 5, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO daily_reward_checkpoint(id,revision,state_json,state_hash) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,state_json=excluded.state_json,state_hash=excluded.state_hash", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, write.state.revision)
        bind(prepared.stateJSON, at: 2, statement: statement); bind(digest(prepared.stateJSON), at: 3, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func dailyRewardReceipts(since: String, until: String, unseenOnly: Bool, limit: Int) throws -> [DailySettlementReceipt] {
        guard (1...5000).contains(limit) else { throw StoreError.resultLimit(5000) }
        var statement: OpaquePointer?
        let sql = "SELECT receipt_json,receipt_hash FROM daily_reward_receipts WHERE day>=? AND day<=?\(unseenOnly ? " AND seen_at IS NULL" : "") ORDER BY day,id LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(since, at: 1, statement: statement); bind(until, at: 2, statement: statement); sqlite3_bind_int64(statement, 3, Int64(unseenOnly ? limit : limit + 1))
        var rows: [DailySettlementReceipt] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure() }
            let json = String(cString: sqlite3_column_text(statement, 0))
            guard json.utf8.count <= 65_536, digest(json) == String(cString: sqlite3_column_text(statement, 1)) else {
                throw StoreError.sqlite("每日结算凭据校验失败，已保留原有数据。")
            }
            let receipt = try JSONDecoder().decode(DailySettlementReceipt.self, from: Data(json.utf8))
            guard receipt.isValid else { throw StoreError.sqlite("每日结算凭据无效，已保留原有数据。") }
            rows.append(receipt)
            if rows.count > limit { throw StoreError.resultLimit(limit) }
        }
        return rows
    }
    /// Oldest first, with a bounded page. Opening or querying does not mark a
    /// receipt seen, so interrupted animations remain available on relaunch.
    public func queryUnseenDailyRewardReceipts(limit: Int = 10) throws -> [DailySettlementReceipt] {
        lock.lock(); defer { lock.unlock() }
        return try dailyRewardReceipts(since: "0000-01-01", until: "9999-12-31", unseenOnly: true, limit: limit)
    }
    public func queryDailyRewardReceipts(since: String, until: String = "9999-12-31", limit: Int = 5000) throws -> [DailySettlementReceipt] {
        try validateRewardDay(since); try validateRewardDay(until)
        lock.lock(); defer { lock.unlock() }
        return try dailyRewardReceipts(since: since, until: until, unseenOnly: false, limit: limit)
    }
    public func dailyRewardReceiptCount(unseenOnly: Bool = true) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM daily_reward_receipts\(unseenOnly ? " WHERE seen_at IS NULL" : "")", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    public func acknowledgeDailyRewardReceipt(id: String) throws {
        try validateIdentifier(id)
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try dailyRewardClaim(id: id) != nil else { throw StoreError.sqlite("未找到需要确认的每日结算凭据。") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE daily_reward_receipts SET seen_at=COALESCE(seen_at,?) WHERE id=?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970); bind(id, at: 2, statement: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func acknowledgeAllDailyRewardReceipts() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE daily_reward_receipts SET seen_at=? WHERE seen_at IS NULL", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func exportDailyRewardCSV(since: String = "0000-01-01", until: String = "9999-12-31") throws -> String {
        try validateRewardDay(since); try validateRewardDay(until)
        lock.lock(); defer { lock.unlock() }
        let rows = try dailyRewardReceipts(since: since, until: until, unseenOnly: false, limit: 5000)
        let zone = try readDailyRewardState()?.progressionTimezone ?? ""
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "day,progression_timezone,policy,score,ordinary_xp,improvement_xp,before_xp,after_xp,settled_at,level_before,level_after,keys,seconds,observed_intervals,estimated_wpm,consistency\n"
        var lines: [String] = []
        for receipt in rows {
            var fields: [String] = [quote(receipt.day), quote(zone), quote(receipt.policy)]
            fields.append(receipt.score.map { String($0) } ?? "")
            fields += [String(receipt.ordinaryXP), String(receipt.improvementXP), String(receipt.beforeXP), String(receipt.afterXP)]
            fields += [quote(formatter.string(from: receipt.settledAt)), String(receipt.levelBefore), String(receipt.levelAfter)]
            fields += [String(receipt.totals.keys), String(receipt.totals.seconds), String(receipt.totals.intervals)]
            fields.append(receipt.totals.wpm.map { String($0) } ?? "")
            fields.append(receipt.totals.consistency.map { String($0) } ?? "")
            lines.append(fields.joined(separator: ","))
        }
        return header + lines.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
    private func rewardAwards(since: Date? = nil, until: Date? = nil, day: String? = nil, source: String? = nil, limit: Int) throws -> [RewardAward] {
        var clauses: [String] = []
        if since != nil { clauses.append("awarded_at>=?") }; if until != nil { clauses.append("awarded_at<?") }
        if day != nil { clauses.append("day=?") }; if source != nil { clauses.append("kind=?") }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT award_json FROM reward_awards\(filter) ORDER BY awarded_at,id LIMIT \(limit + 1)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let since { sqlite3_bind_double(statement, index, since.timeIntervalSince1970); index += 1 }
        if let until { sqlite3_bind_double(statement, index, until.timeIntervalSince1970); index += 1 }
        if let day { bind(day, at: index, statement: statement); index += 1 }
        if let source { bind(source, at: index, statement: statement) }
        var rows: [RewardAward] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw failure() }
            let json = String(cString: sqlite3_column_text(statement, 0))
            guard let data = json.data(using: .utf8) else { throw StoreError.sqlite("奖励明细编码无效。") }
            rows.append(try JSONDecoder().decode(RewardAward.self, from: data))
            if rows.count > limit { throw StoreError.resultLimit(limit) }
        }
        return rows
    }
    /// Earned-at range is half-open. Bonuses attributed to an earlier scoring
    /// day remain inspectable through the separate day-key query.
    public func queryRewardAwards(since: Date, until: Date, source: String? = nil) throws -> [RewardAward] {
        try validateRange(since, until)
        lock.lock(); defer { lock.unlock() }
        return try rewardAwards(since: since, until: until, source: source, limit: 5000)
    }
    public func queryRewardAwards(day: String) throws -> [RewardAward] {
        try validateRewardDay(day)
        lock.lock(); defer { lock.unlock() }
        return try rewardAwards(day: day, limit: 5000)
    }
    /// Attribution uses observed activity hours, independently of the scoring
    /// day or the later date on which a block's quality bonus settled.
    public func queryRewardAwards(attributedSince: Date, until: Date) throws -> [RewardAward] {
        try validateRange(attributedSince, until)
        lock.lock(); defer { lock.unlock() }
        let sql = """
            SELECT awards.award_json FROM reward_awards AS awards
            JOIN (SELECT DISTINCT award_id FROM reward_attributions WHERE hour>=? AND hour<?) AS attribution
              ON attribution.award_id=awards.id
            ORDER BY awards.awarded_at,awards.id LIMIT 5001
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, attributedSince.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        var rows: [RewardAward] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw failure() }
            let json = String(cString: sqlite3_column_text(statement, 0))
            guard let data = json.data(using: .utf8) else { throw StoreError.sqlite("奖励明细编码无效。") }
            rows.append(try JSONDecoder().decode(RewardAward.self, from: data))
            if rows.count > 5000 { throw StoreError.resultLimit(5000) }
        }
        return rows
    }
    private func rewardDays(since: String, until: String) throws -> [StoredRewardDay] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT day,\(Self.rewardValueColumns.joined(separator: ",")) FROM reward_daily WHERE day>=? AND day<=? ORDER BY day LIMIT 50001", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; bind(since, at: 1, statement: statement); bind(until, at: 2, statement: statement)
        var rows: [StoredRewardDay] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw failure() }
            let components = RewardComponents(time: sqlite3_column_double(statement, 1), volume: sqlite3_column_double(statement, 2),
                                              speedBonus: sqlite3_column_double(statement, 3), consistencyBonus: sqlite3_column_double(statement, 4))
            let xp = RewardXP(time: Int(sqlite3_column_int64(statement, 5)), volume: Int(sqlite3_column_int64(statement, 6)), improvement: Int(sqlite3_column_int64(statement, 7)))
            try validateRewardValues(components, xp)
            rows.append(StoredRewardDay(day: String(cString: sqlite3_column_text(statement, 0)), components: components, xp: xp))
            if rows.count > 50000 { throw StoreError.resultLimit(50000) }
        }
        return rows
    }
    /// Inclusive stable scoring-day keys; neither history pruning nor an OS
    /// timezone change resets these earned daily contributions.
    public func queryRewardDays(since: String, until: String = "9999-12-31") throws -> [StoredRewardDay] {
        lock.lock(); defer { lock.unlock() }
        guard since <= until else { throw StoreError.sqlite("奖励查询日期范围无效。") }
        return try rewardDays(since: since, until: until)
    }
    public func queryRewardAttributions(since: Date, until: Date, sessionID: String? = nil) throws -> [RewardAttribution] {
        try validateRange(since, until)
        lock.lock(); defer { lock.unlock() }
        let sessionFilter = sessionID == nil ? "" : " AND session_id=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT attribution_json FROM reward_attributions WHERE hour>=? AND hour<?\(sessionFilter) ORDER BY hour,award_id,ordinal LIMIT 5001", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970); sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        if let sessionID { bind(sessionID, at: 3, statement: statement) }
        var rows: [RewardAttribution] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw failure() }
            let json = String(cString: sqlite3_column_text(statement, 0))
            guard let data = json.data(using: .utf8) else { throw StoreError.sqlite("奖励归属编码无效。") }
            rows.append(try JSONDecoder().decode(RewardAttribution.self, from: data))
            if rows.count > 5000 { throw StoreError.resultLimit(5000) }
        }
        return rows
    }
    /// Separate from the legacy activity CSV. Lifetime/checkpoint metadata and
    /// permanent day totals remain exportable after detailed history expires.
    public func exportRewardCSV(since: Date = .distantPast, until: Date = .distantFuture) throws -> String {
        try validateRange(since, until)
        lock.lock(); defer { lock.unlock() }
        let state = try readRewardState()
        let awards = try rewardAwards(since: since, until: until, limit: 200000)
        let days = try rewardDays(since: "0000-01-01", until: "9999-12-31")
        let formatter = ISO8601DateFormatter()
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func values(_ components: RewardComponents, _ xp: RewardXP) -> [String] {
            componentValues(components).map { String($0) } + xpValues(xp).map { String($0) }
        }
        let coverage = state.map { formatter.string(from: $0.coverageStart) } ?? ""
        let zone = state?.progressionTimezone ?? "", revision = state.map { String($0.revision) } ?? ""
        var output = "record_type,award_id,claim_id,date,day,policy,kind,time_points,volume_points,speed_bonus,consistency_bonus,time_xp,volume_xp,improvement_xp,hour,session_id,coverage_start,progression_timezone,checkpoint_revision\n"
        func append(_ cells: [String]) { output += cells.map(quoted).joined(separator: ",") + "\n" }
        if let state {
            append(["lifetime", "", "", "", "", "score-v2;xp-v1;improvement-v1;levels-v1", ""] +
                   values(state.lifetimeScore, RewardXP(time: state.xpProgress.timeXP, volume: state.xpProgress.volumeXP, improvement: state.xpProgress.improvementXP)) +
                   ["", "", coverage, zone, revision])
        }
        for row in days { append(["day", "", "", "", row.day, "", ""] + values(row.components, row.xp) + ["", "", coverage, zone, revision]) }
        for award in awards {
            append(["award", award.id, award.claimID ?? "", formatter.string(from: award.date), award.day, award.policy, award.kind] + values(award.components, award.xpSources) + ["", "", coverage, zone, revision])
            for attribution in award.attributions {
                append(["attribution", award.id, award.claimID ?? "", formatter.string(from: award.date), attribution.day, award.policy, award.kind] + values(attribution.components, attribution.xp) +
                       [formatter.string(from: attribution.hour), attribution.sessionID ?? "", coverage, zone, revision])
            }
        }
        return output
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
        let rate = totals.rateConsistency
        guard (0...1_000_000_000_000).contains(rate.count), (0...1_000_000_000_000).contains(rate.intervals),
              rate.sum.isFinite, rate.squaredSum.isFinite,
              (0...1e15).contains(rate.sum), (0...1e18).contains(rate.squaredSum),
              rate.count > 0 || (rate.intervals == 0 && rate.sum == 0 && rate.squaredSum == 0),
              rate.sum > 0 || rate.squaredSum == 0 else {
            throw StoreError.sqlite("活动统计的速度样本无效，未保存本次事务。")
        }
        let rateSquared = rate.sum * rate.sum, tolerance = max(1, rateSquared) * 1e-9
        guard rate.squaredSum * Double(rate.count) + tolerance >= rateSquared,
              rate.squaredSum <= rateSquared + tolerance else {
            throw StoreError.sqlite("活动统计的速度样本不一致，未保存本次事务。")
        }
    }
    private func validateMetadata(timezone: String, rule: String) throws {
        guard !timezone.isEmpty, timezone.utf8.count <= 255, !rule.isEmpty, rule.utf8.count <= 512,
              !timezone.contains("\0"), !rule.contains("\0") else {
            throw StoreError.sqlite("活动统计元数据无效，未保存本次事务。")
        }
    }
    private func bindTotals(_ totals: RhythmTotals, statement: OpaquePointer, startingAt index: Int32, rateStartingAt: Int32? = nil) {
        sqlite3_bind_int64(statement, index, Int64(totals.keys))
        sqlite3_bind_double(statement, index + 1, totals.intervals)
        sqlite3_bind_double(statement, index + 2, totals.seconds)
        sqlite3_bind_double(statement, index + 3, totals.squaredIntervalSeconds)
        let rateIndex = rateStartingAt ?? index + 4
        sqlite3_bind_int64(statement, rateIndex, Int64(totals.rateConsistency.count))
        sqlite3_bind_int64(statement, rateIndex + 1, Int64(totals.rateConsistency.intervals))
        sqlite3_bind_double(statement, rateIndex + 2, totals.rateConsistency.sum)
        sqlite3_bind_double(statement, rateIndex + 3, totals.rateConsistency.squaredSum)
    }
    /// Called inside save's daily/activity transaction. Hourly values are
    /// additive deltas; session values are complete checkpoints, never deltas.
    private func saveActivity(_ activity: ActivityBatch) throws {
        guard activity.hourly.count <= 4096, activity.sessions.count <= 512 else {
            throw StoreError.sqlite("活动统计批次超过容量，未保存本次事务。")
        }
        let hourlySQL = """
            INSERT INTO activity_hourly (\(Self.hourlyColumns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(bucket_start,timezone,rule,application_id) DO UPDATE SET
            bucket_end=excluded.bucket_end,keys=keys+excluded.keys,
            intervals=intervals+excluded.intervals,seconds=seconds+excluded.seconds,
            squared_interval_seconds=squared_interval_seconds+excluded.squared_interval_seconds,
            rate_sample_count=rate_sample_count+excluded.rate_sample_count,rate_interval_count=rate_interval_count+excluded.rate_interval_count,
            rate_sum=rate_sum+excluded.rate_sum,rate_squared_sum=rate_squared_sum+excluded.rate_squared_sum
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
            INSERT INTO activity_sessions (\(Self.sessionColumns.joined(separator: ","))) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET start_time=MIN(activity_sessions.start_time,excluded.start_time),end_time=excluded.end_time,keys=excluded.keys,
            intervals=excluded.intervals,seconds=excluded.seconds,squared_interval_seconds=excluded.squared_interval_seconds,
            rate_sample_count=excluded.rate_sample_count,rate_interval_count=excluded.rate_interval_count,
            rate_sum=excluded.rate_sum,rate_squared_sum=excluded.rate_squared_sum,
            end_reason=COALESCE(excluded.end_reason,activity_sessions.end_reason)
            WHERE excluded.end_time>=activity_sessions.end_time AND excluded.keys>=activity_sessions.keys
              AND excluded.intervals>=activity_sessions.intervals AND excluded.seconds>=activity_sessions.seconds
              AND excluded.squared_interval_seconds>=activity_sessions.squared_interval_seconds
              AND excluded.rate_sample_count>=activity_sessions.rate_sample_count AND excluded.rate_interval_count>=activity_sessions.rate_interval_count
              AND excluded.rate_sum>=activity_sessions.rate_sum AND excluded.rate_squared_sum>=activity_sessions.rate_squared_sum
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
            bindTotals(row.totals, statement: session, startingAt: 6, rateStartingAt: 11)
            if let reason = row.endReason { bind(reason, at: 10, statement: session) } else { sqlite3_bind_null(session, 10) }
            guard sqlite3_step(session) == SQLITE_DONE else { throw failure() }
        }
    }
    private func validateSessionIdentity(_ row: TypingSession) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT start_time,timezone,rule,end_time,keys,intervals,seconds,squared_interval_seconds,\(Self.rateColumns.joined(separator: ",")) FROM activity_sessions WHERE id=?", -1, &statement, nil) == SQLITE_OK,
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
                row.totals.rateConsistency.count <= totals.rateConsistency.count && row.totals.rateConsistency.intervals <= totals.rateConsistency.intervals &&
                row.totals.rateConsistency.sum <= totals.rateConsistency.sum && row.totals.rateConsistency.squaredSum <= totals.rateConsistency.squaredSum &&
                (row.end.timeIntervalSince1970 < end || row.totals != totals)
            guard older else { throw StoreError.sqlite("输入会话的新检查点不能向后移动起点，未保存本次事务。") }
        }
    }
    private func readTotals(_ statement: OpaquePointer, startingAt index: Int32, rateStartingAt: Int32? = nil) -> RhythmTotals {
        let rateIndex = rateStartingAt ?? index + 4
        var totals = RhythmTotals(keys: Int(sqlite3_column_int64(statement, index)), intervals: sqlite3_column_double(statement, index + 1),
                                  seconds: sqlite3_column_double(statement, index + 2), squaredIntervalSeconds: sqlite3_column_double(statement, index + 3))
        totals.rateConsistency = RateConsistencyTotals(count: Int(sqlite3_column_int64(statement, rateIndex)),
                                                       intervals: Int(sqlite3_column_int64(statement, rateIndex + 1)),
                                                       sum: sqlite3_column_double(statement, rateIndex + 2), squaredSum: sqlite3_column_double(statement, rateIndex + 3))
        return totals
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
                                      totals: readTotals(statement, startingAt: 5, rateStartingAt: 10),
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
            try execute("""
                DELETE FROM daily; DELETE FROM activity_hourly; DELETE FROM activity_sessions;
                DELETE FROM reward_attributions; DELETE FROM reward_awards; DELETE FROM reward_claims; DELETE FROM reward_improvement_claims;
                DELETE FROM reward_daily; DELETE FROM reward_checkpoint; DELETE FROM reward_batches;
                DELETE FROM daily_reward_receipts; DELETE FROM daily_reward_claims; DELETE FROM daily_reward_checkpoint; COMMIT;
                """)
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
        // Detailed reward history has the same five-year horizon as activity.
        // Lifetime state, daily earned totals, claims and batch receipts are
        // deliberately independent of this retention operation.
        try execute("BEGIN IMMEDIATE")
        do {
            try deleteBefore(instant, table: "reward_awards", column: "awarded_at")
            try execute("DELETE FROM reward_awards WHERE rowid IN (SELECT rowid FROM reward_awards ORDER BY awarded_at DESC,id DESC LIMIT -1 OFFSET 200000)")
            try execute("DELETE FROM reward_attributions WHERE NOT EXISTS(SELECT 1 FROM reward_awards WHERE reward_awards.id=reward_attributions.award_id)")
            // Unseen settlements survive retention so several days (or a long
            // absence) can still be presented in order. Compact immutable
            // claims remain after seen history is pruned to prevent reissue.
            var receipts: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM daily_reward_receipts WHERE seen_at IS NOT NULL AND settled_at<?", -1, &receipts, nil) == SQLITE_OK,
                  let receipts else { throw failure() }
            defer { sqlite3_finalize(receipts) }
            sqlite3_bind_double(receipts, 1, instant)
            guard sqlite3_step(receipts) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
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
