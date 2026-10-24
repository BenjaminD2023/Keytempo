import SwiftUI
import Charts
import TypingCore
import TypingStore

func rewardPointText(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return value.formatted(.number.precision(.fractionLength(1)))
}
func exactXPThreshold(_ value: Int) -> String {
    value > 0 && value.isMultiple(of: 1_000) ? "\(value / 1_000)k" : value.formatted()
}
private func dailyScoreText(_ value: Int?) -> String { value?.formatted() ?? "—" }

enum RewardAccent: Equatable {
    case score, xp
    func color(for scheme: ColorScheme) -> Color {
        switch (self, scheme) {
        case (.score, .dark): return Color(red: 0.48, green: 0.88, blue: 0.79)
        case (.score, _): return Color(red: 0.04, green: 0.42, blue: 0.39)
        case (.xp, .dark): return Color(red: 0.95, green: 0.79, blue: 0.46)
        case (.xp, _): return Color(red: 0.58, green: 0.37, blue: 0.07)
        }
    }
}

struct RewardMenuSummary: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let state = model.dailyRewardState, let level = DailyLevelProgress(totalXP: state.totalXP) {
            let today = state.days[state.currentDay]
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("今日练习积分")).font(.caption).foregroundStyle(.secondary)
                        Text(dailyScoreText(today?.score)).font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(RewardAccent.score.color(for: scheme)).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("预计结算 XP")).font(.caption).foregroundStyle(.secondary)
                        Text(today?.score.map { "+" + $0.formatted() } ?? "—").font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(RewardAccent.xp.color(for: scheme)).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Button(action: model.showAppearance) {
                    HStack(spacing: 6) {
                        Text(L("等级 %@", level.level.formatted())).fontWeight(.medium)
                        Spacer(minLength: 8)
                        Text(L("累计 %@ XP", state.totalXP.formatted())).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }.font(.caption).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("等级与外观…"))
            }.monospacedDigit().padding(13)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Temporary selected-day estimates are never added to the lifetime balance.
struct RewardDashboard: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    private var selected: DailyRewardDay? { model.selectedDailyRewardDay }
    private var receipt: DailySettlementReceipt? {
        model.dailySettlements.first { $0.day == model.rewardDayKey(model.activityDate) }
    }
    private var scoreStatus: String {
        guard let selected else { return L("尚未覆盖") }
        if receipt != nil { return L("已结算") }
        if selected.sealed { return L("待结算") }
        return selected.preliminary ? L("初步估算") : L("当日暂定")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.dailyRewardError {
                Label(L(error), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if model.dailyRewardState != nil {
                HStack(alignment: .top, spacing: 0) {
                    RewardCard(title: L("练习积分"), status: scoreStatus, symbol: "waveform.path", accent: .score) {
                        largeValue(dailyScoreText(selected?.score), accent: .score)
                        Spacer(minLength: 5)
                        if selected?.score == nil {
                            Text(selected == nil ? L("尚未覆盖") : L("数据不足"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1).padding(.vertical, 20)
                    RewardCard(title: receipt == nil ? L("预计结算 XP") : L("获得 XP"),
                               status: receipt == nil ? L("待入账") : L("已入账"), symbol: "sparkles", accent: .xp) {
                        largeValue(xpText, accent: .xp)
                        Spacer(minLength: 5)
                        xpExplanation
                    }
                }.fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
            } else {
                Text(L("奖励暂不可用，请检查本地存储状态。")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var xpText: String {
        if let receipt { return "+" + (receipt.ordinaryXP + receipt.improvementXP).formatted() }
        return selected?.score.map { "+" + $0.formatted() } ?? "—"
    }
    @ViewBuilder private var xpExplanation: some View {
        if let receipt {
            HStack(spacing: 12) {
                Text(L("当日分数 +%@", receipt.ordinaryXP.formatted()))
                if receipt.improvementXP > 0 { Text(L("进步验证 +%@", receipt.improvementXP.formatted())) }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if selected != nil {
            Text(L("当日分数 1:1 转为 XP")).font(.caption).foregroundStyle(RewardAccent.xp.color(for: colorScheme))
            Label(selected?.sealed == true ? L("等待下一次熄屏或睡眠结算") : L("日界线后，熄屏或睡眠时结算"), systemImage: "moon")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L("尚未覆盖")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func largeValue(_ value: String, accent: RewardAccent) -> some View {
        Text(value).font(.system(size: 46, weight: .semibold)).monospacedDigit()
            .foregroundStyle(accent.color(for: colorScheme)).lineLimit(1).minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
    }
}

private struct RewardCard<Content: View>: View {
    let title: String
    let status: String
    let symbol: String
    let accent: RewardAccent
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    init(title: String, status: String, symbol: String, accent: RewardAccent, @ViewBuilder content: () -> Content) {
        self.title = title; self.status = status; self.symbol = symbol; self.accent = accent; self.content = content()
    }
    var body: some View {
        let tint = accent.color(for: colorScheme)
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer(minLength: 4)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RewardDetails: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let state = model.dailyRewardState {
            VStack(alignment: .leading, spacing: 15) {
                if let level = DailyLevelProgress(totalXP: state.totalXP) { lifetime(state.totalXP, level: level) }
                Label(L("奖励日：%@ · %@", model.rewardDayKey(model.activityDate), state.progressionTimezone), systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L("奖励如何计算？")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Score = 150 × √(minutes + keys / 300) × √(WPM / 50) × exp((C − 75) / 100)").textSelection(.enabled)
                        Text(L("分数使用当日加权估算 WPM、每秒稳定度、实际打字时长与敲键数量。当天暂定值可能升降；等待不增加时长。"))
                        Text(L("最终分数按 1:1 转为 XP，个人进步在已完成日验证后另计。"))
                        Text(L("日界线仍划分统计日期；使用电脑时，昨日冻结待结算，下一次熄屏或睡眠再入账。睡眠跨日时在恢复后补做，不唤醒电脑。"))
                        Text(L("结算只入账一次；跳过动画不影响 XP。未覆盖的旧记录不补造新分数。"))
                        Text(L("旧 XP 与等级门槛同步换算为 150 倍，原有等级保留；换算本身不作为新增奖励。"))
                        Text(L("稳定度使用 Monkeytype 式完整一秒速率样本和 Kogasa 映射；统计覆盖不同，不能直接与 Monkeytype 测试成绩比较。"))
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                calibration
                Button(L("导出每日奖励 CSV…"), action: model.exportDailyRewards)
            }
        }
    }
    private func lifetime(_ total: Int, level: DailyLevelProgress) -> some View {
        HStack(spacing: 14) {
            RankSeal(theme: AppAppearanceStyle.rankTheme(level: level.level), level: level.level, size: 52)
            Text(L("等级 %@", level.level.formatted())).font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L("累计 %@ XP", total.formatted()))
                    Spacer(minLength: 8)
                    Text(L("还需 %@ XP", level.remainingXP.formatted()))
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                LevelProgressTrack(value: Double(level.progressXP) / Double(level.requiredXP), theme: model.effectiveAppearanceTheme)
                Text(L("%@ / %@ XP", level.progressXP.formatted(), level.requiredXP.formatted())).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }.padding(.vertical, 9)
    }
    @ViewBuilder private var calibration: some View {
        if let state = model.rewardState {
            DisclosureGroup(L("个人进步与校准")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L("每个语言／输入法分别校准：5 个已完成活跃日、60 分钟；每个合格日需至少 5 分钟。"))
                    if state.improvement.tracks.isEmpty { Text(L("尚无已完成的合格日。未知输入源不生成进步基线。")) }
                    ForEach(state.improvement.tracks.keys.sorted(), id: \.self) { key in
                        if let track = state.improvement.tracks[key] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(track.context.language.uppercased()) · \(track.context.inputMethod)").fontWeight(.medium).textSelection(.enabled)
                                if track.suspended { Text(L("计量策略已改变；保留原奖励并暂停该轨道的进步奖励。")) }
                                Text(L("速度校准：%@ / 5 日 · %.1f / 60 分钟", track.speedCalibration.qualifyingDays.formatted(), track.speedCalibration.seconds / 60))
                                Text(L("稳定度校准：%@ / 5 日 · %.1f / 60 分钟", track.consistencyCalibration.qualifyingDays.formatted(), track.consistencyCalibration.seconds / 60))
                                Text(L("固定基线：%@ WPM · 稳定度 %@ / 100", rewardPointText(track.speedBaseline), rewardPointText(track.consistencyBaseline)))
                                Text(L("已验证里程碑：速度 %@ · 稳定度 %@；近期合格日 %@ / 7", track.speedMilestone.formatted(), track.consistencyMilestone.formatted(), max(track.speedWindow.count, track.consistencyWindow.count).formatted()))
                            }.padding(.vertical, 4)
                        }
                    }
                    Text(L("进步验证使用最近 7 个合格完成日，至少 3 日、30 分钟；汇总值和至少 3 个单日均须达标。速度每提升 5% 或稳定度每提升 5 点，各奖励 750 XP，退步再恢复不重复领奖。"))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}

struct RewardHistory: View {
    @ObservedObject var model: AppModel
    private struct Day: Identifiable { let id: String; let score: Int?; let pending: Bool }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: model.dailyRewardState?.progressionTimezone ?? "") ?? .current
        return value
    }
    private func date(_ key: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
    private var days: [Day] {
        let end = model.rewardDayKey(model.activityDate)
        let start = model.rewardDayKey(calendar.date(byAdding: .day, value: -29, to: model.activityDate) ?? model.activityDate)
        var rows = Dictionary(uniqueKeysWithValues: model.dailySettlements.map { ($0.day, Day(id: $0.day, score: $0.score, pending: false)) })
        for day in model.dailyRewardState?.days.values ?? Dictionary<String, DailyRewardDay>().values {
            rows[day.day] = Day(id: day.day, score: day.score, pending: true)
        }
        return rows.values.filter { $0.id >= start && $0.id <= end }.sorted { $0.id < $1.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("近 30 天每日练习积分"), systemImage: "chart.bar.xaxis").font(.headline)
            if !days.contains(where: { $0.score != nil }) {
                Text(L("新系统尚无可计算的每日分数。")).font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(days) { day in
                    if let date = date(day.id), let score = day.score {
                        BarMark(x: .value(L("日期"), date, unit: .day), y: .value(L("练习积分"), score))
                            .foregroundStyle(Color.teal.opacity(day.pending ? 0.5 : 0.9))
                    }
                }.frame(height: 170).accessibilityLabel(L("每日练习积分，暂定日期使用浅色显示"))
            }
            performance(L("平均速度（估算 WPM）"), color: .orange, value: { $0.wpm })
            performance(L("每秒节奏稳定度"), color: .teal, value: { $0.consistency })
        }
    }
    private func performance(_ label: String, color: Color, value: @escaping (RhythmTotals) -> Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            Chart(model.activityScoreDays) { day in
                if !day.hasMixedRules, let metric = value(day.totals) {
                    PointMark(x: .value(L("日期"), day.day), y: .value(label, metric)).foregroundStyle(color)
                    LineMark(x: .value(L("日期"), day.day), y: .value(label, metric)).foregroundStyle(color)
                }
            }.frame(height: 115).accessibilityLabel(label)
        }
    }
}
