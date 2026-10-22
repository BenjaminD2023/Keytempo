import Foundation
import TypingCore
import TypingStore

let args = CommandLine.arguments
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
