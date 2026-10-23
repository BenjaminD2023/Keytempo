import AppKit
import Charts
import SwiftUI
import TypingCore
import UniformTypeIdentifiers

// Explicit wrapper alias also builds with command-line SDKs that declare the
// newer State macro without shipping its compiler plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

private enum AppStyle {
    static let confirmed = Color.accentColor
    static let estimated = Color.orange
}

private func cadence(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0)))
}

private func primaryCadence(_ value: Double?, unit: PrimaryTypingUnit, includeUnit: Bool = true) -> String {
    guard unit != .unknown else { return "—" }
    let measured = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    let number = measured.map { (unit == .wpm ? "≈" : "") + cadence($0) } ?? "—"
    return number + (includeUnit ? " \(unit.rawValue)" : "")
}

private func currentSpeedCadence(_ speed: MenuSpeedDisplay, includeUnit: Bool = true) -> String {
    guard speed.unit != "—" else { return "—" }
    let measured = speed.value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    let number = measured.map { (speed.estimated ? "≈" : "") + cadence($0) } ?? "—"
    return number + (includeUnit ? " \(speed.unit)" : "")
}

private func elapsed(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return L("0 秒") }
    if seconds < 60 { return L("%.1f 秒", seconds) }
    return L("%d 分 %d 秒", Int(seconds) / 60, Int(seconds) % 60)
}

private struct StatusLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isPaused ? Color.secondary : (model.hasInputPermission ? Color.green : Color.orange))
                .frame(width: 7, height: 7)
            Text(L(model.status)).font(.callout)
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keytempo", systemImage: "keyboard").font(.headline)
            StatusLine(model: model)
            recentAverage
            currentSpeed
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("今日累计")).font(.headline)
                    Spacer()
                    Text(L("合并全部输入语言")).font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text(L("敲键数量")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(compactKeystrokeCount(model.dailyEstimate.keys))
                            .gridColumnAlignment(.trailing)
                            .help(L("全语言敲键数量：%@；快捷键与空格不计入。", model.dailyEstimate.keys.formatted()))
                    }
                    GridRow {
                        Text(L("今日平均速度"))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(primaryCadence(model.todayAverageWPM, unit: .wpm)).fontWeight(.medium)
                    }
                    GridRow {
                        Text(L("输入段时长")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(elapsed(model.dailyEstimate.seconds))
                    }
                    GridRow {
                        Text(L("辅助 KPM（估算）")).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(cadence(model.dailyEstimate.todayKPM)).foregroundStyle(.secondary)
                    }
                }.font(.callout).monospacedDigit()
                if model.todayAverageIsPartial {
                    Text(L("平均速度基于 %@ 次敲键", compactKeystrokeCount(model.todayAverageCoveredKeys)))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L("平均速度基于 %@ 次敲键；部分旧记录使用不同的计数方式，未纳入平均值，累计数量仍保留。", model.todayAverageCoveredKeys.formatted()))
                }
            }
            if let error = model.storageError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L(error), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("重试保存"), action: model.retrySave).font(.caption)
                }
            }
            Text(L("估算 WPM 按五次操作折算，不代表实际词数或上屏字数。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(model.isPaused ? L("恢复统计") : L("暂停统计"), systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.togglePause()
                }
                Spacer()
                Button(L("统计窗口"), action: model.showStats)
                    .keyboardShortcut("o", modifiers: .command)
            }
            HStack {
                Button(L("设置…"), action: model.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
                CheckForUpdatesButton(updater: model.updates)
                    .id(model.interfaceLanguage)
                Spacer()
                Button(L("退出")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }.font(.callout)
        }
        .padding(18)
        .frame(width: 358)
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private var recentAverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("近 10 分钟平均")).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(primaryCadence(model.tenMinuteWPM, unit: .wpm))
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
            }
            .help(L("近 10 分钟只使用本次统计中已记录的全语言输入间隔，按实际段内时长加权，不把停顿加入分母。"))
            Text(recentAverageCoverage)
                .font(.caption)
                .foregroundStyle(model.tenMinuteWindowComplete ? Color.secondary : .orange)
        }
    }

    private var recentAverageCoverage: String {
        if !model.tenMinuteWindowComplete { return L("近期样本不完整，平均速度暂不可用") }
        if model.tenMinuteObservedSeconds < 600 {
            return model.tenMinuteWPM == nil
                ? L("全语言 · 本次统计 %@ · 样本不足", elapsed(model.tenMinuteObservedSeconds))
                : L("全语言 · 本次统计 %@", elapsed(model.tenMinuteObservedSeconds))
        }
        return model.tenMinuteWPM == nil ? L("近 10 分钟样本不足") : L("本次统计内最近 10 分钟 · 全语言")
    }

    private var currentSpeed: some View {
        let speed = model.selectedMenuSpeed
        let isKPM = model.menuDisplay == "kpm"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(model.selectedSpeedIsRecent ? "最近输入速度" : "当前速度")).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(currentSpeedCadence(speed))
                    .font(.system(size: 17, weight: .medium)).monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(L("合并全部输入语言"))
                if model.recentEvidence == .confirmed && !isKPM {
                    Text("·")
                    Text(L("已接入路径"))
                }
                Spacer(minLength: 6)
                Text(speed.value == nil ? L("当前输入段数据不足") : model.selectedSpeedIsRecent ? L("最近已停止") : L("正在输入"))
            }.font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .help(L("当前速度约每秒更新；停止后保留最近值，等待不计入输入时长。"))
    }

}

struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var tab = "today"

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keytempo").font(.largeTitle.weight(.semibold))
                    Text(L("记录敲键节奏，保留输入边界。"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    StatusLine(model: model).fixedSize()
                    Button(model.isPaused ? L("恢复统计") : L("暂停统计"), action: model.togglePause)
                }
            }.padding(24)

            Picker(L("统计页面"), selection: $tab) {
                Text(L("今日概况")).tag("today")
                Text(L("历史趋势")).tag("history")
                Text(L("验证输入")).tag("editor")
                Text(L("统计口径")).tag("method")
                if model.diagnosticsEnabled { Text(L("诊断")).tag("diagnostics") }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Divider()
            Group {
                switch tab {
                case "history": history
                case "editor": editor
                case "method": methodology
                case "diagnostics": DiagnosticsView(model: model)
                default: today
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, idealWidth: 900, minHeight: 580, idealHeight: 720)
        .onChange(of: model.diagnosticsEnabled) { enabled in
            if !enabled, tab == "diagnostics" { tab = "today" }
        }
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private var today: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.hasInputPermission || !model.hasAccessibilityPermission {
                    permissionSummary
                }
                MetricCard(title: L("日常输入（估算）"), subtitle: L(model.chineseKeyboardCompatibilityEnabled ? "全局监听 · 中文键盘兼容模式" : "全局监听 + 可编辑区域证据"), metric: model.probable, tint: AppStyle.estimated, isGlobal: true, totals: model.dailyEstimate, recentKPM: model.estimatedRecentKPM, todayAverageWPM: model.todayAverageWPM, todayAverageIsPartial: model.todayAverageIsPartial, todayAverageCoveredKeys: model.todayAverageCoveredKeys, isRecentRate: model.recentSpeedIsFrozen || model.phase == "idle")
                Text(L("当前速度、今日平均速度和累计合并全部输入语言。"))
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(L("覆盖范围"), systemImage: "scope").font(.headline)
                        Text(L(model.chineseKeyboardCompatibilityEnabled ? "中文输入源的焦点上下文无法查询时，以按键活动估算，可能包含非文本操作；已确认的非编辑区域仍排除。其他语言继续要求编辑上下文证据。权限不足、应用排除或安全输入时不统计。" : "全局估算只接受有编辑上下文证据的敲键。权限不足、过期上下文、终端或不受支持的编辑器可能无法统计。没有事件不能证明没有打字。"))
                        Text("\(model.currentApp) · \(L(model.contextDescription))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("全局速度统一使用估算 WPM；真实 CPM 仅在有实际上屏数据的接入路径显示。"))
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let error = model.storageError {
                    HStack {
                        Label(L(error), systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button(L("重试保存"), action: model.retrySave)
                    }
                }
            }.padding(24)
        }
    }

    private var permissionSummary: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("完成权限设置以启用全局估算")).font(.headline)
                    Text(L("输入监控用于被动接收按键元数据；辅助功能仅查询焦点控件角色和可编辑性。验证输入区可以独立使用。"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if !model.hasInputPermission {
                            Button(L("输入监控设置"), action: model.requestInputPermission)
                        }
                        if !model.hasAccessibilityPermission {
                            Button(L("辅助功能设置"), action: model.requestAccessibilityPermission)
                        }
                        Button(L("重新检查"), action: model.refreshPermissions)
                    }
                }
                Spacer(minLength: 0)
            }.padding(8)
        }
    }

    private var historyRows: [HistoryDay] {
        model.history.sorted { $0.day < $1.day }
    }
    private var historyHasRates: Bool {
        historyRows.contains { $0.estimatedWPM != nil }
    }

    private var historyGranularityLabel: String {
        switch model.historyGranularity {
        case .day: return L("按日汇总")
        case .week: return L("按周汇总")
        case .month: return L("按月汇总")
        }
    }
    private var historyPeriodColumn: String {
        switch model.historyGranularity {
        case .day: return L("日期")
        case .week: return L("周期起始日期")
        case .month: return L("月份")
        }
    }
    private func historyPeriod(_ day: String) -> String {
        model.historyGranularity == .month ? String(day.prefix(7)) : day
    }
    private func historyAxisLabel(_ day: String) -> String {
        switch model.historyGranularity {
        case .day: return String(day.suffix(5))
        case .week: return day
        case .month: return String(day.prefix(7))
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L("输入趋势")).font(.title2.weight(.semibold))
                    Spacer()
                    Picker(L("时间范围"), selection: Binding(get: { model.historyDays }, set: { model.loadHistory(days: $0) })) {
                        Text(L("最近 7 天")).tag(7)
                        Text(L("最近 30 天")).tag(30)
                        Text(L("最近 90 天")).tag(90)
                        Text(L("最近 1 年")).tag(365)
                        Text(L("最近 5 年")).tag(1826)
                    }.pickerStyle(.menu).frame(width: 190)
                    Button(L("导出 CSV…"), action: model.exportCSV)
                }
                HStack {
                    Text(historyGranularityLabel)
                    Spacer()
                    Text(L("%@ 至 %@", model.historyStartDay, model.historyEndDay)).monospacedDigit()
                }.font(.callout).foregroundStyle(.secondary)
                Text(L("仅展示已保存的历史，不补造尚未记录的数据。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.historyLoading {
                    ProgressView(L("正在读取历史…"))
                        .frame(maxWidth: .infinity).frame(height: 220)
                } else if let error = model.historyError {
                    VStack(spacing: 12) {
                        Label(L("历史读取失败"), systemImage: "exclamationmark.triangle").font(.headline)
                        Text(L(error)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L("重试加载")) { model.loadHistory(days: model.historyDays) }
                    }.frame(maxWidth: .infinity).frame(minHeight: 180)
                } else if model.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text(L("还没有历史输入记录")).font(.headline)
                        Text(L("短输入段也会保留；孤立敲键只累计次数，不生成速度。"))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).frame(height: 220)
                } else {
                    Text(L("合并全部输入语言")).font(.headline)
                    Text(L("图表显示全部输入语言合并后的估算 WPM；真实 CPM 仅在验证输入区显示，不与 WPM 叠加。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if historyHasRates {
                        historyChart
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(.tertiary)
                            Text(L("尚无可展示的速度数据"))
                                .font(.headline)
                        }.frame(maxWidth: .infinity).frame(height: 210)
                    }
                    combinedHistoryTable
                }
                Text(L("历史按所选周期合并全部输入语言，统一显示估算 WPM，并保留独立 KPM。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("速度按汇总数量与实际覆盖时长计算，不直接平均各日速度。不同统计规则保留在 CSV 中，不能视为完全可比。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { model.historyVisible = true; model.loadHistory(days: model.historyDays) }
        .onDisappear { model.historyVisible = false; model.releaseHistory() }
    }

    private var historyChart: some View {
        Chart {
            ForEach(historyRows) { day in
                if let rate = day.estimatedWPM {
                    BarMark(x: .value(L("本地日期"), day.day), y: .value("WPM", rate))
                        .foregroundStyle(by: .value(L("来源"), L("全局估算")))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: [L("全局估算")],
            range: [AppStyle.estimated]
        )
        .chartYAxisLabel(L("按键折算 WPM（估算）"))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: model.historyDays == 7 ? 7 : 6)) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(String.self) { Text(historyAxisLabel(date)) }
                }
            }
        }
        .frame(height: 235)
        .accessibilityLabel(L("全部输入语言合并的估算 WPM 趋势，%@", historyGranularityLabel))
    }

    private var combinedHistoryTable: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("合并统计（估算）")).font(.headline).foregroundStyle(AppStyle.estimated)
            Text(L("合并全部输入语言的数量与间隔；WPM 和 KPM 按实际时长加权，不连接中断之间的停顿。"))
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    Text(historyPeriodColumn)
                    Text(L("合并敲键数量"))
                    Text(L("平均速度（估算 WPM）"))
                    Text(L("合并 KPM"))
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(historyRows.reversed()) { day in
                    GridRow {
                        Text(historyPeriod(day.day)).help(L("%@ 至 %@", day.day, day.periodEnd.isEmpty ? day.day : day.periodEnd))
                        Text(compactKeystrokeCount(day.estimatedKeys)).help(day.estimatedKeys.formatted())
                        Text(primaryCadence(day.estimatedWPM, unit: .wpm, includeUnit: false))
                        Text(cadence(day.estimatedKPM))
                            .help(L("新旧计数规则并存时不合并速度；当前速度会从更新后重新采样。"))
                    }.font(.callout).monospacedDigit()
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("验证输入区")).font(.title2.weight(.semibold))
                    Text(L("使用真实 macOS 文本输入回调验证 confirmed 路径。可测试中文输入法、Option 特殊字符、换行和删除。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(L("仅内存"), systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            ConfirmedEditorView(
                onInput: model.receiveConfirmedInput,
                onCommit: { english, chinese, language, unratedCharacters in
                    model.receiveCommit(english: english, chinese: chinese, language: language, unratedCharacters: unratedCharacters)
                },
                onInterrupt: model.interruptConfirmed
            )
            .frame(minHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.3)))
            .accessibilityLabel(L("验证输入区，内容不保存"))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("已接入路径 · 最近主要速度")).font(.caption).foregroundStyle(.secondary)
                    Text(primaryCadence(model.confirmed.primaryRate, unit: model.confirmed.primaryUnit))
                        .font(.title2).monospacedDigit()
                    Text(L("验证区已确认操作：%@", compactKeystrokeCount(model.confirmed.keys)))
                        .font(.caption).foregroundStyle(.secondary).help(model.confirmed.keys.formatted())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("今日手动提交量")).font(.caption).foregroundStyle(.secondary)
                    Text(L("英文字符 %d · 汉字 %d", model.commitsEnglish, model.commitsChinese))
                        .font(.title3).monospacedDigit()
                }
            }
            Text(L("提交量只覆盖此输入区的真实提交路径，不等于文档最终保留字数。粘贴与生成操作不计入手动字符；取消组词不计作已上屏字符。CPM 仅使用真实字符与有覆盖证据的输入间隔。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("验证区内容不会写入统计库；切换页面会销毁此临时文本区。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .onDisappear { model.interruptConfirmed() }
    }

    private var methodology: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                method(L("先识别用途，再计时"), L("输入分为文字、组合、编辑、命令、导航、生成和未知。已确认数据来自实际文本输入适配器；全局可编辑上下文只提供估算。未知事件不进入有效速度。文本框角色本身不能证明某次敲键已经插入文字。"))
                method(L("只累计观察到的间隔"), L("同一输入段里 n 次有效操作产生 n−1 个可测间隔。时长等于末次与首次操作的时间差；停止输入不会追加等待时间。命令、导航、焦点切换、权限中断和长停顿会切段。"))
                method(L("自适应段落，保留真实时间"), L("使用有界近期间隔样本的中位数与 MAD 估计节奏，并识别新的稳定慢速候选。阈值只判断是否连续；接受的间隔完整计时。系数是可验证的启发式，不代表最佳识别精度。"))
                method(L("辅助节奏与编辑"), L("辅助 KPM = 60 × 段内有效间隔数 ÷ 段内真实秒数，包含已接受的组合与编辑过程。删除另计，不视为新增文字或错误。“文字敲键 KPM”只连接文字输入，编辑会切断这一指标。"))
                method(L("统一的估算速度"), L("全部输入语言合并统计，统一使用按键折算 WPM = 输入过程 KPM ÷ 5，包含组合与编辑，不代表实际词数或汉字数。历史按周期合并间隔数量与真实时长，不直接平均不同语言的速度；中断仍切断计时。真实提交路径的 CPM 仅用于验证，不与全局估算 WPM 叠加。"))
                method(L("真实字符 CPM 的时间口径"), L("字符按真实提交的扩展字素簇计数。一条被接受且具备提交覆盖证据的输入间隔，使用其末端操作实际提交的全部字符数与该间隔真实时长；批量上屏按整批字符计数。首个事件的提交只增加累计字符，不凭空生成速率。组合或编辑没有提交时字符增量为零，其有效过程时间仍计入分母。不能把逐键 n−1 修正机械套到字符数。"))
                method(L("样本与停止"), L("最近速度至少需要 4 个有效间隔与 0.5 秒覆盖时长；短段与孤立输入仍保留累计。CPM 的分母仅使用真实提交路径覆盖的间隔。停止后数值冻结并标为最近已停止，等待不增加时长，也不会拉低速度。"))
                method(L("快捷键与未知用途"), L("Command／Control 组合键与已识别的命令、导航会排除并切段。已接入文本区还使用实际命令回调识别用途。纯全局元数据无法识别所有自定义快捷键；证据不足或用途不明时保持未知，不宣称完整识别。"))
                method(L("中文与字符量"), L("拼音敲键不能推算最终汉字。验证输入区在真实提交边界计数字素簇后丢弃内容；选词按键不冒充新增字符。没有真实上屏数据的全局模式不提供 CPM。字符总量不等于删除修改后的文档最终字数。"))
                method(L("能力边界"), L("终端、Vim 模式、自定义编辑器、游戏及拦截按键的网页不具备通用可靠识别。已确认支持限于已接入路径；上下文估算可能误计或漏计。可使用应用排除名单。随机文字、代码、重复标点不会按语义被排除。"))
                method(L("本地与最少数据"), L("只保存日期、输入语言、证据等级、统计规则、敲键与编辑数量、真实字符数、间隔数和时长汇总。不保存原文、按键序列、剪贴板、窗口标题或网址。安全输入与系统权限限制会中断统计；未收到事件不等同于空闲。"))
            }.padding(24)
        }
    }

    private func method(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L(title)).font(.headline)
            Text(L(text)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetricCard: View {
    let title: String
    let subtitle: String
    let metric: MetricDisplay
    let tint: Color
    var isGlobal = false
    var totals: MetricDisplay? = nil
    var recentKPM: Double? = nil
    var todayAverageWPM: Double? = nil
    var todayAverageIsPartial = false
    var todayAverageCoveredKeys = 0
    var isRecentRate = false
    private var totalsMetric: MetricDisplay { totals ?? metric }
    private var displaySpeed: MenuSpeedDisplay {
        MenuSpeedDisplay(metric: metric, evidence: isGlobal ? .probable : .confirmed)
    }

    private var rateDescription: String {
        if isGlobal && displaySpeed.unit == "WPM" {
            if displaySpeed.value != nil && isRecentRate { return L("最近输入速度 · 已停止（估算）") }
            return displaySpeed.value == nil ? L("最近速度 · 数据不足") : L("按键折算速度（估算，含组合与编辑）")
        }
        switch metric.primaryUnit {
        case .wpm:
            return metric.primaryRate == nil ? L("最近速度 · 数据不足") : L("按键折算速度（估算，含组合与编辑）")
        case .cpm:
            if isGlobal { return L("不可用：缺少真实上屏数据") }
            return metric.primaryRate == nil ? L("真实上屏路径 · 数据不足") : L("真实上屏字符 / 分钟")
        case .unknown:
            return L("语言未识别，主要速度不可用")
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L(title)).font(.headline).foregroundStyle(tint)
                    Text(L(subtitle)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(currentSpeedCadence(displaySpeed, includeUnit: false))
                        .font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    if displaySpeed.unit != "—" {
                        Text(displaySpeed.unit).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(rateDescription).font(.caption).foregroundStyle(.secondary)
                if isGlobal && displaySpeed.unit == "WPM" {
                    Text(L("所有输入语言统一按五次操作折算 WPM，含组合与编辑，不代表实际词数或上屏字数。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if isGlobal {
                    metricRow(L("今日平均速度"), primaryCadence(todayAverageWPM, unit: .wpm))
                    if todayAverageIsPartial {
                        Text(L("平均速度基于 %@ 次敲键", compactKeystrokeCount(todayAverageCoveredKeys)))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(L("平均速度基于 %@ 次敲键；部分旧记录使用不同的计数方式，未纳入平均值，累计数量仍保留。", todayAverageCoveredKeys.formatted()))
                    }
                } else {
                    metricRow(L("今日主要速度（当前语言）"), primaryCadence(metric.todayPrimaryRate, unit: metric.primaryUnit))
                }
                metricRow(L("今日合并敲键数量"), compactKeystrokeCount(totalsMetric.keys)).help(totalsMetric.keys.formatted())
                metricRow(L("其中编辑操作"), compactKeystrokeCount(totalsMetric.edits)).help(totalsMetric.edits.formatted())
                metricRow(L("其中组合操作"), compactKeystrokeCount(totalsMetric.composition)).help(totalsMetric.composition.formatted())
                if !isGlobal {
                    metricRow(L("今日手动上屏字符"), metric.characters.formatted())
                }
                metricRow(L("今日合并段内时长"), elapsed(totalsMetric.seconds))
                Divider()
                metricRow(L("最近合并 KPM（估算）"), "\(cadence(isGlobal ? recentKPM : metric.kpm)) KPM")
                metricRow(L("今日合并 KPM"), "\(cadence(totalsMetric.todayKPM)) KPM")
                    .help(L("新旧计数规则并存时不合并速度；当前速度会从更新后重新采样。"))
                if !isGlobal {
                    metricRow(L("文字敲键 KPM（当前语言）"), "\(cadence(metric.newKPM)) KPM")
                        .help(L("只连接相邻的文字输入操作；组合、编辑、命令和导航都会中断这一指标。包含组合与编辑的整体过程见加权节奏。"))
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(label)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(L(value)).monospacedDigit()
        }.font(.callout)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var confirmClear = false

    var body: some View {
        Form {
            Section(L("语言")) {
                Picker(L("App 语言"), selection: Binding(get: { model.interfaceLanguage }, set: model.setInterfaceLanguage)) {
                    Text("中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text(L("输入统计合并全部语言；App 语言只影响界面显示。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("运行")) {
                Toggle(L("登录时启动 Keytempo"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                Picker(L("菜单栏显示"), selection: $model.menuDisplay) {
                    Text(L("输入时 WPM，空闲时今日敲键数")).tag("hybrid")
                    Text(L("主要速度（估算 WPM）")).tag("speed")
                    Text(L("敲键节奏 KPM")).tag("kpm")
                    Text(L("今日敲键数量")).tag("count")
                    Text(L("仅图标")).tag("icon")
                }
                .onChange(of: model.menuDisplay) { _ in model.applySettings() }
                if model.menuDisplay == "hybrid" {
                    Text(L("输入和预热时保持 WPM，样本不足显示 — WPM；确认停打后显示 — WPM 三秒，再显示今日敲键数。暂停或权限失效等情况立即显示数量。约每秒更新，等待不计入输入时长。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L(model.status)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isPaused ? L("恢复统计") : L("暂停统计"), action: model.togglePause)
                }
            }
            UpdateSettingsSection(updater: model.updates)
                .id(model.interfaceLanguage)
            Section(L("段落识别")) {
                Picker(L("连续间隔上限"), selection: $model.maximumGap) {
                    Text(L("2 秒 · 较紧凑")).tag(2.0)
                    Text(L("3 秒 · 默认")).tag(3.0)
                    Text(L("5 秒 · 宽松")).tag(5.0)
                }
                .onChange(of: model.maximumGap) { _ in model.applySettings() }
                Text(L("自适应阈值在上限内调整。上限不会在末次敲键后追加任何时长；修改后切段并保存新的规则版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("输入过滤")) {
                Toggle(L("中文输入法兼容模式（按键估算）"), isOn: $model.chineseKeyboardCompatibilityEnabled)
                    .onChange(of: model.chineseKeyboardCompatibilityEnabled) { _ in model.applySettings() }
                Text(L("仅在中文输入源的焦点上下文无法查询时，改用按键活动估算 WPM，可能计入非文本操作。已确认的非编辑区域、快捷键、空格、自动重复与已识别的生成输入仍排除。不会统计实际汉字数。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("过滤疑似异常输入"), isOn: $model.suspectedInputFilteringEnabled)
                    .onChange(of: model.suspectedInputFilteringEnabled) { _ in model.applySettings() }
                Text(L("排除长串同键与极端按键突发；无法判断文字是否乱打，也不能识别所有宏。误判时可关闭，系统连发与已知合成事件仍排除。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("应用排除")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("通过“添加应用”选择，或每行填写一个 Bundle Identifier。"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("com.apple.Terminal", text: $model.excludedAppsText, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...7)
                        .font(.system(.callout, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L("排除应用标识符列表，每行一个"))
                }
                HStack {
                    Button(L("添加应用…"), action: chooseExcludedApplication)
                    Text(L("当前：%@", model.currentApp)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("保存排除名单"), action: model.applySettings)
                }
            }
            Section(L("系统权限")) {
                permissionRow(L("输入监控"), granted: model.hasInputPermission, action: model.requestInputPermission)
                permissionRow(L("辅助功能"), granted: model.hasAccessibilityPermission, action: model.requestAccessibilityPermission)
                Text(L("辅助功能只读取焦点控件元数据，不读取输入框内容。权限撤销后会使缓存失效并中断统计。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("重新检查权限"), action: model.refreshPermissions)
            }
            Section(L("数据与诊断")) {
                Toggle(L("显示诊断页面（不包含输入内容）"), isOn: $model.diagnosticsEnabled)
                    .onChange(of: model.diagnosticsEnabled) { _ in model.applySettings() }
                HStack {
                    Button(L("导出 CSV…"), action: model.exportCSV)
                    Spacer()
                    Button(L("清除全部历史…"), role: .destructive) { confirmClear = true }
                }
                if let error = model.storageError {
                    Label(L(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L("重试保存"), action: model.retrySave)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 650, idealHeight: 760)
        .confirmationDialog(L("清除全部历史数据？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("清除全部历史"), role: .destructive, action: model.clearHistory)
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("将删除本机统计汇总并重置当前统计。此操作无法撤销；已导出的 CSV 不受影响。"))
        }
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private func permissionRow(_ label: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(L(label), systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Color.primary : .secondary)
            Spacer()
            Text(granted ? L("已授权") : L("未授权")).font(.callout).foregroundStyle(.secondary)
            if !granted { Button(L("打开设置"), action: action) }
        }
    }

    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = L("选择要排除的应用")
        panel.prompt = L("加入排除名单")
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        let existing = model.excludedAppsText.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if !existing.contains(bundle) {
            model.excludedAppsText += (model.excludedAppsText.isEmpty ? "" : "\n") + bundle
            model.applySettings()
        }
    }
}

private struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button(L("检查更新…"), action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

private struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Section(L("软件更新")) {
            HStack {
                Text(L("当前版本 %@", updater.version))
                Spacer()
                CheckForUpdatesButton(updater: updater)
            }
            Toggle(L("自动检查更新"), isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticallyChecks))
            Toggle(L("自动下载并在退出时安装"), isOn: Binding(get: { updater.automaticallyDownloads }, set: updater.setAutomaticallyDownloads))
                .disabled(!updater.allowsAutomaticDownloads)
            Text(L("自动检查约每 24 小时一次。关闭自动下载后，可通过“检查更新”手动下载并安装。更新不会上传输入统计。"))
                .font(.caption).foregroundStyle(.secondary)
            if let lastCheck = updater.lastCheck {
                Text(L("上次检查：%@", lastCheck.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = updater.startupError {
                Label(L("更新暂不可用：%@", error), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if updater.signingChannel == "adhoc" {
                Text(L("此版本使用临时签名，更新后可能需要重新授权系统权限。"))
                    .font(.caption).foregroundStyle(.orange)
            } else if updater.signingChannel == "local-development" {
                Text(L("本地开发签名：后续更新须保持相同签名身份。首次从临时签名迁移后需重新授权一次。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(L("可关闭的元数据诊断"), systemImage: "waveform.path.ecg").font(.title2.weight(.semibold))
                Text(L("只显示分类、覆盖与节奏模型。不会显示输入文本或完整按键序列。可在设置中关闭。"))
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    diagnosticRow(L("运行状态"), model.status)
                    diagnosticRow(L("输入段状态"), model.phase)
                    diagnosticRow(L("前台应用"), model.currentApp, translateValue: false)
                    diagnosticRow(L("上下文"), model.contextDescription)
                    diagnosticRow(L("连续性阈值"), L("%.3f 秒", model.threshold))
                    diagnosticRow(L("间隔中位数"), L("%.3f 秒", model.modelMedian))
                    diagnosticRow("MAD", L("%.3f 秒", model.modelMAD))
                    diagnosticRow(L("模型样本"), model.modelSamples.formatted())
                    diagnosticRow(L("输入源"), model.monitor.inputSourceSummary)
                    diagnosticRow(L("焦点查询（仅元数据）"), model.monitor.contextQuerySummary, translateValue: false)
                    diagnosticRow(L("上下文确认后重放 / 丢弃"), "\(model.monitor.deferredAcceptedEvents) / \(model.monitor.deferredDiscardedEvents)")
                    diagnosticRow(L("等待上下文确认"), "\(model.monitor.pendingContextEvents) · \(model.monitor.deferredContextSummary)")
                    diagnosticRow(L("全局接收 / 未知操作"), "\(model.monitor.capturedEvents) / \(model.monitor.unknownEvents)")
                    diagnosticRow(L("自动重复 / 溢出丢失"), "\(model.monitor.repeatEvents) / \(model.monitor.overflowCount)")
                    diagnosticRow(L("疑似同键 / 突发排除"), "\(model.suspiciousRepeatEvents) / \(model.suspiciousBurstEvents)")
                    diagnosticRow(L("监听回调 p99"), model.monitor.callbackP99Microseconds.map { L("%.1f 微秒（仅回调自身）", $0) } ?? L("未采样或尚无事件"))
                    diagnosticRow(L("输入监控 / 辅助功能"), "\(L(model.hasInputPermission ? "已授权" : "未授权")) / \(L(model.hasAccessibilityPermission ? "已授权" : "未授权"))")
                }.font(.callout).textSelection(.enabled)
                Divider()
                Text(L("最近的分类与中断原因")).font(.headline)
                if model.diagnostics.isEmpty {
                    Text(L("诊断已开启，等待事件。")).foregroundStyle(.secondary)
                }
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(L(line)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private func diagnosticRow(_ title: String, _ value: String, translateValue: Bool = true) -> some View {
        GridRow {
            Text(L(title)).foregroundStyle(.secondary)
            Text(translateValue ? L(value) : value).monospacedDigit()
        }
    }
}
