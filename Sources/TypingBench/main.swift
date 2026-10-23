import Foundation
import TypingCore
import TypingStore

private struct RewardBenchmarkResult {
    var elapsed: Double
    var activity: RhythmTotals
    var measuredKeys: Int
    var measuredSeconds: Double
    var rewardWrite: RewardWrite?
    var checkpoints: Int
    var peakDays: Int
    var peakBlocks: Int
    var peakTracks: Int
    var peakPendingAwards: Int
}
private enum RewardBenchmarkError: Error {
    case invalidArguments, pipelineMismatch, rewardFailure
}
private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
    lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= max(1, max(abs(lhs), abs(rhs))) * 1e-9
}

/// Thirty completed calendar days, five compatible non-app contexts per day.
/// Each context supplies forty accepted keys; this deliberately exercises
/// retained day/context validation without inventing qualifying improvement
/// days. Seed construction and restart restoration are outside timed loops.
private func rewardHistorySeed() throws -> RewardState {
    let zone = TimeZone(secondsFromGMT: 0)!
    let measuredStart = Date(timeIntervalSince1970: 1_792_843_200)
    let first = measuredStart.addingTimeInterval(-30 * 86400)
    var rewards = RewardEngine(coverageStart: first, progressionTimeZone: zone)
    var measurement = StatisticsEngine(timeZone: zone), tracker = ActivityTracker(timeZone: zone)
    for day in 0..<30 {
        for source in 0..<5 {
            measurement.interrupt()
            let context = ImprovementContext(language: "en", inputMethod: "bench-history-\(source)",
                                             measurementPolicy: measurement.config.ruleID, evidencePolicy: "global-probable-v1")
            for index in 0..<40 {
                let time = Double(day * 86400 + source * 60) + Double(index) * 0.2
                let event = ClassifiedInput(time: time, date: first.addingTimeInterval(time), context: UInt64(source + 1),
                                            category: .textEntry, evidence: .probable, source: .global, language: "en",
                                            inputMethodID: "bench-history-\(source)", usesInputMethod: false)
                let result = measurement.recordWithIntervals(event)
                _ = tracker.record(input: event, result: result, rule: measurement.config.ruleID)
                rewards.record(input: event, result: result, context: context, sessionID: tracker.currentSession?.id,
                               pendingIntervalCount: measurement.pendingProbableIntervals)
            }
            rewards.interrupt(at: first.addingTimeInterval(Double(day * 86400 + source * 60) + 7.8), reason: "seed-context")
        }
        let nextDay = first.addingTimeInterval(Double((day + 1) * 86400))
        rewards.advance(to: nextDay)
        _ = rewards.checkpoint(at: nextDay)
        guard rewards.error == nil, rewards.state.isValid else { throw RewardBenchmarkError.rewardFailure }
    }
    guard rewards.state.xpProgress.eligibleKeys == 6000,
          approximatelyEqual(rewards.state.xpProgress.eligibleSeconds, 1170),
          rewards.state.days.count == 30, rewards.state.days.values.reduce(0, { $0 + $1.contexts.count }) == 145,
          rewards.state.improvement.tracks.count == 5, rewards.unpersistedAwards.isEmpty else {
        throw RewardBenchmarkError.pipelineMismatch
    }
    return rewards.state
}

/// Already-classified synthetic global operations only. No input is posted,
/// no monitor starts, and this mode never opens a database or writes a file.
@inline(never) private func rewardPipeline(events count: Int, rewardsEnabled: Bool, history: RewardState? = nil) throws -> RewardBenchmarkResult {
    let zone = TimeZone(secondsFromGMT: 0)!
    let base = Date(timeIntervalSince1970: 1_792_843_200)
    var measurement = StatisticsEngine(timeZone: zone), tracker = ActivityTracker(timeZone: zone)
    var rewards: RewardEngine?
    if rewardsEnabled {
        if let history { rewards = try RewardEngine(restoring: history, now: base) }
        else { rewards = RewardEngine(coverageStart: base, progressionTimeZone: zone) }
    }
    let startingKeys = rewards?.state.xpProgress.eligibleKeys ?? 0
    let startingSeconds = rewards?.state.xpProgress.eligibleSeconds ?? 0
    let context = ImprovementContext(language: "en", inputMethod: "bench-direct", measurementPolicy: measurement.config.ruleID,
                                     evidencePolicy: "global-probable-v1")
    var totals = RhythmTotals(), lastWrite: RewardWrite?
    var checkpoints = 0, peakDays = 0, peakBlocks = 0, peakTracks = 0, peakAwards = 0
    func observe(_ engine: RewardEngine) {
        peakDays = max(peakDays, engine.state.days.count)
        peakBlocks = max(peakBlocks, engine.state.blocks.count)
        peakTracks = max(peakTracks, engine.state.improvement.tracks.count)
        peakAwards = max(peakAwards, engine.unpersistedAwards.count)
    }
    let start = ProcessInfo.processInfo.systemUptime
    for index in 0..<count {
        let time = Double(index) * 0.2, date = base.addingTimeInterval(time)
        let input = ClassifiedInput(time: time, date: date, context: 1, category: .textEntry, evidence: .probable,
                                    source: .global, language: "en", inputMethodID: "bench-direct", usesInputMethod: false)
        let result = measurement.recordWithIntervals(input)
        let activity = tracker.record(input: input, result: result, rule: measurement.config.ruleID)
        for row in activity.hourly where row.applicationID.isEmpty { totals.merge(row.totals) }
        if rewardsEnabled {
            rewards?.record(input: input, result: result, context: context, sessionID: tracker.currentSession?.id,
                            pendingIntervalCount: measurement.pendingProbableIntervals)
            if (index + 1).isMultiple(of: 150) {
                if let rewards { observe(rewards) }
                lastWrite = rewards?.checkpoint(at: date); checkpoints += 1
            }
        }
    }
    if rewardsEnabled {
        if let rewards { observe(rewards) }
        if !count.isMultiple(of: 150) {
            lastWrite = rewards?.checkpoint(at: base.addingTimeInterval(Double(count - 1) * 0.2)); checkpoints += 1
        }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let snapshot = measurement.snapshot(now: Double(count - 1) * 0.2)
    guard snapshot.probable.keys == totals.keys, approximatelyEqual(snapshot.probable.seconds, totals.seconds) else {
        throw RewardBenchmarkError.pipelineMismatch
    }
    if let rewards {
        guard rewards.error == nil, rewards.state.isValid else { throw RewardBenchmarkError.rewardFailure }
        guard rewards.state.xpProgress.eligibleKeys - startingKeys == totals.keys,
              approximatelyEqual(rewards.state.xpProgress.eligibleSeconds - startingSeconds, totals.seconds) else { throw RewardBenchmarkError.pipelineMismatch }
    }
    return RewardBenchmarkResult(elapsed: elapsed, activity: totals, measuredKeys: snapshot.probable.keys,
                                 measuredSeconds: snapshot.probable.seconds, rewardWrite: lastWrite, checkpoints: checkpoints,
                                 peakDays: peakDays, peakBlocks: peakBlocks, peakTracks: peakTracks, peakPendingAwards: peakAwards)
}
private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted(), middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
private func rewardBenchmark(_ arguments: [String]) throws {
    let positional = arguments.filter { $0 != "--json" && $0 != "--history" }
    guard positional.count <= 2,
          positional.first == nil || Int(positional[0]) != nil,
          positional.count < 2 || Int(positional[1]) != nil else { throw RewardBenchmarkError.invalidArguments }
    let count = positional.first.flatMap(Int.init) ?? 50_000
    let repeats = positional.dropFirst().first.flatMap(Int.init) ?? 3
    guard (1...5_000_000).contains(count), (1...20).contains(repeats) else { throw RewardBenchmarkError.invalidArguments }
    let history = arguments.contains("--history") ? try rewardHistorySeed() : nil
    let warmup = min(count, 2000)
    _ = try rewardPipeline(events: warmup, rewardsEnabled: false, history: history)
    _ = try rewardPipeline(events: warmup, rewardsEnabled: true, history: history)
    var baseline: [Double] = [], modified: [Double] = [], last: RewardBenchmarkResult?
    print("rewards_benchmark=synthetic_global_probable events=\(count) repeats=\(repeats) warmup_events=\(warmup) interval_seconds=0.2 checkpoint_keys=150 persistence=none history_seed_events=\(history == nil ? 0 : 6000) history_seed_completed_days=\(history == nil ? 0 : 30) history_contexts_per_day=\(history == nil ? 0 : 5) seed_time_in_pipeline=false")
    for repeatIndex in 0..<repeats {
        let before: RewardBenchmarkResult, after: RewardBenchmarkResult
        // Alternate order to reduce a systematic warmup/thermal ordering bias.
        if repeatIndex.isMultiple(of: 2) {
            before = try rewardPipeline(events: count, rewardsEnabled: false, history: history)
            after = try rewardPipeline(events: count, rewardsEnabled: true, history: history)
        } else {
            after = try rewardPipeline(events: count, rewardsEnabled: true, history: history)
            before = try rewardPipeline(events: count, rewardsEnabled: false, history: history)
        }
        guard before.measuredKeys == after.measuredKeys, before.activity.keys == after.activity.keys,
              approximatelyEqual(before.measuredSeconds, after.measuredSeconds),
              approximatelyEqual(before.activity.intervals, after.activity.intervals) else { throw RewardBenchmarkError.pipelineMismatch }
        baseline.append(before.elapsed); modified.append(after.elapsed); last = after
        print("repeat=\(repeatIndex + 1) baseline_seconds=\(before.elapsed) rewards_seconds=\(after.elapsed) baseline_us_per_event=\(before.elapsed / Double(count) * 1e6) rewards_us_per_event=\(after.elapsed / Double(count) * 1e6) parity=pass")
    }
    let before = median(baseline), after = median(modified), delta = after - before
    print("median_baseline_seconds=\(before) median_rewards_seconds=\(after) delta_seconds=\(delta) delta_us_per_event=\(delta / Double(count) * 1e6) overhead_percent=\(100 * delta / before)")
    if let last, let write = last.rewardWrite {
        let contexts = write.state.days.values.reduce(0) { $0 + $1.contexts.count }
        print("accepted_keys=\(last.measuredKeys) observed_seconds=\(last.measuredSeconds) checkpoints=\(last.checkpoints) state_days=\(write.state.days.count) state_day_contexts=\(contexts) state_blocks=\(write.state.blocks.count) state_tracks=\(write.state.improvement.tracks.count) progression_lifetime_keys=\(write.state.xpProgress.eligibleKeys) progression_lifetime_seconds=\(write.state.xpProgress.eligibleSeconds) unpersisted_awards_after_checkpoint=0 peak_checkpoint_days=\(last.peakDays) peak_checkpoint_blocks=\(last.peakBlocks) peak_checkpoint_tracks=\(last.peakTracks) peak_checkpoint_pending_awards=\(last.peakPendingAwards)")
        if arguments.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            _ = try encoder.encode(write.state)
            let start = ProcessInfo.processInfo.systemUptime
            var bytes = 0
            for _ in 0..<100 { bytes = try encoder.encode(write.state).count }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print("checkpoint_json_bytes=\(bytes) json_iterations=100 mean_json_encode_ms=\(elapsed * 10) json_time_in_pipeline=false")
        }
    }
}

let args = CommandLine.arguments
if args.dropFirst().first == "--rewards" {
    do { try rewardBenchmark(Array(args.dropFirst(2))); exit(0) }
    catch {
        fputs("rewards benchmark failed: \(error)\nusage: TypingBench --rewards [event-count=50000] [repeats=3] [--json] [--history]\n", stderr)
        exit(1)
    }
}
let count = args.dropFirst().first.flatMap(Int.init) ?? 100_000
let wall = Date()
var engine = StatisticsEngine()
let start = ProcessInfo.processInfo.systemUptime
var deltaCount = 0
for i in 0..<count {
    let t = Double(i) * 0.2
    deltaCount += engine.record(ClassifiedInput(time: t, date: wall.addingTimeInterval(t), context: 1, category: .textEntry, evidence: .confirmed, source: .adapter)).count
}
let elapsed = ProcessInfo.processInfo.systemUptime - start
let snapshot = engine.snapshot(now: Double(count) * 0.2)
print("core_events=\(count) wall_seconds=\(elapsed) microseconds_per_event=\(elapsed / Double(count) * 1_000_000) keys=\(snapshot.confirmed.keys) intervals=\(snapshot.confirmed.intervals) rhythm_kpm=\(snapshot.confirmed.rawKPM ?? 0) samples=\(snapshot.sampleCount) delta_rows=\(deltaCount)")
let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-bench-\(UUID().uuidString)").appendingPathComponent("bench.sqlite")
do {
    let store = try AggregateStore(url: url)
    var rows: [StoredAggregate] = []
    for day in 0..<1826 {
        let date = Calendar.current.date(byAdding: .day, value: -day, to: Date())!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var row = StoredAggregate(day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), timezone: "Asia/Shanghai", rule: "adaptive-v1-max3.0", evidence: "probable")
        row.keys = 5000; row.intervals = 4500; row.seconds = 1500; rows.append(row)
    }
    let before = ProcessInfo.processInfo.systemUptime
    try store.save(rows)
    let written = ProcessInfo.processInfo.systemUptime
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    let c = Calendar.current.dateComponents([.year, .month, .day], from: cutoffDate)
    let cutoff = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    var found = 0
    for _ in 0..<100 { found = try store.query(since: cutoff).count }
    let queried = ProcessInfo.processInfo.systemUptime
    print("history_rows=\(rows.count) transaction_ms=\((written-before)*1000) query_30day_rows=\(found) mean_query_ms=\((queried-written)*10)")
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
} catch { fputs("benchmark failed: \(error)\n", stderr); exit(1) }
