import AppKit
import Carbon
import TypingCore

/// Main-thread input-source metadata cache. No text, key names or layout payloads.
/// TIS queries happen at initialization, source notifications and explicit refresh.
enum InputLanguages {
    struct Source: Equatable {
        var identifier: String
        var modeIdentifier: String
        var name: String
        var languageCode: String
        var inputMethod: Bool
    }
    struct Option: Identifiable, Equatable {
        var code: String
        var name: String
        var id: String { code }
    }
    static let sourceChanged = Notification.Name("Keytempo.inputSourceChanged")
    static let policyChanged = Notification.Name("Keytempo.inputLanguagePolicyChanged")
    private static let state = State()
    static var current: Source { state.source }
    static var policy: InputLanguagePolicy { state.policy }
    static var allowsCurrent: Bool { policy.allows(languageCode: current.languageCode) }

    static func reloadPolicy() {
        // Recording now combines every input-source language. An old explicit
        // selection (including an empty one) must not silently keep filtering.
        state.policy = recordingPolicy(in: .standard)
        NotificationCenter.default.post(name: policyChanged, object: nil)
    }

    fileprivate static func recordingPolicy(in defaults: UserDefaults) -> InputLanguagePolicy {
        defaults.removeObject(forKey: "monitoredLanguages")
        return InputLanguagePolicy(selectedCodes: nil)
    }

    static func refreshCurrent() { state.refreshSource() }

    fileprivate static func acceptSource(_ next: Source, replacing source: inout Source) -> Bool {
        let changed = next != source
        source = next
        // IMEs can repeat selection notifications without changing sources.
        // InputModeID still catches a real mode change within the same IME.
        return changed
    }

    /// Used only while opening/refreshing settings, never during a key callback.
    static func available() -> [Option] {
        let properties = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        var codes = Set(sources.map { read($0).languageCode })
        codes.insert(current.languageCode)
        codes.insert("und")
        if let selected = policy.selectedCodes { codes.formUnion(selected) }
        return codes.sorted().map { code in
            Option(code: code, name: code == "und" ? "未识别／无特定语言" : Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
    }

    /// Regression checks do not alter the user's saved selection.
    static func withPolicyForChecks<T>(_ codes: Set<String>?, _ body: () -> T) -> T {
        let original = state.policy
        state.policy = InputLanguagePolicy(selectedCodes: codes)
        defer { state.policy = original }
        return body()
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String {
        guard let property = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }
    private static func read(_ source: TISInputSource) -> Source {
        var primary = ""
        if let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(property).takeUnretainedValue() as? [String]
            // The SDK defines the first entry as the source's intended language.
            // An empty first entry is deliberately unknown, even if later entries exist.
            primary = languages?.first ?? ""
        }
        return Source(identifier: string(source, kTISPropertyInputSourceID),
                      modeIdentifier: string(source, kTISPropertyInputModeID),
                      name: string(source, kTISPropertyLocalizedName),
                      languageCode: InputLanguagePolicy.normalize(primary),
                      inputMethod: string(source, kTISPropertyInputSourceType) != (kTISTypeKeyboardLayout as String))
    }

    private final class State {
        var source: Source
        var policy: InputLanguagePolicy
        private var observer: NSObjectProtocol?
        private var workspaceObserver: NSObjectProtocol?
        private var notificationCenter = NotificationCenter.default
        init() {
            source = TISCopyCurrentKeyboardInputSource().map { read($0.takeRetainedValue()) }
                ?? Source(identifier: "", modeIdentifier: "", name: "", languageCode: "und", inputMethod: false)
            policy = InputLanguages.recordingPolicy(in: .standard)
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { [weak self] _ in self?.refreshSource() }
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshSource() }
        }
        func refreshSource() {
            let next = TISCopyCurrentKeyboardInputSource().map { read($0.takeRetainedValue()) }
                ?? Source(identifier: "", modeIdentifier: "", name: "", languageCode: "und", inputMethod: false)
            applySource(next)
        }
        private init(sourceForChecks: Source, notificationCenter: NotificationCenter) {
            source = sourceForChecks
            policy = InputLanguagePolicy(selectedCodes: nil)
            self.notificationCenter = notificationCenter
        }
        private func applySource(_ next: Source) {
            // End exclusive access to source before notifying observers, which
            // synchronously read InputLanguages.current during UI refresh.
            if acceptSource(next, replacing: &source) {
                notificationCenter.post(name: sourceChanged, object: nil)
            }
        }
        static func exerciseChecks() -> [String] {
            let pinyin = Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
            let center = NotificationCenter()
            let cache = State(sourceForChecks: pinyin, notificationCenter: center)
            var observed = [Source]()
            // This synchronous re-read reproduces the real AppModel observer:
            // posting while &source was still borrowed caused an exclusivity
            // trap. This isolated center never posts an OS notification.
            let observer = center.addObserver(forName: sourceChanged, object: nil, queue: nil) { _ in
                observed.append(cache.source)
            }
            defer { center.removeObserver(observer) }
            var failures = [String]()
            for _ in 0..<10 { cache.applySource(pinyin) }
            if !observed.isEmpty { failures.append("duplicate input-source notifications interrupted unchanged selection") }
            var alternateMode = pinyin
            alternateMode.modeIdentifier = "latin"
            cache.applySource(alternateMode)
            if observed != [alternateMode] || cache.source != alternateMode { failures.append("synchronous observer must see the new IME mode without exclusive-access conflict") }
            cache.applySource(alternateMode)
            if observed.count != 1 { failures.append("duplicate IME-mode notification interrupted unchanged selection") }
            cache.applySource(pinyin)
            if observed != [alternateMode, pinyin] { failures.append("synchronous input-source observer must support repeated source changes") }
            return failures
        }
        deinit {
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        }
    }

    fileprivate static func exerciseSourceChecks() -> [String] { State.exerciseChecks() }
}

func runInputLanguageChecks() -> [String] {
    let current = InputLanguages.current
    let options = InputLanguages.available()
    var failures: [String] = []
    if !options.contains(where: { $0.code == "und" }) { failures.append("input languages missing unknown option") }
    if !options.contains(where: { $0.code == current.languageCode }) { failures.append("input languages missing current source") }
    if options.count != Set(options.map(\.code)).count { failures.append("duplicate input language options") }
    if options.contains(where: { InputLanguagePolicy.normalize($0.code) != $0.code }) { failures.append("input language options not normalized") }
    if InputLanguages.withPolicyForChecks([], { InputLanguages.allowsCurrent }) { failures.append("empty input language selection did not exclude current source") }
    if !InputLanguages.withPolicyForChecks(nil, { InputLanguages.allowsCurrent }) { failures.append("all input languages selection excluded current source") }
    let suite = "Keytempo.language-migration-check.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
        defer { defaults.removePersistentDomain(forName: suite) }
        for legacy in [[], ["en"], ["zh"]] {
            defaults.set(legacy, forKey: "monitoredLanguages")
            let policy = InputLanguages.recordingPolicy(in: defaults)
            if defaults.object(forKey: "monitoredLanguages") != nil ||
                !["en", "zh", "ja", "und"].allSatisfy({ policy.allows(languageCode: $0) }) {
                failures.append("legacy input-language selection continued filtering unified recording")
            }
        }
    } else { failures.append("could not create isolated language-migration preferences") }
    failures += InputLanguages.exerciseSourceChecks()
    return failures
}
