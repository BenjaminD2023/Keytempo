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

private func primaryTitle(_ unit: PrimaryTypingUnit) -> String {
    switch unit {
    case .wpm: return L("按键折算 WPM（估算）")
    case .cpm: return L("真实字符 CPM")
    case .unknown: return L("语言未识别")
    }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Keytempo", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Text(L("今天")).font(.caption).foregroundStyle(.secondary)
            }
            StatusLine(model: model)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.menuDisplay == "kpm" ? L("最近合并 KPM（估算）") : L("当前输入段"))
                    .font(.callout).foregroundStyle(.secondary)
                currentSpeed
                Text(menuMetricExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("正在输入时约每秒更新；停止后数值冻结。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L("当前输入语言：%@", model.currentInputLanguage))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("日常统计（估算）")).font(.caption).foregroundStyle(AppStyle.estimated)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text(L("敲键数量"))
                    Text(compactKeystrokeCount(model.dailyEstimate.keys)).monospacedDigit()
                        .foregroundStyle(AppStyle.estimated).help(model.dailyEstimate.keys.formatted())
                }
                GridRow {
                    Text(L("输入段时长"))
                    Text(elapsed(model.dailyEstimate.seconds)).monospacedDigit().foregroundStyle(AppStyle.estimated)
                }
                GridRow {
                    Text(L("今日主要速度（当前语言）"))
                    Text(primaryCadence(model.probable.todayPrimaryRate, unit: model.probable.primaryUnit))
                        .monospacedDigit().foregroundStyle(AppStyle.estimated)
                }
                GridRow {
                    Text(L("今日合并 KPM"))
                    Text(cadence(model.dailyEstimate.todayKPM)).monospacedDigit().foregroundStyle(AppStyle.estimated)
                        .help(L("新旧计数规则并存时不合并速度；当前速度会从更新后重新采样。"))
                }
            }.font(.callout)
            Text(L("累计合并全部记录语言；主要速度按当前输入源语言显示。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("敲键数量为其他 App 中的日常输入估算；快捷键与空格不计入。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.storageError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L(error), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button(L("重试保存"), action: model.retrySave).font(.caption)
                }
            }
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
                Spacer()
                Button(L("退出")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }.font(.callout)
        }
        .padding(18)
        .frame(width: 358)
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
    }

    private var menuMetricExplanation: String {
        if model.menuDisplay == "kpm" { return L("KPM 合并全部记录语言的近期输入间隔，使用完整真实时长；空格不计入。") }
        switch model.selectedMenuMetric.primaryUnit {
        case .wpm: return L("WPM 按五次有效操作折算，含组合与编辑，不代表实际词数。")
        case .cpm: return L("CPM 只使用真实上屏字符；全局监听无法从拼音敲键推算字符。")
        case .unknown: return L("输入语言未知，保留敲键与时长，不推算主要速度。")
        }
    }

    private var currentSpeed: some View {
        let metric = model.selectedMenuMetric
        let isKPM = model.menuDisplay == "kpm"
        let value = isKPM ? model.estimatedRecentKPM : metric.primaryRate
        let isGlobal = isKPM || model.recentEvidence == .probable
        return VStack(alignment: .leading, spacing: 3) {
            Text(isKPM ? kpmCadence(model.estimatedRecentKPM) : primaryCadence(value, unit: metric.primaryUnit))
                .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            HStack(spacing: 6) {
                Text(isKPM ? L("全部记录语言") : model.languageName(metric.language))
                if value != nil {
                    Text("·")
                    Text(isGlobal ? L("全局估算") : L("已接入路径"))
                        .foregroundStyle(isGlobal ? AppStyle.estimated : AppStyle.confirmed)
                }
                Spacer(minLength: 0)
                Text(model.phase == "idle" ? L("最近已停止") : L("正在输入"))
            }.font(.caption)
            if !isKPM {
                Text(L("合并 KPM：%@", kpmCadence(model.estimatedRecentKPM)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value == nil {
                Text(metric.primaryUnit == .cpm && isGlobal && !isKPM
                     ? L("不可用：缺少真实上屏数据") : L("当前输入段数据不足"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func kpmCadence(_ value: Double?) -> String {
        value.map { "≈" + cadence($0) + " KPM" } ?? "— KPM"
    }

}

struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var tab = "today"
    @ViewState private var historyLanguage = ""

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
                Text(L("当前输入语言：%@", model.currentInputLanguage))
                    .font(.callout).foregroundStyle(.secondary)
                MetricCard(title: L("日常输入（估算）"), subtitle: L("全局监听 + 可编辑区域证据"), metric: model.probable, tint: AppStyle.estimated, isGlobal: true, totals: model.dailyEstimate, recentKPM: model.estimatedRecentKPM)
                Text(L("累计合并全部记录语言；主要速度按当前输入源语言显示。"))
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(L("覆盖范围"), systemImage: "scope").font(.headline)
                        Text(L("全局估算只接受有编辑上下文证据的敲键。权限不足、过期上下文、终端或不受支持的编辑器可能无法统计。没有事件不能证明没有打字。"))
                        Text("\(model.currentApp) · \(L(model.contextDescription))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("主要单位随输入语言切换：字母语言使用估算 WPM，字符语言使用真实 CPM。全局模式没有真实上屏数据时，CPM 显示不可用。"))
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

    private var selectedHistoryLanguage: String {
        let options = model.historyLanguageOptions
        if options.contains(where: { $0.id == historyLanguage }) { return historyLanguage }
        if options.contains(where: { $0.id == model.currentInputLanguageCode }) { return model.currentInputLanguageCode }
        return options.first?.id ?? model.currentInputLanguageCode
    }

    private var historyUnit: PrimaryTypingUnit { TypingRate.primaryUnit(forLanguage: selectedHistoryLanguage) }
    private var selectedHistoryRows: [HistoryDay] {
        model.history.filter { $0.language == selectedHistoryLanguage }.sorted { $0.day < $1.day }
    }
    private var historyHasRates: Bool {
        selectedHistoryRows.contains { $0.primaryRate != nil || $0.estimatedPrimaryRate != nil }
    }
    private var historyConfirmedLabel: String {
        historyUnit == .wpm ? L("已确认敲键折算（估算）") : L("真实上屏")
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
                    HStack(alignment: .firstTextBaseline) {
                        Picker(L("图表语言"), selection: Binding(get: { selectedHistoryLanguage }, set: { historyLanguage = $0 })) {
                            ForEach(model.historyLanguageOptions) { language in
                                Text(language.name).tag(language.id)
                            }
                        }.frame(maxWidth: 300)
                        Spacer()
                        Text(primaryTitle(historyUnit)).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(L("每次只绘制一种输入语言，WPM 与 CPM 不混合。缺少真实上屏或样本不足的周期不会绘制为 0。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if historyHasRates {
                        historyChart.id(selectedHistoryLanguage)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(.tertiary)
                            Text(historyUnit == .unknown ? L("语言未识别，主要速度不可用") : L("尚无可展示的速度数据"))
                                .font(.headline)
                            if historyUnit == .cpm {
                                Text(L("不可用：缺少真实上屏数据，或尚未达到最小样本要求。"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).frame(height: 210)
                    }
                    combinedHistoryTable
                    historyTable
                }
                Text(L("历史按所选周期与输入源语言分别汇总，不跨语言平均 WPM／CPM。旧记录语言未知，只保留原敲键与时长。"))
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
            ForEach(selectedHistoryRows) { day in
                if let rate = day.primaryRate {
                    BarMark(x: .value(L("本地日期"), day.day), y: .value(historyUnit.rawValue, rate))
                        .foregroundStyle(by: .value(L("来源"), historyConfirmedLabel))
                        .position(by: .value(L("来源"), historyConfirmedLabel))
                }
                if let rate = day.estimatedPrimaryRate {
                    BarMark(x: .value(L("本地日期"), day.day), y: .value(historyUnit.rawValue, rate))
                        .foregroundStyle(by: .value(L("来源"), L("上下文估算")))
                        .position(by: .value(L("来源"), L("上下文估算")))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: historyUnit == .wpm ? [historyConfirmedLabel, L("上下文估算")] : [historyConfirmedLabel],
            range: historyUnit == .wpm ? [AppStyle.confirmed, AppStyle.estimated] : [AppStyle.confirmed]
        )
        .chartYAxisLabel(primaryTitle(historyUnit))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: model.historyDays == 7 ? 7 : 6)) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(String.self) { Text(historyAxisLabel(date)) }
                }
            }
        }
        .frame(height: 235)
        .accessibilityLabel(L("所选语言的主要速度趋势，%@", historyGranularityLabel))
    }

    private struct CombinedHistoryDay: Identifiable {
        let day: String
        let periodEnd: String
        let keys: Int
        let kpm: Double?
        var id: String { day }
    }

    private var combinedHistoryDays: [CombinedHistoryDay] {
        Dictionary(grouping: model.history, by: \.day).map { day, rows in
            let intervals = rows.reduce(0.0) { $0 + $1.estimatedIntervals }
            let seconds = rows.reduce(0.0) { $0 + $1.estimatedSeconds }
            let rules = Set(rows.flatMap { row in
                row.rules.split(separator: ";").compactMap { entry in
                    entry.trimmingCharacters(in: .whitespaces).split(separator: "@").first.map(String.init)
                }
            })
            let rate = rows.allSatisfy { $0.rejectedRows == 0 } && rules.count <= 1 && intervals >= 4 && seconds >= 0.5 ? 60 * intervals / seconds : nil
            return CombinedHistoryDay(day: day, periodEnd: rows.map(\.periodEnd).filter { !$0.isEmpty }.max() ?? day,
                                      keys: rows.reduce(0) { $0 + $1.estimatedKeys }, kpm: rate)
        }.sorted { $0.day > $1.day }
    }

    private var combinedHistoryTable: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("合并统计（估算）")).font(.headline).foregroundStyle(AppStyle.estimated)
            Text(L("合并全部记录语言的数量与间隔；KPM 按实际时长加权，不连接跨语言停顿。"))
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    Text(historyPeriodColumn)
                    Text(L("合并敲键数量"))
                    Text(L("合并 KPM"))
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(combinedHistoryDays) { day in
                    GridRow {
                        Text(historyPeriod(day.day)).help(L("%@ 至 %@", day.day, day.periodEnd.isEmpty ? day.day : day.periodEnd))
                        Text(compactKeystrokeCount(day.keys)).help(day.keys.formatted())
                        Text(cadence(day.kpm))
                            .help(L("新旧计数规则并存时不合并速度；当前速度会从更新后重新采样。"))
                    }.font(.callout).monospacedDigit()
                }
            }
            Divider().padding(.vertical, 5)
            Text(L("分语言明细")).font(.headline)
        }
    }

    private var historyTable: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text(historyPeriodColumn)
                    Text(L("输入语言"))
                    Text(L("主要速度 · 接入路径"))
                    Text(L("主要速度 · 全局估算"))
                    Text(L("KPM（该语言估算）"))
                    Text(L("敲键数量（估算）"))
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider().gridCellColumns(6)
                ForEach(model.history.sorted(by: { $0.day == $1.day ? $0.language < $1.language : $0.day > $1.day })) { day in
                    GridRow {
                        Text(historyPeriod(day.day)).help(L("%@ 至 %@", day.day, day.periodEnd.isEmpty ? day.day : day.periodEnd))
                        Text(model.languageName(day.language))
                        Text(primaryCadence(day.primaryRate, unit: day.primaryUnit))
                        Text(day.primaryUnit == .cpm ? L("不可用") : primaryCadence(day.estimatedPrimaryRate, unit: day.primaryUnit))
                        Text(cadence(day.estimatedKPM))
                        Text(compactKeystrokeCount(day.estimatedKeys)).help(day.estimatedKeys.formatted())
                    }.font(.callout).monospacedDigit()
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                method(L("主要速度与语言"), L("字母语言的主要速度为按键折算 WPM = 输入过程 KPM ÷ 5，始终标为估算，包含组合与编辑，不代表真实词数。字符语言的主要速度为真实上屏 CPM，无法取得真实提交数据时显示不可用。输入源语言变化会切段，历史按语言独立汇总。"))
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
    private var totalsMetric: MetricDisplay { totals ?? metric }

    private var rateDescription: String {
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
                    Text(primaryCadence(metric.primaryRate, unit: metric.primaryUnit, includeUnit: false))
                        .font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    if metric.primaryUnit != .unknown {
                        Text(metric.primaryUnit.rawValue).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(rateDescription).font(.caption).foregroundStyle(.secondary)
                Divider()
                metricRow(L("今日主要速度（当前语言）"), primaryCadence(metric.todayPrimaryRate, unit: metric.primaryUnit))
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
                Text(L("要记录的输入语言")).font(.callout)
                Toggle(L("统计所有输入语言"), isOn: Binding(get: { model.monitorAllLanguages }, set: model.setMonitorAllLanguages))
                if !model.monitorAllLanguages {
                    ForEach(model.availableInputLanguages, id: \.id) { option in
                        Toggle(option.name, isOn: Binding(
                            get: { model.monitoredLanguages.contains(option.id) },
                            set: { model.setMonitoredLanguage(option.id, enabled: $0) }
                        ))
                    }
                    if model.monitoredLanguages.isEmpty {
                        Text(L("未选择任何语言，统计已停止"))
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Text(L("当前输入语言：%@", model.currentInputLanguage))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("依据键盘或输入法的语言筛选，不分析文字内容。中文输入法内直接输入英文仍归中文输入源。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("运行")) {
                Toggle(L("登录时启动 Keytempo"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                Picker(L("菜单栏显示"), selection: $model.menuDisplay) {
                    Text(L("主要速度（估算 WPM／字符 CPM）")).tag("speed")
                    Text(L("敲键节奏 KPM")).tag("kpm")
                    Text(L("今日敲键数量")).tag("count")
                    Text(L("仅图标")).tag("icon")
                }
                .onChange(of: model.menuDisplay) { _ in model.applySettings() }
                HStack {
                    Text(L(model.status)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isPaused ? L("恢复统计") : L("暂停统计"), action: model.togglePause)
                }
            }
            UpdateSettingsSection(updater: model.updates)
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
                    diagnosticRow(L("全局接收 / 未知操作"), "\(model.monitor.capturedEvents) / \(model.monitor.unknownEvents)")
                    diagnosticRow(L("自动重复 / 溢出丢失"), "\(model.monitor.repeatEvents) / \(model.monitor.overflowCount)")
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
