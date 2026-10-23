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

struct RewardMenuSummary: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let state = model.rewardState, let level = LevelProgress(totalXP: state.xpProgress.totalXP) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("今日练习积分")).foregroundStyle(.secondary)
                    Spacer()
                    Text(rewardPointText(model.todayReward?.components.total ?? 0)).fontWeight(.medium)
                }
                HStack {
                    Text(L("等级 %@", level.level.formatted()))
                    Spacer()
                    Text(L("今日 %@ XP · 累计 %@ XP", (model.todayReward?.xp.total ?? 0).formatted(), state.xpProgress.totalXP.formatted()))
                }.font(.caption).foregroundStyle(.secondary)
            }.font(.callout).monospacedDigit()
        }
    }
}

struct RewardDashboard: View {
    @ObservedObject var model: AppModel
    private var components: RewardComponents? { model.selectedRewardDay?.components }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let error = model.rewardError { Label(L(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let state = model.rewardState {
                Text(L("奖励日：%@ · %@", model.rewardDayKey(model.activityDate), state.progressionTimezone))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 30) {
                    point(L("近七日积分"), model.weekRewardScore)
                    point(L("累计积分"), state.lifetimeScore.total)
                    Spacer()
                    Button(L("导出奖励 CSV…"), action: model.exportRewards)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        point(L("时长基础分"), components?.time)
                        point(L("敲键基础分"), components?.volume)
                        point(L("速度奖励"), components?.speedBonus)
                        point(L("稳定度奖励"), components?.consistencyBonus)
                    }
                }
                Text(L("基础分即时累计；每 100 次已接受敲键结算质量奖励。未满块与待确认间隔不预支奖励，日界线结算剩余块。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("待结算：%@ 次敲键，%@ 个块", state.pendingBlockKeys.formatted(), state.pendingBlockCount.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
                if let level = LevelProgress(totalXP: state.xpProgress.totalXP) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L("等级 %@", level.level.formatted())).font(.title3.weight(.semibold))
                                Spacer()
                                Text(L("累计 %@ XP", state.xpProgress.totalXP.formatted())).monospacedDigit()
                            }
                            ProgressView(value: Double(level.progressXP), total: Double(level.requiredXP))
                                .accessibilityLabel(L("下一等级进度"))
                                .accessibilityValue(L("%@ / %@ XP", level.progressXP.formatted(), level.requiredXP.formatted()))
                            Text(L("%@ / %@ XP · 距离下一级 %@ XP", level.progressXP.formatted(), level.requiredXP.formatted(), level.remainingXP.formatted()))
                                .font(.callout).monospacedDigit()
                            HStack(spacing: 22) {
                                Text(L("今日 %@ XP", (model.todayReward?.xp.total ?? 0).formatted()))
                                Text(L("近七日 %@ XP", model.weekRewardXP?.formatted() ?? "—"))
                                Text(L("累计来源：时长 %@ · 敲键 %@ · 进步 %@ XP", state.xpProgress.timeXP.formatted(), state.xpProgress.volumeXP.formatted(), state.xpProgress.improvementXP.formatted()))
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(L("下一份时长 XP：%.1f / 300 秒；敲键 XP：%@ / 2,000 次", state.xpProgress.remainderSeconds, state.xpProgress.remainderKeys.formatted()))
                                .font(.caption).foregroundStyle(.secondary)
                            if let next = level.nextThreshold { Text(L("下一级累计门槛：%@ XP", exactXPThreshold(next))).font(.caption).foregroundStyle(.secondary) }
                            if let feedback = model.rewardFeedback { Label(feedback, systemImage: "sparkles").font(.callout).foregroundStyle(.tint) }
                        }.padding(9)
                    }
                }
                calibration(state)
                explanation(state)
                Text(L("奖励自 %@ 起记录；此前为旧版记录，不补造积分、XP 或基线。奖励日界线固定使用 %@，系统时区变化不会重置每日预算。", coverageDate(state), state.progressionTimezone))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("奖励暂不可用，请检查本地存储状态。"))
            }
        }
    }
    private func point(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(rewardPointText(value)).font(.title3.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func coverageDate(_ state: RewardState) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: model.interfaceLanguage)
        formatter.timeZone = TimeZone(identifier: state.progressionTimezone) ?? .current
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: state.coverageStart)
    }
    @ViewBuilder private func calibration(_ state: RewardState) -> some View {
        DisclosureGroup(L("个人进步与校准")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("每个语言／输入法分别校准：5 个已完成活跃日、60 分钟；每个合格日需至少 5 分钟。校准期间照常获得基础积分和练习 XP。"))
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
                Text(L("验证使用校准后的最近 7 个合格完成日，至少 3 日、30 分钟，汇总值和至少 3 个单日都须达到里程碑。速度相对原基线每提升 5%，或稳定度绝对提升 5 点，各奖励 5 XP；退步再恢复不重复领奖。"))
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
    private func explanation(_ state: RewardState) -> some View {
        DisclosureGroup(L("奖励如何计算？")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("积分按奖励日累计：60 × ln(1 + 实际秒数 / 3600) + 60 × ln(1 + 敲键数 / 15000)。只增加边际贡献，不重复计入已有分数；周／累计积分直接相加。"))
                Text("S = min(1, ln(1 + WPM / 50) / ln(4.2)); q(N,k) = min(1,N/40) × min(1,N/k)")
                Text(L("速度奖励 = 25% × 块基础分 × qW × S；稳定度奖励 = 15% × 块基础分 × qC × C。速度至少 20 个间隔、2 秒；稳定度另需 10 个完整一秒样本。缺少证据不代表不稳定。"))
                Text(L("稳定度使用每段与块交集内的完整一秒速率样本。片段至少 10 个间隔、2 个样本；先算各片段 CV，再按已覆盖间隔权重合并 CV²。C = 1 − tanh(CV + CV³/3 + CV⁵/5)。尾部与空闲不补样本；qC 只使用样本实际覆盖的间隔。"))
                Text(L("独立稳定度也采用 Monkeytype 式每秒速率和 Kogasa 映射；上下文过滤、分段和证据门槛不同，不能直接与 Monkeytype 测试成绩比较。"))
                Text(L("XP 独立于积分：每 300 秒实际打字 1 XP，每 2,000 次敲键 1 XP；余量跨日保留。绝对速度、当前稳定度和连续签到都没有额外 XP 倍率。"))
                Text(L("升级成本（当前等级）：1–3 为 10 XP，4 为 20，5–19 为 30，20–29 为 50，30–49 为 100，50 起为 200。无等级上限。"))
                Text(L("累计门槛：等级 2=10，3=20，4=30，5=50，10=200，20=500，30=1k，40=2k，50=3k，60=5k XP。"))
                Text(L("短暂停顿、切换应用和重启不重置每日预算或 100 键块。重启结束计时连续性；正常约 30 秒批量保存，未保存输入可能丢失，写入延迟或失败时可能更多。延迟证据使用有界缓冲；已结算块的真正迟到时长仅作为基础分调整，不改写已发奖励。"))
                Text(L("只保存数量、时长、统计量及非内容输入源代号，不保存文字、按键序列或逐间隔日志。无法识别所有宏，也不判断内容意义、准确率或生产力。清除应用明细与历史保留不会重置奖励；删除全部数据会清除奖励和基线。"))
                Text("score-v2 · xp-v1 · improvement-v1 · levels-v1").monospaced()
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}

struct RewardHistory: View {
    @ObservedObject var model: AppModel
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: model.rewardState?.progressionTimezone ?? "") ?? .current
        return value
    }
    private func date(_ key: String) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
    private var days: [StoredRewardDay] {
        let end = model.rewardDayKey(model.activityDate)
        let start = model.rewardDayKey(calendar.date(byAdding: .day, value: -29, to: model.activityDate) ?? model.activityDate)
        return model.rewardDays.filter { $0.day >= start && $0.day <= end }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("近 30 天累计练习积分"), systemImage: "chart.bar.xaxis").font(.headline)
            Text(L("每天相加实际已发积分；未覆盖的旧日期不显示为零。WPM 与稳定度另列，不与积分混用。"))
                .font(.caption).foregroundStyle(.secondary)
            if days.isEmpty { Text(L("新系统尚无覆盖记录。")).foregroundStyle(.secondary) }
            else {
                Chart(days) { day in
                    if let date = date(day.day) {
                        BarMark(x: .value(L("日期"), date, unit: .day), y: .value(L("练习积分"), day.components.total))
                            .foregroundStyle(Color.accentColor)
                    }
                }.frame(height: 170).accessibilityLabel(L("每日累计练习积分，按已发奖励相加"))
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
