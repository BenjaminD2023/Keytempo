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

        /// A key already captured within a valid lease remains eligible when
        /// its main-thread batch is delivered later. Expired keys never do.
        func permits(time: Double, version eventVersion: UInt64) -> Bool {
            ready && eventVersion == version && time.isFinite && time >= 0 && time <= expires
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
    private var querying = false
    private var pendingQuery = false
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
        retryAfter = 0
        failureCount = 0
        version &+= 1
        focusedElement = nil
        metadata = nil
        snapshot = Snapshot(version: version, bundleID: "", appName: "", role: "", editable: false, ready: false, reason: reason, expires: 0, inputMethod: false, languageCode: "und")
        onInvalidate?(version, reason)
        if query && active { requestQuery() }
    }

    /// No repeating polling timer: unsupported notifications get an event-triggered check.
    func prepareForEvent() {
        switch snapshot.refreshAction(at: ProcessInfo.processInfo.systemUptime) {
        case .expire:
            invalidate("上下文已过期，正在重新确认")
        case .refresh:
            // Start before the lease expires. The old metadata can remain in
            // use only until its original deadline and only while its version
            // is still current. Query results verify the opaque focus identity.
            requestQuery()
        case .none: break
        }
    }

    func requestQuery() {
        guard active else { return }
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        guard !querying else {
            // Ordinary keys during a refresh do not enqueue redundant queries.
            // An explicit invalidation still needs a query for its new version.
            if !snapshot.ready { pendingQuery = true }
            return
        }
        querying = true
        pendingQuery = false
        let requestVersion = version
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let bundle = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "未知应用"
        let trusted = AXIsProcessTrusted()
        if trusted && pid != observedPID { installAXObserver(pid: pid) }
        let hasNotifications = observerSupported
        let source = InputLanguages.current
        queryQueue.async { [weak self] in
            var role = ""
            var editable = false
            var reason = "未获得辅助功能权限；全局输入不进入有效速度"
            var ready = false
            var resolvedElement: AXUIElement?
            var resolvedMetadata: Metadata?
            if trusted && pid != 0 {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.05)
                var focusedValue: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedValue)
                if result == .success, let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
                    let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(focused, 0.05)
                    var roleValue: CFTypeRef?
                    var subroleValue: CFTypeRef?
                    let roleResult = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue)
                    _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleValue)
                    role = roleValue as? String ?? ""
                    let subrole = subroleValue as? String ?? ""
                    var enabledValue: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(focused, kAXEnabledAttribute as CFString, &enabledValue)
                    let enabled = (enabledValue as? Bool) ?? true
                    var settable = DarwinBoolean(false)
                    let settableResult = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
                    var editableValue: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(focused, "AXEditable" as CFString, &editableValue)
                    let editEvidence = (editableValue as? Bool) == true || (settableResult == .success && settable.boolValue)
                    resolvedElement = focused
                    resolvedMetadata = Metadata(pid: pid, bundleID: bundle, role: role, subrole: subrole, enabled: enabled, editEvidence: editEvidence, source: source)
                    let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
                    let secure = subrole == kAXSecureTextFieldSubrole
                    let uncertainApp = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.vscodium", "org.vim.MacVim", "com.jetbrains"].contains { bundle.hasPrefix($0) }
                    ready = roleResult == .success
                    editable = enabled && textRole && editEvidence && !secure && !uncertainApp
                    reason = secure ? "安全文本区域：不统计" : uncertainApp ? "终端或模式编辑器：未接入用途适配器" : editable ? "可编辑控件元数据；仅估算，不能证明插入文字" : "未确认可编辑文本区域"
                } else {
                    reason = "AX 查询失败或超时；上下文未知"
                }
            }
            let value = Snapshot(version: requestVersion, bundleID: bundle, appName: name, role: role, editable: editable, ready: ready, reason: reason, expires: ProcessInfo.processInfo.systemUptime + (hasNotifications ? 30 : 0.75), inputMethod: source.inputMethod, languageCode: source.languageCode)
            let queryElement = resolvedElement
            let queryMetadata = resolvedMetadata
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.querying = false
                let followUpNeeded = self.pendingQuery || self.version != requestVersion
                self.pendingQuery = false
                if self.active && self.version == requestVersion {
                    self.apply(value, focused: queryElement, metadata: queryMetadata)
                }
                if self.active && followUpNeeded { self.requestQuery() }
            }
        }
    }

    private func apply(_ value: Snapshot, focused: AXUIElement?, metadata nextMetadata: Metadata?) {
        var resolved = value
        if snapshot.ready {
            let sameElement = focusedElement.map { previous in focused.map { CFEqual(previous, $0) } ?? false } ?? false
            if !value.ready || !sameElement || metadata != nextMetadata {
                // Notification-less applications can change focus silently.
                // A refresh must not transfer the old field's continuity to it.
                invalidate(value.ready ? "焦点或输入上下文已变化" : value.reason, query: false)
                resolved.version = version
            }
        }
        snapshot = resolved
        focusedElement = resolved.ready ? focused : nil
        metadata = resolved.ready ? nextMetadata : nil
        if resolved.ready { failureCount = 0; retryAfter = 0 }
        else {
            failureCount = min(failureCount + 1, 4)
            retryAfter = ProcessInfo.processInfo.systemUptime + Double(1 << (failureCount - 1))
        }
        onResolved?(resolved)
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
        return failures
    }

    private func installAXObserver(pid: pid_t) {
        removeAXObserver()
        guard pid > 0 else { return }
        var result: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, raw in
            guard let raw else { return }
            let owner = Unmanaged<FocusContext>.fromOpaque(raw).takeUnretainedValue()
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
