import AppKit
import SwiftUI
import TypingCore
import TypingStore

struct AppearanceUnlock: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let level: Int
    var threshold: Int { DailyLevelSchedule.threshold(for: level) ?? 0 }
}

enum AppearanceCatalog {
    static let customGradientLevel = 70
    static let themes: [AppearanceUnlock] = [
        .init(id: "classic", name: "经典", symbol: "circle.hexagongrid", level: 1),
        .init(id: "ocean", name: "海洋", symbol: "water.waves", level: 10),
        .init(id: "prism", name: "棱光", symbol: "diamond", level: 20),
        .init(id: "forest", name: "森林", symbol: "leaf", level: 30),
        .init(id: "ember", name: "余烬", symbol: "flame", level: 40),
        .init(id: "graphite", name: "石墨", symbol: "square.stack.3d.up", level: 50),
        .init(id: "stellar", name: "星辉", symbol: "sparkle", level: 60),
        .init(id: "rose", name: "玫瑰", symbol: "camera.macro", level: 80),
        .init(id: "aurora", name: "极光", symbol: "light.beacon.max", level: 100)
    ]
    static let icons: [AppearanceUnlock] = [
        .init(id: "keyboard", name: "键盘", symbol: "keyboard", level: 1),
        .init(id: "wave", name: "声波", symbol: "waveform", level: 5),
        .init(id: "orbit", name: "轨道", symbol: "circle.dotted", level: 25),
        .init(id: "spark", name: "星芒", symbol: "sparkles", level: 35),
        .init(id: "bolt", name: "闪电", symbol: "bolt.fill", level: 55)
    ]
    static let colors: [AppearanceUnlock] = [
        .init(id: "system", name: "系统颜色", symbol: "circle.lefthalf.filled", level: 1),
        .init(id: "speed", name: "随速度变化", symbol: "speedometer", level: 15),
        .init(id: "volume", name: "随今日输入量变化", symbol: "chart.bar", level: 45)
    ]
    static let milestones: [AppearanceUnlock] = (themes + icons.filter { $0.level > 1 } + colors.filter { $0.level > 1 } + [
        .init(id: "settlement-prism", name: "棱光结算特效", symbol: "diamond", level: 18),
        .init(id: "settlement-stellar", name: "星辉结算特效", symbol: "sparkles", level: 58),
        .init(id: "custom-gradient", name: "自定义速度渐变", symbol: "slider.horizontal.3", level: customGradientLevel)
    ]).sorted { $0.level < $1.level }
}

/// Cosmetic unlocks never change measurement, XP or the level schedule.
enum AppearancePolicy {
    enum Choice { case theme, icon, color }
    static func mode(_ value: String) -> String { ["system", "light", "dark"].contains(value) ? value : "system" }
    static func requiredLevel(_ value: String, choice: Choice) -> Int? {
        switch choice {
        case .theme: return AppearanceCatalog.themes.first { $0.id == value }?.level
        case .icon: return AppearanceCatalog.icons.first { $0.id == value }?.level
        case .color: return AppearanceCatalog.colors.first { $0.id == value }?.level
        }
    }
    static func effective(_ value: String, choice: Choice, level: Int) -> String {
        if let required = requiredLevel(value, choice: choice), level >= required { return value }
        switch choice { case .theme: return "classic"; case .icon: return "keyboard"; case .color: return "system" }
    }
    static func hex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return digits.uppercased()
    }
    static func validRange(low: Double, high: Double) -> Bool {
        low.isFinite && high.isFinite && low >= 0 && high <= 1000 && high >= low + 1
    }
    static func fraction(mode: String, wpm: Double?, keys: Int) -> Double? {
        switch mode {
        case "speed":
            guard let wpm, wpm.isFinite, wpm >= 0 else { return nil }
            return min(1, wpm / 120)
        case "volume": return min(1, Double(max(0, keys)) / 20_000)
        default: return nil
        }
    }
}

enum AppAppearanceStyle {
    static func accent(theme: String, scheme: ColorScheme) -> Color {
        switch (theme, scheme) {
        case ("ocean", .dark): return Color(red: 0.40, green: 0.72, blue: 0.98)
        case ("ocean", _): return Color(red: 0.08, green: 0.38, blue: 0.65)
        case ("forest", .dark): return Color(red: 0.52, green: 0.85, blue: 0.58)
        case ("forest", _): return Color(red: 0.16, green: 0.41, blue: 0.26)
        case ("ember", .dark): return Color(red: 0.98, green: 0.64, blue: 0.37)
        case ("ember", _): return Color(red: 0.66, green: 0.28, blue: 0.10)
        case ("graphite", .dark): return Color(red: 0.77, green: 0.82, blue: 0.88)
        case ("graphite", _): return Color(red: 0.30, green: 0.35, blue: 0.40)
        case ("rose", .dark): return Color(red: 0.97, green: 0.63, blue: 0.74)
        case ("rose", _): return Color(red: 0.64, green: 0.28, blue: 0.43)
        case ("aurora", .dark): return Color(red: 0.66, green: 0.72, blue: 0.99)
        case ("aurora", _): return Color(red: 0.29, green: 0.30, blue: 0.67)
        case ("prism", .dark): return Color(red: 0.76, green: 0.66, blue: 0.98)
        case ("prism", _): return Color(red: 0.43, green: 0.32, blue: 0.68)
        case ("stellar", .dark): return Color(red: 0.95, green: 0.79, blue: 0.46)
        case ("stellar", _): return Color(red: 0.58, green: 0.37, blue: 0.07)
        case (_, .dark): return Color(red: 0.48, green: 0.88, blue: 0.79)
        default: return Color(red: 0.04, green: 0.42, blue: 0.39)
        }
    }
    static func canvas(theme: String, scheme: ColorScheme) -> Color {
        switch (theme, scheme) {
        case ("ocean", .dark): return Color(red: 0.09, green: 0.13, blue: 0.18)
        case ("ocean", _): return Color(red: 0.95, green: 0.977, blue: 0.993)
        case ("forest", .dark): return Color(red: 0.10, green: 0.15, blue: 0.12)
        case ("forest", _): return Color(red: 0.96, green: 0.983, blue: 0.96)
        case ("ember", .dark): return Color(red: 0.17, green: 0.11, blue: 0.09)
        case ("ember", _): return Color(red: 0.995, green: 0.97, blue: 0.95)
        case ("graphite", .dark): return Color(red: 0.10, green: 0.11, blue: 0.12)
        case ("graphite", _): return Color(red: 0.965, green: 0.97, blue: 0.975)
        case ("rose", .dark): return Color(red: 0.17, green: 0.105, blue: 0.14)
        case ("rose", _): return Color(red: 0.99, green: 0.962, blue: 0.975)
        case ("aurora", .dark): return Color(red: 0.12, green: 0.11, blue: 0.19)
        case ("aurora", _): return Color(red: 0.965, green: 0.963, blue: 0.995)
        case ("prism", .dark): return Color(red: 0.12, green: 0.11, blue: 0.15)
        case ("prism", _): return Color(red: 0.975, green: 0.969, blue: 0.989)
        case ("stellar", .dark): return Color(red: 0.10, green: 0.12, blue: 0.16)
        case ("stellar", _): return Color(red: 0.98, green: 0.972, blue: 0.949)
        default: return Color(nsColor: .windowBackgroundColor)
        }
    }
    static func menuSymbol(style: String) -> String {
        AppearanceCatalog.icons.first { $0.id == style }?.symbol ?? "keyboard"
    }
    static func color(hex: String) -> NSColor? {
        guard let normalized = AppearancePolicy.hex(hex), let value = UInt32(normalized, radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func gradientTint(wpm: Double?, lowHex: String, highHex: String, lowWPM: Double, highWPM: Double, dark: Bool) -> NSColor? {
        guard let wpm, wpm.isFinite, AppearancePolicy.validRange(low: lowWPM, high: highWPM),
              let low = color(hex: lowHex), let high = color(hex: highHex) else { return nil }
        let f = min(1, max(0, (wpm - lowWPM) / (highWPM - lowWPM)))
        return NSColor(srgbRed: low.redComponent + (high.redComponent - low.redComponent) * f,
                       green: low.greenComponent + (high.greenComponent - low.greenComponent) * f,
                       blue: low.blueComponent + (high.blueComponent - low.blueComponent) * f, alpha: 1)
    }
    /// Preserve hue and adapt brightness for the bar's light/dark appearance.
    static func accessibleTint(_ color: NSColor, dark: Bool) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .labelColor }
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        let background = linear(dark ? 0.12 : 0.97)
        let r = Double(rgb.redComponent), g = Double(rgb.greenComponent), b = Double(rgb.blueComponent)
        let target = dark ? 1.0 : 0.0
        func candidate(_ f: Double) -> (Double, Double, Double) { (r + (target - r) * f, g + (target - g) * f, b + (target - b) * f) }
        func contrast(_ c: (Double, Double, Double)) -> Double {
            let value = luminance(c.0, c.1, c.2)
            return (max(value, background) + 0.05) / (min(value, background) + 0.05)
        }
        guard contrast((r, g, b)) < 4.5 else { return color }
        var lower = 0.0, upper = 1.0
        for _ in 0..<12 {
            let middle = (lower + upper) / 2
            if contrast(candidate(middle)) >= 4.5 { upper = middle } else { lower = middle }
        }
        let adjusted = candidate(upper)
        return NSColor(srgbRed: adjusted.0, green: adjusted.1, blue: adjusted.2, alpha: 1)
    }
    /// A bounded color ramp reuses existing snapshots; no animation or timer.
    static func menuTint(mode: String, wpm: Double?, keys: Int, dark: Bool) -> NSColor? {
        guard let f = AppearancePolicy.fraction(mode: mode, wpm: wpm, keys: keys) else { return nil }
        let start = dark ? (0.48, 0.88, 0.79) : (0.04, 0.42, 0.39)
        let end = dark ? (0.95, 0.79, 0.46) : (0.58, 0.37, 0.07)
        return NSColor(srgbRed: start.0 + (end.0 - start.0) * f,
                       green: start.1 + (end.1 - start.1) * f,
                       blue: start.2 + (end.2 - start.2) * f, alpha: 1)
    }
}

private struct KeytempoThemeKey: EnvironmentKey { static let defaultValue = "classic" }
extension EnvironmentValues {
    var keytempoTheme: String {
        get { self[KeytempoThemeKey.self] }
        set { self[KeytempoThemeKey.self] = newValue }
    }
}
private struct AppAppearanceSurface: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let selected: ColorScheme? = model.appearanceMode == "dark" ? .dark : model.appearanceMode == "light" ? .light : nil
        let resolved = selected ?? scheme
        content
            .environment(\.keytempoTheme, model.effectiveAppearanceTheme)
            .tint(AppAppearanceStyle.accent(theme: model.effectiveAppearanceTheme, scheme: resolved))
            .background(AppAppearanceStyle.canvas(theme: model.effectiveAppearanceTheme, scheme: resolved))
            .preferredColorScheme(selected)
    }
}
extension View {
    func keytempoAppearance(model: AppModel) -> some View { modifier(AppAppearanceSurface(model: model)) }
}

@MainActor func runAppearanceChecks() -> [String] {
    var failures = [String]()
    func expect(_ condition: Bool, _ label: String) { if !condition { failures.append("FAIL: appearance \(label)") } }
    let themes = [("classic", 1), ("ocean", 10), ("prism", 20), ("forest", 30), ("ember", 40),
                  ("graphite", 50), ("stellar", 60), ("rose", 80), ("aurora", 100)]
    let icons = [("keyboard", 1), ("wave", 5), ("orbit", 25), ("spark", 35), ("bolt", 55)]
    let colors = [("system", 1), ("speed", 15), ("volume", 45)]
    expect(AppearanceCatalog.themes.count == 9 && AppearanceCatalog.themes.map(\.id) == themes.map(\.0), "nine ordered theme choices")
    expect(AppearanceCatalog.icons.map(\.id) == icons.map(\.0) && AppearanceCatalog.colors.map(\.id) == colors.map(\.0), "complete icon and color catalogs")
    let milestones = AppearanceCatalog.milestones.map(\.level)
    expect(milestones.count == 18 && Set(milestones).count == milestones.count && milestones == milestones.sorted(), "sorted unique unlock milestones")
    expect(AppearanceCatalog.customGradientLevel == 70, "custom speed gradient unlocks at 70")
    for (choice, baseline, options) in [(AppearancePolicy.Choice.theme, "classic", themes), (.icon, "keyboard", icons), (.color, "system", colors)] {
        for (value, level) in options {
            expect(AppearancePolicy.requiredLevel(value, choice: choice) == level, "\(value) unlock threshold")
            expect(AppearancePolicy.effective(value, choice: choice, level: level) == value, "\(value) unlocks exactly at \(level)")
            if level > 1 {
                expect(AppearancePolicy.effective(value, choice: choice, level: level - 1) == baseline, "\(value) remains locked before threshold")
                expect(AppearancePolicy.effective(value, choice: choice, level: 1) == baseline, "\(value) clear/reset fallback")
            }
        }
        expect(AppearancePolicy.effective("invalid", choice: choice, level: 100) == baseline, "invalid stored option fallback")
    }
    expect(AppearancePolicy.mode("invalid") == "system", "invalid mode follows system")
    expect(AppearancePolicy.fraction(mode: "speed", wpm: nil, keys: 0) == nil && AppearancePolicy.fraction(mode: "speed", wpm: .nan, keys: 0) == nil, "missing speed stays neutral")
    expect(AppearancePolicy.fraction(mode: "speed", wpm: 60, keys: 0) == 0.5 && AppearancePolicy.fraction(mode: "speed", wpm: 240, keys: 0) == 1, "speed ramp bounded")
    expect(AppearancePolicy.fraction(mode: "volume", wpm: nil, keys: 10_000) == 0.5 && AppearancePolicy.fraction(mode: "volume", wpm: nil, keys: Int.max) == 1, "volume ramp bounded")
    expect(AppAppearanceStyle.menuSymbol(style: "spark") == "sparkles", "native icon mapping")
    expect(AppearancePolicy.hex("#a1b2c3") == "A1B2C3" && AppearancePolicy.hex("112233") == "112233", "custom colors normalize six hex digits")
    for value in ["#123", "GGGGGG", "AA00FF11", "../AABBCC"] {
        expect(AppearancePolicy.hex(value) == nil, "invalid custom color rejected")
    }
    func gradient(_ wpm: Double?) -> NSColor? {
        AppAppearanceStyle.gradientTint(wpm: wpm, lowHex: "112233", highHex: "AABBCC", lowWPM: 20, highWPM: 140, dark: false)?.usingColorSpace(.sRGB)
    }
    if let low = gradient(20), let middle = gradient(80), let high = gradient(140), let below = gradient(0), let above = gradient(300) {
        expect(abs(low.redComponent - below.redComponent) < 1e-6 && abs(low.greenComponent - below.greenComponent) < 1e-6 &&
               abs(low.blueComponent - below.blueComponent) < 1e-6, "custom gradient clamps below low WPM")
        expect(abs(high.redComponent - above.redComponent) < 1e-6 && abs(high.greenComponent - above.greenComponent) < 1e-6 &&
               abs(high.blueComponent - above.blueComponent) < 1e-6, "custom gradient clamps above high WPM")
        expect(abs(middle.redComponent - (low.redComponent + high.redComponent) / 2) < 1e-6 &&
               abs(middle.greenComponent - (low.greenComponent + high.greenComponent) / 2) < 1e-6 &&
               abs(middle.blueComponent - (low.blueComponent + high.blueComponent) / 2) < 1e-6, "custom gradient interpolates midpoint")
        expect(abs(low.redComponent - high.redComponent) > 0.1, "custom endpoints produce distinct colors")
    } else { failures.append("FAIL: appearance valid custom gradient endpoints") }
    expect(gradient(nil) == nil && gradient(.nan) == nil, "missing current speed has no custom tint")
    failures += runAppearancePersistenceChecks()
    return failures
}

/// Public coordinator setters, isolated preferences and a disposable ledger.
/// Cosmetic selection must never spend XP or change measured input history.
@MainActor private func runAppearancePersistenceChecks() -> [String] {
    var failures = [String]()
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { failures.append("FAIL: appearance preferences \(label)") }
    }
    func waitFor(_ condition: () -> Bool, _ label: String) {
        let deadline = Date().addingTimeInterval(6)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        expect(condition(), label)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-appearance-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    for (expectedLevel, theme, icon, color) in [(1, "classic", "keyboard", "system"),
                                              (20, "prism", "wave", "speed"),
                                              (60, "stellar", "bolt", "volume"),
                                              (70, "stellar", "bolt", "speed")] {
        guard let seedXP = DailyLevelSchedule.threshold(for: expectedLevel), seedXP.isMultiple(of: DailyRewardPolicy.legacyScale) else {
            failures.append("FAIL: appearance preferences exact level \(expectedLevel) threshold")
            continue
        }
        let legacyXP = seedXP / DailyRewardPolicy.legacyScale
        let suiteName = "local.keytempo.appearance-check.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            failures.append("FAIL: appearance preferences isolated defaults suite")
            continue
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let directory = root.appendingPathComponent("level-\(expectedLevel)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            var seed = DailyRewardEngine(legacyTotalXP: legacyXP)
            let checkpoint = seed.checkpoint()
            try store.save([], dailyRewards: checkpoint, batchID: "appearance-seed-\(UUID().uuidString)")
            let model = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
            expect(model.appearanceLevel == expectedLevel, "seed unlocks exactly level \(expectedLevel)")
            let dailyBefore = model.dailyRewardState
            let legacyBefore = model.rewardState
            let storedBefore = try store.loadDailyRewardState()?.totalXP
            let customBefore = model.menuCustomGradientEnabled
            let lowColorBefore = model.menuLowColorHex, highColorBefore = model.menuHighColorHex
            let lowWPMBefore = model.menuGradientLowWPM, highWPMBefore = model.menuGradientHighWPM

            if expectedLevel == 1 {
                for value in ["ocean", "prism", "forest", "ember", "graphite", "stellar", "rose", "aurora", "invalid"] { model.setAppearanceTheme(value) }
                for value in ["wave", "orbit", "spark", "bolt", "invalid"] { model.setMenuBarStyle(value) }
                for value in ["speed", "volume", "invalid"] { model.setMenuColorMode(value) }
                expect(model.appearanceTheme == "classic" && model.menuBarStyle == "keyboard" && model.menuColorMode == "system",
                       "locked and invalid choices rejected at level 1")
                expect(preferences.string(forKey: "appearanceTheme") == nil && preferences.string(forKey: "menuBarStyle") == nil &&
                       preferences.string(forKey: "menuColorMode") == nil, "locked choices are not persisted")
            } else {
                model.setAppearanceMode("dark")
                model.setAppearanceTheme(theme); model.setMenuBarStyle(icon); model.setMenuColorMode(color)
                expect(model.appearanceMode == "dark" && model.appearanceTheme == theme && model.menuBarStyle == icon && model.menuColorMode == color,
                       "public setters accept level \(expectedLevel) choices")
                if expectedLevel == 20 {
                    model.setAppearanceTheme("stellar"); model.setMenuBarStyle("spark"); model.setMenuColorMode("volume")
                    expect(model.appearanceTheme == theme && model.menuBarStyle == icon && model.menuColorMode == color,
                           "higher level choices rejected without replacing level 20 selection")
                }
                expect(preferences.string(forKey: "appearanceMode") == "dark" && preferences.string(forKey: "appearanceTheme") == theme &&
                       preferences.string(forKey: "menuBarStyle") == icon && preferences.string(forKey: "menuColorMode") == color,
                       "accepted level \(expectedLevel) choices persist in isolated defaults")
            }
            model.setMenuCustomGradientEnabled(true)
            model.setMenuLowColorHex("#112233"); model.setMenuHighColorHex("aabbcc")
            model.setMenuGradientRange(low: 25, high: 175)
            if expectedLevel < 70 {
                expect(model.menuCustomGradientEnabled == customBefore && model.menuLowColorHex == lowColorBefore && model.menuHighColorHex == highColorBefore &&
                       model.menuGradientLowWPM == lowWPMBefore && model.menuGradientHighWPM == highWPMBefore,
                       "custom gradient setters rejected below level 70")
            } else {
                expect(model.menuCustomGradientEnabled && model.menuLowColorHex == "112233" && model.menuHighColorHex == "AABBCC" &&
                       model.menuGradientLowWPM == 25 && model.menuGradientHighWPM == 175, "custom gradient accepted exactly at level 70")
                model.setMenuLowColorHex("invalid"); model.setMenuHighColorHex("123")
                expect(model.menuLowColorHex == "112233" && model.menuHighColorHex == "AABBCC", "invalid custom colors leave selection intact")
                expect(preferences.bool(forKey: "menuCustomGradientEnabled") && preferences.string(forKey: "menuLowColorHex") == "112233" &&
                       preferences.string(forKey: "menuHighColorHex") == "AABBCC" && preferences.double(forKey: "menuGradientLowWPM") == 25 &&
                       preferences.double(forKey: "menuGradientHighWPM") == 175, "custom gradient persists in isolated preferences")
            }
            expect(model.dailyRewardState == dailyBefore && model.rewardState == legacyBefore,
                   "cosmetic choices leave both reward states unchanged at level \(expectedLevel)")
            let storedAfter = try store.loadDailyRewardState()?.totalXP
            expect(storedAfter == storedBefore, "cosmetic choices do not change stored XP")
            model.flushBeforeExit()

            let restored = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
            expect(restored.appearanceLevel == expectedLevel && restored.dailyRewardState?.totalXP == legacyXP * DailyRewardPolicy.legacyScale,
                   "reload preserves level and all XP")
            expect(restored.appearanceTheme == theme && restored.menuBarStyle == icon && restored.menuColorMode == color &&
                   restored.effectiveAppearanceTheme == theme && restored.effectiveMenuBarStyle == icon && restored.effectiveMenuColorMode == color,
                   "reload restores selected and effective level \(expectedLevel) cosmetics")
            expect(restored.appearanceMode == (expectedLevel == 1 ? "system" : "dark"), "reload restores app appearance mode")
            if expectedLevel == 70 {
                expect(restored.menuCustomGradientEnabled && restored.menuLowColorHex == "112233" && restored.menuHighColorHex == "AABBCC" &&
                       restored.menuGradientLowWPM == 25 && restored.menuGradientHighWPM == 175, "reload restores complete custom gradient")
            } else {
                expect(restored.menuCustomGradientEnabled == customBefore && restored.menuLowColorHex == lowColorBefore && restored.menuHighColorHex == highColorBefore &&
                       restored.menuGradientLowWPM == lowWPMBefore && restored.menuGradientHighWPM == highWPMBefore, "locked custom choices do not survive as preferences")
            }

            if expectedLevel == 60 || expectedLevel == 70 {
                restored.clearHistory()
                waitFor({ restored.dailyRewardState?.totalXP == 0 && restored.appearanceLevel == 1 }, "explicit clear completes and resets XP")
                expect(restored.effectiveAppearanceTheme == "classic" && restored.effectiveMenuBarStyle == "keyboard" && restored.effectiveMenuColorMode == "system",
                       "clear history falls back to unlocked cosmetics")
                expect(restored.appearanceTheme == theme && restored.menuBarStyle == icon && restored.menuColorMode == color && restored.appearanceMode == "dark",
                       "clear preserves cosmetic preferences while applying level fallback")
                if expectedLevel == 70 {
                    expect(restored.menuCustomGradientEnabled && restored.menuLowColorHex == "112233" && restored.menuHighColorHex == "AABBCC" &&
                           restored.menuGradientLowWPM == 25 && restored.menuGradientHighWPM == 175, "clear retains saved custom gradient without granting level 70")
                }
                restored.flushBeforeExit()
                let cleared = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
                expect(cleared.dailyRewardState?.totalXP == 0 && cleared.appearanceLevel == 1 &&
                       cleared.effectiveAppearanceTheme == "classic" && cleared.effectiveMenuBarStyle == "keyboard" && cleared.effectiveMenuColorMode == "system",
                       "clear fallback and zero XP survive reload")
                cleared.flushBeforeExit()
            } else { restored.flushBeforeExit() }
        } catch {
            failures.append("FAIL: appearance preferences level \(expectedLevel) fixture: \(error.localizedDescription)")
        }
    }
    return failures
}
