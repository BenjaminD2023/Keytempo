import SwiftUI
import TypingCore

private typealias AppearanceViewState<Value> = SwiftUI.State<Value>

/// Typing progression and freely selectable presentation preferences.
@MainActor struct ProgressionAppearanceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: DailyLevelProgress? {
        model.dailyRewardState.flatMap { DailyLevelProgress(totalXP: $0.totalXP) }
    }
    private var level: Int { progress?.level ?? 1 }
    private var currentRank: AppearanceOption { AppearanceCatalog.themes.last { level >= $0.level } ?? AppearanceCatalog.themes[0] }
    private var tint: Color { AppAppearanceStyle.accent(theme: model.effectiveAppearanceTheme, scheme: scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("等级与外观")).font(.title2.weight(.semibold))
                    Text(L("所有主题与图标均可自由使用，打字等级持续成长。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.dailyRewardError {
                    Label(L(error), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                levelProfile
                appearanceControls
                menuControls
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }.keytempoAppearance(model: model)

    }

    private var levelProfile: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                RankSeal(theme: currentRank.id, level: level, size: 84)
                VStack(alignment: .leading, spacing: 5) {
                    Text(progress.map { L("等级 %@", $0.level.formatted()) } ?? L("等级数据暂不可用"))
                        .font(.system(size: 27, weight: .semibold)).monospacedDigit()
                    Text(L(currentRank.name)).font(.callout).foregroundStyle(tint)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.dailyRewardState.map { L("%@ XP", $0.totalXP.formatted()) } ?? "— XP")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text(L("已入账累计 XP")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let progress {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("下一等级进度")).font(.callout)
                        Spacer(minLength: 12)
                        Text(L("%@ / %@ XP", progress.progressXP.formatted(), progress.requiredXP.formatted()))
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    LevelProgressTrack(value: Double(progress.progressXP) / Double(progress.requiredXP), theme: model.effectiveAppearanceTheme)
                    HStack {
                        Text(L("还需 %@ XP", progress.remainingXP.formatted()))
                        Spacer(minLength: 12)
                        if let threshold = progress.nextThreshold {
                            Text(L("目标累计 %@ XP", threshold.formatted()))
                        }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text(L("等级数据恢复后显示进度，所有外观仍可使用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(alignment: .topTrailing) {
            ThemeArtwork(theme: model.effectiveAppearanceTheme).frame(width: 350, height: 170).opacity(0.35)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("App 外观")).font(.headline)
            VStack(spacing: 0) {
                AppearanceSettingRow(title: L("明暗模式")) {
                    Picker(L("明暗模式"), selection: Binding(get: { model.appearanceMode }, set: model.setAppearanceMode)) {
                        Text(L("跟随系统")).tag("system")
                        Text(L("浅色")).tag("light")
                        Text(L("深色")).tag("dark")
                    }.pickerStyle(.segmented)
                        .tint(AppAppearanceStyle.filledControlTint(theme: model.effectiveAppearanceTheme))
                        .labelsHidden().frame(width: 280)
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            Text(L("主题")).font(.callout.weight(.medium)).padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(AppearanceCatalog.themes) { theme in
                    ThemeChoice(theme: theme, level: level,
                                selected: model.effectiveAppearanceTheme == theme.id) {
                        model.setAppearanceTheme(theme.id)
                    }
                }
            }
        }
    }

    private var menuControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("菜单栏")).font(.headline)
                Spacer(minLength: 12)
                Text(L("预览 · 当前数据")).font(.caption).foregroundStyle(.secondary)
            }
            menuPreview
            VStack(spacing: 0) {
                AppearanceSettingRow(title: L("图标样式")) {
                    Picker(L("图标样式"), selection: Binding(get: { model.effectiveMenuBarStyle }, set: model.setMenuBarStyle)) {
                        ForEach(AppearanceCatalog.icons) { icon in
                            Text(L(icon.name)).tag(icon.id)
                        }
                    }.labelsHidden().frame(width: 240)
                }
                Divider().padding(.horizontal, 16)
                menuMotionControls
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            Text(L("外观选择会自动保存，并立即应用。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menuMotionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("图标随打字速度动效"), isOn: Binding(
                get: { model.menuIconMotionEnabled }, set: { model.setMenuIconMotionEnabled($0) }))
            Text(L("图案与动效按所选 WPM 范围的百分比逐渐变化。停止输入后静止。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            MenuIconRangeControls(model: model)
            HStack(spacing: 12) {
                Button(L("预览菜单栏特效"), action: model.previewMenuEffects)
                    .disabled(!model.menuIconMotionEnabled || reduceMotion || contrast == .increased ||
                              ProcessInfo.processInfo.isLowPowerModeEnabled || model.menuEffectPreviewWPM != nil)
                if let sample = model.menuEffectPreviewWPM {
                    Text(L("示例 %@ WPM · %@", sample.formatted(.number.precision(.fractionLength(0))),
                           (model.menuIconSpeedRange.fraction(wpm: sample) ?? 0).formatted(.percent.precision(.fractionLength(0)))))
                        .font(.caption).monospacedDigit().foregroundStyle(tint)
                } else {
                    Text(L("%@ → %@ WPM · 6 秒", model.menuIconLowWPM.formatted(), model.menuIconHighWPM.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if reduceMotion || contrast == .increased || ProcessInfo.processInfo.isLowPowerModeEnabled {
                Text(L("系统减少动态效果、增强对比度或低电量模式开启时，暂停动画；速度图标仍更新图案。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private var menuPreview: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(nsImage: MenuIconRenderer.image(style: model.effectiveMenuBarStyle, level: level,
                    wpm: model.menuEffectPreviewWPM ?? model.appearanceMenuWPM,
                    lowWPM: model.menuIconLowWPM, highWPM: model.menuIconHighWPM))
                    .renderingMode(.template).frame(width: 18, height: 18).accessibilityHidden(true)
                if !previewText.isEmpty { Text(previewText).font(.system(size: 13, weight: .medium)).monospacedDigit() }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6).frame(minHeight: 27)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("菜单栏预览")).font(.callout.weight(.medium))
                Text(L("使用系统前景色，适应菜单栏明暗。")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if MenuIconRenderer.isSpeedResponsive(style: model.effectiveMenuBarStyle) {
                    Text(L("图案按速度百分比逐渐变化；停打后恢复静止图案。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                            let sample = max(0.001, model.menuIconLowWPM + fraction * (model.menuIconHighWPM - model.menuIconLowWPM))
                            HStack(spacing: 5) {
                                Image(nsImage: MenuIconRenderer.image(style: model.effectiveMenuBarStyle,
                                    level: level, wpm: sample, lowWPM: model.menuIconLowWPM, highWPM: model.menuIconHighWPM))
                                    .renderingMode(.template).frame(width: 18, height: 18).accessibilityHidden(true)
                                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit()
                            }
                        }
                    }.padding(.top, 3).accessibilityLabel(L("速度图案示例：0%、50%、100%"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 2)
    }

    private var previewText: String {
        switch model.menuDisplay {
        case "icon": return ""
        case "count": return "≈" + compactKeystrokeCount(model.dailyEstimate.keys)
        case "hybrid":
            switch model.hybridMenuDisplay {
            case .count: return "≈" + compactKeystrokeCount(model.dailyEstimate.keys)
            case let .wpm(value): return rateText(value, unit: "WPM")
            }
        default: return rateText(model.selectedMenuSpeed.value, unit: model.selectedMenuSpeed.unit)
        }
    }
    private func rateText(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "— " + unit }
        return "≈" + value.formatted(.number.precision(.fractionLength(0))) + " " + unit
    }
}

/// Keep edits local until both endpoints are valid, then persist one range.
private struct MenuIconRangeControls: View {
    @ObservedObject var model: AppModel
    @AppearanceViewState private var lowText = ""
    @AppearanceViewState private var highText = ""
    @AppearanceViewState private var invalidRange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 12) {
                endpoint(L("起点 WPM · 0%"), text: $lowText)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 6).accessibilityHidden(true)
                endpoint(L("终点 WPM · 100%"), text: $highText)
                Button(L("应用范围"), action: apply).padding(.bottom, 1)
                Button(L("恢复默认")) {
                    model.setMenuIconSpeedRange(lowWPM: 20, highWPM: 120)
                    reload()
                }.padding(.bottom, 1)
            }
            Text(L(invalidRange ? "范围须为 0–1,000 WPM，终点至少比起点高 1 WPM。" :
                   "范围外保持最低或最高强度。只调整外观，不影响打字统计。"))
                .font(.caption).foregroundStyle(invalidRange ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onChange(of: model.menuIconLowWPM) { _ in reload() }
        .onChange(of: model.menuIconHighWPM) { _ in reload() }
    }

    private func endpoint(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(width: 105)
                .accessibilityLabel(title).onSubmit(apply)
        }
    }
    private func apply() {
        guard let low = Double(lowText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let high = Double(highText.trimmingCharacters(in: .whitespacesAndNewlines)),
              model.setMenuIconSpeedRange(lowWPM: low, highWPM: high) else {
            invalidRange = true; return
        }
        reload()
    }
    private func reload() {
        lowText = String(format: "%g", model.menuIconLowWPM)
        highText = String(format: "%g", model.menuIconHighWPM)
        invalidRange = false
    }
}

private struct ThemeChoice: View {
    let theme: AppearanceOption
    let level: Int
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppearanceViewState private var hovered = false
    private var tint: Color { AppAppearanceStyle.accent(theme: theme.id, scheme: scheme) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .leading) {
                    ThemeArtwork(theme: theme.id)
                    RankSeal(theme: theme.id, level: level, size: 49).padding(.leading, 10)
                }.frame(height: 73)
                HStack(alignment: .center, spacing: 7) {
                    Text(L(theme.name)).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(tint)
                    }
                }.padding(.horizontal, 13).padding(.top, 1).padding(.bottom, 12)
            }
            .background(AppAppearanceStyle.canvas(theme: theme.id, scheme: scheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? tint : hovered ? tint.opacity(0.55) : Color.primary.opacity(contrast == .increased ? 0.4 : 0.1), lineWidth: selected ? 1.8 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(L("%@ 主题", L(theme.name)))
            .accessibilityValue(selected ? L("已选择") : L("未选择"))
            .help(L("%@ 主题", L(theme.name)))
    }
}

private struct AppearanceSettingRow<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(spacing: 20) {
            Text(title).font(.callout)
            Spacer(minLength: 12)
            content
        }.padding(16).frame(minHeight: 54)
    }
}
