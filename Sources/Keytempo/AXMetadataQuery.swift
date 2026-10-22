import ApplicationServices
import Foundation

/// A bounded query of focus identity and control metadata. No text, title, URL,
/// selected text, or selected range is read, and no accessibility value is set.
enum AXMetadataQuery {
    struct Result {
        let focused: AXUIElement?
        let role: String
        let subrole: String
        let enabled: Bool
        let editEvidence: Bool
        let ready: Bool
        let transientFailure: Bool
        let summary: String
    }

    /// Run away from the keyboard callback. All remote messages share a 300 ms
    /// deadline, with at most 100 ms allowed for an individual message.
    static func read(pid: pid_t) -> Result {
        var reader = AXMetadataReader(client: AXMetadataSystemClient())
        let value = reader.read(pid: pid)
        return Result(focused: value.focused, role: value.role, subrole: value.subrole,
                      enabled: value.enabled, editEvidence: value.editEvidence, ready: value.ready,
                      transientFailure: value.transientFailure, summary: value.summary)
    }

    /// Pure scripted replies: no accessibility queries, keyboard events, or
    /// application activation occur while exercising these checks.
    static func exerciseChecks() -> [String] {
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { failures.append(name) } }
        func check(_ client: AXMetadataFakeClient) -> (AXMetadataRead<Int>, AXMetadataFakeClient) {
            var reader = AXMetadataReader(client: client)
            let result = reader.read(pid: 42)
            return (result, reader.client)
        }

        var app = AXMetadataFakeClient()
        app.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.success, .element(4))
        app.setters[.init(4, kAXValueAttribute)] = (.success, true)
        let direct = check(app)
        expect(direct.0.ready && direct.0.editEvidence && direct.0.focused == 4, "AX app focus resolves writable value metadata")
        expect(!direct.1.copied.contains(kAXValueAttribute), "AX never reads a text value")

        var system = app
        system.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.noValue)
        system.copies[.init(2, kAXFocusedUIElementAttribute)] = .init(.success, .element(4))
        expect(check(system).0.ready, "AX noValue app focus falls back to system focus")
        system.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.cannotComplete)
        expect(check(system).0.ready, "AX cannotComplete app focus can recover through system focus")

        var window = app
        window.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.attributeUnsupported)
        window.copies[.init(1, kAXFocusedWindowAttribute)] = .init(.success, .element(3))
        window.copies[.init(3, kAXFocusedUIElementAttribute)] = .init(.success, .element(4))
        expect(check(window).0.ready, "AX unsupported app focus can resolve through its focused window")

        var foreign = system
        foreign.copies[.init(2, kAXFocusedUIElementAttribute)] = .init(.success, .element(5))
        let rejected = check(foreign)
        expect(!rejected.0.ready && rejected.0.focused == nil, "AX rejects system focus from an IME or another process")
        expect(!rejected.1.requests.contains(.init(5, kAXRoleAttribute)), "AX does not classify a foreign focused control")
        var wrongAppPID = system
        wrongAppPID.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.success, .element(5))
        expect(check(wrongAppPID).0.ready, "AX invalid app focus PID can recover through validated system focus")
        var invalidAppFocus = system
        invalidAppFocus.copies[.init(1, kAXFocusedUIElementAttribute)] = .init(.success, .boolean(true))
        expect(check(invalidAppFocus).0.ready, "AX malformed app focus can recover through validated system focus")

        var readOnly = app
        readOnly.setters[.init(4, kAXValueAttribute)] = (.success, false)
        readOnly.setters[.init(4, kAXSelectedTextAttribute)] = (.success, false)
        readOnly.setters[.init(4, kAXSelectedTextRangeAttribute)] = (.success, true)
        let readOnlyResult = check(readOnly)
        expect(readOnlyResult.0.ready && !readOnlyResult.0.editEvidence, "AX selectable read-only text is not edit evidence")
        expect(!readOnlyResult.1.requests.contains(.init(4, kAXSelectedTextRangeAttribute)), "AX does not use selected-range capability as edit evidence")
        readOnly.setters[.init(4, kAXSelectedTextAttribute)] = (.success, true)
        let selected = check(readOnly)
        expect(selected.0.ready && selected.0.editEvidence, "AX selected-text setter capability is edit evidence")
        expect(!selected.1.copied.contains(kAXSelectedTextAttribute), "AX checks selected-text capability without reading selected text")

        var failedEvidence = readOnly
        failedEvidence.setters[.init(4, kAXSelectedTextAttribute)] = (.cannotComplete, false)
        let unknownEvidence = check(failedEvidence).0
        expect(!unknownEvidence.ready && unknownEvidence.transientFailure, "AX inconclusive editability communication failure remains unknown")
        failedEvidence.setters[.init(4, kAXSelectedTextAttribute)] = (.success, true)
        failedEvidence.copies[.init(4, "AXEditable")] = .init(.cannotComplete)
        let recoveredEvidence = check(failedEvidence).0
        expect(recoveredEvidence.ready && recoveredEvidence.editEvidence, "AX independent positive edit evidence overrides earlier optional failure")

        var failedRole = app
        failedRole.copies[.init(4, kAXRoleAttribute)] = .init(.cannotComplete)
        expect(!check(failedRole).0.ready, "AX role communication failure remains unknown")
        var failedSubrole = app
        failedSubrole.copies[.init(4, kAXSubroleAttribute)] = .init(.cannotComplete)
        expect(!check(failedSubrole).0.ready, "AX secure-subrole communication failure remains unknown")
        expect(direct.0.ready, "AX unsupported optional metadata does not reject positive edit evidence")

        var disabled = app
        disabled.copies[.init(4, kAXEnabledAttribute)] = .init(.success, .boolean(false))
        expect(!check(disabled).0.editEvidence, "AX disabled controls cannot supply edit evidence")
        var secure = app
        secure.copies[.init(4, kAXSubroleAttribute)] = .init(.success, .string(kAXSecureTextFieldSubrole))
        expect(!check(secure).0.editEvidence, "AX secure text controls cannot supply edit evidence")

        var slow = window
        slow.duration = 0.2
        let bounded = check(slow)
        expect(!bounded.0.ready && bounded.0.transientFailure, "AX exhausted query budget remains unknown")
        expect(bounded.1.now <= 0.300001 && bounded.1.maximumTimeout <= 0.100001, "AX fallback messages share the 300 ms budget")
        expect(bounded.1.requests.count <= 12, "AX focus query has a fixed maximum number of metadata requests")
        return failures
    }
}

private enum AXMetadataValue<Element> {
    case element(Element), string(String), boolean(Bool)
}

private struct AXMetadataReply<Element> {
    let error: AXError
    let value: AXMetadataValue<Element>?
    init(_ error: AXError, _ value: AXMetadataValue<Element>? = nil) { self.error = error; self.value = value }
}

private protocol AXMetadataClient {
    associatedtype Element
    var now: Double { get }
    func application(pid: pid_t) -> Element
    func systemWide() -> Element
    mutating func setTimeout(_ element: Element, _ seconds: Float) -> AXError
    mutating func copy(_ element: Element, _ attribute: String) -> AXMetadataReply<Element>
    mutating func isSettable(_ element: Element, _ attribute: String) -> (AXError, Bool)
    mutating func pid(_ element: Element) -> (AXError, pid_t)
}

private struct AXMetadataRead<Element> {
    let focused: Element?
    let role: String
    let subrole: String
    let enabled: Bool
    let editEvidence: Bool
    let ready: Bool
    let transientFailure: Bool
    let summary: String
}

private struct AXMetadataReader<Client: AXMetadataClient> {
    var client: Client
    private var deadline: Double = 0
    private var trace = [String]()
    private var path = "none"
    private var transient = false
    private enum Stop: Error { case unavailable }

    init(client: Client) { self.client = client }

    mutating func read(pid: pid_t) -> AXMetadataRead<Client.Element> {
        let started = client.now
        deadline = started + 0.30
        var focused: Client.Element?
        var role = "", subrole = ""
        var enabled = false, editEvidence = false, ready = false
        do {
            guard pid > 0 else { trace.append("pid.invalid"); throw Stop.unavailable }
            let element = try focusedElement(pid: pid)
            focused = element
            role = try string(element, kAXRoleAttribute, stage: "role", optional: false)
            subrole = try string(element, kAXSubroleAttribute, stage: "subrole", optional: true)
            let enabledReply = try copy(element, kAXEnabledAttribute, stage: "enabled")
            if enabledReply.error == .success, case let .boolean(value)? = enabledReply.value { enabled = value }
            else if optionalAbsence(enabledReply.error) { enabled = true }
            else {
                if enabledReply.error == .success { trace.append("enabled.invalidType") }
                throw Stop.unavailable
            }
            if enabled && subrole != kAXSecureTextFieldSubrole {
                editEvidence = try editableEvidence(element)
            }
            guard client.now <= deadline else { trace.append("complete.budget"); transient = true; throw Stop.unavailable }
            ready = true
        } catch { /* The trace records the exact failed stage without content. */ }
        let elapsed = Int((max(0, client.now - started) * 1_000).rounded())
        return AXMetadataRead(focused: ready ? focused : nil, role: role, subrole: subrole,
                              enabled: enabled, editEvidence: editEvidence, ready: ready,
                              transientFailure: !ready && transient,
                              summary: "path=\(path);\(trace.joined(separator: ","));elapsed=\(elapsed)ms")
    }

    private mutating func focusedElement(pid: pid_t) throws -> Client.Element {
        let application = client.application(pid: pid)
        path = "app"
        let direct = try copy(application, kAXFocusedUIElementAttribute, stage: "app.focus")
        if direct.error == .success, let element = try? ownedElement(direct, pid: pid, stage: "app.pid") { return element }
        if direct.error != .success && !fallbackAllowed(direct.error) { throw Stop.unavailable }

        path = "system"
        let system = try copy(client.systemWide(), kAXFocusedUIElementAttribute, stage: "system.focus")
        if system.error == .success, let element = try? ownedElement(system, pid: pid, stage: "system.pid") { return element }
        if system.error != .success && !fallbackAllowed(system.error) { throw Stop.unavailable }

        // Only the actual focused window is consulted; no descendants are scanned.
        path = "window"
        let windowReply = try copy(application, kAXFocusedWindowAttribute, stage: "app.window")
        let window = try ownedElement(windowReply, pid: pid, stage: "window.pid")
        let focused = try copy(window, kAXFocusedUIElementAttribute, stage: "window.focus")
        return try ownedElement(focused, pid: pid, stage: "window.focus.pid")
    }

    private mutating func ownedElement(_ reply: AXMetadataReply<Client.Element>, pid: pid_t, stage: String) throws -> Client.Element {
        guard reply.error == .success, case let .element(element)? = reply.value else {
            if reply.error == .success { trace.append("\(stage).invalidType") }
            throw Stop.unavailable
        }
        try prepare(element, stage: stage)
        let (error, actualPID) = client.pid(element)
        record(error, stage: stage)
        guard error == .success, actualPID == pid else {
            if error == .success { trace.append("\(stage).mismatch"); transient = true }
            throw Stop.unavailable
        }
        return element
    }

    private mutating func string(_ element: Client.Element, _ attribute: String, stage: String, optional: Bool) throws -> String {
        let reply = try copy(element, attribute, stage: stage)
        if reply.error == .success, case let .string(value)? = reply.value, optional || !value.isEmpty { return value }
        if optional && optionalAbsence(reply.error) { return "" }
        if reply.error == .success { trace.append("\(stage).invalidType") }
        throw Stop.unavailable
    }

    private mutating func editableEvidence(_ element: Client.Element) throws -> Bool {
        let editable = try copy(element, "AXEditable", stage: "editable")
        if editable.error == .success, case .boolean(true)? = editable.value { return true }
        var unresolvedFailure = !optionalAbsence(editable.error)
        if editable.error == .success, case .boolean(false)? = editable.value { unresolvedFailure = false }
        else if editable.error == .success { trace.append("editable.invalidType") }
        // Setter capability is metadata. The Value and SelectedText attributes
        // themselves are never fetched, and no setter is invoked.
        for (attribute, stage) in [(kAXValueAttribute, "value.settable"), (kAXSelectedTextAttribute, "selectedText.settable")] {
            try prepare(element, stage: stage)
            let (error, settable) = client.isSettable(element, attribute)
            record(error, stage: stage)
            if error == .success && settable { return true }
            if error != .success && !optionalAbsence(error) { unresolvedFailure = true }
        }
        // A supported false or an unsupported optional attribute is conclusive
        // enough to withhold edit evidence. Failed communication is not: a later
        // independent positive may recover it, otherwise the context is unknown.
        if unresolvedFailure { transient = true; throw Stop.unavailable }
        return false
    }

    private mutating func copy(_ element: Client.Element, _ attribute: String, stage: String) throws -> AXMetadataReply<Client.Element> {
        try prepare(element, stage: stage)
        let reply = client.copy(element, attribute)
        record(reply.error, stage: stage)
        return reply
    }

    private mutating func prepare(_ element: Client.Element, stage: String) throws {
        let remaining = deadline - client.now
        guard remaining > 0 else { trace.append("\(stage).budget"); transient = true; throw Stop.unavailable }
        let timeout = Float(min(0.10, remaining)).nextDown
        guard timeout > 0 else { trace.append("\(stage).budget"); transient = true; throw Stop.unavailable }
        let error = client.setTimeout(element, timeout)
        guard error == .success else { record(error, stage: "\(stage).timeout"); throw Stop.unavailable }
    }

    private mutating func record(_ error: AXError, stage: String) {
        trace.append("\(stage):\(error.rawValue)")
        if [.cannotComplete, .invalidUIElement, .failure, .noValue].contains(error) { transient = true }
    }

    private func optionalAbsence(_ error: AXError) -> Bool { [.attributeUnsupported, .noValue, .notImplemented].contains(error) }
    private func fallbackAllowed(_ error: AXError) -> Bool { optionalAbsence(error) || error == .cannotComplete }
}

private struct AXMetadataSystemClient: AXMetadataClient {
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func application(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func systemWide() -> AXUIElement { AXUIElementCreateSystemWide() }
    func setTimeout(_ element: AXUIElement, _ seconds: Float) -> AXError {
        // Setting the system-wide element timeout changes this process's default.
        // The fallback deliberately retains that bounded (<=100 ms) default;
        // resetting to zero would restore the SDK's potentially long default.
        AXUIElementSetMessagingTimeout(element, seconds)
    }
    func copy(_ element: AXUIElement, _ attribute: String) -> AXMetadataReply<AXUIElement> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return .init(error) }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return .init(error, .element(unsafeBitCast(value, to: AXUIElement.self))) }
        if let string = value as? String { return .init(error, .string(string)) }
        if CFGetTypeID(value) == CFBooleanGetTypeID(), let bool = value as? Bool { return .init(error, .boolean(bool)) }
        return .init(error)
    }
    func isSettable(_ element: AXUIElement, _ attribute: String) -> (AXError, Bool) {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return (error, settable.boolValue)
    }
    func pid(_ element: AXUIElement) -> (AXError, pid_t) {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)
        return (error, pid)
    }
}

private struct AXMetadataFakeClient: AXMetadataClient {
    struct Request: Hashable {
        let element: Int
        let attribute: String
        init(_ element: Int, _ attribute: String) { self.element = element; self.attribute = attribute }
    }
    var now: Double = 0
    var duration: Double = 0.001
    var copies: [Request: AXMetadataReply<Int>] = [
        .init(4, kAXRoleAttribute): .init(.success, .string(kAXTextAreaRole)),
        .init(4, kAXEnabledAttribute): .init(.success, .boolean(true))
    ]
    var setters = [Request: (AXError, Bool)]()
    var copied = [String]()
    var requests = [Request]()
    var maximumTimeout: Float = 0
    private var timeouts = [Int: Float]()
    init() {}
    func application(pid: pid_t) -> Int { 1 }
    func systemWide() -> Int { 2 }
    mutating func setTimeout(_ element: Int, _ seconds: Float) -> AXError {
        timeouts[element] = seconds
        maximumTimeout = max(maximumTimeout, seconds)
        return .success
    }
    mutating func advance(_ element: Int) -> Bool {
        let timeout = Double(timeouts[element] ?? 0.1)
        now += min(duration, timeout)
        return duration <= timeout
    }
    mutating func copy(_ element: Int, _ attribute: String) -> AXMetadataReply<Int> {
        copied.append(attribute)
        let request = Request(element, attribute)
        requests.append(request)
        guard advance(element) else { return .init(.cannotComplete) }
        return copies[request] ?? .init(.attributeUnsupported)
    }
    mutating func isSettable(_ element: Int, _ attribute: String) -> (AXError, Bool) {
        let request = Request(element, attribute)
        requests.append(request)
        guard advance(element) else { return (.cannotComplete, false) }
        return setters[request] ?? (.attributeUnsupported, false)
    }
    mutating func pid(_ element: Int) -> (AXError, pid_t) {
        guard advance(element) else { return (.cannotComplete, 0) }
        return (.success, element == 5 ? 99 : 42)
    }
}
