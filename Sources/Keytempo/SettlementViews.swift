import SwiftUI
import TypingCore

private typealias SettlementViewState<Value> = SwiftUI.State<Value>

/// Immutable presentation of one committed ledger entry. Showing, dismissing
/// or skipping this value never changes its already awarded XP.
struct SettlementPresentation: Identifiable, Equatable {
    let id: String
    let day: String
    let score: Int?
    let ordinaryXP: Int
    let improvementXP: Int
    let totalXPBefore: Int
    let totalXPAfter: Int

    init(id: String, day: String, score: Int?, ordinaryXP: Int, improvementXP: Int, totalXPBefore: Int, totalXPAfter: Int) {
        self.id = id; self.day = day; self.score = score; self.ordinaryXP = ordinaryXP
        self.improvementXP = improvementXP; self.totalXPBefore = totalXPBefore; self.totalXPAfter = totalXPAfter
    }
    init(_ receipt: DailySettlementReceipt) {
        self.init(id: receipt.id, day: receipt.day, score: receipt.score, ordinaryXP: receipt.ordinaryXP,
                  improvementXP: receipt.improvementXP, totalXPBefore: receipt.beforeXP, totalXPAfter: receipt.afterXP)
    }

    var totalXP: Int { ordinaryXP + improvementXP }
    var before: DailyLevelProgress? { DailyLevelProgress(totalXP: totalXPBefore) }
    var after: DailyLevelProgress? { DailyLevelProgress(totalXP: totalXPAfter) }
    var levelsGained: Int { max(0, (after?.level ?? 1) - (before?.level ?? 1)) }
    var tier: Int {
        let level = after?.level ?? 1
        return level >= 60 ? 60 : level >= 20 ? 20 : 1
    }
    var newlyUnlockedTier: Bool {
        let prior = before?.level ?? 1, next = after?.level ?? 1
        return (prior < 20 && next >= 20) || (prior < 60 && next >= 60)
    }
}

struct SettlementView: View {
    let presentation: SettlementPresentation
    let position: Int
    let count: Int
    let onNext: () -> Void
    let onSkipAll: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SettlementViewState private var displayedXP = 0.0
    @SettlementViewState private var burst = 0.0
    @SettlementViewState private var medalScale = 1.0
    @SettlementViewState private var medalRotation = 0.0
    @SettlementViewState private var progress = 0.0
    @SettlementViewState private var effectsVisible = false
    @SettlementViewState private var levelVisible = false

    private var gold: Color { colorScheme == .dark ? Color(red: 0.95, green: 0.79, blue: 0.46) : Color(red: 0.58, green: 0.37, blue: 0.07) }
    private var teal: Color { colorScheme == .dark ? Color(red: 0.48, green: 0.88, blue: 0.79) : Color(red: 0.04, green: 0.42, blue: 0.39) }
    private var tierSymbol: String { presentation.tier >= 60 ? "sparkle" : presentation.tier >= 20 ? "diamond" : "circle.hexagongrid" }
    private var tierName: String { L(presentation.tier >= 60 ? "星辉" : presentation.tier >= 20 ? "棱光" : "基础") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("%@ 结算", presentation.day), systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(L("已入账")).font(.caption).foregroundStyle(teal)
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 25, height: 25) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("关闭"))
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 26).padding(.top, 20)

            VStack(spacing: 16) {
                ZStack {
                    if effectsVisible && !reduceMotion && presentation.tier >= 20 {
                        SettlementParticles(progress: burst, count: presentation.tier >= 60 ? 28 : 10, gold: gold, teal: teal)
                            .frame(width: 300, height: 220).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    medal
                        .scaleEffect(medalScale)
                        .rotationEffect(.degrees(medalRotation))
                }.frame(height: 116).padding(.top, 11)
                if levelVisible && presentation.levelsGained > 0 {
                    Text(L("等级 %@", (presentation.after?.level ?? 1).formatted()))
                        .font(.title2.weight(.semibold)).foregroundStyle(gold)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(L("练习积分")).font(.callout).foregroundStyle(.secondary)
                    Text(presentation.score.map { $0.formatted() } ?? "—")
                        .font(.system(size: 28, weight: .semibold)).monospacedDigit().foregroundStyle(teal)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }.accessibilityElement(children: .combine)

                VStack(spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettlementXPNumber(value: displayedXP)
                            .font(.system(size: 54, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).accessibilityHidden(true)
                        Text("XP").font(.title3.weight(.medium))
                    }.foregroundStyle(gold)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("获得 %@ XP", presentation.totalXP.formatted()))
                    HStack(spacing: 16) {
                        Text(L("当日分数 +%@", presentation.ordinaryXP.formatted()))
                        if presentation.improvementXP > 0 { Text(L("进步验证 +%@", presentation.improvementXP.formatted())).foregroundStyle(teal) }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.padding(.top, 7)

                levelSummary.padding(.top, 14)
                Spacer(minLength: 0)
            }.padding(.horizontal, 35)

            Divider().padding(.horizontal, 26)
            HStack(spacing: 12) {
                Text(L("%@ / %@", position.formatted(), count.formatted())).font(.caption).foregroundStyle(.secondary)
                Button(L("跳过全部"), action: onSkipAll).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("跳过这份"), action: onNext)
                Button(position < count ? L("下一份") : L("完成"), action: onNext)
                    .buttonStyle(.borderedProminent).tint(teal)
                    .keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 460, height: 560)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .task(id: presentation.id) { await play() }
        .onDisappear { effectsVisible = false }
    }

    private var medal: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [gold.opacity(0.15), Color(nsColor: .windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(gold.opacity(presentation.tier >= 20 ? 0.50 : 0.25), lineWidth: 1)
            Circle().inset(by: 7).fill(gold.opacity(presentation.tier >= 20 ? 0.10 : 0.04))
            Circle().inset(by: 7).strokeBorder(gold.opacity(0.24), lineWidth: 1)
            Image(systemName: tierSymbol).font(.system(size: 29, weight: .light)).foregroundStyle(gold)
        }.frame(width: 78, height: 78)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.06), radius: 9, x: 0, y: 6)
            .accessibilityHidden(true)
    }

    private var levelSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let before = presentation.before, let after = presentation.after, before.level != after.level {
                    Text(L("等级 %@ → %@", before.level.formatted(), after.level.formatted())).fontWeight(.semibold)
                } else {
                    Text(L("等级 %@", (presentation.after?.level ?? 1).formatted())).fontWeight(.semibold)
                }
                Spacer(minLength: 10)
                Text(L("%@ → %@ XP", presentation.totalXPBefore.formatted(), presentation.totalXPAfter.formatted()))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.font(.callout)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(gold).frame(width: max(0, min(geometry.size.width, geometry.size.width * progress)))
                }
            }.frame(height: 5).accessibilityHidden(true)
            if presentation.newlyUnlockedTier {
                Label(L("%@ · 已解锁", tierName), systemImage: "sparkles")
                    .font(.caption).foregroundStyle(gold).frame(maxWidth: .infinity).padding(.top, 3)
            } else if presentation.improvementXP > 0 {
                Label(L("日均进步 · 已验证"), systemImage: "arrow.up.right")
                    .font(.caption).foregroundStyle(teal).frame(maxWidth: .infinity).padding(.top, 3)
            }
        }
    }

    @MainActor private func play() async {
        let finalProgress = presentation.after.map { Double($0.progressXP) / Double($0.requiredXP) } ?? 0
        displayedXP = reduceMotion ? Double(presentation.totalXP) : 0
        levelVisible = reduceMotion
        progress = presentation.before.map { Double($0.progressXP) / Double($0.requiredXP) } ?? 0
        medalScale = 1; medalRotation = 0; burst = 0; effectsVisible = !reduceMotion && presentation.tier >= 20
        guard !reduceMotion else { progress = finalProgress; return }
        withAnimation(.easeOut(duration: 1.15)) { displayedXP = Double(presentation.totalXP) }
        withAnimation(.easeOut(duration: 2.4)) { burst = 1 }
        withAnimation(.easeOut(duration: 0.9)) { progress = presentation.levelsGained > 0 ? 1 : finalProgress }
        do {
            try await Task.sleep(for: .milliseconds(1_200))
            try Task.checkCancellation()
            if presentation.levelsGained > 0 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { levelVisible = true; medalScale = 1.12; medalRotation = -5 }
                progress = 0
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.9)) { progress = finalProgress; medalScale = 1; medalRotation = 0 }
            }
            try await Task.sleep(for: .milliseconds(2_400))
            try Task.checkCancellation()
            effectsVisible = false
            try await Task.sleep(for: .milliseconds(presentation.levelsGained > 0 ? 2_500 : 1_900))
            try Task.checkCancellation()
            onNext()
        } catch { return }
    }
}

private struct SettlementXPNumber: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("+" + Int(max(0, value)).formatted()) }
}

/// Finite, view-local particles. There is no display link or idle timer; the
/// parent removes this layer after its one animation and on dismissal.
private struct SettlementParticles: View, Animatable {
    var progress: Double
    let count: Int
    let gold: Color
    let teal: Color
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        GeometryReader { geometry in
            ForEach(0..<count, id: \.self) { index in
                let angle = Double(index) / Double(count) * 2 * Double.pi
                let radius = Double(68 + index % 5 * 13)
                Circle().fill(index.isMultiple(of: 3) ? teal : gold)
                    .frame(width: index.isMultiple(of: 4) ? 3 : 2, height: index.isMultiple(of: 4) ? 3 : 2)
                    .opacity(max(0, sin(progress * .pi)) * 0.8)
                    .position(x: geometry.size.width / 2 + cos(angle) * radius * progress,
                              y: geometry.size.height / 2 + sin(angle) * radius * progress)
            }
        }.clipped()
    }
}
