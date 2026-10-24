import SwiftUI
import Charts
import TypingCore

private typealias ActivityViewState<Value> = SwiftUI.State<Value>

private func activityValue(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0)))
}

private func activityDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return L("0 秒") }
    if seconds < 60 { return L("%.1f 秒", seconds) }
    if seconds < 3600 { return L("%d 分 %d 秒", Int(seconds) / 60, Int(seconds) % 60) }
    return L("%d 小时 %d 分", Int(seconds) / 3600, Int(seconds) % 3600 / 60)
}

private func mergedActivity(_ rows: [HourlyActivity]) -> RhythmTotals {
    rows.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
}

private struct ActivityHour: Identifiable {
    let start: Date
    let end: Date
    let timezone: String
    let rows: [HourlyActivity]
    var id: String { "\(start.timeIntervalSince1970)|\(timezone)" }
    var totals: RhythmTotals { mergedActivity(rows) }
    var compatible: Bool { Set(rows.map(\.rule)).count == 1 }
    var label: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.currentLocale
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = "HH:mm z"
        return formatter.string(from: start)
    }
}

private func activityTime(_ date: Date, timezone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.currentLocale
    formatter.timeZone = TimeZone(identifier: timezone) ?? .current
    formatter.dateFormat = "HH:mm z"
    return formatter.string(from: date)
}

private struct ActivityApp: Identifiable {
    let id: String
    let rows: [HourlyActivity]
    var totals: RhythmTotals { mergedActivity(rows) }
    var compatible: Bool { Set(rows.map(\.rule)).count == 1 }
}

/// Reads only aggregate metadata loaded by the coordinator. Charts do not
/// query SQLite, and never retain an input event or input content.
struct ActivityView: View {
    @ObservedObject var model: AppModel
    @ActivityViewState private var confirmClearApps = false

    private var combinedRows: [HourlyActivity] { model.activityHourly.filter { $0.applicationID.isEmpty } }
    private var totals: RhythmTotals { mergedActivity(combinedRows) }
    private var rateRows: [HourlyActivity] {
        Set(combinedRows.map(\.rule)).count > 1
            ? combinedRows.filter { $0.rule == model.activityCurrentRule } : combinedRows
    }
    private var rateTotals: RhythmTotals { mergedActivity(rateRows) }
    private var partialRates: Bool { rateRows.count != combinedRows.count }
    private var hours: [ActivityHour] {
        Dictionary(grouping: combinedRows, by: { "\($0.bucketStart.timeIntervalSince1970)|\($0.timezone)" })
            .values.compactMap { rows in
                guard let first = rows.first else { return nil }
                return ActivityHour(start: first.bucketStart, end: first.bucketEnd, timezone: first.timezone, rows: rows)
            }.sorted { $0.start < $1.start }
    }
    private var applications: [ActivityApp] {
        Dictionary(grouping: model.activityHourly.filter { !$0.applicationID.isEmpty }, by: \.applicationID)
            .map { ActivityApp(id: $0.key, rows: $0.value) }
            .sorted { $0.totals.keys > $1.totals.keys }
    }
    private var selectedDayRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: model.activityDate)
        return start...(calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
    }

    private var scoreDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let last = calendar.startOfDay(for: model.activityDate)
        let first = calendar.date(byAdding: .day, value: -29, to: last) ?? last
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400)
        return first...end
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.activityActionError {
                    Label(L(error), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = model.activityError {
                    HStack {
                        Label(L(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button(L("重试加载")) { model.loadActivity(day: model.activityDate) }
                    }.font(.callout)
                }
                if model.activityLoading && model.activityHourly.isEmpty {
                    ProgressView(L("正在加载活动…")).frame(maxWidth: .infinity, minHeight: 180)
                } else if model.activityError == nil {
                    RewardDashboard(model: model)
                    summary
                    RewardDetails(model: model)
                    hourlyTimeline
                    sessions
                    appBreakdown
                    RewardHistory(model: model)
                    DisclosureGroup(L("旧版评分（practice-v1，满分 100）")) { legacyScoreHistory }
                }
                Text(L("活动详情从 0.4.0 开始记录；旧版每日汇总不会被补造成小时或会话。这里只统计全局估算输入，验证输入区不计入。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let since = model.activityCoverageStart {
                    Text(L("最早活动记录：%@", since.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
        }
        .onAppear { model.activityVisible = true; model.loadActivity(day: model.activityDate) }
        .onDisappear { model.releaseActivity() }
        .confirmationDialog(L("清除应用活动明细？"), isPresented: $confirmClearApps, titleVisibility: .visible) {
            Button(L("清除应用活动明细"), role: .destructive, action: model.clearAppActivity)
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("仅删除按应用保存的统计；合并统计与会话保留。此操作无法撤销。"))
        }
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("输入活动")).font(.title2.weight(.semibold))
                Text(L("查看何时输入、练习多少，以及节奏是否稳定。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            DatePicker(L("活动日期"), selection: Binding(get: { model.activityDate }, set: { model.loadActivity(day: $0) }),
                       in: (Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? .distantPast)...Date(),
                       displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact).fixedSize()
                .accessibilityLabel(L("活动日期"))
            Button(L("今天")) { model.loadActivity(day: Date()) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                ActivityMetric(label: L("平均速度（估算 WPM）"), value: rateTotals.wpm.map { "≈\(activityValue($0)) WPM" } ?? "— WPM")
                Divider().frame(height: 50)
                ActivityMetric(label: L("每秒节奏稳定度"), value: activityValue(rateTotals.consistency) + " / 100",
                               detail: L("%@ 秒样本", rateTotals.rateConsistency.count.formatted()))
                    .help(L("%@ 个完整一秒样本 · %@ 个已接受间隔", rateTotals.rateConsistency.count.formatted(), rateTotals.rateConsistency.intervals.formatted()))
                Divider().frame(height: 50)
                ActivityMetric(label: L("实际打字时长"), value: activityDuration(totals.seconds))
                Divider().frame(height: 50)
                ActivityMetric(label: L("敲键数量"), value: compactKeystrokeCount(totals.keys))
                    .help(totals.keys.formatted())
            }
            if partialRates {
                Text(L("速度与稳定度使用当前计数方式；敲键数量与时长包含全部记录。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hourlyTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("小时活动时间线"), systemImage: "clock").font(.headline)
            if hours.isEmpty {
                ActivityEmptyState(title: L("这一天还没有活动详情"), detail: L("正常输入后会记录小时汇总；尚未记录的过去不会补造数据。"))
            } else {
                Chart(hours) { hour in
                    RectangleMark(xStart: .value(L("小时"), hour.start), xEnd: .value(L("小时"), hour.end),
                                  yStart: .value(L("敲键数量"), 0), yEnd: .value(L("敲键数量"), hour.totals.keys))
                        .foregroundStyle(Color.orange)
                }
                .chartXScale(domain: selectedDayRange)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) }
                .chartYAxisLabel(L("敲键数量"))
                .frame(height: 165)
                .accessibilityLabel(L("所选日期的小时敲键时间线"))
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        GridRow {
                            Text(L("小时")); Text(L("敲键数量")); Text(L("实际打字时长")); Text(L("平均速度（估算 WPM）"))
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(hours) { hour in
                            GridRow {
                                Text(hour.label)
                                Text(compactKeystrokeCount(hour.totals.keys))
                                Text(activityDuration(hour.totals.seconds))
                                Text(activityValue(hour.compatible ? hour.totals.wpm : nil))
                            }.font(.callout).monospacedDigit()
                        }
                    }.padding(.vertical, 4)
                }
                Text(L("空白小时表示没有记录。跨小时的已接受间隔按实际覆盖比例分配，速度按间隔总数与总时长加权；混合计数方式的小时不显示速度。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("输入会话"), systemImage: "rectangle.stack").font(.headline)
            Text(L("连续五分钟没有接受到输入，或暂停、睡眠、退出、跨日等边界，会结束一个会话。会话经过时间与实际打字时长分别展示。"))
                .font(.caption).foregroundStyle(.secondary)
            if model.activitySessions.isEmpty {
                ActivityEmptyState(title: L("这一天还没有输入会话"), detail: L("单次敲键保留数量；速度与每日分数需要更多样本。"))
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 11) {
                        GridRow {
                            Text(L("开始 — 最后输入")); Text(L("经过时间")); Text(L("实际打字时长")); Text(L("敲键数量")); Text("WPM"); Text(L("每秒稳定度"))
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(model.activitySessions.sorted { $0.start > $1.start }.prefix(200))) { session in
                            GridRow {
                                Text("\(activityTime(session.start, timezone: session.timezone)) — \(activityTime(session.end, timezone: session.timezone))")
                                Text(activityDuration(max(0, session.end.timeIntervalSince(session.start))))
                                Text(activityDuration(session.totals.seconds))
                                Text(compactKeystrokeCount(session.totals.keys))
                                Text(activityValue(session.totals.wpm))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(activityValue(session.totals.consistency))
                                    Text(L("%@ 秒样本", session.totals.rateConsistency.count.formatted()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .help(L("%@ 个完整一秒样本 · %@ 个已接受间隔", session.totals.rateConsistency.count.formatted(), session.totals.rateConsistency.intervals.formatted()))
                            }.font(.callout).monospacedDigit()
                        }
                    }.padding(.vertical, 4)
                }
                if model.activitySessions.count > 200 {
                    Text(L("显示最近 200 个会话，共 %@ 个；小时汇总仍包含完整已加载活动。", model.activitySessions.count.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("按应用查看"), systemImage: "app.dashed").font(.headline)
                Spacer()
                Toggle(L("按应用记录活动"), isOn: Binding(get: { model.perAppTrackingEnabled }, set: model.setPerAppTracking))
                    .toggleStyle(.switch).fixedSize()
            }
            Text(L("默认关闭。开启后仅在本机保存应用标识符与统计汇总，不保存窗口标题、网址或输入内容。关闭后停止新增；已保存的应用明细可单独清除。"))
                .font(.caption).foregroundStyle(.secondary)
            if !model.perAppTrackingEnabled {
                Text(L("应用明细记录已关闭")).font(.callout).foregroundStyle(.secondary)
            } else if applications.isEmpty {
                Text(L("开启后记录的应用活动会显示在这里。")).font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    Text(L("应用")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("敲键数量")).frame(minWidth: 65, alignment: .trailing)
                    Text(L("打字时长")).frame(minWidth: 85, alignment: .trailing)
                    Text("WPM").frame(minWidth: 85, alignment: .trailing)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(applications) { application in
                    HStack(spacing: 18) {
                        Text(model.activityAppName(application.id)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(compactKeystrokeCount(application.totals.keys)).frame(minWidth: 65, alignment: .trailing)
                        Text(activityDuration(application.totals.seconds)).frame(minWidth: 85, alignment: .trailing)
                        Text(activityValue(application.compatible ? application.totals.wpm : nil) + " WPM").frame(minWidth: 85, alignment: .trailing)
                    }.font(.callout).monospacedDigit()
                }
                Text(L("仅包含开启后记录的应用活动；混合计数方式的应用不显示速度。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("清除应用活动明细…"), role: .destructive) { confirmClearApps = true }
                .font(.callout)
        }
    }

    private var legacyScoreHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("近 30 天练习评分"), systemImage: "chart.bar.xaxis").font(.headline)
            Text(L("截止所选日期；仅显示样本足够且计数方式一致的日期，不补造缺失天数。"))
                .font(.caption).foregroundStyle(.secondary)
            if model.activityScoreDays.contains(where: { !$0.hasMixedRules && $0.totals.score != nil }) {
                Chart(model.activityScoreDays) { day in
                    if !day.hasMixedRules, let score = day.totals.score {
                        RectangleMark(xStart: .value(L("日期"), day.day),
                                xEnd: .value(L("日期"), Calendar.current.date(byAdding: .day, value: 1, to: day.day) ?? day.day.addingTimeInterval(86400)),
                                      yStart: .value(L("评分"), 0.0), yEnd: .value(L("评分"), score.value))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXScale(domain: scoreDateRange)
                .chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .frame(height: 175)
                .accessibilityLabel(L("每日练习评分趋势，满分一百分"))
            } else {
                Text(L("记录更多输入后，这里会显示每日评分趋势。")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActivityMetric: View {
    let label: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ScoreComponent: View {
    let label: String
    let value: Double?
    let target: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label).fontWeight(.medium)
                Spacer(minLength: 5)
                Text(activityValue(value)).monospacedDigit()
            }.font(.callout)
            ProgressView(value: value ?? 0, total: 100).tint(color)
                .accessibilityLabel(label).accessibilityValue(value.map { "\(activityValue($0)) / 100" } ?? L("数据不足"))
            Text(L("占比 25%") + " · " + target).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityEmptyState: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
