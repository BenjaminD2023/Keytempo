import Testing
import Foundation
import TypingStore
import CSQLite

final class AggregateStoreTests {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("TypingStoreTests-\(UUID().uuidString)").appendingPathComponent("test.sqlite") }
    @Test func testTransactionalAdditivePersistenceAndReopen() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var row = StoredAggregate(day: "2026-10-22", timezone: "Asia/Shanghai", rule: "adaptive-v1-max3", evidence: "confirmed")
        row.keys = 5; row.intervals = 4; row.seconds = 0.8; row.english = 5
        do { let db = try AggregateStore(url: url); try db.save([row]); try db.save([row]) }
        let reopened = try AggregateStore(url: url)
        let rows = try reopened.query(since: "2026-10-01")
        #expect(rows.count == 1); #expect(rows[0].keys == 10); #expect(rows[0].intervals == 8); #expect(rows[0].seconds == 1.6); #expect(rows[0].english == 10)
    }
    @Test func testEvidenceRulesAndTimezonesRemainSeparate() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url)
        let rows = [StoredAggregate(day: "2026-10-22", timezone: "Asia/Shanghai", rule: "v1", evidence: "confirmed"), StoredAggregate(day: "2026-10-22", timezone: "Asia/Shanghai", rule: "v1", evidence: "probable"), StoredAggregate(day: "2026-10-22", timezone: "Asia/Shanghai", rule: "v2", evidence: "probable"), StoredAggregate(day: "2026-10-22", timezone: "UTC", rule: "v1", evidence: "probable")]
        try db.save(rows); #expect(try db.query(since: "2026-10-22").count == 4)
        #expect(try db.query(since: "2026-10-23").isEmpty)
        try db.clear(); #expect(try db.query(since: "0000").isEmpty)
    }
    @Test func testCSVQuotingAndNoContentColumns() {
        let row = StoredAggregate(day: "2026-10-22", timezone: "Example,\"zone", rule: "v1", evidence: "confirmed")
        let csv = AggregateStore.csv([row])
        #expect(csv.contains("\"Example,\"\"zone\"")); #expect(csv.contains("observed_intervals"))
        #expect(!csv.contains("keycode")); #expect(!csv.contains("window_title")); #expect(!csv.contains("text_content"))
    }
    @Test func testFailureIsVisible() throws {
        let url = URL(fileURLWithPath: "/dev/null/statistics.sqlite")
        #expect(throws: (any Error).self) { try AggregateStore(url: url) }
    }

    private let legacySchema = """
        CREATE TABLE daily (
          day TEXT NOT NULL, timezone TEXT NOT NULL, rule TEXT NOT NULL, evidence TEXT NOT NULL,
          keys INTEGER NOT NULL, edits INTEGER NOT NULL, composition INTEGER NOT NULL,
          intervals REAL NOT NULL, seconds REAL NOT NULL, new_intervals REAL NOT NULL, new_seconds REAL NOT NULL,
          english INTEGER NOT NULL, chinese INTEGER NOT NULL,
          PRIMARY KEY(day, timezone, rule, evidence));
        CREATE INDEX daily_range ON daily(day);
        """
    private func executeFixture(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite("fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }
    private func fixtureScalar(_ sql: String, at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StoreError.sqlite("fixture read") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.sqlite("fixture prepare") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.sqlite("fixture scalar") }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    @Test func testLegacyMigrationPreservesEveryValueWithoutInventingCharacterData() throws {
        for version in [0, 1] {
            let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try executeFixture(legacySchema + """
                INSERT INTO daily VALUES ('2026-10-22','Asia/Shanghai','v1','confirmed',17,3,4,12.5,3.25,7.5,1.75,9,2);
                CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('preserved');
                PRAGMA user_version=\(version);
                """, at: url)
            do {
                let store = try AggregateStore(url: url)
                let rows = try store.query(since: "0000")
                #expect(rows.count == 1)
                let row = try #require(rows.first)
                #expect(row.day == "2026-10-22"); #expect(row.timezone == "Asia/Shanghai")
                #expect(row.rule == "v1"); #expect(row.evidence == "confirmed"); #expect(row.language == "und")
                #expect(row.keys == 17); #expect(row.edits == 3); #expect(row.composition == 4)
                #expect(row.intervals == 12.5); #expect(row.seconds == 3.25)
                #expect(row.newIntervals == 7.5); #expect(row.newSeconds == 1.75)
                #expect(row.english == 9); #expect(row.chinese == 2)
                #expect(row.characters == 0); #expect(row.ratedCharacters == 0)
                #expect(row.characterSeconds == 0); #expect(row.characterIntervals == 0)
            }
            #expect(try fixtureScalar("PRAGMA user_version", at: url) == "2")
            #expect(try fixtureScalar("SELECT value FROM unrelated", at: url) == "preserved")
            let reopened = try AggregateStore(url: url)
            #expect(try reopened.query(since: "0000").first?.keys == 17)
        }
    }

    @Test func testMigrationFailureRollsBackTableRebuildAndVersion() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // An invalid legacy NULL forces copy failure after the table has been renamed.
        let permissiveSchema = legacySchema.replacingOccurrences(of: "keys INTEGER NOT NULL", with: "keys INTEGER")
        try executeFixture(permissiveSchema + """
            INSERT INTO daily VALUES ('2026-10-22','UTC','v1','confirmed',NULL,0,0,0,0,0,0,0,0);
            PRAGMA user_version=1;
            """, at: url)
        #expect(throws: (any Error).self) { try AggregateStore(url: url) }
        #expect(try fixtureScalar("PRAGMA user_version", at: url) == "1")
        #expect(try fixtureScalar("SELECT keys IS NULL FROM daily", at: url) == "1")
        #expect(try fixtureScalar("SELECT COUNT(*) FROM sqlite_master WHERE name='keytempo_daily_v1_migration'", at: url) == "0")
    }

    @Test func testFutureSchemaVersionIsRejectedWithoutOverwrite() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try executeFixture("CREATE TABLE future_data (value TEXT); INSERT INTO future_data VALUES ('keep'); PRAGMA user_version=99;", at: url)
        do {
            _ = try AggregateStore(url: url)
            Issue.record("A future schema version was accepted")
        } catch StoreError.unsupportedVersion(let version) { #expect(version == 99) }
        #expect(try fixtureScalar("PRAGMA user_version", at: url) == "99")
        #expect(try fixtureScalar("PRAGMA journal_mode", at: url) == "delete")
        #expect(try fixtureScalar("SELECT value FROM future_data", at: url) == "keep")
        #expect(try fixtureScalar("SELECT COUNT(*) FROM sqlite_master WHERE name='daily'", at: url) == "0")
    }

    @Test func testLanguagesAndCoveredCharacterRatesRoundTripAndMerge() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var english = StoredAggregate(day: "2026-10-22", timezone: "UTC", rule: "v2", evidence: "confirmed", language: "en")
        english.keys = 5; english.intervals = 4; english.seconds = 0.8
        english.characters = 9; english.ratedCharacters = 8; english.characterSeconds = 1.6; english.characterIntervals = 4
        var chinese = english; chinese.language = "zh"; chinese.characters = 4
        let unknown = StoredAggregate(day: english.day, timezone: english.timezone, rule: english.rule, evidence: english.evidence)
        #expect(english.id != chinese.id); #expect(english.id != unknown.id)
        do {
            let db = try AggregateStore(url: url)
            try db.save([english, chinese, unknown]); try db.save([english])
        }
        let reopened = try AggregateStore(url: url), rows = try reopened.query(since: "0000")
        #expect(rows.count == 3)
        let saved = try #require(rows.first { $0.language == "en" })
        #expect(saved.keys == 10); #expect(saved.characters == 18); #expect(saved.ratedCharacters == 16)
        #expect(saved.characterSeconds == 3.2); #expect(saved.characterIntervals == 8)
        #expect(rows.first { $0.language == "zh" }?.characters == 4)
        var merged = english; merged.merge(english)
        #expect(merged.characters == saved.characters); #expect(merged.ratedCharacters == saved.ratedCharacters)
        #expect(merged.characterSeconds == saved.characterSeconds); #expect(merged.characterIntervals == saved.characterIntervals)
        let csv = AggregateStore.csv([english]), lines = csv.split(separator: "\n")
        let values = Dictionary(uniqueKeysWithValues: zip(lines[0].split(separator: ",").map(String.init), lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)))
        #expect(values["language"] == "\"en\""); #expect(values["characters"] == "9")
        #expect(values["rated_characters"] == "8.0"); #expect(values["character_intervals"] == "4.0")
        #expect(Double(values["kpm"] ?? "") == 300)
        #expect(Double(values["estimated_wpm"] ?? "") == 60)
        #expect(Double(values["character_cpm"] ?? "") == 300)
        english.characterIntervals = 3
        #expect(AggregateStore.csv([english]).split(separator: "\n")[1].hasSuffix(","))
    }
}
