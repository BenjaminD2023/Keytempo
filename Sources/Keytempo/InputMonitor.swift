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
    private(set) var inputSourceSummary = "—"
    private(set) var status = "尚未开始"
    private(set) var capturedEvents: UInt64 = 0
    private(set) var overflowCount: UInt64 = 0
    private(set) var unknownEvents: UInt64 = 0
    private(set) var repeatEvents: UInt64 = 0
    private(set) var suspiciousRepeatEvents: UInt64 = 0
    private(set) var suspiciousBurstEvents: UInt64 = 0
    private(set) var languageFilteredEvents: UInt64 = 0
    private(set) var callbackP99Microseconds: Double?
    var diagnosticsEnabled = false { didSet { lock.lock(); measureCallback = diagnosticsEnabled; lock.unlock() } }
    var suspectedInputFilteringEnabled = true {
        didSet {
            guard oldValue != suspectedInputFilteringEnabled else { return }
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
    private var languagePolicyObserver: NSObjectProtocol?
    private lazy var signal: DispatchSourceUserDataAdd = {
        let value = DispatchSource.makeUserDataAddSource(queue: .main)
        value.setEventHandler { [weak self] in self?.drain() }
        value.resume()
        return value
    }()

    init() {
        languagePolicyObserver = NotificationCenter.default.addObserver(forName: InputLanguages.policyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.context.invalidate("监控语言设置已变化")
        }
        context.onInvalidate = { [weak self] version, reason in
            guard let self else { return }
            self.lock.lock(); self.callbackVersion = version; self.lock.unlock()
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
            self.currentAppName = value.appName
            self.contextSummary = value.reason
            self.inputSourceSummary = (value.inputMethod ? "输入法：组合用途需适配器确认" : "键盘布局") + " · " + value.languageCode
            if !InputLanguages.policy.allows(languageCode: value.languageCode) { self.publish("当前输入源语言已排除") }
            else if self.excluded.contains(value.bundleID) { self.publish("应用已排除") }
            else if value.bundleID == Bundle.main.bundleIdentifier { self.publish("本应用仅在确认输入区统计") }
            else if !self.hasAccessibilityPermission { self.publish("辅助功能权限不可用") }
            else { self.publish(value.editable ? "正在统计 · 估算模式" : "未知输入上下文") }
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
    func flushPendingInput() { flushInputQuality() }

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
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
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

    private func capture(type: CGEventType, event: CGEvent) {
        // Include lock contention in diagnostics. The single monotonic clock
        // read remains cheap when detailed sampling is disabled.
        let start = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let measure = measureCallback
        guard accepting else { lock.unlock(); return }
        if buffered == ring.count { dropped &+= 1 }
        else {
            let slot = (readIndex + buffered) % ring.count
            // Private sources receive a unique state-table ID, not the -1
            // initializer constant. Only 0 (combined session) and 1 (HID) are
            // public state tables. This excludes known private-source input;
            // generators using either public state remain indistinguishable.
            let sourceState = Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID))
            ring[slot] = Raw(time: Double(event.timestamp) / 1_000_000_000, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, synthetic: sourceState != 0 && sourceState != 1, version: callbackVersion, disabled: type == .tapDisabledByTimeout || type == .tapDisabledByUserInput)
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
    private func takePending() -> Batch {
        lock.lock()
        var events = [Raw]()
        events.reserveCapacity(buffered)
        while buffered > 0 {
            events.append(ring[readIndex])
            readIndex = (readIndex + 1) % ring.count
            buffered -= 1
        }
        let lost = dropped; dropped = 0
        let durations = diagnosticsEnabled && measureCount > 0 ? Array(measurements.prefix(measureCount)) : []
        lock.unlock()
        return Batch(events: events, lost: lost, durations: durations)
    }

    private func drain() {
        guard running else { return }
        let batch = takePending()
        let events = batch.events, lost = batch.lost, durations = batch.durations
        if !durations.isEmpty { callbackP99Microseconds = Double(durations.sorted()[min(durations.count - 1, Int(Double(durations.count) * 0.99))]) / 1000 }
        if lost > 0 {
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
        // Classify this batch against its captured context version and original
        // timestamps before a refresh can invalidate that lease. A key captured
        // after expiry is still unknown, even if it is the one requesting refresh.
        let snapshot = context.snapshot
        let now = ProcessInfo.processInfo.systemUptime
        let date = Date()
        for event in events {
            capturedEvents &+= 1
            if event.disabled { recoverTap(); continue }
            if snapshot.bundleID == Bundle.main.bundleIdentifier { flushInputQuality(); compositionTracker.reset(); continue }
            if excluded.contains(snapshot.bundleID) {
                flushInputQuality()
                compositionTracker.reset()
                onInterruption?("应用已排除")
                publish("应用已排除")
                continue
            }
            if event.repeated {
                flushInputQuality()
                compositionTracker.reset()
                repeatEvents &+= 1
                onInterruption?("自动重复不计入手动敲键节奏")
                continue
            }
            if snapshot.ready && event.version == snapshot.version && !InputLanguages.policy.allows(languageCode: snapshot.languageCode) {
                flushInputQuality()
                compositionTracker.reset()
                languageFilteredEvents &+= 1
                onInterruption?("当前输入源语言已排除")
                publish("当前输入源语言已排除")
                continue
            }
            let modifiers = CGEventFlags(rawValue: event.flags)
            let decision = compositionTracker.classify(
                key: event.key, time: event.time, contextVersion: event.version,
                command: modifiers.contains(.maskCommand), control: modifiers.contains(.maskControl),
                shift: modifiers.contains(.maskShift), option: modifiers.contains(.maskAlternate),
                synthetic: event.synthetic, editable: snapshot.editable, inputMethod: snapshot.inputMethod,
                valid: snapshot.permits(time: event.time, version: event.version) && hasInputPermission && hasAccessibilityPermission)
            // Valid text-context spaces contribute neither keys nor an explicit
            // break. The next accepted operation retains its full actual gap.
            guard case let .classified(category, evidence) = decision else {
                // A space closes a repeated-key hypothesis, while remaining
                // absent from both the key count and interruption rules.
                flushInputQuality()
                continue
            }
            if category == .unknown { unknownEvents &+= 1 }
            let input = ClassifiedInput(time: event.time, date: date.addingTimeInterval(event.time - now), context: event.version, category: category, evidence: evidence, source: .global, language: snapshot.languageCode)
            if suspectedInputFilteringEnabled && category == .textEntry && evidence == .probable {
                deliverInputQuality(inputQuality.observe(input, physicalKey: event.key))
            } else {
                // Forward every valid short prefix before the command,
                // navigation, generated or unknown operation breaks timing.
                flushInputQuality()
                onInput?(input)
            }
        }
        context.prepareForEvent()
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
        return failures
    }

    static func classify(key: Int64, flags: UInt64, synthetic: Bool, editable: Bool, inputMethod: Bool, valid: Bool) -> (InputCategory, Evidence) {
        let modifiers = CGEventFlags(rawValue: flags)
        return MetadataClassifier.classify(key: key, command: modifiers.contains(.maskCommand), control: modifiers.contains(.maskControl), synthetic: synthetic, editable: editable, inputMethod: inputMethod, valid: valid)
    }

    private func recoverTap() {
        flushInputQuality()
        compositionTracker.reset()
        onInterruption?("系统暂停了事件监听")
        publish("事件监听中断")
        guard running && retryCount < 3 && retryTask == nil else { return }
        retryCount += 1
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryTask = nil
            guard self.running && CGPreflightListenEventAccess() else { self.refreshPermissions(); return }
            self.lock.lock(); let port = self.tap; self.lock.unlock()
            if let port, CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
                self.context.invalidate("监听恢复；重新确认上下文")
                self.publish("监听已恢复")
            }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount), execute: task)
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

func runInputBufferChecks() -> [String] { InputMonitor.exerciseBufferChecks() + FocusContext.exerciseChecks() }
