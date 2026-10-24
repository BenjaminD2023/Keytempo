import Foundation
import Testing
import TypingCore
import TypingStore
import CSQLite

final class DailyRewardsStoreTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let base = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
    private let firstDay = "2026-10-24"

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DailyRewardsStoreTests-\(UUID().uuidString)").appendingPathComponent("test.sqlite")
    }
    private func execute(_ sql: String, at url: URL) throws {
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
    private func aggregate() -> StoredAggregate {
        var value = StoredAggregate(day: firstDay, timezone: utc.identifier, rule: "fixture", evidence: "probable")
        value.keys = 5; value.intervals = 4; value.seconds = 0.8
        return value
    }
    private func activity() -> ActivityBatch {
        .init(hourly: [.init(bucketStart: base, bucketEnd: base.addingTimeInterval(3600), timezone: utc.identifier,
                            rule: "fixture", totals: .init(keys: 5, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.16))])
    }
    private func legacyWrite() -> RewardWrite {
        var state = RewardState(coverageStart: base, progressionTimezone: utc.identifier, currentDay: firstDay)
        state.revision = 1; state.nextAward = 1
        let components = RewardComponents(time: 60 * log1p(300.0 / 3600), volume: 60 * log1p(2000.0 / 15000))
        _ = state.xpProgress.add(seconds: 300, keys: 2000); state.lifetimeScore = components
        var budget = RewardDayBudget(day: firstDay); budget.keys = 2000; budget.seconds = 300
        budget.components = components; budget.xp = RewardXP(time: 1, volume: 1); state.days[firstDay] = budget
        let attribution = RewardAttribution(day: firstDay, hour: base, components: components, xp: budget.xp)
        return RewardWrite(state: state, awards: [.init(id: state.lineage + ":1", date: base, day: firstDay, kind: "base",
                                                      components: components, xpSources: budget.xp, attributions: [attribution])])
    }
    private func initialWrite() -> DailyRewardWrite {
        var state = DailyRewardState(coverageStart: base, progressionTimezone: utc.identifier, currentDay: firstDay, migratedLegacyXP: 300)
        state.revision = 1
        return .init(state: state)
    }
    private func settledWrite(after previous: DailyRewardState) -> DailyRewardWrite {
        let totals = RhythmTotals(keys: 1001, intervals: 1000, seconds: 200, squaredIntervalSeconds: 40,
                                  rateConsistency: .init(count: 200, intervals: 999, sum: 12000, squaredSum: 720000))
        let score = DailyRewardScore.value(totals: totals)!
        var state = previous, balance = previous.totalXP
        var receipts: [DailySettlementReceipt] = []
        for (index, day) in ["2026-10-24", "2026-10-25"].enumerated() {
            let bonus = index == 1 ? 750 : 0
            let receipt = DailySettlementReceipt(id: previous.lineage + "|" + day, day: day,
                settledAt: base.addingTimeInterval(2 * 86400), score: score, ordinaryXP: score, improvementXP: bonus,
                beforeXP: balance, afterXP: balance + score + bonus, totals: totals, rule: "fixture")
            balance = receipt.afterXP; receipts.append(receipt)
        }
        state.revision += 1; state.currentDay = "2026-10-26"; state.settledThroughDay = "2026-10-25"
        state.days = [state.currentDay: .init(day: state.currentDay)]; state.totalXP = balance
        state.observedLegacyImprovementXP += 5
        return .init(state: state, receipts: receipts)
    }

    @Test func migrationFromV5PreservesLegacyRewardsAndDoesNotBackfillDailyReceipts() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = legacyWrite()
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try db.save([aggregate()], activity: activity(), progression: legacy, batchID: "legacy-v5")
        }
        let legacyJSON = try scalar("SELECT state_json FROM reward_checkpoint", at: url)
        try execute("DROP TABLE daily_reward_receipts; DROP TABLE daily_reward_claims; DROP TABLE daily_reward_checkpoint; PRAGMA user_version=5", at: url)
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        #expect(try scalar("PRAGMA user_version", at: url) == "6")
        #expect(try scalar("SELECT state_json FROM reward_checkpoint", at: url) == legacyJSON)
        #expect(try db.loadRewardState() == legacy.state)
        #expect(try db.query(since: "0000") == [aggregate()])
        #expect(try db.loadDailyRewardState() == nil)
        #expect(try db.dailyRewardReceiptCount(unseenOnly: false) == 0)
        // The optional v3 payload must not change the fingerprint of v5 batches.
        try db.save([aggregate()], activity: activity(), progression: legacy, batchID: "legacy-v5")
        #expect(try db.query(since: "0000").first?.keys == 5)
    }

    @Test func canonicalRollbackAndCrashRetryCommitBothRewardEnginesExactlyOnce() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = legacyWrite(), daily = initialWrite()
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try execute("CREATE TRIGGER fail_daily_reward BEFORE INSERT ON daily_reward_checkpoint BEGIN SELECT RAISE(ABORT,'fixture'); END", at: url)
            #expect(throws: (any Error).self) {
                try db.save([self.aggregate()], activity: self.activity(), progression: legacy, dailyRewards: daily, batchID: "canonical")
            }
            #expect(try db.query(since: "0000").isEmpty)
            #expect(try db.queryHourly(since: base, until: base.addingTimeInterval(3600)).isEmpty)
            #expect(try db.loadRewardState() == nil && db.loadDailyRewardState() == nil)
            #expect(try scalar("SELECT COUNT(*) FROM reward_batches", at: url) == "0")
            try execute("DROP TRIGGER fail_daily_reward", at: url)
            try db.save([aggregate()], activity: activity(), progression: legacy, dailyRewards: daily, batchID: "canonical")
        }
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        try db.save([aggregate()], activity: activity(), progression: legacy, dailyRewards: daily, batchID: "canonical")
        #expect(try db.query(since: "0000").first?.keys == 5)
        #expect(try db.loadRewardState() == legacy.state)
        #expect(try db.loadDailyRewardState() == daily.state)
        #expect(throws: (any Error).self) { try db.save([], progression: legacy, dailyRewards: daily, batchID: "canonical") }
        #expect(throws: (any Error).self) { try db.save([], dailyRewards: daily, batchID: "new-id-same-revision") }
    }

    @Test func fifoAcknowledgementAndSkipAllNeverChangeXPOrImmutableReceipts() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc), initial = initialWrite()
        try db.save([], dailyRewards: initial, batchID: "initial")
        let settled = settledWrite(after: initial.state)
        try db.save([], dailyRewards: settled, batchID: "settled")
        #expect(try db.queryUnseenDailyRewardReceipts(limit: 1) == [settled.receipts[0]])
        let json = try scalar("SELECT state_json FROM daily_reward_checkpoint", at: url)
        try db.acknowledgeDailyRewardReceipt(id: settled.receipts[0].id)
        try db.acknowledgeDailyRewardReceipt(id: settled.receipts[0].id)
        #expect(try db.dailyRewardReceiptCount() == 1)
        #expect(try db.queryUnseenDailyRewardReceipts() == [settled.receipts[1]])
        #expect(try db.queryDailyRewardReceipts(since: "2026-10-24") == settled.receipts)
        #expect(try scalar("SELECT state_json FROM daily_reward_checkpoint", at: url) == json)
        try db.acknowledgeAllDailyRewardReceipts(); try db.acknowledgeAllDailyRewardReceipts()
        #expect(try db.dailyRewardReceiptCount() == 0)
        #expect(try db.loadDailyRewardState() == settled.state)
        #expect(try db.queryDailyRewardReceipts(since: "2026-10-24") == settled.receipts)
        #expect(throws: (any Error).self) { try db.acknowledgeDailyRewardReceipt(id: "missing") }
        #expect(throws: (any Error).self) { try db.queryUnseenDailyRewardReceipts(limit: 0) }
        let csv = try db.exportDailyRewardCSV()
        #expect(csv.contains("ordinary_xp,improvement_xp,before_xp,after_xp"))
        #expect(csv.contains("2026-10-24") && csv.contains("daily-score-v3"))
    }

    @Test func failedReceiptInsertionRollsBackBalancesClaimsAndMeasurements() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc), initial = initialWrite()
        try db.save([], dailyRewards: initial, batchID: "initial")
        let settled = settledWrite(after: initial.state)
        try execute("CREATE TRIGGER fail_second_receipt BEFORE INSERT ON daily_reward_receipts WHEN NEW.day='2026-10-25' BEGIN SELECT RAISE(ABORT,'fixture'); END", at: url)
        #expect(throws: (any Error).self) { try db.save([self.aggregate()], dailyRewards: settled, batchID: "settled") }
        #expect(try db.loadDailyRewardState() == initial.state)
        #expect(try db.dailyRewardReceiptCount(unseenOnly: false) == 0)
        #expect(try scalar("SELECT COUNT(*) FROM daily_reward_claims", at: url) == "0")
        #expect(try db.query(since: "0000").isEmpty)
        try execute("DROP TRIGGER fail_second_receipt", at: url)
        try db.save([aggregate()], dailyRewards: settled, batchID: "settled")
        try db.save([aggregate()], dailyRewards: settled, batchID: "settled")
        #expect(try db.loadDailyRewardState() == settled.state)
        #expect(try db.query(since: "0000").first?.keys == 5)
    }

    @Test func conflictingReceiptOrUnreceiptedXPIsRejectedWithoutChangingTheBalance() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc), initial = initialWrite()
        try db.save([], dailyRewards: initial, batchID: "initial")
        let settled = settledWrite(after: initial.state)
        try db.save([], dailyRewards: settled, batchID: "settled")
        var forged = settled
        forged.state.revision += 1; forged.state.totalXP += 1; forged.receipts = []
        #expect(forged.state.isValid)
        #expect(throws: (any Error).self) { try db.save([], dailyRewards: forged, batchID: "unreceipted-xp") }
        forged.state.totalXP = settled.state.totalXP; forged.receipts = [settled.receipts[0]]
        forged.receipts[0].settledAt.addTimeInterval(1)
        #expect(forged.receipts[0].isValid)
        #expect(throws: (any Error).self) { try db.save([], dailyRewards: forged, batchID: "changed-receipt") }
        #expect(try db.loadDailyRewardState() == settled.state)
        #expect(try db.dailyRewardReceiptCount() == 2)
    }

    @Test func retentionNeverDropsUnseenSettlementsAndKeepsClaimsAfterSeenHistoryExpires() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initial = initialWrite(), settled = settledWrite(after: initial.state)
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try db.save([], dailyRewards: initial, batchID: "initial")
            try db.save([], dailyRewards: settled, batchID: "settled")
            try db.acknowledgeDailyRewardReceipt(id: settled.receipts[0].id)
        }
        let future = Calendar(identifier: .gregorian).date(byAdding: .year, value: 6, to: base)!
        let db = try AggregateStore(url: url, now: future, timeZone: utc)
        #expect(try db.queryUnseenDailyRewardReceipts() == [settled.receipts[1]])
        #expect(try db.dailyRewardReceiptCount(unseenOnly: false) == 1)
        #expect(try scalar("SELECT COUNT(*) FROM daily_reward_claims", at: url) == "2")
        #expect(try db.loadDailyRewardState() == settled.state)
        try db.acknowledgeDailyRewardReceipt(id: settled.receipts[0].id)
        #expect(try db.dailyRewardReceiptCount() == 1)
    }

    @Test func appDetailClearPreservesDailyRewardsAndFullClearResetsThem() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc), initial = initialWrite()
        try db.save([], dailyRewards: initial, batchID: "initial")
        let settled = settledWrite(after: initial.state)
        try db.save([], dailyRewards: settled, batchID: "settled")
        try db.clearAppActivity()
        #expect(try db.loadDailyRewardState() == settled.state && db.dailyRewardReceiptCount() == 2)
        try db.clear()
        #expect(try db.loadDailyRewardState() == nil && db.dailyRewardReceiptCount(unseenOnly: false) == 0)
        #expect(try scalar("SELECT COUNT(*) FROM daily_reward_claims", at: url) == "0")
        try db.save([], dailyRewards: initial, batchID: "initial")
        #expect(try db.loadDailyRewardState() == initial.state)
    }

    @Test func damagedDailyStateOrReceiptFailsClosedWithoutErasingItsRows() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc), initial = initialWrite()
        try db.save([], dailyRewards: initial, batchID: "initial")
        let settled = settledWrite(after: initial.state)
        try db.save([], dailyRewards: settled, batchID: "settled")
        try execute("UPDATE daily_reward_receipts SET receipt_json='{}' WHERE day='2026-10-24'", at: url)
        #expect(throws: (any Error).self) { try db.queryUnseenDailyRewardReceipts() }
        #expect(try db.dailyRewardReceiptCount() == 2)
        try execute("UPDATE daily_reward_checkpoint SET state_hash='damaged'", at: url)
        #expect(throws: (any Error).self) { try db.loadDailyRewardState() }
        #expect(try scalar("SELECT COUNT(*) FROM daily_reward_checkpoint", at: url) == "1")
    }

    @Test func pendingDaysAcceptDelayedEvidenceButCannotDisappearOrLoseProgress() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        var initial = initialWrite()
        initial.state.currentDay = "2026-10-25"
        initial.state.days[firstDay] = .init(day: firstDay, totals: .init(keys: 5, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.16), rule: "fixture", sealed: true)
        initial.state.days[initial.state.currentDay] = .init(day: initial.state.currentDay)
        #expect(initial.state.isValid)
        try db.save([], dailyRewards: initial, batchID: "pending")
        var delayed = initial
        delayed.state.revision += 1
        delayed.state.days[firstDay]!.totals.merge(.init(intervals: 1, seconds: 0.2, squaredIntervalSeconds: 0.04))
        try db.save([], dailyRewards: delayed, batchID: "late-evidence")
        #expect(try db.loadDailyRewardState()?.days[firstDay]?.totals.seconds == 1)
        var discarded = delayed
        discarded.state.revision += 1; discarded.state.days.removeValue(forKey: firstDay)
        #expect(discarded.state.isValid)
        #expect(throws: (any Error).self) { try db.save([], dailyRewards: discarded, batchID: "discarded-pending") }
        #expect(try db.loadDailyRewardState() == delayed.state)
    }
}
