import AppKit
import ApplicationServices
import Carbon
import TypingCore

/// Passive capture. The callback copies numeric metadata into a fixed 1,024-slot ring.
/// Classification, accessibility, model updates and UI publication happen after the callback.
final class InputMonitor {
    var onInput: ((ClassifiedInput) -> Void)?
    var onInterruption: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var hasInputPermission = CGPreflightListenEventAccess()
    private(set) var hasAccessibilityPermission = AXIsProcessTrusted()
    private(set) var currentAppName = "—"
    private(set) var contextSummary = "尚未开始"
    var contextQuerySummary: String { context.snapshot.querySummary }
    var usesGlobalKeyboardEstimate: Bool {
        globalKeyboardCompatibilityEnabled && contextSummary == Self.globalKeyboardCompatibilitySummary
    }
    private(set) var inputSourceSummary = "—"
    private(set) var status = "尚未开始"
    private(set) var capturedEvents: UInt64 = 0
    private(set) var overflowCount: UInt64 = 0
    private(set) var unknownEvents: UInt64 = 0
    private(set) var repeatEvents: UInt64 = 0
    private(set) var suspiciousRepeatEvents: UInt64 = 0
    private(set) var suspiciousBurstEvents: UInt64 = 0
    private(set) var languageFilteredEvents: UInt64 = 0
    private(set) var deferredAcceptedEvents: UInt64 = 0
    private(set) var deferredDiscardedEvents: UInt64 = 0
    private(set) var deferredContextSummary = "—"
    var pendingContextEvents: Int { deferredContext.count }
    private(set) var callbackP99Microseconds: Double?
    var diagnosticsEnabled = false { didSet { lock.lock(); measureCallback = diagnosticsEnabled; lock.unlock() } }
    var globalKeyboardCompatibilityEnabled = false {
        didSet {
            guard oldValue != globalKeyboardCompatibilityEnabled else { return }
            context.keyboardCompatibilityEnabled = globalKeyboardCompatibilityEnabled
            discardDeferredContext("全局键盘兼容模式已变化")
            flushInputQuality()
            compositionTracker.reset()
            if !globalKeyboardCompatibilityEnabled && status == Self.globalKeyboardCompatibilitySummary {
                contextSummary = context.snapshot.reason
                publish("未知输入上下文")
            }
            onInterruption?("全局键盘兼容模式已变化")
        }
    }
    var suspectedInputFilteringEnabled = true {
        didSet {
            guard oldValue != suspectedInputFilteringEnabled else { return }
            discardDeferredContext("疑似异常输入过滤设置已变化")
            flushInputQuality()
            compositionTracker.reset()
            onInterruption?("疑似异常输入过滤设置已变化")
        }
    }

    private struct Raw {
        var time: Double = 0
        var key: Int64 = 0
        var flags: UInt64 = 0
        var repeated = false
        var synthetic = false
        var version: UInt64 = 0
        var disabled = false
        var modifierChanged = false
    }
    private let lock = NSLock()
    private var ring = [Raw](repeating: Raw(), count: 1024)
    private var readIndex = 0
    private var buffered = 0
    private var dropped: UInt64 = 0
    private var callbackVersion: UInt64 = 1
    private var accepting = false
    private var measureCallback = false
    private var measurements = [UInt64](repeating: 0, count: 2048)
    private var measureIndex = 0
    private var measureCount = 0
    private var tap: CFMachPort?
    private var tapLoop: CFRunLoop?
    private var tapThread: Thread?
    private var running = false
    private var retryCount = 0
    private var retryTask: DispatchWorkItem?
    private var excluded = Set<String>()
    private let context = FocusContext()
    private var compositionTracker = ProbableCompositionTracker()
    private var inputQuality = InputQualityGuard()
    private var qualityFlushTask: DispatchWorkItem?
    private static let deferredContextCapacity = 64
    private static let deferredContextMaximumAge = 0.35
    private static let globalKeyboardCompatibilitySummary = "全局键盘活动估算；未确认文本框"
    private var deferredContext = [Raw]()
    private var deferredContextExpiryTask: DispatchWorkItem?
    private var languagePolicyObserver: NSObjectProtocol?
    private lazy var signal: DispatchSourceUserDataAdd = {
        let value = DispatchSource.makeUserDataAddSource(queue: .main)
        value.setEventHandler { [weak self] in self?.drain() }
        value.resume()
        return value
    }()

    init() {
        context.onSourceWillChange = { [weak self] nextVersion, capturedLease in
            guard let self else { return }
            // Source notifications arrive after TIS updates its cache. Drain
            // the previous version with its own source identity before rebinding.
            // Rotate capture and extract the old batch atomically: input that
            // arrives during delivery must remain queued for the new source.
            let batch = self.takePending(advancingTo: nextVersion)
            self.drain(refreshSource: false, refreshContext: false, capturedBatch: batch,
                       capturedLeaseOverride: capturedLease)
        }
        languagePolicyObserver = NotificationCenter.default.addObserver(forName: InputLanguages.policyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.context.invalidate("监控语言设置已变化")
        }
        context.onInvalidate = { [weak self] version, reason in
            guard let self else { return }
            self.lock.lock(); self.callbackVersion = version; self.lock.unlock()
            self.discardDeferredContext(reason)
            self.flushInputQuality()
            self.compositionTracker.reset()
            self.contextSummary = reason
            // Activation/focus notifications also refresh capability state,
            // including revocation that caused the keyboard stream to stop.
            let previouslyAllowed = self.hasInputPermission
            self.hasInputPermission = CGPreflightListenEventAccess()
            self.hasAccessibilityPermission = AXIsProcessTrusted()
            if !self.hasInputPermission { self.publish("输入监控权限不可用") }
            else if IsSecureEventInputEnabled() { self.publish("安全输入：统计不可用") }
            if self.running && self.hasInputPermission && !previouslyAllowed { self.launchTap() }
            self.onInterruption?(reason)
        }
        context.onResolved = { [weak self] value in
            guard let self else { return }
            self.refreshPermissions()
            let secureInputEnabled = IsSecureEventInputEnabled()
            self.currentAppName = value.appName
            self.contextSummary = value.reason
            self.inputSourceSummary = (value.inputMethod ? "输入法：组合用途需适配器确认" : "键盘布局") + " · " + value.languageCode
            if !InputLanguages.policy.allows(languageCode: value.languageCode) { self.publish("当前输入源语言已排除") }
            else if self.excluded.contains(value.bundleID) { self.publish("应用已排除") }
            else if value.bundleID == Bundle.main.bundleIdentifier { self.publish("本应用仅在确认输入区统计") }
            else if !self.hasInputPermission { self.publish("输入监控权限不可用") }
            else if !self.hasAccessibilityPermission { self.publish("辅助功能权限不可用") }
            else if secureInputEnabled {
                self.contextSummary = "系统安全输入已启用"
                self.publish("安全输入：统计不可用")
            }
            else if self.permitsGlobalKeyboardCompatibility(value, time: ProcessInfo.processInfo.systemUptime, version: self.context.version) {
                self.contextSummary = Self.globalKeyboardCompatibilitySummary
                self.publish(Self.globalKeyboardCompatibilitySummary)
            }
            else { self.publish(value.editable ? "正在统计 · 估算模式" : "未知输入上下文") }
            if self.running && !secureInputEnabled {
                self.resolveDeferredContext(snapshot: value, contextVersion: self.context.version,
                                            now: ProcessInfo.processInfo.systemUptime, date: Date())
            } else {
                self.discardDeferredContext("统计不可用；未确认输入已丢弃")
            }
        }
    }

    deinit { if let languagePolicyObserver { NotificationCenter.default.removeObserver(languagePolicyObserver) } }

    func start() {
        guard !running else { refreshPermissions(); return }
        running = true
        retryCount = 0
        refreshPermissions()
        context.start()
        guard hasInputPermission else { publish("输入监控权限不可用"); return }
        launchTap()
    }

    private func launchTap() {
        guard running && hasInputPermission && tapThread == nil else { return }
        _ = signal
        lock.lock(); accepting = true; lock.unlock()
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "Keytempo passive event tap"
        thread.qualityOfService = .utility
        tapThread = thread
        thread.start()
    }

    func stop() {
        running = false
        discardDeferredContext("统计已暂停；未确认输入已丢弃")
        flushInputQuality()
        compositionTracker.reset()
        retryTask?.cancel(); retryTask = nil
        lock.lock()
        accepting = false
        buffered = 0
        readIndex = 0
        dropped = 0
        let loop = tapLoop
        let currentTap = tap
        lock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                if let currentTap { CFMachPortInvalidate(currentTap) }
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }
        context.stop()
        publish("已暂停")
    }

    func refreshPermissions() {
        let oldInput = hasInputPermission
        let oldAX = hasAccessibilityPermission
        hasInputPermission = CGPreflightListenEventAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        if oldInput != hasInputPermission || oldAX != hasAccessibilityPermission {
            context.invalidate("系统权限已变化")
            onInterruption?("系统权限已变化")
        }
        if !hasInputPermission { publish("输入监控权限不可用") }
        if running && hasInputPermission && !oldInput {
            launchTap()
        }
    }

    func updateExcludedApps(_ bundles: Set<String>) {
        excluded = bundles
        context.invalidate("应用排除设置已变化")
    }

    /// Called before the coordinator changes pause/sleep/rule state, so a short
    /// valid buffered prefix is accepted under its original counting policy.
    func flushPendingInput() {
        discardDeferredContext("统计规则已变化；未确认输入已丢弃")
        flushInputQuality()
    }

    /// Triggered by UI activation, wake, and events; never a perpetual permission poll.
    func checkSystemState() {
        refreshPermissions()
        if IsSecureEventInputEnabled() {
            context.invalidate("系统安全输入已启用", query: false)
            publish("安全输入：统计不可用")
        }
    }

    private func publish(_ value: String) {
        guard status != value else { return }
        status = value
        onStatus?(value)
    }

    private func runTap() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                   (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let createdTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, raw in
            guard let raw else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(raw).takeUnretainedValue()
            monitor.capture(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: pointer)
        guard let createdTap else {
            DispatchQueue.main.async { [weak self] in
                self?.tapThread = nil
                self?.publish("无法创建被动监听；请检查输入监控权限")
                self?.onInterruption?("监听创建失败")
                self?.retryCreation()
            }
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)!
        lock.lock()
        tap = createdTap; tapLoop = loop
        let shouldRun = accepting
        lock.unlock()
        if shouldRun {
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        CFMachPortInvalidate(createdTap)
        lock.lock(); tap = nil; tapLoop = nil; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tapThread = nil
            // A resume that arrived while the previous run loop was stopping is
            // serialized here, so two event taps never run concurrently.
            if self.running && self.hasInputPermission { self.launchTap() }
        }
    }

    private static func reenableTap(_ port: CFMachPort?) {
        guard let port, CFMachPortIsValid(port) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func capture(type: CGEventType, event: CGEvent,
                         reenableTap: (CFMachPort?) -> Void = InputMonitor.reenableTap) {
        // Include lock contention in diagnostics. The single monotonic clock
        // read remains cheap when detailed sampling is disabled.
        let start = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let measure = measureCallback
        guard accepting else { lock.unlock(); return }
        let disabled = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        // Resume on the tap thread immediately, even if the main queue or ring
        // is busy. Repeated OS suspensions do not consume the creation budget.
        if disabled { reenableTap(tap) }
        if buffered == ring.count { dropped &+= 1 }
        else {
            let slot = (readIndex + buffered) % ring.count
            // Private sources receive a unique state-table ID, not the -1
            // initializer constant. Only 0 (combined session) and 1 (HID) are
            // public state tables. This excludes known private-source input;
            // generators using either public state remain indistinguishable.
            let sourceState = Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID))
            ring[slot] = Raw(time: Double(event.timestamp) / 1_000_000_000, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, synthetic: sourceState != 0 && sourceState != 1, version: callbackVersion, disabled: disabled, modifierChanged: type == .flagsChanged)
            buffered += 1
        }
        lock.unlock()
        signal.add(data: 1)
        if measure {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            lock.lock()
            measurements[measureIndex] = elapsed
            measureIndex = (measureIndex + 1) % measurements.count
            measureCount = min(measureCount + 1, measurements.count)
            lock.unlock()
        }
    }

    private struct Batch {
        let events: [Raw]
        let lost: UInt64
        let durations: [UInt64]
    }

    /// Shared by the live drain and regression checks; taking a batch clears
    /// every pending slot and the overflow marker atomically.
    private func takePending(advancingTo nextVersion: UInt64? = nil) -> Batch {
        lock.lock()
        var events = [Raw]()
        events.reserveCapacity(buffered)
        while buffered > 0 {
            events.append(ring[readIndex])
            readIndex = (readIndex + 1) % ring.count
            buffered -= 1
        }
        let lost = dropped; dropped = 0
        if let nextVersion { callbackVersion = nextVersion }
        let durations = diagnosticsEnabled && measureCount > 0 ? Array(measurements.prefix(measureCount)) : []
        lock.unlock()
        return Batch(events: events, lost: lost, durations: durations)
    }

    /// Resolution can precede the next drain. A boundary already captured in
    /// the ring must invalidate the uncertain prefix before any replay occurs.
    private func peekPendingForContextBoundary() -> Batch {
        guard !deferredContext.isEmpty else { return Batch(events: [], lost: 0, durations: []) }
        lock.lock()
        var events = [Raw]()
        events.reserveCapacity(buffered)
        for offset in 0..<buffered { events.append(ring[(readIndex + offset) % ring.count]) }
        let lost = dropped
        lock.unlock()
        return Batch(events: events, lost: lost, durations: [])
    }

    private func drain(refreshSource: Bool = true, refreshContext: Bool = true, capturedBatch: Batch? = nil,
                       capturedLeaseOverride: FocusContext.Snapshot? = nil) {
        guard running else { return }
        // Vorssaint can switch via TIS directly and consume Caps Lock/F18.
        // Refresh on delivered batches instead of relying on seeing its trigger
        // or on a timely distributed source notification. Never query in capture.
        if refreshSource { InputLanguages.refreshCurrent() }
        let batch = capturedBatch ?? takePending()
        let events = batch.events, lost = batch.lost, durations = batch.durations
        if !durations.isEmpty { callbackP99Microseconds = Double(durations.sorted()[min(durations.count - 1, Int(Double(durations.count) * 0.99))]) / 1000 }
        if lost > 0 {
            discardDeferredContext("事件缓冲区溢出；未确认输入已丢弃")
            flushInputQuality()
            compositionTracker.reset()
            overflowCount &+= lost
            onInterruption?("事件缓冲区溢出；已丢弃 \(lost) 个事件")
            publish("统计中断：缓冲区溢出")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            context.invalidate("系统安全输入已启用", query: false)
            publish("安全输入：统计不可用")
            return
        }
        if !CGPreflightListenEventAccess() || !AXIsProcessTrusted() {
            refreshPermissions()
        }
        let capturedLease = capturedLeaseOverride ?? context.snapshot
        let now = ProcessInfo.processInfo.systemUptime
        // Expired eligibility is withheld before this batch is classified.
        // Same-version input may wait briefly for a fresh identity validation.
        if refreshContext { context.prepareForBatch(at: now) }
        let snapshot = context.snapshot
        let date = Date()
        replayDeferredContext(snapshot: snapshot, contextVersion: context.version, now: now, date: date, followingEvents: events)
        for event in events {
            capturedEvents &+= 1
            _ = process(event, snapshot: snapshot, contextVersion: context.version, now: now, date: date,
                        capturedLease: capturedLease)
        }
        if refreshContext { context.prepareForEvent() }
    }

    /// Both live and context-confirmed events use the same classification and
    /// input-quality path. Deferral never supplies editable evidence itself.
    @discardableResult
    private func process(_ event: Raw, snapshot currentSnapshot: FocusContext.Snapshot, contextVersion: UInt64,
                         now: Double, date: Date, mayDefer: Bool = true,
                         capturedLease: FocusContext.Snapshot? = nil) -> Bool {
        if event.disabled { recoverTap(); return false }
        if event.modifierChanged {
            // Shift/Option are normal text modifiers. Caps Lock, Globe/Fn and
            // shortcut modifiers can end an IME hypothesis even when switching
            // fails or leaves the selected input source unchanged.
            if Self.breaksComposition(event) {
                if mayDefer && !deferredContext.isEmpty &&
                    Self.mayWaitForContext(event, contextVersion: contextVersion, now: now) &&
                    deferredContext.count < Self.deferredContextCapacity {
                    deferredContext.append(event)
                } else {
                    flushInputQuality()
                    compositionTracker.reset()
                    onInterruption?("输入切换键或快捷键修饰键已变化")
                }
            }
            return false
        }
        // Delivery delay does not revoke an event captured inside a lease.
        // A real invalidation must still reject the entire previous version.
        var snapshot: FocusContext.Snapshot
        if let capturedLease, capturedLease.version == contextVersion,
           capturedLease.permits(time: event.time, version: event.version) {
            snapshot = capturedLease
        } else {
            snapshot = currentSnapshot
        }
        expireDeferredContext(now: now)
        let modifiers = CGEventFlags(rawValue: event.flags)
        var keyboardEstimate = false
        let physical = Self.classify(key: event.key, flags: event.flags, synthetic: event.synthetic,
                                     editable: true, inputMethod: false, valid: true)
        if !event.repeated && now >= event.time &&
            (physical.0 == .textEntry || physical.0 == .editing) &&
            permitsGlobalKeyboardCompatibility(snapshot, time: event.time, version: contextVersion) &&
            event.version == contextVersion {
            // This lease permits a keyboard-activity estimate only. It never
            // changes AX metadata or establishes text insertion/character output.
            snapshot = FocusContext.Snapshot(version: snapshot.version, bundleID: snapshot.bundleID,
                                             appName: snapshot.appName, role: snapshot.role, editable: true,
                                             ready: true, reason: Self.globalKeyboardCompatibilitySummary,
                                             expires: snapshot.identityExpires, inputMethod: snapshot.inputMethod,
                                             languageCode: snapshot.languageCode,
                                             inputSourceID: snapshot.inputSourceID, inputModeID: snapshot.inputModeID,
                                             validSince: snapshot.validSince,
                                             querySummary: snapshot.querySummary)
            keyboardEstimate = true
            contextSummary = Self.globalKeyboardCompatibilitySummary
            publish(Self.globalKeyboardCompatibilitySummary)
        }
        if mayDefer && !snapshot.ready && hasInputPermission && hasAccessibilityPermission &&
            Self.mayWaitForContext(event, contextVersion: contextVersion, now: now) {
            if deferredContext.count < Self.deferredContextCapacity {
                deferredContext.append(event)
                deferredContextSummary = "正在等待输入上下文确认（最多 0.35 秒）"
                scheduleDeferredContextExpiry(now: now)
                return false
            }
            discardDeferredContext("上下文等待缓冲区已满；未确认输入已丢弃")
        } else if !deferredContext.isEmpty {
            discardDeferredContext("未确认输入遇到中断边界；已丢弃")
        }
        if snapshot.bundleID == Bundle.main.bundleIdentifier {
            flushInputQuality(); compositionTracker.reset(); return false
        }
        if excluded.contains(snapshot.bundleID) {
            flushInputQuality(); compositionTracker.reset()
            onInterruption?("应用已排除"); publish("应用已排除")
            return false
        }
        if event.repeated {
            flushInputQuality(); compositionTracker.reset()
            repeatEvents &+= 1
            onInterruption?("自动重复不计入手动敲键节奏")
            return false
        }
        if snapshot.ready && event.version == snapshot.version && !InputLanguages.policy.allows(languageCode: snapshot.languageCode) {
            flushInputQuality(); compositionTracker.reset()
            languageFilteredEvents &+= 1
            onInterruption?("当前输入源语言已排除"); publish("当前输入源语言已排除")
            return false
        }
        var decision = compositionTracker.classify(
            key: event.key, time: event.time, contextVersion: event.version,
            command: modifiers.contains(.maskCommand), control: modifiers.contains(.maskControl),
            shift: modifiers.contains(.maskShift), option: modifiers.contains(.maskAlternate),
            synthetic: event.synthetic, editable: snapshot.editable, inputMethod: snapshot.inputMethod && !keyboardEstimate,
            valid: snapshot.permits(time: event.time, version: event.version) &&
                event.version == contextVersion && hasInputPermission && hasAccessibilityPermission)
        if globalKeyboardCompatibilityEnabled,
           decision == .classified(.unknown, .unknown),
           snapshot.editable, snapshot.permits(time: event.time, version: event.version),
           event.version == contextVersion && hasInputPermission && hasAccessibilityPermission,
           physical.0 == .textEntry || physical.0 == .editing {
            // An IME can remain selected while Caps Lock puts it in Latin
            // passthrough. Printable digits still represent keyboard activity
            // when no composition hypothesis exists to establish their purpose.
            decision = .classified(physical.0, physical.1)
        }
        guard case let .classified(category, evidence) = decision else {
            // Valid spaces close a quality hypothesis without adding a key or
            // splitting the actual elapsed interval between accepted operations.
            flushInputQuality()
            return false
        }
        if category == .unknown { unknownEvents &+= 1 }
        let input = ClassifiedInput(time: event.time, date: date.addingTimeInterval(event.time - now),
                                    context: event.version, category: category, evidence: evidence,
                                    source: .global, language: snapshot.languageCode, applicationID: snapshot.bundleID,
                                    inputMethodID: snapshot.inputSourceID + "|" + snapshot.inputModeID,
                                    usesInputMethod: snapshot.inputMethod)
        if suspectedInputFilteringEnabled && category == .textEntry && evidence == .probable {
            deliverInputQuality(inputQuality.observe(input, physicalKey: event.key))
        } else {
            flushInputQuality()
            onInput?(input)
        }
        return category.isEffective && evidence == .probable
    }

    private func permitsGlobalKeyboardCompatibility(_ snapshot: FocusContext.Snapshot,
                                                     time: Double, version: UInt64) -> Bool {
        globalKeyboardCompatibilityEnabled && !snapshot.ready && hasInputPermission && hasAccessibilityPermission &&
            !excluded.contains(snapshot.bundleID) && snapshot.bundleID != Bundle.main.bundleIdentifier &&
            InputLanguages.policy.allows(languageCode: snapshot.languageCode) &&
            snapshot.permitsIdentity(time: time, version: version)
    }

    private static func mayWaitForContext(_ event: Raw, contextVersion: UInt64, now: Double) -> Bool {
        let candidate = classify(key: event.key, flags: event.flags, synthetic: event.synthetic,
                                 editable: true, inputMethod: false, valid: true)
        return !event.disabled && !event.repeated && !event.synthetic && event.key != 49 &&
            event.version == contextVersion && event.time.isFinite && event.time >= 0 &&
            now >= event.time && now - event.time < deferredContextMaximumAge &&
            (event.modifierChanged || candidate.0 == .textEntry || candidate.0 == .editing)
    }

    private static func breaksComposition(_ event: Raw) -> Bool {
        [54, 55, 57, 59, 62, 63].contains(event.key)
    }

    private func scheduleDeferredContextExpiry(now: Double) {
        guard deferredContextExpiryTask == nil, let first = deferredContext.first else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredContextExpiryTask = nil
            self.expireDeferredContext(now: ProcessInfo.processInfo.systemUptime)
        }
        deferredContextExpiryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, first.time + Self.deferredContextMaximumAge - now), execute: task)
    }

    private func expireDeferredContext(now: Double) {
        guard let first = deferredContext.first else { return }
        if now - first.time >= Self.deferredContextMaximumAge {
            discardDeferredContext("输入上下文确认超时；未确认输入已丢弃")
        } else {
            scheduleDeferredContextExpiry(now: now)
        }
    }

    private func discardDeferredContext(_ reason: String) {
        deferredContextExpiryTask?.cancel(); deferredContextExpiryTask = nil
        guard !deferredContext.isEmpty else { return }
        let count = UInt64(deferredContext.count)
        deferredContext.removeAll(keepingCapacity: true)
        deferredDiscardedEvents &+= count
        unknownEvents &+= count
        deferredContextSummary = reason
        // Confirmed short prefixes precede the unknown boundary, never follow it.
        flushInputQuality()
        compositionTracker.reset()
        onInterruption?(reason)
    }

    private func replayDeferredContext(snapshot: FocusContext.Snapshot, contextVersion: UInt64,
                                       now: Double, date: Date, followingEvents: [Raw] = []) {
        guard !deferredContext.isEmpty else { return }
        guard snapshot.version == contextVersion, deferredContext.allSatisfy({ $0.version == contextVersion }) else {
            discardDeferredContext("输入上下文版本已变化；未确认输入已丢弃")
            return
        }
        guard hasInputPermission && hasAccessibilityPermission else {
            discardDeferredContext("系统权限不可用；未确认输入已丢弃")
            return
        }
        guard followingEvents.allSatisfy({ Self.mayWaitForContext($0, contextVersion: contextVersion, now: now) }) else {
            discardDeferredContext("已捕获输入包含中断边界；未确认输入已丢弃")
            return
        }
        guard snapshot.ready else { expireDeferredContext(now: now); return }
        guard snapshot.editable, !excluded.contains(snapshot.bundleID),
              snapshot.bundleID != Bundle.main.bundleIdentifier,
              InputLanguages.policy.allows(languageCode: snapshot.languageCode) else {
            discardDeferredContext("已确认上下文不允许统计；未确认输入已丢弃")
            return
        }
        guard deferredContext.allSatisfy({ now >= $0.time && now - $0.time < Self.deferredContextMaximumAge &&
            snapshot.permits(time: $0.time, version: $0.version) }) else {
            discardDeferredContext("上下文确认超过等待时限或有效范围；未确认输入已丢弃")
            return
        }
        let pending = deferredContext
        deferredContext.removeAll(keepingCapacity: true)
        deferredContextExpiryTask?.cancel(); deferredContextExpiryTask = nil
        for event in pending {
            let accepted = process(event, snapshot: snapshot, contextVersion: contextVersion, now: now, date: date, mayDefer: false)
            if event.modifierChanged { continue }
            if accepted {
                deferredAcceptedEvents &+= 1
            } else {
                deferredDiscardedEvents &+= 1
            }
        }
        deferredContextSummary = "已按原始时间重放通过上下文确认的输入"
    }

    private func resolveDeferredContext(snapshot: FocusContext.Snapshot, contextVersion: UInt64,
                                        now: Double, date: Date) {
        let pending = peekPendingForContextBoundary()
        if pending.lost > 0 {
            discardDeferredContext("事件缓冲区溢出；未确认输入已丢弃")
        } else {
            replayDeferredContext(snapshot: snapshot, contextVersion: contextVersion, now: now,
                                  date: date, followingEvents: pending.events)
        }
    }

    private func flushInputQuality() {
        qualityFlushTask?.cancel(); qualityFlushTask = nil
        let result = inputQuality.flush()
        for input in result.accepted { onInput?(input) }
    }

    private func deliverInputQuality(_ result: InputQualityResult) {
        for input in result.accepted { onInput?(input) }
        if result.excluded > 0 {
            compositionTracker.reset()
            if result.reason == .repeatedKey {
                suspiciousRepeatEvents &+= UInt64(result.excluded)
                onInterruption?("疑似连续重复按键已排除")
            } else {
                suspiciousBurstEvents &+= UInt64(result.excluded)
                onInterruption?("疑似多键突发输入已排除")
            }
        }
        guard let deadline = result.deadline else {
            qualityFlushTask?.cancel(); qualityFlushTask = nil
            return
        }
        // Reuse the existing deadline instead of cancelling/creating one task
        // per key. A still-active prefix reschedules this single one-shot once.
        guard qualityFlushTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.qualityFlushTask = nil
            let result = self.inputQuality.flushIfDue(now: ProcessInfo.processInfo.systemUptime)
            self.deliverInputQuality(result)
        }
        qualityFlushTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: task)
    }

    fileprivate static func exerciseBufferChecks() -> [String] {
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
        let monitor = InputMonitor()
        var interruptions = [String]()
        var forwarded = 0
        monitor.onInterruption = { interruptions.append($0) }
        monitor.onInput = { _ in forwarded += 1 }
        // These constructed events are never posted to macOS. Tests exercise
        // the actual callback ring without a tap or either TCC permission.
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return ["construct metadata event"] }
        monitor.running = true
        monitor.accepting = true
        _ = monitor.compositionTracker.classify(key: 0, time: 1, contextVersion: 1, editable: true, inputMethod: true, valid: true)
        _ = monitor.signal
        for _ in 0..<1024 { monitor.capture(type: .keyDown, event: event) }
        expect(monitor.buffered == 1024 && monitor.ring.count == 1024, "fixed ring capacity")
        monitor.capture(type: .keyDown, event: event)
        expect(monitor.buffered == 1024 && monitor.dropped == 1, "overflow is bounded")
        monitor.drain()
        expect(!monitor.compositionTracker.isActive, "overflow clears the estimated composition hypothesis")
        expect(monitor.overflowCount == 1 && interruptions.contains(where: { $0.contains("溢出") }), "overflow publishes interruption")
        expect(monitor.buffered == 0 && monitor.dropped == 0 && forwarded == 0, "overflow batch is discarded without stale forwarding")
        event.setIntegerValueField(.keyboardEventKeycode, value: 7)
        monitor.capture(type: .keyDown, event: event)
        let recovered = monitor.takePending()
        expect(recovered.events.count == 1 && recovered.events.first?.key == 7 && recovered.lost == 0, "next batch recovers after loss")
        for _ in 0..<1030 { monitor.capture(type: .keyDown, event: event) }
        _ = monitor.compositionTracker.classify(key: 0, time: 2, contextVersion: 1, editable: true, inputMethod: true, valid: true)
        monitor.stop()
        expect(!monitor.compositionTracker.isActive, "pause clears the estimated composition hypothesis")
        expect(monitor.buffered == 0 && monitor.dropped == 0 && !monitor.accepting, "stop clears pending data and loss marker")
        monitor.capture(type: .keyDown, event: event)
        expect(monitor.buffered == 0, "stopped callback accepts nothing")
        monitor.running = true
        monitor.accepting = true
        monitor.diagnosticsEnabled = true
        for _ in 0..<3000 { monitor.capture(type: .keyDown, event: event) }
        expect(monitor.measureCount == 2048 && monitor.measurements.count == 2048 && monitor.ring.count == 1024, "diagnostic and input memory stay bounded")
        monitor.stop()
        monitor.running = true
        monitor.accepting = true
        monitor.capture(type: .keyDown, event: event)
        let resumed = monitor.takePending()
        expect(resumed.events.count == 1 && resumed.lost == 0, "resume has no old overflow marker")
        monitor.stop()

        // Verify the live capture copies the OS flags used by the hard
        // exclusions, without posting these constructed events to the system.
        monitor.running = true; monitor.accepting = true
        guard let privateSource = CGEventSource(stateID: .privateState),
              let privateEvent = CGEvent(keyboardEventSource: privateSource, virtualKey: 0, keyDown: true) else {
            monitor.stop()
            return failures + ["construct private-source metadata fixture"]
        }
        privateEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let privateState = privateSource.sourceStateID.rawValue
        expect(privateState != 0 && privateState != 1 && Int32(truncatingIfNeeded: privateEvent.getIntegerValueField(.eventSourceStateID)) == privateState, "private-source fixture preserves its unique state-table ID")
        monitor.capture(type: .keyDown, event: privateEvent)
        let marked = monitor.takePending()
        expect(marked.events.first?.repeated == true && marked.events.first?.synthetic == true, "capture preserves autorepeat and known synthetic metadata")
        for publicState: CGEventSourceStateID in [.combinedSessionState, .hidSystemState] {
            guard let source = CGEventSource(stateID: publicState),
                  let publicEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                failures.append("construct public-source metadata fixture")
                continue
            }
            monitor.capture(type: .keyDown, event: publicEvent)
            expect(monitor.takePending().events.first?.synthetic == false, "public event source alone does not establish generated input")
        }
        monitor.stop()

        // The coordinator can flush valid short prefixes before pause/sleep;
        // heuristic opt-out also flushes rather than silently losing input.
        let start = ProcessInfo.processInfo.systemUptime
        let candidate = ClassifiedInput(time: start, date: Date(), context: 1,
                                        category: .textEntry, evidence: .probable,
                                        source: .global, language: "en")
        let before = forwarded
        monitor.deliverInputQuality(monitor.inputQuality.observe(candidate, physicalKey: 0))
        expect(forwarded == before && monitor.qualityFlushTask != nil, "quality prefix uses one bounded one-shot deadline")
        monitor.flushPendingInput()
        expect(forwarded == before + 1 && monitor.inputQuality.bufferedCount == 0 && monitor.qualityFlushTask == nil, "pause boundary flush preserves short valid input")
        monitor.deliverInputQuality(monitor.inputQuality.observe(candidate, physicalKey: 0))
        monitor.suspectedInputFilteringEnabled = false
        expect(forwarded == before + 2 && monitor.inputQuality.bufferedCount == 0 && monitor.qualityFlushTask == nil, "disabling suspected filtering flushes its pending prefix")
        expect(interruptions.contains("疑似异常输入过滤设置已变化"), "heuristic policy change interrupts timing")
        return failures + exerciseDeferredContextChecks() + exerciseGlobalKeyboardCompatibilityChecks() + exerciseCaptureRecoveryChecks()
    }

    /// Fake metadata exercises the live classification/replay helpers without
    /// posting keys, querying AX elements, starting a tap or prompting for TCC.
    private static func exerciseDeferredContextChecks() -> [String] {
        InputLanguages.withPolicyForChecks(nil) {
            var failures = [String]()
            func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
            let start = ProcessInfo.processInfo.systemUptime
            let date = Date(timeIntervalSince1970: 1_767_225_600)
            func sample(version: UInt64 = 1, ready: Bool = true, editable: Bool = true,
                        ime: Bool = true, expires: Double? = nil, bundle: String = "test.editor") -> FocusContext.Snapshot {
                FocusContext.Snapshot(version: version, bundleID: bundle, appName: "Editor", role: kAXTextAreaRole,
                                      editable: editable, ready: ready, reason: "metadata fixture",
                                      expires: expires ?? start + 10, inputMethod: ime, languageCode: ime ? "zh" : "en")
            }
            func raw(_ key: Int64 = 0, offset: Double = 0, version: UInt64 = 1,
                     flags: CGEventFlags = [], synthetic: Bool = false, repeated: Bool = false) -> Raw {
                Raw(time: start + offset, key: key, flags: flags.rawValue, repeated: repeated,
                    synthetic: synthetic, version: version)
            }
            func makeMonitor(filtering: Bool = false) -> InputMonitor {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                monitor.suspectedInputFilteringEnabled = filtering
                return monitor
            }
            let unresolved = sample(ready: false)

            for ime in [false, true] {
                let monitor = makeMonitor(filtering: true)
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                let firstTask = monitor.deferredContextExpiryTask.map(ObjectIdentifier.init)
                monitor.process(raw(45, offset: 0.08), snapshot: unresolved, contextVersion: 1, now: start + 0.08, date: date)
                monitor.process(raw(ime ? 18 : 14, offset: 0.16), snapshot: unresolved, contextVersion: 1, now: start + 0.16, date: date)
                expect(monitor.pendingContextEvents == 3 && forwarded.isEmpty && monitor.unknownEvents == 0, "unresolved same-version metadata waits without counting")
                expect(firstTask != nil && monitor.deferredContextExpiryTask.map(ObjectIdentifier.init) == firstTask, "context wait reuses one oldest-event expiry task")
                monitor.replayDeferredContext(snapshot: sample(ime: ime), contextVersion: 1, now: start + 0.2, date: date)
                monitor.replayDeferredContext(snapshot: sample(ime: ime), contextVersion: 1, now: start + 0.21, date: date)
                monitor.process(raw(14, offset: 0.24), snapshot: sample(ime: ime), contextVersion: 1, now: start + 0.24, date: date)
                monitor.flushPendingInput()
                expect(forwarded.map(\.time) == [start, start + 0.08, start + 0.16, start + 0.24], "replay precedes later live input with original timestamps exactly once")
                expect(forwarded.count == 4 && forwarded[2].category == (ime ? .composition : .textEntry), "replayed input still passes language-aware metadata classification")
                expect(!forwarded.isEmpty && abs(forwarded[0].date.timeIntervalSince(date) + 0.2) < 0.000_01, "replay preserves capture-time wall-clock mapping")
                expect(monitor.deferredAcceptedEvents == 3 && monitor.deferredDiscardedEvents == 0 && monitor.pendingContextEvents == 0 && monitor.deferredContextExpiryTask == nil, "successful replay clears bounded pending state")
            }

            for boundary in 0..<5 {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                if boundary == 0 {
                    monitor.replayDeferredContext(snapshot: sample(version: 2), contextVersion: 2, now: start + 0.1, date: date)
                } else if boundary == 1 {
                    monitor.replayDeferredContext(snapshot: sample(editable: false), contextVersion: 1, now: start + 0.1, date: date)
                } else if boundary == 2 {
                    monitor.hasInputPermission = false
                    monitor.replayDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.1, date: date)
                } else if boundary == 3 {
                    monitor.hasAccessibilityPermission = false
                    monitor.replayDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.1, date: date)
                } else {
                    monitor.replayDeferredContext(snapshot: sample(expires: start - 0.1), contextVersion: 1, now: start + 0.1, date: date)
                }
                expect(monitor.deferredAcceptedEvents == 0 && monitor.deferredDiscardedEvents == 1 && monitor.unknownEvents == 1 && monitor.pendingContextEvents == 0, "version permissions noneditable and lease boundaries discard unconfirmed metadata")
            }

            for key: Int64 in [49,123,36,48] {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(key, offset: 0.1), snapshot: unresolved, contextVersion: 1, now: start + 0.1, date: date)
                monitor.replayDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.2, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.deferredDiscardedEvents == 1 && monitor.deferredAcceptedEvents == 0, "space navigation and ambiguous actions prevent replay across an unknown boundary")
            }
            for boundary in 0..<4 {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(offset: 0.1, flags: boundary == 0 ? .maskCommand : boundary == 1 ? .maskControl : [],
                                    synthetic: boundary == 2, repeated: boundary == 3),
                                snapshot: unresolved, contextVersion: 1, now: start + 0.1, date: date)
                monitor.replayDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.2, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.deferredDiscardedEvents == 1 && monitor.deferredAcceptedEvents == 0, "shortcut generated and repeat boundaries cannot revive queued metadata")
            }

            for boundary in 0..<3 {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: boundary == 1 ? 49 : 0, keyDown: true) else {
                    monitor.discardDeferredContext("fixture cleanup")
                    failures.append("construct deferred-ring boundary fixture")
                    continue
                }
                event.timestamp = CGEventTimestamp((start + 0.1) * 1_000_000_000)
                if boundary == 0 { event.flags = .maskCommand }
                monitor.accepting = true
                for _ in 0..<(boundary == 2 ? 1025 : 1) { monitor.capture(type: .keyDown, event: event) }
                monitor.resolveDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.2, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.deferredAcceptedEvents == 0 && monitor.deferredDiscardedEvents == 1, "already captured ring boundaries and loss prevent early context replay")
                expect(monitor.buffered > 0, "context resolution inspects the ring without consuming its next batch")
                monitor.accepting = false
                _ = monitor.takePending()
            }

            do {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(45, offset: 0.2), snapshot: unresolved, contextVersion: 1, now: start + 0.2, date: date)
                monitor.expireDeferredContext(now: start + 0.351)
                expect(monitor.pendingContextEvents == 0 && monitor.deferredDiscardedEvents == 2 && monitor.deferredContextSummary.contains("超时"), "oldest-event deadline bounds the entire uncertain run")
                for index in 0..<65 {
                    let offset = Double(index) * 0.001
                    monitor.process(raw(offset: offset), snapshot: unresolved, contextVersion: 1, now: start + offset, date: date)
                    expect(monitor.pendingContextEvents <= deferredContextCapacity, "context metadata queue stays bounded at 64")
                }
                expect(monitor.pendingContextEvents == 0 && monitor.deferredDiscardedEvents == 66 && monitor.unknownEvents == 67 && monitor.deferredContextSummary.contains("已满"), "context capacity loss is explicit and leaves no stale prefix")
            }

            do {
                let monitor = makeMonitor(filtering: true)
                var order = [String]()
                monitor.onInput = { order.append($0.category.rawValue) }
                monitor.onInterruption = { _ in order.append("break") }
                monitor.process(raw(), snapshot: sample(), contextVersion: 1, now: start, date: date)
                monitor.process(raw(45, offset: 0.05), snapshot: unresolved, contextVersion: 1, now: start + 0.05, date: date)
                monitor.process(raw(offset: 0.1, flags: .maskCommand), snapshot: unresolved, contextVersion: 1, now: start + 0.1, date: date)
                expect(order == ["textEntry", "break", "command"], "confirmed quality prefix flushes before uncertain discard and command")
                monitor.process(raw(14, offset: 0.15), snapshot: unresolved, contextVersion: 1, now: start + 0.15, date: date)
                monitor.flushPendingInput()
                expect(monitor.pendingContextEvents == 0 && monitor.deferredDiscardedEvents == 2, "counting-policy flush discards unresolved metadata")
            }

            for timestamp in [Double.nan, .infinity, -1, start + 0.1] {
                let monitor = makeMonitor()
                var event = raw(); event.time = timestamp
                monitor.process(event, snapshot: unresolved, contextVersion: 1, now: start, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.unknownEvents == 1, "invalid or future event clocks cannot extend context waiting")
            }
            do {
                let monitor = makeMonitor()
                monitor.process(raw(), snapshot: sample(expires: start - 0.01), contextVersion: 1, now: start, date: date)
                monitor.process(raw(version: 2), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(), snapshot: sample(editable: false), contextVersion: 1, now: start, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.unknownEvents == 3, "expired leases obsolete versions and resolved noneditable contexts never defer")
            }
            do {
                let monitor = makeMonitor()
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                let capturedLease = sample(expires: start + 0.1)
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start + 0.5,
                                date: date, capturedLease: capturedLease)
                expect(forwarded.count == 1 && forwarded[0].category == .textEntry && monitor.pendingContextEvents == 0,
                       "capture-time-valid input survives late delivery without requiring lease renewal")
                monitor.process(raw(45, offset: 0.4), snapshot: unresolved, contextVersion: 1, now: start + 0.5,
                                date: date, capturedLease: capturedLease)
                expect(forwarded.count == 1 && monitor.pendingContextEvents == 1,
                       "post-expiry input waits for fresh validation instead of reusing prior eligibility")
                monitor.replayDeferredContext(snapshot: sample(), contextVersion: 1, now: start + 0.55, date: date)
                expect(forwarded.count == 2 && monitor.deferredAcceptedEvents == 1,
                       "fresh same-version validation recovers only the post-expiry pending input")
                monitor.process(raw(), snapshot: sample(version: 2, ready: false), contextVersion: 2,
                                now: start + 0.6, date: date, capturedLease: capturedLease)
                expect(forwarded.last?.category == .unknown && monitor.pendingContextEvents == 0,
                       "real version invalidation rejects even previously valid captured leases")
            }
            return failures
        }
    }

    private static func exerciseGlobalKeyboardCompatibilityChecks() -> [String] {
        InputLanguages.withPolicyForChecks(nil) {
            var failures = [String]()
            func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
            let start = ProcessInfo.processInfo.systemUptime
            let date = Date(timeIntervalSince1970: 1_767_225_600)
            func sample(version: UInt64 = 1, ready: Bool = false, editable: Bool = false,
                        ime: Bool = true, language: String = "zh", identityReady: Bool = true,
                        identityExpires: Double? = nil, validSince: Double = 0,
                        keyboardActivityBlocked: Bool = false) -> FocusContext.Snapshot {
                FocusContext.Snapshot(version: version, bundleID: "test.editor", appName: "Editor", role: "",
                                      editable: editable, ready: ready, reason: "AX unresolved fixture",
                                      expires: start + 1, inputMethod: ime, languageCode: language,
                                      validSince: validSince, identityReady: identityReady,
                                      identityExpires: identityExpires ?? start + 1,
                                      keyboardActivityBlocked: keyboardActivityBlocked)
            }
            func raw(_ key: Int64 = 0, offset: Double = 0, version: UInt64 = 1,
                     flags: CGEventFlags = [], synthetic: Bool = false, repeated: Bool = false) -> Raw {
                Raw(time: start + offset, key: key, flags: flags.rawValue, repeated: repeated,
                    synthetic: synthetic, version: version)
            }
            func makeMonitor() -> InputMonitor {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                monitor.globalKeyboardCompatibilityEnabled = true
                expect(monitor.context.keyboardCompatibilityEnabled, "global compatibility updates the identity-lease capture policy")
                return monitor
            }
            let unresolved = sample()
            do {
                let monitor = makeMonitor()
                var forwarded = [ClassifiedInput]()
                var engine = StatisticsEngine(timeZone: TimeZone(secondsFromGMT: 0)!)
                monitor.onInput = { forwarded.append($0); _ = engine.record($0) }
                monitor.onInterruption = { _ in engine.interrupt() }
                for (offset, key): (Double, Int64) in [(0,0), (0.2,18), (0.4,30), (0.5,49), (0.6,51), (0.8,45)] {
                    monitor.process(raw(key, offset: offset), snapshot: unresolved, contextVersion: 1,
                                    now: start + offset, date: date.addingTimeInterval(offset))
                }
                monitor.flushPendingInput()
                let measured = engine.snapshot(now: start + 0.8)
                expect(forwarded.map(\.time) == [start, start + 0.2, start + 0.4, start + 0.6, start + 0.8], "global compatibility preserves physical counts and original timing while excluding spaces")
                expect(forwarded.allSatisfy({ $0.evidence == .probable && $0.source == .global && $0.language == "zh" && $0.committedCharacters == nil }), "global compatibility remains probable global activity without character coverage")
                expect(measured.probable.keys == 5 && measured.probable.intervals == 4 && abs(measured.probable.seconds - 0.8) < 0.000_01, "global keyboard estimate uses accepted n-minus-one intervals")
                expect(measured.probable.rhythmKPM.map({ abs($0 - 300) < 0.001 }) == true && measured.probable.characters == 0 && measured.probable.characterCPM == nil && measured.confirmed.keys == 0, "global compatibility yields estimated speed without CPM or confirmed input")
                expect(monitor.contextSummary == globalKeyboardCompatibilitySummary && monitor.status == globalKeyboardCompatibilitySummary, "global compatibility identifies the unconfirmed-textbox estimate")
                monitor.replayDeferredContext(snapshot: sample(ready: true, editable: true), contextVersion: 1, now: start + 0.9, date: date)
                expect(monitor.pendingContextEvents == 0 && monitor.deferredAcceptedEvents == 0 && forwarded.count == 5, "global compatibility never duplicates activity through AX deferral replay")
            }

            for boundary in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11] {
                let monitor = makeMonitor()
                var effective = 0
                monitor.onInput = { if $0.category.isEffective { effective += 1 } }
                let snapshot = sample(version: boundary == 5 ? 2 : 1, ready: boundary == 0,
                                      identityReady: boundary != 3,
                                      identityExpires: boundary == 4 ? start - 0.1 : nil,
                                      validSince: boundary == 6 ? start + 0.1 : 0,
                                      keyboardActivityBlocked: boundary == 11)
                if boundary == 7 { monitor.hasInputPermission = false }
                if boundary == 8 { monitor.hasAccessibilityPermission = false }
                if boundary == 10 { monitor.excluded.insert("test.editor") }
                monitor.process(raw(offset: boundary == 9 ? 0.1 : 0), snapshot: snapshot,
                                contextVersion: boundary == 5 ? 2 : 1, now: start, date: date, mayDefer: false)
                monitor.flushPendingInput()
                expect(effective == 0 && monitor.pendingContextEvents == 0, "global compatibility rejects resolved noneditable stale identity version clock permission and mode-editor boundaries")
            }
            for (language, ime) in [("en", false), ("zh", true), ("ja", true), ("ko", true), ("fr", false), ("und", false)] {
                let monitor = makeMonitor()
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                var source = sample(ime: ime, language: language)
                source.inputSourceID = "test." + language
                source.inputModeID = "mode"
                monitor.process(raw(), snapshot: source,
                                contextVersion: 1, now: start, date: date)
                monitor.process(raw(18, offset: 0.08), snapshot: source,
                                contextVersion: 1, now: start + 0.08, date: date)
                monitor.flushPendingInput()
                expect(forwarded.count == 2 && forwarded.allSatisfy({ $0.language == language && $0.evidence == .probable &&
                    $0.inputMethodID == "test." + language + "|mode" && $0.usesInputMethod == ime && $0.committedCharacters == nil }) &&
                    monitor.deferredAcceptedEvents == 0 && monitor.pendingContextEvents == 0 &&
                    monitor.contextSummary == globalKeyboardCompatibilitySummary,
                    "global fallback counts letters and digits for every source and retains that source's metadata")
            }
            do {
                let monitor = makeMonitor()
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                monitor.process(raw(18), snapshot: sample(ready: true, editable: true),
                                contextVersion: 1, now: start, date: date)
                monitor.flushPendingInput()
                expect(forwarded.count == 1 && forwarded[0].category == .textEntry,
                       "global mode counts a leading digit when a selected IME is in Latin passthrough")
            }

            for key: Int64 in [49,123,124,125,126,53,115,116,119,121,36,48,76,122] {
                let monitor = makeMonitor()
                var effective = 0
                monitor.onInput = { if $0.category.isEffective { effective += 1 } }
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(key, offset: 0.2), snapshot: unresolved, contextVersion: 1, now: start + 0.2, date: date)
                monitor.flushPendingInput()
                expect(effective == 1 && monitor.pendingContextEvents == 0, "global compatibility excludes space navigation and ambiguous actions after printable activity")
            }
            for boundary in 0..<4 {
                let monitor = makeMonitor()
                var effective = 0
                monitor.onInput = { if $0.category.isEffective { effective += 1 } }
                monitor.process(raw(flags: boundary == 0 ? .maskCommand : boundary == 1 ? .maskControl : [],
                                    synthetic: boundary == 2, repeated: boundary == 3),
                                snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.flushPendingInput()
                expect(effective == 0 && monitor.pendingContextEvents == 0, "global compatibility retains shortcut generated and autorepeat exclusions")
            }
            do {
                let monitor = makeMonitor()
                var effective = 0
                monitor.onInput = { if $0.category.isEffective { effective += 1 } }
                InputLanguages.withPolicyForChecks(["en"]) {
                    monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date, mayDefer: false)
                    monitor.flushPendingInput()
                }
                expect(effective == 0 && monitor.pendingContextEvents == 0, "global compatibility honors the monitored-language policy")
            }
            do {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                var effective = 0
                monitor.onInput = { if $0.category.isEffective { effective += 1 } }
                monitor.process(raw(), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                expect(monitor.pendingContextEvents == 1 && !monitor.globalKeyboardCompatibilityEnabled, "global compatibility is opt-in and preserves strict-mode deferral")
                monitor.globalKeyboardCompatibilityEnabled = true
                monitor.process(raw(45, offset: 0.1), snapshot: unresolved, contextVersion: 1, now: start + 0.1, date: date)
                monitor.flushPendingInput()
                monitor.replayDeferredContext(snapshot: sample(ready: true, editable: true), contextVersion: 1, now: start + 0.2, date: date)
                expect(effective == 1 && monitor.deferredDiscardedEvents == 1 && monitor.pendingContextEvents == 0 && monitor.deferredAcceptedEvents == 0, "mode changes discard prior unresolved metadata before keyboard activity starts")
                monitor.globalKeyboardCompatibilityEnabled = false
                expect(monitor.status == "未知输入上下文" && !monitor.context.keyboardCompatibilityEnabled, "disabling global compatibility removes its active status and identity policy")
            }
            return failures + exerciseModifierChecks()
        }
    }

    private static func exerciseModifierChecks() -> [String] {
        InputLanguages.withPolicyForChecks(nil) {
            var failures = [String]()
            func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
            let start = ProcessInfo.processInfo.systemUptime
            let date = Date()
            let snapshot = FocusContext.Snapshot(version: 1, bundleID: "test.editor", appName: "Editor",
                role: kAXTextAreaRole, editable: true, ready: true, reason: "fixture", expires: start + 10,
                inputMethod: true, languageCode: "zh", inputSourceID: "test.pinyin", inputModeID: "pinyin")
            func raw(_ key: Int64, _ offset: Double, flags: CGEventFlags = [], modifier: Bool = false) -> Raw {
                Raw(time: start + offset, key: key, flags: flags.rawValue, version: 1, modifierChanged: modifier)
            }
            for key: Int64 in [54, 55, 57, 59, 62, 63] {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                monitor.process(raw(0, 0), snapshot: snapshot, contextVersion: 1, now: start, date: date)
                expect(monitor.compositionTracker.isActive && forwarded.isEmpty, "initial IME letter waits in the quality prefix")
                monitor.process(raw(key, 0.05, modifier: true), snapshot: snapshot, contextVersion: 1, now: start + 0.05, date: date)
                expect(!monitor.compositionTracker.isActive && forwarded.count == 1 && monitor.unknownEvents == 0,
                       "no-op switch and shortcut modifier changes preserve valid input without counting the modifier")
                monitor.process(raw(45, 0.1), snapshot: snapshot, contextVersion: 1, now: start + 0.1, date: date)
                monitor.flushPendingInput()
                expect(forwarded.map(\.time) == [start, start + 0.1] && forwarded.allSatisfy({ $0.category == .textEntry }),
                       "typing resumes immediately after no-op Caps Lock Globe or Super-key release")
            }
            for key: Int64 in [56, 60, 58, 61] {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                monitor.process(raw(0, 0), snapshot: snapshot, contextVersion: 1, now: start, date: date)
                monitor.process(raw(key, 0.05, modifier: true), snapshot: snapshot, contextVersion: 1, now: start + 0.05, date: date)
                expect(monitor.compositionTracker.isActive && monitor.inputQuality.bufferedCount == 1 && monitor.unknownEvents == 0,
                       "Shift and Option flags alone preserve ordinary typing continuity")
                monitor.flushPendingInput()
            }
            do {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                monitor.suspectedInputFilteringEnabled = false
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                // Super-key shortcuts remain commands; its release must not
                // leave ordinary letters carrying a cached modifier state.
                monitor.process(raw(0, 0, flags: [.maskCommand, .maskControl, .maskShift, .maskAlternate]),
                                snapshot: snapshot, contextVersion: 1, now: start, date: date)
                monitor.process(raw(55, 0.05, modifier: true), snapshot: snapshot, contextVersion: 1, now: start + 0.05, date: date)
                monitor.process(raw(45, 0.1), snapshot: snapshot, contextVersion: 1, now: start + 0.1, date: date)
                expect(forwarded.map(\.category) == [.command, .textEntry], "Vorssaint Super shortcuts are excluded and following ordinary typing is accepted")
                expect(forwarded.last?.inputMethodID == "test.pinyin|pinyin", "source attribution comes from the event's focus lease instead of the live TIS cache")
            }
            do {
                let monitor = InputMonitor()
                monitor.hasInputPermission = true; monitor.hasAccessibilityPermission = true
                let unresolved = FocusContext.Snapshot(version: 1, bundleID: snapshot.bundleID, appName: snapshot.appName,
                    role: "", editable: false, ready: false, reason: "fixture", expires: 0, inputMethod: true, languageCode: "zh")
                var forwarded = [ClassifiedInput]()
                monitor.onInput = { forwarded.append($0) }
                monitor.process(raw(0, 0), snapshot: unresolved, contextVersion: 1, now: start, date: date)
                monitor.process(raw(57, 0.04, modifier: true), snapshot: unresolved, contextVersion: 1, now: start + 0.04, date: date)
                monitor.process(raw(45, 0.08), snapshot: unresolved, contextVersion: 1, now: start + 0.08, date: date)
                monitor.replayDeferredContext(snapshot: snapshot, contextVersion: 1, now: start + 0.12, date: date)
                monitor.flushPendingInput()
                expect(forwarded.map(\.time) == [start, start + 0.08] && monitor.deferredAcceptedEvents == 2 && monitor.deferredDiscardedEvents == 0,
                       "a no-op Caps Lock between deferred letters neither drops nor duplicates them")
            }
            return failures
        }
    }

    static func classify(key: Int64, flags: UInt64, synthetic: Bool, editable: Bool, inputMethod: Bool, valid: Bool) -> (InputCategory, Evidence) {
        let modifiers = CGEventFlags(rawValue: flags)
        return MetadataClassifier.classify(key: key, command: modifiers.contains(.maskCommand), control: modifiers.contains(.maskControl), synthetic: synthetic, editable: editable, inputMethod: inputMethod, valid: valid)
    }

    /// Constructed events exercise recovery and the source-rotation race
    /// without opening a tap, posting keyboard events or requesting permission.
    private static func exerciseCaptureRecoveryChecks() -> [String] {
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return ["construct capture recovery fixture"]
        }
        let monitor = InputMonitor()
        monitor.accepting = true
        var resumed = 0
        for index in 0..<6 {
            monitor.capture(type: index.isMultiple(of: 2) ? .tapDisabledByTimeout : .tapDisabledByUserInput,
                            event: event, reenableTap: { _ in resumed += 1 })
            expect(resumed == index + 1 && monitor.takePending().events.first?.disabled == true,
                   "every tap suspension resumes synchronously before main-thread delivery")
        }
        expect(monitor.retryCount == 0 && monitor.retryTask == nil && monitor.tapThread == nil,
               "repeated suspensions neither exhaust creation retries nor start capture in checks")
        for _ in 0..<1024 { monitor.capture(type: .keyDown, event: event) }
        monitor.capture(type: .tapDisabledByTimeout, event: event, reenableTap: { _ in resumed += 1 })
        expect(resumed == 7 && monitor.buffered == 1024 && monitor.dropped == 1,
               "tap resumes even when its disabled marker cannot enter a full ring")
        _ = monitor.takePending()
        monitor.capture(type: .flagsChanged, event: event)
        expect(monitor.takePending().events.first?.modifierChanged == true,
               "capture distinguishes flagsChanged from countable keyDown events")
        monitor.capture(type: .keyDown, event: event)
        let old = monitor.takePending(advancingTo: 2)
        // Reproduce a callback arriving while the old batch is being delivered.
        monitor.capture(type: .keyDown, event: event)
        let next = monitor.takePending()
        expect(old.events.count == 1 && old.events.first?.version == 1 &&
               next.events.count == 1 && next.events.first?.version == 2 && next.lost == 0,
               "atomic source rotation retains callbacks arriving during old-source delivery")
        monitor.accepting = false
        return failures
    }

    private func recoverTap() {
        discardDeferredContext("事件监听中断；未确认输入已丢弃")
        flushInputQuality()
        compositionTracker.reset()
        onInterruption?("系统暂停了事件监听")
        publish("事件监听中断")
        guard running else { return }
        refreshPermissions()
        guard hasInputPermission else { return }
        lock.lock(); let port = tap; lock.unlock()
        if let port, CFMachPortIsValid(port) {
            CGEvent.tapEnable(tap: port, enable: true)
            // Losing keyboard delivery does not itself change the focused
            // field. Preserve its original lease while breaking timing above.
            publish("监听已恢复")
        } else {
            launchTap()
        }
    }

    private func retryCreation() {
        guard running && retryTask == nil else { return }
        guard retryCount < 3 else { publish("监听不可用：重试已用尽，请检查权限后恢复统计"); return }
        retryCount += 1
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryTask = nil
            guard self.running else { return }
            self.hasInputPermission = CGPreflightListenEventAccess()
            guard self.hasInputPermission else { self.publish("输入监控权限不可用"); return }
            // launchTap deliberately does not reset the retry budget. Only an
            // explicit stop/start starts a fresh bounded recovery session.
            self.launchTap()
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount), execute: task)
    }
}

func runInputBufferChecks() -> [String] {
    InputMonitor.exerciseBufferChecks() + FocusContext.exerciseChecks() + AXMetadataQuery.exerciseChecks()
}
