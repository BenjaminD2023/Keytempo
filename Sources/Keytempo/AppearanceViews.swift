import SwiftUI
import TypingCore

private typealias AppearanceViewState<Value> = SwiftUI.State<Value>

/// Presentation preferences use the committed balance. Pending daily XP does
/// not unlock choices early; model setters enforce the same level gates.
@MainActor struct ProgressionAppearanceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppearanceViewState private var roadmapExpanded = false
    @AppearanceViewState private var gradientLowDraft = ""
    @AppearanceViewState private var gradientHighDraft = ""
    @AppearanceViewState private var gradientRangeError: String?

    private var progress: DailyLevelProgress? {
        model.dailyRewardState.flatMap { DailyLevelProgress(totalXP: $0.totalXP) }
    }
    private var level: Int { progress?.level ?? 1 }
    private var currentRank: AppearanceUnlock { AppearanceCatalog.themes.last { level >= $0.level } ?? AppearanceCatalog.themes[0] }
    private var nextUnlock: AppearanceUnlock? { AppearanceCatalog.milestones.first { $0.level > level } }
    private var customGradientUnlocked: Bool { level >= 70 }
    private var tint: Color { AppAppearanceStyle.accent(theme: model.effectiveAppearanceTheme, scheme: scheme) }
    private var gold: Color { AppAppearanceStyle.accent(theme: "stellar", scheme: scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("等级与外观")).font(.title2.weight(.semibold))
                    Text(L("用已结算 XP 解锁主题与菜单栏样式。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.dailyRewardError {
                    Label(L(error), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                levelProfile
                nextUnlockSummary
                appearanceControls
                menuControls
                customGradientControls
                unlockRoadmap
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }.keytempoAppearance(model: model)
            .onAppear(perform: loadGradientDrafts)
            .onChange(of: model.menuGradientLowWPM) { _ in loadGradientDrafts() }
            .onChange(of: model.menuGradientHighWPM) { _ in loadGradientDrafts() }
    }

    private var levelProfile: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                rankMedallion(currentRank, size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    Text(progress.map { L("等级 %@", $0.level.formatted()) } ?? L("等级数据暂不可用"))
                        .font(.title2.weight(.semibold)).monospacedDigit()
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
                    ProgressView(value: Double(progress.progressXP), total: Double(progress.requiredXP))
                        .tint(gold).accessibilityLabel(L("下一等级进度"))
                    HStack {
                        Text(L("还需 %@ XP", progress.remainingXP.formatted()))
                        Spacer(minLength: 12)
                        if let threshold = progress.nextThreshold {
                            Text(L("目标累计 %@ XP", threshold.formatted()))
                        }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text(L("等级数据恢复后显示进度，基础外观仍可使用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var nextUnlockSummary: some View {
        HStack(spacing: 12) {
            if let nextUnlock {
                Image(systemName: nextUnlock.symbol).font(.system(size: 20, weight: .regular))
                    .foregroundStyle(tint).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("下一解锁")).font(.caption).foregroundStyle(.secondary)
                    Text(unlockTitle(nextUnlock)).font(.callout.weight(.medium))
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("等级 %@", nextUnlock.level.formatted())).font(.callout.weight(.medium))
                    Text(L("累计 %@ XP", nextUnlock.threshold.formatted()))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Label(L("全部外观已解锁"), systemImage: "checkmark.circle").font(.callout).foregroundStyle(tint)
                Spacer()
            }
        }
    }

    private var unlockRoadmap: some View {
        DisclosureGroup(isExpanded: $roadmapExpanded) {
            VStack(spacing: 0) {
                ForEach(AppearanceCatalog.milestones) { unlock in
                    HStack(spacing: 12) {
                        Image(systemName: unlock.symbol).frame(width: 24)
                            .foregroundStyle(level >= unlock.level ? tint : .secondary).accessibilityHidden(true)
                        Text(unlockTitle(unlock)).font(.callout)
                        Spacer(minLength: 8)
                        Text(L("等级 %@", unlock.level.formatted())).font(.caption).monospacedDigit()
                        Text(L("%@ XP", unlock.threshold.formatted())).font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary).frame(minWidth: 95, alignment: .trailing)
                        Image(systemName: level >= unlock.level ? "checkmark.circle.fill" : "lock")
                            .foregroundStyle(level >= unlock.level ? tint : .secondary).frame(width: 18)
                            .accessibilityLabel(level >= unlock.level ? L("已解锁") : L("尚未解锁"))
                    }.padding(.vertical, 11).accessibilityElement(children: .combine)
                    if unlock.id != AppearanceCatalog.milestones.last?.id { Divider() }
                }
            }.padding(.top, 10)
        } label: { Text(L("等级路线图")).font(.headline) }
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
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                Divider().padding(.horizontal, 16)
                AppearanceSettingRow(title: L("主题")) {
                    HStack(spacing: 10) {
                        Circle().fill(tint).frame(width: 9, height: 9).accessibilityHidden(true)
                        Picker(L("主题"), selection: Binding(get: { model.effectiveAppearanceTheme }, set: model.setAppearanceTheme)) {
                            ForEach(AppearanceCatalog.themes) { theme in
                                Text(optionLabel(theme.name, required: theme.level)).tag(theme.id).disabled(level < theme.level)
                            }
                        }.labelsHidden().frame(width: 220)
                    }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
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
                            Text(optionLabel(icon.name, required: icon.level)).tag(icon.id).disabled(level < icon.level)
                        }
                    }.labelsHidden().frame(width: 240)
                }
                Divider().padding(.horizontal, 16)
                AppearanceSettingRow(title: L("图标与数字颜色")) {
                    Picker(L("图标与数字颜色"), selection: Binding(get: { model.effectiveMenuColorMode }, set: model.setMenuColorMode)) {
                        ForEach(AppearanceCatalog.colors) { color in
                            Text(optionLabel(color.name, required: color.level)).tag(color.id).disabled(level < color.level)
                        }
                    }.labelsHidden().frame(width: 240)
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            Text(L("已解锁的选择会自动保存，并立即应用。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var customGradientControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("自定义速度渐变")).font(.headline)
                Spacer(minLength: 12)
                if !customGradientUnlocked {
                    Label(L("等级 %@ 解锁", 70.formatted()), systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Toggle(L("使用自定义颜色与 WPM 范围"), isOn: Binding(
                    get: { customGradientUnlocked && model.menuCustomGradientEnabled }, set: { model.setMenuCustomGradientEnabled($0) }))
                    .disabled(!customGradientUnlocked)
                if customGradientUnlocked && model.menuCustomGradientEnabled {
                    HStack(spacing: 24) {
                        gradientColorWell(low: true)
                        gradientColorWell(low: false)
                    }
                    Divider()
                    HStack(alignment: .bottom, spacing: 16) {
                        gradientRangeField(low: true)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 6).accessibilityHidden(true)
                        gradientRangeField(low: false)
                        Spacer(minLength: 4)
                        Button(L("应用范围"), action: applyGradientRange).padding(.bottom, 1)
                    }
                    if let gradientRangeError {
                        Label(L(gradientRangeError), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [gradientColor(low: true), gradientColor(low: false)],
                            startPoint: .leading, endPoint: .trailing)).frame(height: 8).accessibilityHidden(true)
                        HStack {
                            Text(rangeText(model.menuGradientLowWPM) + " WPM")
                            Spacer()
                            Text(L("所选颜色范围"))
                            Spacer()
                            Text(rangeText(model.menuGradientHighWPM) + " WPM")
                        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if !customGradientUnlocked {
                    Text(L("累计 %@ XP 解锁自定义低速、高速颜色与渐变范围。", (DailyLevelSchedule.threshold(for: 70) ?? 0).formatted()))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            Text(L("启用后使用速度着色；颜色亮度随菜单栏明暗自动适配。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func gradientColorWell(low: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(low ? "低速端颜色" : "高速端颜色")).font(.callout)
                Text("#" + (low ? model.menuLowColorHex : model.menuHighColorHex)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ColorPicker(L(low ? "低速端颜色" : "高速端颜色"), selection: Binding(
                get: { gradientColor(low: low) }, set: { setGradientColor($0, low: low) }), supportsOpacity: false)
                .labelsHidden().frame(width: 38)
        }.frame(maxWidth: .infinity)
    }
    private func gradientRangeField(low: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(low ? "起始 WPM" : "结束 WPM")).font(.caption).foregroundStyle(.secondary)
            TextField(L(low ? "起始 WPM" : "结束 WPM"), text: low ? $gradientLowDraft : $gradientHighDraft)
                .textFieldStyle(.roundedBorder).frame(width: 100).monospacedDigit()
        }
    }
    private func gradientColor(low: Bool) -> Color {
        let hex = low ? model.menuLowColorHex : model.menuHighColorHex
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .primary }
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
    private func setGradientColor(_ value: Color, low: Bool) {
        guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return }
        let bytes = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        let hex = String(format: "%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        if low { model.setMenuLowColorHex(hex) } else { model.setMenuHighColorHex(hex) }
    }
    private func applyGradientRange() {
        guard let low = Double(gradientLowDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              let high = Double(gradientHighDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              low.isFinite, high.isFinite, (0...1000).contains(low), (0...1000).contains(high), high >= low + 1 else {
            gradientRangeError = "范围须为 0–1000 WPM，高速端至少比低速端高 1 WPM。"; return
        }
        model.setMenuGradientRange(low: low, high: high); gradientRangeError = nil
    }
    private func loadGradientDrafts() {
        gradientLowDraft = rangeText(model.menuGradientLowWPM); gradientHighDraft = rangeText(model.menuGradientHighWPM)
        gradientRangeError = nil
    }
    private func rangeText(_ value: Double) -> String {
        guard value.isFinite, (0...1000).contains(value) else { return "—" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private var menuPreview: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: menuSymbol).font(.system(size: 14, weight: .medium)).accessibilityHidden(true)
                if !previewText.isEmpty { Text(previewText).font(.system(size: 13, weight: .medium)).monospacedDigit() }
            }
            .foregroundStyle(menuTint)
            .padding(.horizontal, 15).frame(minWidth: 105, minHeight: 36)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("菜单栏预览")).font(.callout.weight(.medium))
                Text(L(colorExplanation)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(tint.opacity(scheme == .dark ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(contrast == .increased ? 0.65 : 0.15), lineWidth: 1) }
    }

    private var menuSymbol: String {
        AppAppearanceStyle.menuSymbol(style: model.effectiveMenuBarStyle)
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
    private var colorExplanation: String {
        switch model.effectiveMenuColorMode {
        case "speed": return customGradientUnlocked && model.menuCustomGradientEnabled ? "使用自定义速度范围与颜色。" : "颜色随最新估算 WPM 变化。"
        case "volume": return "颜色随今日已接受敲键量变化。"
        default: return "使用系统前景色，适应菜单栏明暗。"
        }
    }
    private var menuTint: Color {
        let color = model.menuAppearanceTint(dark: scheme == .dark, increasedContrast: contrast == .increased)
        return color.map { Color(nsColor: $0) } ?? .primary
    }
    private func unlockTitle(_ unlock: AppearanceUnlock) -> String {
        if AppearanceCatalog.themes.contains(where: { $0.id == unlock.id }) { return L("%@ 主题", L(unlock.name)) }
        if AppearanceCatalog.icons.contains(where: { $0.id == unlock.id }) { return L("%@ 图标", L(unlock.name)) }
        return L(unlock.name)
    }
    private func optionLabel(_ title: String, required: Int) -> String {
        level >= required ? L(title) : L("%@ · 等级 %@ 解锁", L(title), required.formatted())
    }
    private func rankMedallion(_ rank: AppearanceUnlock, size: CGFloat) -> some View {
        let color = AppAppearanceStyle.accent(theme: rank.id, scheme: scheme)
        return ZStack {
            Circle().fill(color.opacity(0.10))
            Circle().strokeBorder(color.opacity(0.28), lineWidth: 1)
            Circle().inset(by: 6).strokeBorder(color.opacity(0.15), lineWidth: 1)
            Image(systemName: rank.symbol).font(.system(size: size * 0.36, weight: .light)).foregroundStyle(color)
        }.frame(width: size, height: size).accessibilityHidden(true)
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
