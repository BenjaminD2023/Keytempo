import Foundation
import Testing
import TypingCore
import TypingStore
import CSQLite

final class ProgressionStoreTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let base = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
    private let day = "2026-10-24"
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProgressionStoreTests-\(UUID().uuidString)").appendingPathComponent("test.sqlite")
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
    private func write() -> RewardWrite {
        var state = RewardState(coverageStart: base, progressionTimezone: utc.identifier, currentDay: day)
        state.revision = 1; state.nextAward = 1
        let components = RewardComponents(time: 60 * log1p(300.0 / 3600), volume: 60 * log1p(2000.0 / 15000))
        _ = state.xpProgress.add(seconds: 300, keys: 2000)
        state.lifetimeScore = components
        var budget = RewardDayBudget(day: day); budget.keys = 2000; budget.seconds = 300
        budget.components = components; budget.xp = RewardXP(time: 1, volume: 1); state.days[day] = budget
        let attribution = RewardAttribution(day: day, hour: base, sessionID: "session", components: components, xp: budget.xp)
        let award = RewardAward(id: state.lineage + ":1", date: base, day: day, kind: "base", components: components, xpSources: budget.xp, attributions: [attribution])
        return RewardWrite(state: state, awards: [award])
    }
    private func daily() -> StoredAggregate {
        var row = StoredAggregate(day: day, timezone: utc.identifier, rule: "fixture", evidence: "probable")
        row.keys = 5; row.intervals = 4; row.seconds = 0.8
        return row
    }
    private func activity(app: String = "") -> ActivityBatch {
        ActivityBatch(hourly: [.init(bucketStart: base, bucketEnd: base.addingTimeInterval(3600), timezone: utc.identifier, rule: "fixture", applicationID: app,
                                    totals: .init(keys: 5, intervals: 4, seconds: 0.8, squaredIntervalSeconds: 0.16))])
    }

    @Test func migrationFromV4PreservesAllLegacyHistoryAndStartsWithNoRewards() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var before: [HourlyActivity] = []
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try db.save([daily()], activity: activity())
            before = try db.queryHourly(since: base, until: base.addingTimeInterval(3600))
        }
        try execute("""
            DROP TABLE reward_checkpoint; DROP TABLE reward_batches; DROP TABLE reward_awards; DROP TABLE reward_claims;
            DROP TABLE reward_attributions; DROP TABLE reward_daily; DROP TABLE reward_improvement_claims; PRAGMA user_version=4;
            """, at: url)
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        #expect(try scalar("PRAGMA user_version", at: url) == "5")
        #expect(try db.query(since: "0000") == [daily()])
        #expect(try db.queryHourly(since: base, until: base.addingTimeInterval(3600)) == before)
        #expect(try db.loadRewardState() == nil)
        #expect(try db.queryRewardDays(since: "0000").isEmpty)
        #expect(try db.queryRewardAwards(day: day).isEmpty)
    }

    @Test func rollbackThenCrashRetryCommitsMeasurementsAwardsAndCheckpointExactlyOnce() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reward = write(), id = "stable-batch"
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try execute("CREATE TRIGGER fail_reward BEFORE INSERT ON reward_checkpoint BEGIN SELECT RAISE(ABORT,'fixture'); END;", at: url)
            #expect(throws: (any Error).self) { try db.save([self.daily()], activity: self.activity(), progression: reward, batchID: id) }
            #expect(try db.query(since: "0000").isEmpty)
            #expect(try db.queryHourly(since: base, until: base.addingTimeInterval(3600)).isEmpty)
            #expect(try db.queryRewardAwards(day: day).isEmpty)
            #expect(try scalar("SELECT COUNT(*) FROM reward_batches", at: url) == "0")
            #expect(try scalar("SELECT COUNT(*) FROM reward_claims", at: url) == "0")
            try execute("DROP TRIGGER fail_reward", at: url)
            try db.save([daily()], activity: activity(), progression: reward, batchID: id)
        }
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        try db.save([daily()], activity: activity(), progression: reward, batchID: id)
        #expect(try db.query(since: "0000").first?.keys == 5)
        #expect(try db.queryHourly(since: base, until: base.addingTimeInterval(3600)).first?.totals.keys == 5)
        #expect(try db.loadRewardState() == reward.state)
        #expect(try db.queryRewardAwards(day: day) == reward.awards)
        #expect(try db.queryRewardDays(since: day).first?.xp.total == 2)
        #expect(throws: (any Error).self) { try db.save([], progression: reward, batchID: id) }
        #expect(throws: (any Error).self) { try db.save([self.daily()], progression: reward, batchID: "different-id") }
        #expect(try db.query(since: "0000").first?.keys == 5)
    }

    @Test func partialCanonicalBlocksSurviveRestartWithoutBridgingTypingTime() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = ImprovementContext(language: "en", inputMethod: "abc", measurementPolicy: "adaptive-v1", evidencePolicy: "probable")
        var rewards = RewardEngine(coverageStart: base, progressionTimeZone: utc), measurement = StatisticsEngine(timeZone: utc)
        func feed(_ range: Range<Int>, offset: Double, dateOffset: Double) {
            for index in range {
                let time = offset + Double(index) * 0.2
                let event = ClassifiedInput(time: time, date: base.addingTimeInterval(dateOffset + Double(index) * 0.2), context: 1,
                                            category: .textEntry, evidence: .probable, source: .global, language: "en", applicationID: "org.example.NeverStore")
                let result = measurement.recordWithIntervals(event)
                rewards.record(input: event, result: result, context: context, pendingIntervalCount: measurement.pendingProbableIntervals)
            }
        }
        feed(0..<50, offset: 0, dateOffset: 0)
        let first = rewards.checkpoint(at: base.addingTimeInterval(10))
        do { let db = try AggregateStore(url: url, now: base, timeZone: utc); try db.save([], progression: first, batchID: "partial-1") }
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        let restored = try #require(try db.loadRewardState())
        #expect(restored.pendingBlockKeys == 50 && restored.xpProgress.eligibleKeys == 50)
        rewards = try RewardEngine(restoring: restored, now: base.addingTimeInterval(3600)); measurement = StatisticsEngine(timeZone: utc)
        feed(0..<50, offset: 3600, dateOffset: 3600)
        let second = rewards.checkpoint(at: base.addingTimeInterval(3610))
        try db.save([], progression: second, batchID: "partial-2")
        try db.save([], progression: second, batchID: "partial-2")
        let saved = try #require(try db.loadRewardState())
        #expect(saved.xpProgress.eligibleKeys == 100 && abs(saved.xpProgress.eligibleSeconds - 19.6) < 1e-8)
        #expect(saved.blocks.isEmpty && saved.lifetimeScore.total >= first.state.lifetimeScore.total)
        #expect(try scalar("SELECT state_json FROM reward_checkpoint", at: url).contains("org.example.NeverStore") == false)
    }

    @Test func scoringDayQueriesAndAttributionKeepLateBonusOnItsOriginalDay() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var reward = write()
        reward.awards[0].date = base.addingTimeInterval(86400)
        let half = reward.awards[0].components.scaled(by: 0.5)
        reward.awards[0].attributions = [RewardAttribution(day: day, hour: base, sessionID: "session", components: half, xp: .init(time: 1)),
                                       RewardAttribution(day: day, hour: base, sessionID: "session-2", components: half, xp: .init(volume: 1))]
        let db = try AggregateStore(url: url, now: base, timeZone: utc)
        try db.save([], progression: reward, batchID: "late")
        #expect(try db.queryRewardAwards(day: day).count == 1)
        #expect(try db.queryRewardAwards(since: base, until: base.addingTimeInterval(86400)).isEmpty)
        #expect(try db.queryRewardAwards(attributedSince: base, until: base.addingTimeInterval(3600)) == reward.awards)
        #expect(try db.queryRewardAwards(attributedSince: base.addingTimeInterval(-3600), until: base).isEmpty)
        #expect(try db.queryRewardAttributions(since: base, until: base.addingTimeInterval(3600), sessionID: "session").count == 1)
        #expect(try db.queryRewardDays(since: day).first?.components == reward.state.lifetimeScore)
        let csv = try db.exportRewardCSV()
        #expect(csv.contains("\"lifetime\"") && csv.contains("score-v2;xp-v1;improvement-v1;levels-v1"))
        #expect(csv.contains("\"attribution\"") && csv.contains("\"session\""))
    }

    @Test func detailPruningPreservesLifetimeXPBaselineClaimsDailyTotalsAndBatchReceipts() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var reward = write()
        reward.state.coverageStart = base.addingTimeInterval(-30 * 86400)
        let context = ImprovementContext(language: "en", inputMethod: "abc", measurementPolicy: "fixture", evidencePolicy: "probable")
        for index in 1...8 {
            let key = String(format: "2026-10-%02d", index)
            let seconds = index <= 5 ? 720.0 : 600.0, wpm = index <= 5 ? 40.0 : 44.0
            _ = reward.state.improvement.completedDay(context: context, day: ImprovementDay(day: key, speedIntervals: seconds * wpm / 12, seconds: seconds))
        }
        #expect(reward.state.improvement.tracks[context.id]?.speedMilestone == 2)
        _ = reward.state.xpProgress.addImprovementXP(10); reward.state.days[day]!.xp.improvement = 10; reward.state.nextAward = 2
        let xp = RewardXP(improvement: 10), attribution = RewardAttribution(day: day, hour: base, xp: xp)
        let claimID = "improvement-v1|" + String(repeating: "x", count: 300) + "|speed|1-2"
        reward.awards.append(RewardAward(id: reward.state.lineage + ":2", date: base, day: day, kind: "improvement", xpSources: xp, attributions: [attribution], claimID: claimID))
        do {
            let db = try AggregateStore(url: url, now: base, timeZone: utc)
            try db.save([daily()], activity: activity(), progression: reward, batchID: "retained")
            let csv = try db.exportRewardCSV()
            #expect(csv.contains("award_id,claim_id,date") && csv.contains(claimID))
        }
        let future = Calendar(identifier: .gregorian).date(byAdding: .year, value: 6, to: base)!
        let db = try AggregateStore(url: url, now: future, timeZone: utc)
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.queryRewardAwards(day: day).isEmpty)
        #expect(try db.loadRewardState() == reward.state)
        #expect(try db.queryRewardDays(since: day).first?.xp.total == 12)
        #expect(try scalar("SELECT COUNT(*) FROM reward_claims", at: url) == "2")
        #expect(try scalar("SELECT COUNT(*) FROM reward_improvement_claims", at: url) == "1")
        #expect(try scalar("SELECT COUNT(*) FROM reward_batches", at: url) == "1")
        try db.save([daily()], activity: activity(), progression: reward, batchID: "retained")
        #expect(try db.query(since: "0000").isEmpty)
        #expect(throws: (any Error).self) { try db.save([], progression: reward, batchID: "reused-under-new-batch") }
        var duplicate = reward; duplicate.state.revision = 2; duplicate.state.nextAward = 3
        _ = duplicate.state.xpProgress.addImprovementXP(10); duplicate.state.days[day]!.xp.improvement += 10
        duplicate.awards = [RewardAward(id: reward.state.lineage + ":3", date: future, day: day, kind: "improvement", xpSources: xp,
                                       attributions: [attribution], claimID: claimID)]
        #expect(throws: (any Error).self) { try db.save([self.daily()], activity: self.activity(), progression: duplicate, batchID: "same-claim-new-award") }
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.loadRewardState() == reward.state)
        #expect(try db.exportRewardCSV().contains("\"lifetime\""))
    }

    @Test func perAppDeletionPreservesProgressionAndAllDataDeletionClearsEveryRewardTable() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reward = write(), db = try AggregateStore(url: url, now: base, timeZone: utc)
        var combined = activity(); combined.hourly += activity(app: "org.example.Editor").hourly
        try db.save([daily()], activity: combined, progression: reward, batchID: "clear")
        try db.clearAppActivity()
        #expect(try db.loadRewardState() == reward.state)
        #expect(try db.queryRewardAwards(day: day).count == 1)
        #expect(try db.queryHourly(since: base, until: base.addingTimeInterval(3600), includeApplications: true).allSatisfy { $0.applicationID.isEmpty })
        try db.clear()
        #expect(try db.loadRewardState() == nil)
        for table in ["reward_checkpoint", "reward_batches", "reward_awards", "reward_claims", "reward_improvement_claims", "reward_attributions", "reward_daily"] {
            #expect(try scalar("SELECT COUNT(*) FROM \(table)", at: url) == "0")
        }
        try db.save([], progression: reward, batchID: "clear")
        #expect(try db.loadRewardState() == reward.state)
    }

    @Test func invalidRevisionAwardIdentityBudgetsAndCheckpointCorruptionRejectAtomically() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reward = write(), db = try AggregateStore(url: url, now: base, timeZone: utc)
        #expect(throws: (any Error).self) { try db.save([], progression: reward) }
        try db.save([], progression: reward, batchID: "original")
        var conflict = reward; conflict.state.revision = 2; conflict.awards[0].kind = "different"
        #expect(throws: (any Error).self) { try db.save([self.daily()], progression: conflict, batchID: "conflict") }
        var reset = reward; reset.state.revision = 2; reset.awards = []; reset.state.days[day]!.keys = 0
        #expect(throws: (any Error).self) { try db.save([self.daily()], progression: reset, batchID: "reset") }
        var missing = reward; missing.state.revision = 2; missing.awards = []; missing.state.lifetimeScore.time += 1
        #expect(throws: (any Error).self) { try db.save([self.daily()], progression: missing, batchID: "missing") }
        #expect(try db.query(since: "0000").isEmpty)
        #expect(try db.loadRewardState() == reward.state)
        try execute("UPDATE reward_checkpoint SET state_json='{}'", at: url)
        #expect(throws: (any Error).self) { try db.loadRewardState() }
    }

    @Test func futureV6IsRejectedBeforeMutation() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try execute("CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('keep'); PRAGMA user_version=6", at: url)
        let mode = try scalar("PRAGMA journal_mode", at: url)
        #expect(throws: (any Error).self) { try AggregateStore(url: url, now: self.base, timeZone: self.utc) }
        #expect(try scalar("PRAGMA user_version", at: url) == "6")
        #expect(try scalar("PRAGMA journal_mode", at: url) == mode)
        #expect(try scalar("SELECT value FROM future_data", at: url) == "keep")
    }
}
