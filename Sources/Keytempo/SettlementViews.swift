import AppKit
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
}

struct SettlementView: View {
    let presentation: SettlementPresentation
    var theme: String = "classic"
    let position: Int
    let count: Int
    let onNext: () -> Void
    let onSkipAll: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SettlementViewState private var displayedXP = 0.0
    @SettlementViewState private var burst = 0.0
    @SettlementViewState private var medalScale = 1.0
    @SettlementViewState private var medalRotation = 0.0
    @SettlementViewState private var progress = 0.0
    @SettlementViewState private var effectsVisible = false
    @SettlementViewState private var levelVisible = false
    @SettlementViewState private var motionFinished = false

    private var gold: Color { colorScheme == .dark ? Color(red: 0.95, green: 0.79, blue: 0.46) : Color(red: 0.58, green: 0.37, blue: 0.07) }
    private var teal: Color { colorScheme == .dark ? Color(red: 0.48, green: 0.88, blue: 0.79) : Color(red: 0.04, green: 0.42, blue: 0.39) }
    private var animationsAllowed: Bool { !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled }

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

            VStack(spacing: 14) {
                ZStack {
                    ThemeArtwork(theme: theme).frame(width: 390, height: 164)
                        .mask(LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing))
                    if effectsVisible && animationsAllowed {
                        SettlementParticles(progress: burst, gold: gold, teal: teal)
                            .frame(width: 360, height: 190).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    medal
                        .scaleEffect(medalScale)
                        .rotationEffect(.degrees(medalRotation))
                }.frame(height: 134).padding(.top, 8)
                Text(L("等级 %@", (presentation.after?.level ?? 1).formatted()))
                    .font(.title2.weight(.semibold)).foregroundStyle(gold)
                    .opacity(presentation.levelsGained == 0 || levelVisible ? 1 : 0)
                    .accessibilityHidden(presentation.levelsGained > 0 && !levelVisible)

                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("练习积分")).font(.callout).foregroundStyle(.secondary)
                        Text(presentation.score.map { $0.formatted() } ?? "—")
                            .font(.system(size: 38, weight: .semibold)).monospacedDigit().foregroundStyle(teal)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                    Divider().frame(height: 65)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("获得 XP")).font(.callout).foregroundStyle(.secondary)
                        SettlementXPNumber(value: displayedXP)
                            .font(.system(size: 38, weight: .semibold)).monospacedDigit().foregroundStyle(gold)
                            .lineLimit(1).minimumScaleFactor(0.5).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore).accessibilityLabel(L("获得 %@ XP", presentation.totalXP.formatted()))
                }.padding(.top, 3)
                HStack(spacing: 16) {
                    Text(L("当日分数 +%@", presentation.ordinaryXP.formatted()))
                    if presentation.improvementXP > 0 { Text(L("进步验证 +%@", presentation.improvementXP.formatted())).foregroundStyle(teal) }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()

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
                    .buttonStyle(.borderedProminent).tint(AppAppearanceStyle.filledControlTint(theme: "classic"))
                    .keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 460, height: 560)
        .background(AppAppearanceStyle.canvas(theme: theme, scheme: colorScheme))
        .task(id: presentation.id) { await play() }
        .onDisappear { finishMotion() }
        .onChange(of: reduceMotion) { if $0 { finishMotion() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            if ProcessInfo.processInfo.isLowPowerModeEnabled { finishMotion() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in finishMotion() }
    }

    private var medal: some View {
        RankSeal(theme: theme, level: presentation.after?.level ?? 1, size: 110)
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
            LevelProgressTrack(value: progress, theme: theme)
            if presentation.improvementXP > 0 {
                Label(L("日均进步 · 已验证"), systemImage: "arrow.up.right")
                    .font(.caption).foregroundStyle(teal).frame(maxWidth: .infinity).padding(.top, 3)
            }
        }
    }

    @MainActor private func play() async {
        let finalProgress = presentation.after.map { Double($0.progressXP) / Double($0.requiredXP) } ?? 0
        motionFinished = false
        displayedXP = animationsAllowed ? 0 : Double(presentation.totalXP)
        levelVisible = !animationsAllowed
        progress = presentation.before.map { Double($0.progressXP) / Double($0.requiredXP) } ?? 0
        medalScale = 1; medalRotation = 0; burst = 0; effectsVisible = animationsAllowed
        guard animationsAllowed else { progress = finalProgress; return }
        withAnimation(.easeOut(duration: 1.15)) { displayedXP = Double(presentation.totalXP) }
        withAnimation(.easeOut(duration: 2.4)) { burst = 1 }
        withAnimation(.easeOut(duration: 0.9)) { progress = presentation.levelsGained > 0 ? 1 : finalProgress }
        do {
            try await Task.sleep(for: .milliseconds(1_200))
            try Task.checkCancellation()
            guard !motionFinished && animationsAllowed else { finishMotion(); return }
            if presentation.levelsGained > 0 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { levelVisible = true; medalScale = 1.12; medalRotation = -5 }
                progress = 0
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard !motionFinished && animationsAllowed else { finishMotion(); return }
                withAnimation(.easeOut(duration: 0.9)) { progress = finalProgress; medalScale = 1; medalRotation = 0 }
            }
            try await Task.sleep(for: .milliseconds(2_400))
            try Task.checkCancellation()
            guard !motionFinished && animationsAllowed else { finishMotion(); return }
            effectsVisible = false
            try await Task.sleep(for: .milliseconds(presentation.levelsGained > 0 ? 2_500 : 1_900))
            try Task.checkCancellation()
            guard !motionFinished && animationsAllowed else { finishMotion(); return }
            onNext()
        } catch { return }
    }

    @MainActor private func finishMotion() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            motionFinished = true
            effectsVisible = false; displayedXP = Double(presentation.totalXP); levelVisible = true
            medalScale = 1; medalRotation = 0; burst = 1
            progress = presentation.after.map { Double($0.progressXP) / Double($0.requiredXP) } ?? 0
        }
    }
}

private struct SettlementXPNumber: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text("+" + Int(max(0, value)).formatted()) }
}

/// Finite, view-local particles. There is no display link or idle timer; the
/// parent removes this layer after its one animation and on dismissal. Every
/// level uses the same ten particles and two rings.
private struct SettlementParticles: View, Animatable {
    var progress: Double
    let gold: Color
    let teal: Color
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, size in
            let t = min(1, max(0, progress))
            let opacity = max(0, sin(t * .pi))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let count = 10
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * Double.pi + Double(index % 3) * 0.1
                let radius = Double(60 + index % 5 * 18) * (0.35 + t * 0.65)
                let x = center.x + cos(angle) * radius, y = center.y + sin(angle) * radius * 0.64
                let color = index.isMultiple(of: 3) ? teal : gold
                var p = Path()
                if index.isMultiple(of: 3) {
                    let r = (index.isMultiple(of: 2) ? 4.0 : 2.8) * sin(t * .pi)
                    p.move(to: CGPoint(x: x - r, y: y)); p.addLine(to: CGPoint(x: x + r, y: y))
                    p.move(to: CGPoint(x: x, y: y - r)); p.addLine(to: CGPoint(x: x, y: y + r))
                } else {
                    let length = (1 - t) * 10 + 2
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length * 0.64))
                }
                context.stroke(p, with: .color(color.opacity(opacity * 0.9)), style: StrokeStyle(lineWidth: index.isMultiple(of: 4) ? 1.7 : 0.9, lineCap: .round))
            }
            for ring in 0..<2 {
                let radius = (40 + t * 65 + Double(ring) * 14)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius * 0.5, width: radius * 2, height: radius)), with: .color((ring == 0 ? gold : teal).opacity(opacity * 0.25)), lineWidth: 0.65)
            }
        }.clipped()
    }
}
