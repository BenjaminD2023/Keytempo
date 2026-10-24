import AppKit
import QuartzCore

/// A valid current rate controls cadence and highlight strength. The shared
/// response is available at every level and uses a bounded 20–120 WPM scale.
struct MenuIconMotionProfile: Equatable {
    let fraction: Double
    var cyclesPerSecond: Double { 0.65 + fraction * 1.95 }
    var strength: Double { 0.50 + fraction * 0.43 }
    var lineWidth: CGFloat { CGFloat(0.70 + fraction * 0.35) }

    init?(wpm: Double?, lowWPM: Double = 20, highWPM: Double = 120) {
        guard let wpm, wpm.isFinite, wpm > 0,
              lowWPM.isFinite, highWPM.isFinite, lowWPM >= 0, highWPM >= lowWPM + 1,
              highWPM <= 1_000 else { return nil }
        fraction = min(1, max(0, (wpm - lowWPM) / (highWPM - lowWPM)))
    }
}

struct MenuIconMotionEnvironment {
    var permitted = true
    var enabled = true
    var visible = true
    var suspended = false
    var reduceMotion = false
    var increaseContrast = false
    var lowPower = false
    var allowsMotion: Bool { permitted && enabled && visible && !suspended && !reduceMotion && !increaseContrast && !lowPower }
}

struct MenuIconEffectLease {
    let id: UInt64
    let issuedAt: TimeInterval
    let duration: TimeInterval
    let profile: MenuIconMotionProfile
    let phase: Double
    var expiresAt: TimeInterval { issuedAt + duration }
    func phase(at time: TimeInterval) -> Double {
        (phase + max(0, time - issuedAt) * profile.cyclesPerSecond).truncatingRemainder(dividingBy: 1)
    }
}

enum MenuIconEffectDecision {
    case stop, keep
    case animate(MenuIconEffectLease)
}

/// Only fresh aggregated snapshots renew a lease, at most once per second.
/// A 2.2 s lease tolerates the existing 1 s snapshot timer's coalescing and a
/// skipped sub-second boundary. No snapshot means the effect expires itself.
struct MenuIconEffectPolicy {
    static let duration: TimeInterval = 2.2
    static let minimumUpdateInterval: TimeInterval = 1
    private(set) var lease: MenuIconEffectLease?
    private var lastRenderedAt: TimeInterval?
    private var lastSampledAt: TimeInterval?
    private var nextID: UInt64 = 0
    private var awaitingIdle = false

    mutating func update(typing: Bool, environment: MenuIconMotionEnvironment, level: Int,
                         wpm: Double?, lowWPM: Double = 20, highWPM: Double = 120,
                         sampledAt: TimeInterval, now: TimeInterval) -> MenuIconEffectDecision {
        guard now.isFinite, now >= 0, sampledAt.isFinite, sampledAt >= 0,
              sampledAt <= now, now - sampledAt <= Self.duration,
              lastRenderedAt.map({ now >= $0 }) ?? true else { invalidate(); return .stop }
        guard typing else { awaitingIdle = false; invalidate(); return .stop }
        guard environment.allowsMotion else { suppressCurrentSegment(); return .stop }
        guard !awaitingIdle,
              let profile = MenuIconMotionProfile(wpm: wpm, lowWPM: lowWPM, highWPM: highWPM) else {
            invalidate(); return .stop
        }
        if (lastRenderedAt.map { now - $0 < Self.minimumUpdateInterval } ?? false) ||
            (lastSampledAt.map { sampledAt <= $0 } ?? false) {
            if let lease, now < lease.expiresAt { return .keep }
            invalidate(); return .stop
        }
        let phase = lease.map { $0.phase(at: now) } ?? 0
        nextID &+= 1
        let next = MenuIconEffectLease(id: nextID, issuedAt: now, duration: Self.duration, profile: profile, phase: phase)
        lease = next; lastRenderedAt = now; lastSampledAt = sampledAt
        return .animate(next)
    }

    func shouldExpire(id: UInt64, now: TimeInterval) -> Bool {
        guard let lease else { return false }
        return lease.id == id && now.isFinite && now >= lease.expiresAt
    }
    mutating func invalidate() { lease = nil }
    mutating func suppressCurrentSegment() { awaitingIdle = true; invalidate() }
}

/// The compositor runs finite keyframes inside the real status icon's bounds.
/// There is no display link, polling timer, per-key renderer or infinite repeat.
@MainActor final class MenuIconEffects {
    private weak var button: NSStatusBarButton?
    private var policy = MenuIconEffectPolicy()
    private var effectView: MenuIconEffectView?
    private var cleanupTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewStage: ((Int?) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspended = false
    private var generation: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private(set) var activeProfile: MenuIconMotionProfile?
    var isPreviewing: Bool { previewStage != nil }

    init(button: NSStatusBarButton) {
        self.button = button
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name: name) { owner in owner.suspended = true; owner.suppress() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name: name) { owner in owner.suspended = false; owner.suppress() }
        }
        observe(workspace, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.suppress() }
        observe(.default, name: .NSProcessInfoPowerStateDidChange) { $0.suppress() }
        observe(.default, name: NSWindow.didChangeOcclusionStateNotification) { owner in
            if !owner.visible { owner.suppress() }
        }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor (MenuIconEffects) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, observer))
    }

    private var visible: Bool {
        guard let button, let window = button.window else { return false }
        return !button.isHiddenOrHasHiddenAncestor && window.isVisible && window.occlusionState.contains(.visible)
    }

    private func environment(permitted: Bool, enabled: Bool) -> MenuIconMotionEnvironment {
        MenuIconMotionEnvironment(permitted: permitted, enabled: enabled, visible: visible, suspended: suspended,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func update(typing: Bool, permitted: Bool, level: Int, color: NSColor, wpm: Double?,
                lowWPM: Double = 20, highWPM: Double = 120, enabled: Bool = true, sampledAt: TimeInterval? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let state = environment(permitted: permitted, enabled: enabled)
        // Ordinary idle snapshots must not cancel an explicitly requested demo;
        // permission, power, visibility and accessibility gates still do.
        if isPreviewing {
            if !state.allowsMotion { suppress() }
            return
        }
        switch policy.update(typing: typing, environment: state, level: level, wpm: wpm,
                             lowWPM: lowWPM, highWPM: highWPM, sampledAt: sampledAt ?? now, now: now) {
        case .stop: removeEffect()
        case .keep:
            if let effectView, let rect = iconRect {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                effectView.frame = rect
                CATransaction.commit()
            }
        case .animate(let lease):
            render(lease: lease, level: level, color: color)
            scheduleCleanup(lease: lease)
        }
    }

    /// Explicit, labeled sample data only. Three finite two-second stages never
    /// modify the menu title, input pipeline, history or XP.
    func preview(permitted: Bool, level: Int, color: NSColor, enabled: Bool = true,
                 onStage: @escaping (Int?) -> Void) {
        cancel()
        guard environment(permitted: permitted, enabled: enabled).allowsMotion else {
            onStage(nil); return
        }
        previewStage = onStage
        let token = previewGeneration
        playPreviewStage(30, level: level, color: color)
        guard previewGeneration == token, isPreviewing else { return }
        previewTask = Task { [weak self] in
            for sample in [70, 120] {
                do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() }
                catch { return }
                guard let self, self.previewGeneration == token,
                      self.environment(permitted: permitted, enabled: enabled).allowsMotion else { self?.cancel(); return }
                self.playPreviewStage(sample, level: level, color: color)
            }
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() }
            catch { return }
            guard let self, self.previewGeneration == token else { return }
            self.cancel()
        }
    }

    private func playPreviewStage(_ wpm: Int, level: Int, color: NSColor) {
        guard let profile = MenuIconMotionProfile(wpm: Double(wpm)) else { return }
        let lease = MenuIconEffectLease(id: 0, issuedAt: ProcessInfo.processInfo.systemUptime,
                                       duration: 2, profile: profile, phase: 0)
        let token = previewGeneration
        previewStage?(wpm)
        guard previewGeneration == token, isPreviewing else { return }
        render(lease: lease, level: level, color: color)
    }

    /// A cached glyph change invalidates its old mask, not the explicit preview.
    /// The next aggregate update or preview stage supplies the matching overlay.
    func iconDidChange() { policy.invalidate(); removeEffect() }

    /// Lifecycle suppression requires a new idle→typing segment. Catch-up
    /// notifications after sleep or an accessibility change cannot replay it.
    func suppress() { policy.suppressCurrentSegment(); cancel() }
    func cancel() {
        previewGeneration &+= 1
        previewTask?.cancel(); previewTask = nil
        let callback = previewStage; previewStage = nil
        policy.invalidate(); removeEffect()
        callback?(nil)
    }

    private var iconRect: NSRect? {
        guard let button, let cell = button.cell else { return nil }
        let rect = cell.imageRect(forBounds: button.bounds).intersection(button.bounds)
        guard rect.width >= 10, rect.height >= 10, !rect.isEmpty else { return nil }
        return rect
    }

    private func render(lease: MenuIconEffectLease, level: Int, color: NSColor) {
        removeEffect()
        guard let button, let rect = iconRect, let icon = button.image,
              let maskImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let overlay = MenuIconEffectView(frame: rect)
        overlay.wantsLayer = true
        guard let root = overlay.layer else { return }
        root.masksToBounds = true
        let extent = overlay.bounds, profile = lease.profile
        let scale = button.window?.backingScaleFactor ?? 2
        var resolved = NSColor.white
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .white
        }
        let tint = resolved.cgColor
        let luminance = 0.2126 * resolved.redComponent + 0.7152 * resolved.greenComponent + 0.0722 * resolved.blueComponent
        // A contrasting pass stays visible for both the dark system glyph on a
        // light menu bar and the light glyph on a dark one. The base is intact.
        let highlight = luminance > 0.55 ? NSColor.black : NSColor.white
        let time = lease.duration
        // An 18 pt ornament does not need display-rate rendering. This is an
        // OS frame-rate request, not an additional clock or polling source.
        let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let gleam = CAGradientLayer(); gleam.frame = extent
        gleam.startPoint = CGPoint(x: 0, y: 0.15); gleam.endPoint = CGPoint(x: 1, y: 0.85)
        gleam.colors = [highlight.withAlphaComponent(0).cgColor,
                        highlight.withAlphaComponent(profile.strength).cgColor,
                        highlight.withAlphaComponent(0).cgColor]
        gleam.locations = [-0.55, -0.35, -0.15]
        let mask = CALayer(); mask.frame = extent; mask.contents = maskImage
        mask.contentsGravity = .resizeAspect; mask.contentsScale = scale; gleam.mask = mask
        let sweep = CAKeyframeAnimation(keyPath: "locations")
        sweep.preferredFrameRateRange = frameRate
        var times: [NSNumber] = [], positions: [[NSNumber]] = []
        func sweepPoint(_ t: Double, phase: Double) {
            let center = -0.35 + phase * 1.7
            times.append(NSNumber(value: t / time))
            positions.append([center - 0.20, center, center + 0.20].map { NSNumber(value: $0) })
        }
        sweepPoint(0, phase: lease.phase)
        var boundary = (1 - lease.phase) / profile.cyclesPerSecond
        while boundary < time {
            sweepPoint(max(0, boundary - 0.0001), phase: 1)
            sweepPoint(boundary, phase: 0)
            boundary += 1 / profile.cyclesPerSecond
        }
        let finalPhase = lease.phase(at: lease.expiresAt)
        sweepPoint(time, phase: finalPhase < 0.000000001 ? 1 : finalPhase)
        sweep.values = positions; sweep.keyTimes = times; sweep.duration = time
        sweep.calculationMode = .linear; gleam.add(sweep, forKey: "speed-gleam")
        root.addSublayer(gleam)

        // Two short rotating cuts read as cadence, not a progress ring. Only
        // this overlay rotates; the selected silhouette and all text stay put.
        let cadence = CAShapeLayer(); cadence.frame = extent; cadence.contentsScale = scale
        let path = CGMutablePath(), center = CGPoint(x: extent.midX, y: extent.midY)
        let radius = max(1, min(extent.width, extent.height) * 0.5 - 1.05)
        for angle in [0.0, Double.pi] {
            path.move(to: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            path.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + 0.65, clockwise: false)
        }
        cadence.path = path; cadence.fillColor = nil; cadence.strokeColor = tint
        cadence.lineWidth = profile.lineWidth; cadence.lineCap = .round; cadence.opacity = 0
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.preferredFrameRateRange = frameRate
        rotation.fromValue = lease.phase * 2 * Double.pi
        rotation.toValue = (lease.phase + time * profile.cyclesPerSecond) * 2 * Double.pi
        rotation.duration = time
        cadence.add(rotation, forKey: "speed-cadence")
        let visible = CABasicAnimation(keyPath: "opacity")
        visible.preferredFrameRateRange = frameRate
        visible.fromValue = profile.strength; visible.toValue = profile.strength; visible.duration = time
        cadence.add(visible, forKey: "speed-presence"); root.addSublayer(cadence)

        let sparks = 2
        let points = [CGPoint(x: 0.18, y: 0.82), CGPoint(x: 0.82, y: 0.18),
                      CGPoint(x: 0.18, y: 0.18), CGPoint(x: 0.82, y: 0.82)]
        for index in 0..<sparks {
            let p = CGPoint(x: extent.width * points[index].x, y: extent.height * points[index].y)
            let spark = CAShapeLayer(); spark.frame = extent; spark.contentsScale = scale
            let cut = CGMutablePath(), length = 0.9 + profile.fraction * 0.65
            cut.move(to: CGPoint(x: p.x - length, y: p.y)); cut.addLine(to: CGPoint(x: p.x + length, y: p.y))
            cut.move(to: CGPoint(x: p.x, y: p.y - length)); cut.addLine(to: CGPoint(x: p.x, y: p.y + length))
            spark.path = cut; spark.strokeColor = tint; spark.lineWidth = 0.8; spark.lineCap = .round; spark.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.preferredFrameRateRange = frameRate
            let steps = Int(ceil(time * 24))
            fade.values = (0...steps).map { step in
                let phase = lease.phase + Double(step) / Double(steps) * time * profile.cyclesPerSecond + Double(index) * 0.25
                return profile.strength * pow((1 + cos(phase * 2 * Double.pi)) * 0.5, 2)
            }
            fade.duration = time; fade.calculationMode = .linear
            spark.add(fade, forKey: "speed-spark"); root.addSublayer(spark)
        }
        button.addSubview(overlay); effectView = overlay; activeProfile = profile
        CATransaction.commit()
    }

    private func scheduleCleanup(lease: MenuIconEffectLease) {
        let token = generation
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lease.duration)); try Task.checkCancellation() }
            catch { return }
            guard let self, self.generation == token,
                  self.policy.shouldExpire(id: lease.id, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.policy.invalidate(); self.removeEffect()
        }
    }

    private func removeEffect() {
        generation &+= 1
        cleanupTask?.cancel(); cleanupTask = nil
        effectView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        effectView?.removeFromSuperview(); effectView = nil; activeProfile = nil
    }

    func shutdown() {
        suppress()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
    deinit {
        cleanupTask?.cancel(); previewTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}

@MainActor private final class MenuIconEffectView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

func runMenuIconEffectChecks() -> [String] {
    var failures = [String]()
    func expect(_ condition: Bool, _ message: String) { if !condition { failures.append("FAIL: menu effects \(message)") } }
    func rendered(_ decision: MenuIconEffectDecision) -> MenuIconEffectLease? {
        if case .animate(let lease) = decision { return lease }; return nil
    }
    let environment = MenuIconMotionEnvironment()
    var policy = MenuIconEffectPolicy()
    func sample(_ wpm: Double?, at now: Double, sampledAt: Double? = nil, typing: Bool = true, level: Int = 100,
                environment: MenuIconMotionEnvironment = MenuIconMotionEnvironment()) -> MenuIconEffectDecision {
        policy.update(typing: typing, environment: environment, level: level, wpm: wpm, sampledAt: sampledAt ?? now, now: now)
    }
    let invalidRates: [Double?] = [nil, .nan, .infinity, -1, 0]
    for value in invalidRates {
        expect(MenuIconMotionProfile(wpm: value) == nil, "invalid or absent WPM has no invented cadence")
    }
    let low = MenuIconMotionProfile(wpm: 30)!, medium = MenuIconMotionProfile(wpm: 70)!, high = MenuIconMotionProfile(wpm: 120)!
    expect(low.cyclesPerSecond < medium.cyclesPerSecond && medium.cyclesPerSecond < high.cyclesPerSecond &&
           high.cyclesPerSecond > low.cyclesPerSecond * 2.5, "30/70/120 WPM have visibly distinct cadence")
    expect(low.strength < medium.strength && medium.strength < high.strength, "speed also increases highlight strength")
    expect(MenuIconMotionProfile(wpm: 1)?.fraction == 0 && MenuIconMotionProfile(wpm: 900)?.fraction == 1, "speed clamps within the visual budget")
    expect(MenuIconMotionProfile(wpm: 70, lowWPM: 40, highWPM: 100)?.fraction == 0.5, "configured speed range controls intensity")
    expect(MenuIconMotionProfile(wpm: 70, lowWPM: .nan) == nil && MenuIconMotionProfile(wpm: 70, lowWPM: 100, highWPM: 20) == nil,
           "invalid speed range fails closed")
    expect(rendered(sample(30, at: 0, typing: false)) == nil && policy.lease == nil, "idle is static")
    expect(rendered(sample(nil, at: 0.5)) == nil, "warmup without WPM is static")
    let first = rendered(sample(30, at: 1, level: 1))
    expect(first != nil, "current WPM starts motion at the initial level")
    for time in [1.01, 1.25, 1.9] { expect(rendered(sample(120, at: time)) == nil, "render updates never exceed 1 Hz") }
    let next = rendered(sample(70, at: 2))
    expect(next != nil && next?.profile == medium, "ongoing typing renews with changed WPM")
    if let first, let next {
        expect(abs(next.phase - first.phase(at: 2)) < 1e-9, "renewal preserves cadence phase")
        expect(!policy.shouldExpire(id: first.id, now: 9), "stale cleanup cannot remove a renewed lease")
        expect(!policy.shouldExpire(id: next.id, now: 4.19) && policy.shouldExpire(id: next.id, now: 4.2), "lease expires without a snapshot")
    }
    expect(rendered(sample(70, at: 3, sampledAt: 2)) == nil, "appearance updates cannot renew old snapshot")
    _ = sample(70, at: 4.3, sampledAt: 2)
    expect(policy.lease == nil, "stale sample removes effect instead of keeping fake speed")
    expect(rendered(sample(120, at: 5)) != nil, "fresh snapshot resumes after expiry")
    _ = sample(nil, at: 6)
    expect(policy.lease == nil, "missing rate immediately clears active effect")
    expect(rendered(sample(70, at: 7, level: 1)) != nil, "motion is a standard feature without a level gate")
    for key in [\MenuIconMotionEnvironment.permitted, \.enabled, \.visible] {
        var blocked = environment; blocked[keyPath: key] = false
        policy = MenuIconEffectPolicy()
        _ = sample(70, at: 1, environment: blocked)
        expect(policy.lease == nil, "permission, user toggle or visibility suppresses motion")
        expect(rendered(sample(70, at: 2)) == nil, "restored gate cannot replay the current segment")
    }
    for key in [\MenuIconMotionEnvironment.suspended, \.reduceMotion, \.increaseContrast, \.lowPower] {
        var blocked = environment; blocked[keyPath: key] = true
        policy = MenuIconEffectPolicy()
        _ = sample(70, at: 1)
        _ = sample(70, at: 2, environment: blocked)
        expect(policy.lease == nil, "sleep/accessibility/power gate immediately clears effect")
    }
    policy.suppressCurrentSegment()
    expect(rendered(sample(70, at: 3)) == nil, "lifecycle suppression blocks catch-up motion")
    _ = sample(nil, at: 4, typing: false)
    expect(rendered(sample(70, at: 5)) != nil, "new segment works after lifecycle suppression")
    policy.invalidate()
    expect(policy.lease == nil, "explicit cancellation clears the cleanup lease")
    expect(rendered(sample(70, at: .nan)) == nil && rendered(sample(70, at: 8, sampledAt: 9)) == nil,
           "nonfinite clock and future snapshot fail closed")
    return failures
}
