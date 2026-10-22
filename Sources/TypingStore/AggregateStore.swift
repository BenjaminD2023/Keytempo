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
    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): return message
        case let .unsupportedVersion(version): return "统计数据库版本 \(version) 高于此版本支持的版本 2，请使用较新版本的 Keytempo。"
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
    public let url: URL
    public init(url: URL) throws {
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
            guard version <= 2 else { throw StoreError.unsupportedVersion(version) }
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")
            try prepareSchema()
            try prune()
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
    private func dailyLayout() throws -> (columns: [String], primaryKey: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(daily)", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
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
    /// The table rebuild and version update commit together; failure leaves v1 intact.
    private func prepareSchema() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try schemaVersion(), layout = try dailyLayout()
            guard version <= 2 else { throw StoreError.unsupportedVersion(version) }
            let legacyKey = ["day", "timezone", "rule", "evidence"]
            if version == 0 && layout.columns.isEmpty {
                try execute(Self.createDaily)
            } else if (version == 0 || version == 1) && layout.columns == Self.legacyColumns && layout.primaryKey == legacyKey {
                try execute("ALTER TABLE daily RENAME TO keytempo_daily_v1_migration")
                try execute(Self.createDaily)
                let legacy = Self.legacyColumns.joined(separator: ",")
                try execute("INSERT INTO daily (\(Self.columns.joined(separator: ","))) SELECT \(legacy),'und',0,0,0,0 FROM keytempo_daily_v1_migration")
                try execute("DROP TABLE keytempo_daily_v1_migration")
            } else if version != 2 || layout.columns != Self.columns || layout.primaryKey != legacyKey + ["language"] {
                throw StoreError.sqlite("统计数据库结构与版本 \(version) 不匹配，已保留原有数据。")
            }
            try execute("CREATE INDEX IF NOT EXISTS daily_range ON daily(day); PRAGMA user_version=2; COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func save(_ rows: [StoredAggregate]) throws {
        guard !rows.isEmpty else { return }
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
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
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
        try execute("BEGIN IMMEDIATE; DELETE FROM daily; COMMIT; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
    private func prune() throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -1826, to: Date())!
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM daily WHERE day<?", -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        bind(formatter.string(from: cutoff), at: 1, statement: statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try execute("DELETE FROM daily WHERE rowid IN (SELECT rowid FROM daily ORDER BY day DESC LIMIT -1 OFFSET 50000)")
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
