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
        .init(id: "rhythm", name: "节奏柱", symbol: "chart.bar.fill", level: 15),
        .init(id: "orbit", name: "轨道", symbol: "circle.dotted", level: 25),
        .init(id: "spark", name: "星芒", symbol: "sparkles", level: 35),
        .init(id: "ripple", name: "波纹", symbol: "dot.radiowaves.left.and.right", level: 45),
        .init(id: "bolt", name: "闪电", symbol: "bolt.fill", level: 55),
        .init(id: "comet", name: "流星", symbol: "sparkle", level: 70)
    ]
    static let milestones: [AppearanceUnlock] = (themes + icons.filter { $0.level > 1 }).sorted { $0.level < $1.level }
}

/// Cosmetic unlocks never change measurement, XP or the level schedule.
enum AppearancePolicy {
    enum Choice { case theme, icon }
    static func mode(_ value: String) -> String { ["system", "light", "dark"].contains(value) ? value : "system" }
    static func requiredLevel(_ value: String, choice: Choice) -> Int? {
        switch choice {
        case .theme: return AppearanceCatalog.themes.first { $0.id == value }?.level
        case .icon: return AppearanceCatalog.icons.first { $0.id == value }?.level
        }
    }
    static func effective(_ value: String, choice: Choice, level: Int) -> String {
        if let required = requiredLevel(value, choice: choice), level >= required { return value }
        switch choice { case .theme: return "classic"; case .icon: return "keyboard" }
    }
}

enum AppAppearanceStyle {
    /// Native selected segments and prominent buttons draw white labels.
    /// Their fill uses the deeper palette in both appearances; the separate
    /// accent palette remains bright enough for text and artwork in dark mode.
    static func filledControlTint(theme: String) -> Color {
        accent(theme: theme, scheme: .light)
    }
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
    let icons = [("keyboard", 1), ("wave", 5), ("rhythm", 15), ("orbit", 25), ("spark", 35),
                 ("ripple", 45), ("bolt", 55), ("comet", 70)]
    expect(AppearanceCatalog.themes.map(\.id) == themes.map(\.0), "nine ordered theme choices")
    expect(AppearanceCatalog.icons.map(\.id) == icons.map(\.0), "eight ordered icon choices")
    let milestones = AppearanceCatalog.milestones.map(\.level)
    let milestoneIDs = Set(AppearanceCatalog.milestones.map(\.id))
    expect(milestones == [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 70, 80, 100], "theme and icon unlock levels")
    expect(milestoneIDs == Set(themes.map(\.0) + icons.dropFirst().map(\.0)), "roadmap only contains themes and icons")
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        guard let appearance = NSAppearance(named: appearanceName) else {
            failures.append("FAIL: appearance missing native appearance for filled-control contrast checks")
            continue
        }
        appearance.performAsCurrentDrawingAppearance {
            for theme in AppearanceCatalog.themes {
                guard let fill = NSColor(AppAppearanceStyle.filledControlTint(theme: theme.id)).usingColorSpace(.sRGB) else {
                    failures.append("FAIL: appearance unresolved filled-control tint for \(theme.id)")
                    continue
                }
                func linear(_ value: CGFloat) -> Double {
                    let component = Double(value)
                    return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(fill.redComponent) + 0.7152 * linear(fill.greenComponent) + 0.0722 * linear(fill.blueComponent)
                expect(abs(fill.alphaComponent - 1) < 1e-6 && 1.05 / (luminance + 0.05) >= 4.5,
                       "white filled-control label contrast for \(theme.id) in \(appearanceName.rawValue)")
            }
        }
    }
    expect(AppAppearanceStyle.rankTheme(level: 10_000) == "aurora", "unbounded levels retain highest rank artwork")
    failures += runProportionalMenuIconChecks()
    for (choice, baseline, options) in [(AppearancePolicy.Choice.theme, "classic", themes), (.icon, "keyboard", icons)] {
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
    expect(AppAppearanceStyle.menuSymbol(style: "spark") == "sparkles", "native icon mapping")
    failures += runAppearancePersistenceChecks()
    return failures
}

/// Exercise actual template raster output, not only the normalized scalar.
/// Every responsive icon must change within the old 40–80 WPM tier, and the
/// user's range must affect geometry and the shared motion profile equally.
@MainActor private func runProportionalMenuIconChecks() -> [String] {
    var failures = [String]()
    func expect(_ condition: Bool, _ label: String) {
        if !condition { failures.append("FAIL: proportional menu icons \(label)") }
    }
    let standard = MenuIconSpeedRange.default
    let invalidRates: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 0]
    for rate in invalidRates {
        expect(standard.fraction(wpm: rate) == nil, "invalid and absent rate remains idle")
    }
    for percentage in 0...100 {
        let wpm = 20 + Double(percentage)
        expect(abs((standard.fraction(wpm: wpm) ?? -1) - Double(percentage) / 100) < 1e-9,
               "configured range maps linearly at \(percentage)%")
    }
    expect(standard.fraction(wpm: 1) == 0 && standard.fraction(wpm: .greatestFiniteMagnitude) == 1,
           "valid rates outside the range clamp to its endpoints")
    let dynamicIDs: Set<String> = ["rhythm", "ripple", "comet"]
    let nearbyRates: [Double] = [50, 52, 54]
    for icon in AppearanceCatalog.icons {
        let responsive = dynamicIDs.contains(icon.id)
        expect(MenuIconRenderer.isSpeedResponsive(style: icon.id) == responsive, "explicit speed response for \(icon.id)")
        let idle = MenuIconRenderer.image(style: icon.id, level: 1)
        let nearby = nearbyRates.map { MenuIconRenderer.image(style: icon.id, level: 1, wpm: $0) }
        let data = nearby.compactMap(\.tiffRepresentation)
        expect(data.count == nearbyRates.count, "\(icon.id) produces raster output")
        if responsive {
            expect(Set(data).count == nearbyRates.count,
                   "\(icon.id) changes gradually inside the former fixed speed tier")
            let midpoint = MenuIconRenderer.image(style: icon.id, level: 1, wpm: 70)
            let configuredMidpoint = MenuIconRenderer.image(style: icon.id, level: 1, wpm: 140, lowWPM: 40, highWPM: 240)
            expect(midpoint === configuredMidpoint,
                   "\(icon.id) uses the chosen range and reuses equal-percentage output")
            let low = MenuIconRenderer.image(style: icon.id, level: 1, wpm: 20)
            let high = MenuIconRenderer.image(style: icon.id, level: 1, wpm: 120)
            expect(MenuIconRenderer.image(style: icon.id, level: 1, wpm: 1) === low &&
                   MenuIconRenderer.image(style: icon.id, level: 1, wpm: .greatestFiniteMagnitude) === high,
                   "\(icon.id) clamps visual response below and above the range")
            expect(low.tiffRepresentation != idle.tiffRepresentation,
                   "\(icon.id) distinguishes typing at the low endpoint from idle")
        } else {
            expect(nearby.allSatisfy { $0 === idle }, "\(icon.id) retains its static silhouette")
            expect(MenuIconRenderer.image(style: icon.id, level: 100, wpm: 950, lowWPM: 900, highWPM: 1_000) === idle,
                   "\(icon.id) stays static under a custom range")
        }
        for rate in invalidRates {
            expect(MenuIconRenderer.image(style: icon.id, level: 100, wpm: rate) === idle,
                   "\(icon.id) does not invent input for an invalid rate")
        }
        for level in [1, 15, 45, 70, 100, 10_000] {
            for (index, rate) in nearbyRates.enumerated() {
                let image = MenuIconRenderer.image(style: icon.id, level: level, wpm: rate)
                expect(image === nearby[index], "\(icon.id) reuses the same percentage across levels")
                expect(image.size == NSSize(width: 18, height: 18) && image.isTemplate,
                       "\(icon.id) preserves native tint and fixed menu width")
            }
        }
    }
    let base = MenuIconRenderer.image(style: "keyboard", level: 1)
    expect(MenuIconRenderer.image(style: "invalid", level: 100, wpm: 90) === base &&
           !MenuIconRenderer.isSpeedResponsive(style: "invalid"), "invalid style keeps the static fallback")
    // Populate every percentage more than once, using different ranges. A
    // range, level or arbitrary speed must not become another cache dimension.
    for icon in dynamicIDs {
        for percentage in 0...100 {
            let first = MenuIconRenderer.image(style: icon, level: 1, wpm: 20 + Double(percentage))
            let second = MenuIconRenderer.image(style: icon, level: 100,
                wpm: 100 + Double(percentage) * 9, lowWPM: 100, highWPM: 1_000)
            expect(first === second, "\(icon) cache key uses percentage rather than raw WPM or range")
        }
    }
    expect(MenuIconRenderer.cachedImageCount <= MenuIconRenderer.cacheCapacity && MenuIconRenderer.cacheCapacity <= 311,
           "all responsive states retain a finite shared image cache")
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

    for expectedLevel in AppearanceCatalog.milestones.map(\.level) {
        guard let seedXP = DailyLevelSchedule.threshold(for: expectedLevel), seedXP.isMultiple(of: DailyRewardPolicy.legacyScale) else {
            failures.append("FAIL: appearance preferences exact level \(expectedLevel) threshold")
            continue
        }
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
            var seed = DailyRewardEngine(legacyTotalXP: seedXP / DailyRewardPolicy.legacyScale)
            var preservedRow = StoredAggregate(day: AppModel.day(), timezone: TimeZone.current.identifier,
                                               rule: "appearance-check", evidence: "probable", language: "en")
            preservedRow.keys = 37; preservedRow.intervals = 30; preservedRow.seconds = 12.5
            try store.save([preservedRow], dailyRewards: seed.checkpoint(), batchID: "appearance-seed-\(UUID().uuidString)")
            let historyBefore = try store.query(since: "0000-01-01")
            let model = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
            expect(model.appearanceLevel == expectedLevel, "seed unlocks exactly level \(expectedLevel)")
            let dailyBefore = model.dailyRewardState, legacyBefore = model.rewardState
            let storedBefore = try store.loadDailyRewardState()?.totalXP
            expect(model.appearanceMode == "system" && model.appearanceTheme == "classic" && model.menuBarStyle == "keyboard",
                   "fresh preferences use system mode and baseline cosmetics")
            expect(model.menuIconMotionEnabled, "menu motion defaults on")
            expect(model.menuIconLowWPM == 20 && model.menuIconHighWPM == 120, "missing range uses the shared defaults")
            var appearanceUpdates = 0
            model.onAppearanceUpdate = { appearanceUpdates += 1 }
            expect(model.setMenuIconSpeedRange(lowWPM: 40, highWPM: 240), "custom animation range is accepted at every level")
            expect(model.menuIconLowWPM == 40 && model.menuIconHighWPM == 240 && appearanceUpdates == 1,
                   "accepted range updates the live appearance")
            let savedRange = preferences.dictionary(forKey: "menuIconSpeedRange")
            expect(savedRange?["lowWPM"] as? Double == 40 && savedRange?["highWPM"] as? Double == 240,
                   "range endpoints persist together")
            let invalidRanges: [(Double, Double)] = [(-1, 120), (20, 20), (100, 20), (20, 20.5), (20, 1_001), (.nan, 120), (20, .infinity)]
            for (low, high) in invalidRanges {
                expect(!model.setMenuIconSpeedRange(lowWPM: low, highWPM: high), "invalid range is rejected")
                expect(model.menuIconLowWPM == 40 && model.menuIconHighWPM == 240 && appearanceUpdates == 1,
                       "invalid range preserves the last accepted appearance")
                expect(NSDictionary(dictionary: savedRange ?? [:]).isEqual(to: preferences.dictionary(forKey: "menuIconSpeedRange") ?? [:]),
                       "invalid range does not partially persist")
            }
            var previewCalls = 0
            model.onMenuEffectPreview = { previewCalls += 1 }
            model.previewMenuEffects()
            expect(previewCalls == 1, "menu preview is available at level \(expectedLevel)")
            model.setMenuIconMotionEnabled(false)
            model.previewMenuEffects()
            expect(previewCalls == 1 && preferences.object(forKey: "menuIconMotionEnabled") as? Bool == false,
                   "motion opt-out persists and prevents previews")

            for theme in AppearanceCatalog.themes {
                let previous = model.appearanceTheme
                model.setAppearanceTheme(theme.id)
                expect(model.appearanceTheme == (expectedLevel >= theme.level ? theme.id : previous),
                       "theme setter enforces \(theme.id) threshold at level \(expectedLevel)")
            }
            for icon in AppearanceCatalog.icons {
                let previous = model.menuBarStyle
                model.setMenuBarStyle(icon.id)
                expect(model.menuBarStyle == (expectedLevel >= icon.level ? icon.id : previous),
                       "icon setter enforces \(icon.id) threshold at level \(expectedLevel)")
            }
            let theme = AppearanceCatalog.themes.last { expectedLevel >= $0.level }!.id
            let icon = AppearanceCatalog.icons.last { expectedLevel >= $0.level }!.id
            model.setAppearanceTheme("invalid"); model.setMenuBarStyle("invalid")
            expect(model.appearanceTheme == theme && model.menuBarStyle == icon, "invalid choices preserve the current selection")
            model.setAppearanceMode("invalid")
            expect(model.appearanceMode == "system", "invalid mode uses system appearance")
            let mode = expectedLevel == 1 ? "system" : "dark"
            model.setAppearanceMode(mode)
            expect(preferences.string(forKey: "appearanceMode") == mode && preferences.string(forKey: "appearanceTheme") == theme &&
                   preferences.string(forKey: "menuBarStyle") == icon, "accepted choices persist in isolated defaults")
            expect(model.dailyRewardState == dailyBefore && model.rewardState == legacyBefore,
                   "cosmetic choices leave both reward states unchanged at level \(expectedLevel)")
            let storedAfter = try store.loadDailyRewardState()?.totalXP
            expect(storedAfter == storedBefore, "cosmetic choices do not change stored XP")
            let historyAfter = try store.query(since: "0000-01-01")
            expect(historyAfter == historyBefore, "appearance, ranges and previews preserve actual aggregate history")
            model.flushBeforeExit()

            let restored = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
            expect(restored.appearanceLevel == expectedLevel && restored.dailyRewardState?.totalXP == seedXP, "reload preserves level and all XP")
            expect(restored.appearanceTheme == theme && restored.menuBarStyle == icon &&
                   restored.effectiveAppearanceTheme == theme && restored.effectiveMenuBarStyle == icon,
                   "reload restores selected and effective level \(expectedLevel) cosmetics")
            expect(restored.appearanceMode == mode, "reload restores app appearance mode")
            expect(!restored.menuIconMotionEnabled, "reload preserves menu motion opt-out")
            expect(restored.menuIconLowWPM == 40 && restored.menuIconHighWPM == 240,
                   "reload preserves both custom range endpoints")
            var restoredPreviewCalls = 0
            restored.onMenuEffectPreview = { restoredPreviewCalls += 1 }
            restored.previewMenuEffects()
            expect(restoredPreviewCalls == 0, "restored opt-out prevents previews")
            restored.setMenuIconMotionEnabled(true)
            restored.previewMenuEffects()
            expect(restoredPreviewCalls == 1 && preferences.bool(forKey: "menuIconMotionEnabled"),
                   "motion can be enabled and previewed at every level")
            if [10, 55, 100].contains(expectedLevel) {
                restored.clearHistory()
                waitFor({ restored.dailyRewardState?.totalXP == 0 && restored.appearanceLevel == 1 }, "explicit clear completes and resets XP")
                expect(restored.effectiveAppearanceTheme == "classic" && restored.effectiveMenuBarStyle == "keyboard",
                       "clear history falls back to baseline cosmetics")
                expect(restored.appearanceTheme == theme && restored.menuBarStyle == icon && restored.appearanceMode == "dark" &&
                       restored.menuIconMotionEnabled && restored.menuIconLowWPM == 40 && restored.menuIconHighWPM == 240,
                       "clear preserves appearance preferences and range while applying level fallback")
                restored.previewMenuEffects()
                expect(restoredPreviewCalls == 2, "clear history keeps standard motion preview available")
                restored.flushBeforeExit()
                let cleared = AppModel(dataDirectory: directory, monitoringEnabled: false, appearancePreferences: preferences)
                expect(cleared.dailyRewardState?.totalXP == 0 && cleared.appearanceLevel == 1 &&
                       cleared.effectiveAppearanceTheme == "classic" && cleared.effectiveMenuBarStyle == "keyboard" && cleared.menuIconMotionEnabled,
                       "clear fallback, zero XP and enabled motion survive reload")
                expect(cleared.menuIconLowWPM == 40 && cleared.menuIconHighWPM == 240, "cleared history retains the custom range after reload")
                cleared.flushBeforeExit()
            } else { restored.flushBeforeExit() }
        } catch {
            failures.append("FAIL: appearance preferences level \(expectedLevel) fixture: \(error.localizedDescription)")
        }
    }

    // Older preference domains are read without migrating unrelated state.
    let cleanSuite = "local.keytempo.clean-appearance.\(UUID().uuidString)"
    let legacySuite = "local.keytempo.legacy-appearance.\(UUID().uuidString)"
    if let cleanPreferences = UserDefaults(suiteName: cleanSuite), let legacyPreferences = UserDefaults(suiteName: legacySuite) {
        defer {
            cleanPreferences.removePersistentDomain(forName: cleanSuite)
            legacyPreferences.removePersistentDomain(forName: legacySuite)
        }
        let currentValues: [String: Any] = ["appearanceMode": "dark", "appearanceTheme": "aurora", "menuBarStyle": "bolt",
                                           "menuIconMotionEnabled": false, "unrelatedPreference": "preserve"]
        let legacyValues: [String: Any] = ["menuColorMode": "fixed", "menuCustomGradientEnabled": true,
                                          "menuLowColorHex": "112233", "menuHighColorHex": "AABBCC",
                                          "menuGradientLowWPM": 25.0, "menuGradientHighWPM": 175.0,
                                          "menuVolumeCustomGradientEnabled": true, "menuVolumeLowColorHex": "315577",
                                          "menuVolumeHighColorHex": "BB6633", "menuGradientLowKeys": 1_000.0,
                                          "menuGradientHighKeys": 32_000.0, "menuFixedColorHex": "5A3377"]
        for (key, value) in currentValues { cleanPreferences.set(value, forKey: key); legacyPreferences.set(value, forKey: key) }
        for (key, value) in legacyValues { legacyPreferences.set(value, forKey: key) }
        let domainBefore = legacyPreferences.persistentDomain(forName: legacySuite) ?? [:]
        let clean = AppModel(dataDirectory: root.appendingPathComponent("clean-preferences"), monitoringEnabled: false, appearancePreferences: cleanPreferences)
        let legacy = AppModel(dataDirectory: root.appendingPathComponent("legacy-preferences"), monitoringEnabled: false, appearancePreferences: legacyPreferences)
        expect(legacy.appearanceMode == clean.appearanceMode && legacy.appearanceTheme == clean.appearanceTheme &&
               legacy.menuBarStyle == clean.menuBarStyle && legacy.effectiveAppearanceTheme == clean.effectiveAppearanceTheme &&
               legacy.effectiveMenuBarStyle == clean.effectiveMenuBarStyle && legacy.menuIconMotionEnabled == clean.menuIconMotionEnabled &&
               legacy.menuIconLowWPM == clean.menuIconLowWPM && legacy.menuIconHighWPM == clean.menuIconHighWPM &&
               legacy.menuIconLowWPM == 20 && legacy.menuIconHighWPM == 120 &&
               legacy.appearanceMenuWPM == clean.appearanceMenuWPM && legacy.appearanceLevel == clean.appearanceLevel &&
               legacy.dailyRewardState?.totalXP == clean.dailyRewardState?.totalXP, "legacy color preferences have no effect on current appearance or XP")
        expect(legacy.effectiveAppearanceTheme == "classic" && legacy.effectiveMenuBarStyle == "keyboard",
               "stored locked choices use baseline cosmetics without discarding the selection")
        expect(NSDictionary(dictionary: domainBefore).isEqual(to: legacyPreferences.persistentDomain(forName: legacySuite) ?? [:]),
               "loading old preferences does not rewrite the preference domain")
        clean.flushBeforeExit(); legacy.flushBeforeExit()
    } else { failures.append("FAIL: appearance isolated legacy preferences suites") }
    let malformedRanges: [[String: Any]] = [
        ["lowWPM": 240.0, "highWPM": 40.0], ["lowWPM": -1.0, "highWPM": 120.0],
        ["lowWPM": 20.0, "highWPM": 1_001.0], ["lowWPM": 20.0],
        ["lowWPM": "twenty", "highWPM": 120.0]
    ]
    for (index, value) in malformedRanges.enumerated() {
        let suiteName = "local.keytempo.invalid-animation-range.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            failures.append("FAIL: appearance invalid-range isolated suite"); continue
        }
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(value, forKey: "menuIconSpeedRange")
        preferences.set("preserve", forKey: "unrelatedPreference")
        let before = preferences.persistentDomain(forName: suiteName) ?? [:]
        let restored = AppModel(dataDirectory: root.appendingPathComponent("malformed-range-\(index)"),
                                monitoringEnabled: false, appearancePreferences: preferences)
        expect(restored.menuIconLowWPM == 20 && restored.menuIconHighWPM == 120,
               "malformed stored range falls back as one pair")
        expect(NSDictionary(dictionary: before).isEqual(to: preferences.persistentDomain(forName: suiteName) ?? [:]),
               "malformed range recovery does not rewrite unrelated or stored preferences")
        restored.flushBeforeExit()
    }
    return failures
}
