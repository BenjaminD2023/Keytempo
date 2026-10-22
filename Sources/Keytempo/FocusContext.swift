import AppKit
import ApplicationServices
import Carbon

/// Only accessibility metadata is queried. Text values, titles and URLs are never read.
final class FocusContext {
    struct Snapshot {
        var version: UInt64
        let bundleID: String
        let appName: String
        let role: String
        let editable: Bool
        let ready: Bool
        let reason: String
        let expires: Double
        let inputMethod: Bool
        let languageCode: String
        var validSince: Double = 0
        var querySummary: String = ""

        /// A key already captured within a valid lease remains eligible when
        /// its main-thread batch is delivered later. Expired keys never do.
        func permits(time: Double, version eventVersion: UInt64) -> Bool {
            ready && eventVersion == version && time.isFinite && time >= validSince && time <= expires
        }

        fileprivate func refreshAction(at now: Double) -> RefreshAction {
            if !ready { return .refresh }
            if now > expires { return .expire }
            return now >= expires - 0.2 ? .refresh : .none
        }
    }

    fileprivate enum RefreshAction { case none, refresh, expire }

    /// Only opaque element identity and metadata, never the element's value.
    private struct Metadata: Equatable {
        let pid: pid_t
        let bundleID: String
        let role: String
        let subrole: String
        let enabled: Bool
        let editEvidence: Bool
        let source: InputLanguages.Source
    }

    var onInvalidate: ((UInt64, String) -> Void)?
    var onResolved: ((Snapshot) -> Void)?
    private(set) var version: UInt64 = 1
    private(set) var snapshot = Snapshot(version: 1, bundleID: "", appName: "", role: "", editable: false, ready: false, reason: "正在确认输入上下文", expires: 0, inputMethod: false, languageCode: "und")
    private let queryQueue = DispatchQueue(label: "local.keytempo.focus", qos: .utility)
    private var queryingVersion: UInt64?
    private var retryWork: DispatchWorkItem?
    private var validSince: Double = 0
    private var workspaceObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var active = false
    private var observerSupported = false
    private var retryAfter: Double = 0
    private var failureCount = 0
    private var focusedElement: AXUIElement?
    private var metadata: Metadata?
    private var renewingExpiredLease = false

    func start() {
        guard !active else { return }
        active = true
        _ = InputLanguages.current
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidate("前台应用已变化")
        }
        sourceObserver = NotificationCenter.default.addObserver(forName: InputLanguages.sourceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.invalidate("输入源已变化")
        }
        invalidate("正在确认输入上下文")
    }

    func stop() {
        active = false
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        workspaceObserver = nil
        sourceObserver = nil
        removeAXObserver()
        invalidate("输入上下文已停止", query: false)
    }

    func invalidate(_ reason: String, query: Bool = true) {
        invalidate(reason, query: query, resetFailures: true)
    }

    private func invalidate(_ reason: String, query: Bool, resetFailures: Bool) {
        retryWork?.cancel()
        retryWork = nil
        if resetFailures { retryAfter = 0; failureCount = 0 }
        validSince = ProcessInfo.processInfo.systemUptime
        version &+= 1
        focusedElement = nil
        metadata = nil
        renewingExpiredLease = false
        snapshot = Snapshot(version: version, bundleID: "", appName: "", role: "", editable: false, ready: false, reason: reason, expires: 0, inputMethod: false, languageCode: "und", validSince: validSince)
        onInvalidate?(version, reason)
        if query && active { requestQuery() }
    }

    /// No repeating polling timer: unsupported notifications get an event-triggered check.
    func prepareForEvent() {
        switch snapshot.refreshAction(at: ProcessInfo.processInfo.systemUptime) {
        case .expire:
            beginLeaseRenewal()
        case .refresh:
            // Start before the lease expires. The old metadata can remain in
            // use only until its original deadline and only while its version
            // is still current. Query results verify the opaque focus identity.
            requestQuery()
        case .none: break
        }
    }

    /// Withhold an expired lease before classification, while retaining only
    /// opaque identity for the fresh query's comparison. No expired metadata
    /// authorizes a key. A changed identity still increments the version and
    /// discards all uncertain events; a matching result may replay their times.
    func prepareForBatch(at now: Double) {
        if snapshot.ready && now > snapshot.expires { beginLeaseRenewal() }
    }

    private func beginLeaseRenewal() {
        guard snapshot.ready else { return }
        let previous = snapshot
        renewingExpiredLease = true
        snapshot = Snapshot(version: version, bundleID: previous.bundleID, appName: previous.appName,
                            role: "", editable: false, ready: false, reason: "上下文已过期，正在重新确认",
                            expires: 0, inputMethod: previous.inputMethod, languageCode: previous.languageCode,
                            validSince: previous.validSince, querySummary: previous.querySummary)
        requestQuery()
    }

    func requestQuery() {
        guard active, ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        // A query's completion requests the latest version when necessary.
        // Keys arriving in the same unknown context must not queue more work.
        guard queryingVersion == nil else { return }
        let requestVersion = version
        queryingVersion = requestVersion
        retryWork?.cancel()
        retryWork = nil
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let bundle = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "未知应用"
        let trusted = AXIsProcessTrusted()
        if trusted && pid != observedPID { installAXObserver(pid: pid) }
        let hasNotifications = observerSupported
        let source = InputLanguages.current
        let requestSince = validSince
        queryQueue.async { [weak self] in
            let result = trusted && pid > 0 ? AXMetadataQuery.read(pid: pid) : nil
            let role = result?.role ?? ""
            let subrole = result?.subrole ?? ""
            let ready = result?.ready ?? false
            let enabled = result?.enabled ?? false
            let editEvidence = result?.editEvidence ?? false
            let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            let secure = subrole == kAXSecureTextFieldSubrole
            let uncertainApp = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.vscodium", "org.vim.MacVim", "com.jetbrains"].contains { bundle.hasPrefix($0) }
            let editable = ready && enabled && textRole && editEvidence && !secure && !uncertainApp
            let reason = !trusted ? "未获得辅助功能权限；全局输入不进入有效速度" : !ready ? "AX 查询暂未确认焦点；上下文未知" : secure ? "安全文本区域：不统计" : uncertainApp ? "终端或模式编辑器：未接入用途适配器" : editable ? "可编辑控件元数据；仅估算，不能证明插入文字" : "未确认可编辑文本区域"
            let resolvedMetadata = ready ? Metadata(pid: pid, bundleID: bundle, role: role, subrole: subrole, enabled: enabled, editEvidence: editEvidence, source: source) : nil
            let value = Snapshot(version: requestVersion, bundleID: bundle, appName: name, role: role, editable: editable, ready: ready, reason: reason, expires: ProcessInfo.processInfo.systemUptime + (hasNotifications ? 30 : 0.75), inputMethod: source.inputMethod, languageCode: source.languageCode, validSince: requestSince, querySummary: result?.summary ?? "AX permission unavailable")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queryingVersion = nil
                guard self.active else { return }
                guard self.version == requestVersion else { self.requestQuery(); return }
                InputLanguages.refreshCurrent()
                // A source refresh can synchronously invalidate this version.
                guard self.active, self.version == requestVersion else { self.requestQuery(); return }
                // Notifications can be late or unsupported. Never install a
                // result from an application or input source that already left.
                guard (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == pid,
                      InputLanguages.current == source else {
                    self.invalidate("前台应用或输入源在查询期间已变化")
                    return
                }
                guard !trusted || AXIsProcessTrusted() else {
                    self.invalidate("辅助功能权限已变化", query: false)
                    return
                }
                self.apply(value, focused: result?.focused, metadata: resolvedMetadata, transientFailure: result?.transientFailure ?? false)
            }
        }
    }

    private func apply(_ value: Snapshot, focused: AXUIElement?, metadata nextMetadata: Metadata?, transientFailure: Bool = false) {
        var resolved = value
        if snapshot.ready || (renewingExpiredLease && value.ready) {
            let sameElement = focusedElement.map { previous in focused.map { CFEqual(previous, $0) } ?? false } ?? false
            if !value.ready || !sameElement || metadata != nextMetadata {
                // Notification-less applications can change focus silently.
                // A refresh must not transfer the old field's continuity to it.
                invalidate(value.ready ? "焦点或输入上下文已变化" : value.reason, query: false, resetFailures: false)
                resolved.version = version
                resolved.validSince = validSince
            }
        }
        snapshot = resolved
        if resolved.ready {
            focusedElement = focused
            metadata = nextMetadata
            renewingExpiredLease = false
        } else if !renewingExpiredLease {
            focusedElement = nil
            metadata = nil
        }
        retryWork?.cancel()
        retryWork = nil
        if resolved.ready { failureCount = 0; retryAfter = 0 }
        else {
            failureCount = min(failureCount + 1, 6)
            let delay = Self.retryDelay(failureCount: failureCount, transient: transientFailure)
            retryAfter = ProcessInfo.processInfo.systemUptime + delay
            // Two short, bounded retries cover app/IME focus transitions. After
            // that only a later input event or real notification can retry.
            if active && transientFailure && failureCount <= 2 {
                let retryVersion = version
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.active, self.version == retryVersion else { return }
                    self.retryWork = nil
                    self.requestQuery()
                }
                retryWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        onResolved?(resolved)
    }

    private static func retryDelay(failureCount: Int, transient: Bool) -> Double {
        if transient && failureCount <= 2 { return failureCount == 1 ? 0.04 : 0.12 }
        return Double(1 << max(0, min(3, failureCount - 3)))
    }

    /// In-memory lease/refresh checks; the opaque AX objects are never queried
    /// and no keyboard or system notification is posted by these checks.
    static func exerciseChecks() -> [String] {
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
        func sample(version: UInt64 = 1, ready: Bool = true, expires: Double = 100, editable: Bool = true) -> Snapshot {
            Snapshot(version: version, bundleID: "test.editor", appName: "Editor", role: kAXTextAreaRole, editable: editable, ready: ready, reason: ready ? "metadata" : "AX failure", expires: expires, inputMethod: true, languageCode: "zh")
        }
        let lease = sample()
        expect(lease.refreshAction(at: 99.79) == .none, "focus lease avoids an early AX query")
        expect(lease.refreshAction(at: 99.81) == .refresh, "focus lease requests event-triggered refresh before expiry")
        expect(lease.refreshAction(at: 100.01) == .expire, "expired focus lease must invalidate")
        expect(lease.permits(time: 99.9, version: 1), "valid captured event survives late batch delivery")
        expect(lease.permits(time: 100, version: 1), "focus lease includes its final instant")
        expect(!lease.permits(time: 100.01, version: 1), "expired event cannot reuse prior focus metadata")
        expect(!lease.permits(time: 99, version: 2), "focus lease rejects an obsolete context version")
        expect(!lease.permits(time: -.infinity, version: 1) && !lease.permits(time: -1, version: 1), "focus lease rejects invalid capture timestamps")
        expect(!sample(ready: false).permits(time: 99, version: 1), "unknown focus cannot classify text")
        var freshLease = sample()
        freshLease.validSince = 99
        expect(!freshLease.permits(time: 98.9, version: 1) && freshLease.permits(time: 99, version: 1), "resolved metadata never applies to events captured before the context began")
        expect(retryDelay(failureCount: 1, transient: true) == 0.04 && retryDelay(failureCount: 2, transient: true) == 0.12, "transient focus failures get two bounded short retries")
        expect(retryDelay(failureCount: 3, transient: true) == 1 && retryDelay(failureCount: 6, transient: true) == 8, "persistent focus failures return to event-driven backoff")
        expect(retryDelay(failureCount: 1, transient: false) >= 1, "permission or unsupported failures do not trigger fast retries")

        let context = FocusContext()
        var invalidations = 0
        context.onInvalidate = { _, _ in invalidations += 1 }
        let source = InputLanguages.Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
        let evidence = Metadata(pid: getpid(), bundleID: "test.editor", role: kAXTextAreaRole, subrole: "", enabled: true, editEvidence: true, source: source)
        let focused = AXUIElementCreateApplication(getpid())
        context.apply(lease, focused: focused, metadata: evidence)
        context.apply(sample(expires: 101), focused: focused, metadata: evidence)
        expect(context.version == 1 && invalidations == 0 && context.snapshot.expires == 101, "same opaque focus and metadata refresh without interrupting")

        let differentFocus = AXUIElementCreateSystemWide()
        context.apply(sample(expires: 102), focused: differentFocus, metadata: evidence)
        expect(context.version == 2 && invalidations == 1, "silent focused-element change invalidates context")
        expect(!context.snapshot.permits(time: 99, version: 1), "focus change rejects previously queued context version")

        let disabled = Metadata(pid: getpid(), bundleID: "test.editor", role: kAXTextAreaRole, subrole: "", enabled: false, editEvidence: true, source: source)
        context.apply(sample(version: 2, expires: 103, editable: false), focused: differentFocus, metadata: disabled)
        expect(context.version == 3 && invalidations == 2 && !context.snapshot.editable, "changed focus metadata invalidates continuity")

        context.apply(sample(version: 3, ready: false), focused: nil, metadata: nil)
        expect(context.version == 4 && invalidations == 3 && !context.snapshot.ready && context.focusedElement == nil, "failed refresh immediately discards usable focus")
        expect(context.failureCount == 1 && context.retryAfter > ProcessInfo.processInfo.systemUptime, "failed focus refresh has bounded retry delay")
        context.apply(sample(version: 4, ready: false), focused: nil, metadata: nil)
        expect(context.version == 4 && context.failureCount == 2, "repeated AX failure backs off without a version loop")
        context.invalidate("test notification", query: false)
        expect(context.version == 5 && !context.snapshot.ready && context.metadata == nil, "explicit focus notification invalidates immediately")

        let renewal = FocusContext()
        renewal.apply(lease, focused: focused, metadata: evidence)
        renewal.prepareForBatch(at: 100.1)
        expect(renewal.version == 1 && !renewal.snapshot.ready && !renewal.snapshot.editable, "expired lease withholds eligibility before the first new batch")
        expect(!renewal.snapshot.permits(time: 100.1, version: 1), "renewal cannot authorize input with stale metadata")
        renewal.apply(sample(ready: false), focused: nil, metadata: nil, transientFailure: true)
        expect(renewal.version == 1 && !renewal.snapshot.ready && renewal.renewingExpiredLease, "transient renewal failure never reuses eligibility or relabels buffered events")
        renewal.apply(sample(expires: 102), focused: focused, metadata: evidence)
        expect(renewal.version == 1 && renewal.snapshot.permits(time: 100.1, version: 1), "fresh identical focus evidence can recover the first expired-lease batch")
        renewal.prepareForBatch(at: 102.1)
        renewal.apply(sample(expires: 103), focused: differentFocus, metadata: evidence)
        expect(renewal.version == 2 && !renewal.snapshot.permits(time: 102.1, version: 1), "changed focus during renewal discards the old context version")
        renewal.prepareForBatch(at: 103.1)
        renewal.invalidate("real focus change", query: false)
        expect(!renewal.renewingExpiredLease && renewal.focusedElement == nil && renewal.metadata == nil, "real notifications clear any pending renewal identity immediately")
        return failures
    }

    private func installAXObserver(pid: pid_t) {
        removeAXObserver()
        guard pid > 0 else { return }
        var result: AXObserver?
        let status = AXObserverCreate(pid, { sender, _, _, raw in
            guard let raw else { return }
            let owner = Unmanaged<FocusContext>.fromOpaque(raw).takeUnretainedValue()
            guard owner.active, let current = owner.axObserver,
                  CFEqual(sender, current),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.observedPID else { return }
            owner.invalidate("焦点已变化")
        }, &result)
        guard status == .success, let result else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let focusStatus = AXObserverAddNotification(result, application, kAXFocusedUIElementChangedNotification as CFString, pointer)
        _ = AXObserverAddNotification(result, application, kAXFocusedWindowChangedNotification as CFString, pointer)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        axObserver = result
        observedPID = pid
        observerSupported = focusStatus == .success || focusStatus == .notificationAlreadyRegistered
    }

    private func removeAXObserver() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        observedPID = 0
        observerSupported = false
    }
}
