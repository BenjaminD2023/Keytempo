import SwiftUI
import Charts
import TypingCore

/// Descriptive comparisons use completed days, independently of XP milestones.
struct TypingProgressView: View {
    let days: [ActivityScoreDay]
    let selectedDate: Date

    private var progress: TypingProgress {
        // Match the coordinator's bounded query. An early trend must not
        // omit older activity that was outside the loaded calendar range.
        let calendar = Calendar.current
        let historyStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: selectedDate))
        return TypingProgress.analyze(days: days.map { .init(date: $0.day, totals: $0.totals, rules: $0.rules) },
                                      through: selectedDate, historyStart: historyStart)
    }

    var body: some View {
        let result = progress
        VStack(alignment: .leading, spacing: 14) {
            Label(L("进步趋势"), systemImage: "chart.line.uptrend.xyaxis").font(.headline)
            Text(L("比较最近两个完整的 7 天，分开观察速度、稳定度与练习量。今天尚未完成的数据不参与比较。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            comparison(result)
            if result.speedReadiness != .ready || result.consistencyReadiness != .ready {
                Text(readinessText(result)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 24) {
                trend(result, consistency: false)
                trend(result, consistency: true)
            }
            HStack(spacing: 18) {
                Label(L("单日"), systemImage: "circle.fill").font(.caption)
                HStack(spacing: 5) {
                    Rectangle().frame(width: 18, height: 2)
                    Text(L("7 天加权趋势"))
                }.font(.caption)
                Spacer(minLength: 0)
                Text(L("悬停图表查看精确值")).font(.caption)
            }.foregroundStyle(.secondary)
            if result.speedReadiness == .ready || result.consistencyReadiness == .ready {
                Text(L("虚线表示前 7 天的加权基准。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("每段至少需要 3 个合格日、合计 5 分钟；合格日需 30 秒、20 个间隔。速度按实测时长加权，稳定度使用完整秒样本。缺失日不按零速填充；不同计数方式不比较。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private func comparison(_ result: TypingProgress) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
            GridRow(alignment: .top) {
                Text(L("指标")).foregroundStyle(.secondary)
                periodHeading(L("前 7 天"), period: result.previous)
                periodHeading(L("最近 7 天"), period: result.recent)
                Text(L("变化")).foregroundStyle(.secondary)
            }.font(.caption.weight(.medium))
            Divider().gridCellColumns(4)
            GridRow {
                Text(L("估算速度"))
                Text(chartExactValue(result.previous.wpm) + " WPM")
                Text(chartExactValue(result.recent.wpm) + " WPM")
                VStack(alignment: .leading, spacing: 3) {
                    Text(signed(result.speedChangePercent, suffix: "%"))
                        .fontWeight(.semibold)
                    if let delta = result.speedChangeWPM {
                        Text(signed(delta, suffix: " WPM")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text(L("每秒稳定度"))
                Text(chartExactValue(result.previous.consistency) + " / 100")
                Text(chartExactValue(result.recent.consistency) + " / 100")
                Text(result.consistencyChangePoints.map { L("%@ 点", signed($0)) } ?? "—")
                    .fontWeight(.semibold)
            }
            GridRow {
                Text(L("实际打字时长"))
                Text(duration(result.previous.totals.seconds))
                Text(duration(result.recent.totals.seconds))
                Text(signedPercent(result.recent.totals.seconds, from: result.previous.totals.seconds))
            }
            GridRow {
                Text(L("敲键数量"))
                Text(result.previous.totals.keys.formatted(.number.locale(AppLanguage.currentLocale)))
                Text(result.recent.totals.keys.formatted(.number.locale(AppLanguage.currentLocale)))
                Text(signedPercent(Double(result.recent.totals.keys), from: Double(result.previous.totals.keys)))
            }
            GridRow {
                Text(L("活跃日"))
                Text("\(result.previous.activeDays) / 7")
                Text("\(result.recent.activeDays) / 7")
                Text(L("%@ 天", signed(Double(result.recent.activeDays - result.previous.activeDays), precision: 0)))
            }
            GridRow(alignment: .top) {
                Text(L("比较样本")).foregroundStyle(.secondary)
                evidence(result.previous)
                evidence(result.recent)
                Color.clear.frame(width: 1, height: 1)
            }.font(.caption).foregroundStyle(.secondary)
        }.font(.callout).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }

    private func periodHeading(_ title: String, period: TypingProgressPeriod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.primary)
            Text(periodLabel(period)).foregroundStyle(.secondary)
        }
    }

    private func evidence(_ period: TypingProgressPeriod) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("%d 日 · %.1f 分钟", period.qualifyingDays, period.rateTotals.seconds / 60))
            Text(L("%@ 秒样本", period.consistencySampleSeconds.formatted(.number.locale(AppLanguage.currentLocale))))
        }
    }

    private func readinessText(_ result: TypingProgress) -> String {
        if result.speedReadiness == .invalidData || result.consistencyReadiness == .invalidData {
            return L("部分汇总无效，暂不显示进步比较。")
        }
        if result.speedReadiness == .incompatibleRules || result.consistencyReadiness == .incompatibleRules {
            return L("这两个时段使用了不同的计数方式；继续积累相同方式的记录后再比较。")
        }
        if result.speedReadiness == .ready {
            return L("速度已可比较；稳定度还需要每段至少 3 日的完整秒样本。")
        }
        return L("正在建立基线。每段达到 3 个合格日、合计 5 分钟后显示速度变化；练习量始终单独展示。")
    }

    private func trend(_ result: TypingProgress, consistency: Bool) -> some View {
        let label = consistency ? L("每秒稳定度") : L("估算速度")
        let daily = result.dailyData.filter { consistency ? $0.consistency != nil : $0.wpm != nil }
        let samples = result.trend.filter { !consistency || $0.consistency != nil }
        let groups = trendGroups(samples)
        let baseline = consistency ? result.previous.consistency : result.previous.wpm
        let comparable = consistency ? result.consistencyReadiness == .ready : result.speedReadiness == .ready
        let color: Color = consistency ? .teal : .orange
        return VStack(alignment: .leading, spacing: 8) {
            Text(consistency ? L("每秒稳定度") : L("平均速度（估算 WPM）")).font(.callout.weight(.medium))
            if daily.isEmpty {
                Text(L("还没有足够的完整日样本"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 145)
            } else {
                Chart {
                    ForEach(daily) { day in
                        if let value = consistency ? day.consistency : day.wpm {
                            PointMark(x: .value(L("日期"), day.date), y: .value(label, value))
                                .foregroundStyle(color.opacity(0.5)).symbolSize(24)
                                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                                .accessibilityValue(chartExactValue(value))
                        }
                    }
                    ForEach(samples) { sample in
                        if let value = consistency ? sample.consistency : sample.wpm {
                            LineMark(x: .value(L("日期"), sample.date), y: .value(label, value),
                                     series: .value(L("7 天加权趋势"), groups[sample.date] ?? 0))
                                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value(L("日期"), sample.date), y: .value(label, value))
                                .foregroundStyle(color).symbolSize(12)
                        }
                    }
                    if comparable, let baseline {
                        RuleMark(y: .value(L("前 7 天"), baseline))
                            .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYScale(domain: consistency ? 0...100 : 0...speedCeiling(result))
                .frame(height: 145)
                .accessibilityLabel(label)
                .inspectDateChart(result.dailyData.filter { day in
                    daily.contains { $0.date == day.date } || samples.contains { $0.date == day.date }
                }.map { day in
                    let sample = samples.first { $0.date == day.date }
                    let value = consistency ? day.consistency : day.wpm
                    let smoothed = consistency ? sample?.consistency : sample?.wpm
                    return DateChartInspectionPoint(id: String(day.date.timeIntervalSince1970), date: day.date,
                        title: day.date.formatted(.dateTime.year().month(.abbreviated).day().locale(AppLanguage.currentLocale)),
                        details: [L("单日：%@", chartExactValue(value) + (consistency ? " / 100" : " WPM")),
                                  L("7 天加权趋势：%@", chartExactValue(smoothed) + (consistency ? " / 100" : " WPM")),
                                  L("%@ 次敲键", day.totals.keys.formatted(.number.locale(AppLanguage.currentLocale))),
                                  L("打字时长：%@ 秒", chartExactValue(day.totals.seconds))])
                })
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendGroups(_ samples: [TypingProgressTrendSample]) -> [Date: Int] {
        var groups: [Date: Int] = [:], group = 0
        var previous: TypingProgressTrendSample?
        for sample in samples {
            if let previous, Calendar.current.date(byAdding: .day, value: 1, to: previous.date) != sample.date || previous.period.rules != sample.period.rules { group += 1 }
            groups[sample.date] = group; previous = sample
        }
        return groups
    }

    private func speedCeiling(_ result: TypingProgress) -> Double {
        let values = result.dailyData.compactMap(\.wpm) + result.trend.map(\.wpm)
        return max(10, (values.max() ?? 100) * 1.12)
    }

    private func signed(_ value: Double?, suffix: String = "", precision: Int = 2) -> String {
        guard let value, value.isFinite else { return "—" }
        let threshold = 0.5 * pow(10, -Double(precision))
        let rounded = abs(value) < threshold ? 0 : value
        return (rounded > 0 ? "+" : "") + rounded.formatted(.number.precision(.fractionLength(precision)).locale(AppLanguage.currentLocale)) + suffix
    }
    private func signedPercent(_ value: Double, from previous: Double) -> String {
        previous > 0 ? signed(100 * (value - previous) / previous, suffix: "%", precision: 1) : "—"
    }
    private func duration(_ seconds: Double) -> String {
        L("%.1f 分钟", seconds / 60)
    }
    private func periodLabel(_ period: TypingProgressPeriod) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: period.end) ?? period.start
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(AppLanguage.currentLocale)
        return "\(period.start.formatted(format)) – \(last.formatted(format))"
    }
}
