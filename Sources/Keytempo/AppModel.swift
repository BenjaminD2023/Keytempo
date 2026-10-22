import AppKit
import SwiftUI
import ServiceManagement
import TypingCore
import TypingStore

// Read/written only on diskQueue; retained by the main actor until completion.
private final class WriteReceipt: @unchecked Sendable { var succeeded: Bool? }

private struct HistorySelection: Equatable, Sendable {
    let days: Int
    let startDay: String
    let endDay: String
}
private struct HistoryReadRequest: Sendable {
    let token: UInt64
    let generation: UInt64
    let selection: HistorySelection
}

struct MetricDisplay: Equatable {
    var language = "und"
    var keys = 0, edits = 0, composition = 0
    var characters = 0
    var intervals = 0.0, seconds = 0.0
    var kpm: Double?, todayKPM: Double?, newKPM: Double?
    var cpm: Double?, todayCPM: Double?
    var estimatedWPM: Double? { TypingRate.estimatedWPM(fromKPM: kpm) }
    var todayEstimatedWPM: Double? { TypingRate.estimatedWPM(fromKPM: todayKPM) }
    var primaryUnit: PrimaryTypingUnit { TypingRate.primaryUnit(forLanguage: language) }
    var primaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: kpm); case .cpm: return cpm; case .unknown: return nil }
    }
    var todayPrimaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: todayKPM); case .cpm: return todayCPM; case .unknown: return nil }
    }
}

/// Global estimates use the same five-operation WPM scale for every language.
/// This presentation never creates committed characters or a measured CPM.
struct MenuSpeedDisplay: Equatable {
    let value: Double?
    let unit: String
    let estimated: Bool
    let isCharacterFallback: Bool

    init(metric: MetricDisplay, evidence: Evidence, forceKPM: Bool = false) {
        isCharacterFallback = !forceKPM && evidence == .probable && metric.primaryUnit == .cpm
        if forceKPM {
            value = metric.kpm; unit = "KPM"; estimated = true
        } else if evidence == .probable {
            value = metric.estimatedWPM; unit = "WPM"; estimated = true
        } else {
            value = metric.primaryRate; unit = metric.primaryUnit.rawValue
            estimated = metric.primaryUnit == .wpm
        }
    }
}
/// Session-only last completed results; never reconstructed from daily averages.
struct CompletedMenuMetric: Equatable {
    let language: String
    let evidence: Evidence
    let kpm: Double?
    let cpm: Double?
    let endDate: Date
    var primaryUnit: PrimaryTypingUnit { TypingRate.primaryUnit(forLanguage: language) }
    var primaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: kpm); case .cpm: return cpm; case .unknown: return nil }
    }
    init(_ segment: CompletedTypingSegment) {
        language = segment.language; evidence = segment.evidence
        kpm = segment.kpm; cpm = segment.cpm; endDate = segment.endDate
    }
}
struct InputLanguageOption: Identifiable, Equatable {
    let id: String
    let name: String
}
struct HistoryDay: Identifiable {
    var id: String { day + "|" + language }
    var day: String
    var periodEnd = ""
    var language = "und"
    var keys = 0, estimatedKeys = 0, edits = 0
    var characters = 0
    var seconds = 0.0, estimatedSeconds = 0.0, intervals = 0.0, estimatedIntervals = 0.0
    var kpm: Double?, estimatedKPM: Double?
    var cpm: Double?
    var rules: String
    var rejectedRows = 0
    var primaryUnit: PrimaryTypingUnit { TypingRate.primaryUnit(forLanguage: language) }
    var primaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: kpm); case .cpm: return cpm; case .unknown: return nil }
    }
    var estimatedPrimaryRate: Double? { primaryUnit == .wpm ? TypingRate.estimatedWPM(fromKPM: estimatedKPM) : nil }
    var estimatedWPM: Double? { TypingRate.estimatedWPM(fromKPM: estimatedKPM) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var status = "正在启动"
    @Published var isPaused = UserDefaults.standard.bool(forKey: "paused")
    @Published var confirmed = MetricDisplay()
    @Published var probable = MetricDisplay()
    @Published private(set) var dailyEstimate = MetricDisplay()
    @Published private(set) var estimatedRecentKPM: Double?
    @Published private(set) var completedPrimaryMetric: CompletedMenuMetric?
    @Published private(set) var completedKPMMetric: CompletedMenuMetric?
    @Published private(set) var completionPending = false
    var selectedCompletedMetric: CompletedMenuMetric? { menuDisplay == "kpm" ? completedKPMMetric : completedPrimaryMetric }
    /// Units follow the current source even before that source has a sample.
    /// Never use a completed result from another language as a live fallback.
    var selectedMenuMetric: MetricDisplay {
        if menuDisplay == "kpm" {
            return MetricDisplay(language: "und", kpm: estimatedRhythmHasFreshInterval ? estimatedRecentKPM : nil)
        }
        var metric = recentEvidence == .confirmed ? confirmed : probable
        metric.language = currentInputLanguageCode
        if !recentPresentationValid { metric.kpm = nil; metric.cpm = nil }
        return metric
    }
    var selectedMenuSpeed: MenuSpeedDisplay {
        MenuSpeedDisplay(metric: selectedMenuMetric, evidence: recentEvidence, forceKPM: menuDisplay == "kpm")
    }
    @Published var phase = "idle"
    @Published var threshold = 1.5
    @Published var modelMedian = 0.0
    @Published var modelMAD = 0.0
    @Published var modelSamples = 0
    @Published var currentApp = ""
    @Published var contextDescription = ""
    @Published var hasInputPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var history: [HistoryDay] = []
    @Published var historyDays = 7
    @Published private(set) var historyStartDay = ""
    @Published private(set) var historyEndDay = ""
    @Published private(set) var historyLoading = false
    @Published private(set) var historyError: String?
    var historyGranularity: HistoryGranularity { .forHistoryDays(historyDays) }
    @Published var excludedAppsText = UserDefaults.standard.string(forKey: "excludedApps") ?? "com.apple.Terminal\ncom.mitchellh.ghostty\ncom.googlecode.iterm2"
    @Published var maximumGap = UserDefaults.standard.object(forKey: "maximumGap") as? Double ?? 3
    @Published var menuDisplay = UserDefaults.standard.string(forKey: "menuDisplay") ?? "speed"
    @Published var diagnosticsEnabled = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var storageError: String?
    @Published var interfaceLanguage = UserDefaults.standard.string(forKey: "interfaceLanguage") == "en" ? "en" : "zh-Hans"
    @Published var monitorAllLanguages = UserDefaults.standard.array(forKey: "monitoredLanguages") == nil
    @Published var monitoredLanguages = UserDefaults.standard.stringArray(forKey: "monitoredLanguages") ?? []
    @Published private(set) var availableInputLanguages: [InputLanguageOption] = []
    @Published private(set) var currentInputLanguage = ""
    @Published private(set) var currentInputLanguageCode = "und"
    @Published var diagnostics: [String] = []
    @Published var commitsEnglish = 0
    @Published var commitsChinese = 0
    private(set) var recentEvidence: Evidence = .probable
    var onMenuUpdate: (() -> Void)?
    var onInterfaceLanguageUpdate: (() -> Void)?
    var openStats: (() -> Void)?, openSettings: (() -> Void)?
    var statisticsVisible = false
    var historyVisible = false
    let updates = AppUpdater()
    let monitor = InputMonitor()
    private var consumedCompletionRevision: UInt64 = 0
    private var engine: StatisticsEngine
    private var store: AggregateStore?
    private var databaseURL: URL!
    private var cached: [String: StoredAggregate] = [:]
    private var pending: [String: StoredAggregate] = [:]
    private var inFlight: [String: StoredAggregate] = [:]
    private var activeReceipt: WriteReceipt?
    private let diskQueue = DispatchQueue(label: "local.keytempo.persistence", qos: .utility)
    private var uiTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var retryCount = 0
    private var generation: UInt64 = 0
    private var clearing = false
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var pendingDiagnostics: [String] = []
    private let monitoringEnabled: Bool
    private var ownedAdapterExcluded = false
    private var presentedInputSource: InputLanguages.Source?
    private var recentPresentationValid = false
    private var estimatedRhythm = RecentIntervalRhythm()
    private var estimatedRhythmHasFreshInterval = false
    private var lastEstimatedInputTime: Double?
    private var historySelection: HistorySelection?
    private var loadedHistoryRows: [String: StoredAggregate] = [:]
    private var historyReadToken: UInt64 = 0
    private var activeHistoryRead: HistoryReadRequest?
    private var pendingHistoryRead: HistoryReadRequest?

    static func rule(_ maximum: Double) -> String { "adaptive-v3-no-space-ime-estimate-max" + String(format: "%.1f", maximum) }
    static func day(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    init(dataDirectory: URL? = nil, monitoringEnabled: Bool = true) {
        self.monitoringEnabled = monitoringEnabled
        let gap = UserDefaults.standard.object(forKey: "maximumGap") as? Double ?? 3
        engine = StatisticsEngine(config: SegmentationConfig(maximumGap: gap, ruleID: Self.rule(gap)), timeZone: .current)
        // Keep the existing on-disk identity so renaming the app preserves history.
        let directory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TypingSpeed", isDirectory: true)
        databaseURL = directory.appendingPathComponent("statistics.sqlite")
        do {
            let db = try AggregateStore(url: databaseURL)
            store = db
            let start = Self.day(Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
            for row in try db.query(since: start) { cached[row.id] = row }
        } catch { storageError = error.localizedDescription }
        monitor.onInput = { [weak self] input in self?.receive(input) }
        monitor.onInterruption = { [weak self] reason in
            guard let self else { return }
            self.interruptEngine(); self.status = reason; self.scheduleUI()
            if self.diagnosticsEnabled {
                self.pendingDiagnostics.append("中断 · \(reason)")
                if self.pendingDiagnostics.count > 60 { self.pendingDiagnostics.removeFirst(self.pendingDiagnostics.count - 60) }
            }
        }
        monitor.onStatus = { [weak self] value in
            guard let self else { return }
            if !self.isPaused { self.status = value }; self.scheduleUI()
        }
        updateExclusions()
        refreshInputLanguages()
        for name in [InputLanguages.sourceChanged, InputLanguages.policyChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.interruptEngine()
                    self.refreshInputLanguages()
                    self.refreshSnapshot()
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.sleeping = true; self.interruptEngine(); self.monitor.stop(); self.flush(); self.status = "系统睡眠，统计已中断"; self.stopUI()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.sleeping = false; self.interruptEngine(); if !self.isPaused { self.monitor.start() }; self.refreshSnapshot()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.updateTimeZone(.current); self?.refreshSnapshot() }
        })
        if !isPaused && monitoringEnabled { monitor.start() } else { status = "已暂停" }
        refreshSnapshot()
    }
    func receiveConfirmedInput(_ input: ClassifiedInput) {
        guard !ownedAdapterExcluded else { return }
        receive(input)
    }
    func interruptConfirmed() { interruptEngine(); scheduleUI() }
    private func receive(_ input: ClassifiedInput) {
        guard !isPaused, !sleeping, !clearing else { return }
        let deltas = engine.record(input)
        captureCompletion()
        if input.category.isEffective && input.evidence != .unknown {
            // A deduplicated or invalid event cannot revive the old lane after
            // an input-source change. Accepted events always emit a key delta.
            if deltas.contains(where: { $0.keys > 0 }) {
                recentEvidence = input.evidence
                recentPresentationValid = input.language == currentInputLanguageCode
            }
        } else {
            recentPresentationValid = false
            estimatedRhythmHasFreshInterval = false
        }
        let estimateDeltas = deltas.filter { $0.evidence == .probable }
        if estimateDeltas.contains(where: { $0.keys > 0 }) {
            // Reset on the next accepted key, never on an idle timer: frozen
            // speeds do not decay, and a fresh burst cannot inherit stale days.
            if let last = lastEstimatedInputTime, input.time < last || input.time - last > 30 {
                estimatedRhythm.reset()
                estimatedRhythmHasFreshInterval = false
            }
            lastEstimatedInputTime = input.time
        }
        let estimatedIntervals = estimateDeltas.reduce(0.0) { $0 + $1.intervals }
        let estimatedSeconds = estimateDeltas.reduce(0.0) { $0 + $1.seconds }
        if estimatedRhythm.record(intervals: estimatedIntervals, seconds: estimatedSeconds) {
            estimatedRhythmHasFreshInterval = true
        } else if deltas.contains(where: { $0.evidence == .confirmed && $0.keys > 0 }) {
            // The validation adapter never contributes to the global estimate.
            estimatedRhythmHasFreshInterval = false
        }
        for d in deltas {
            var row = StoredAggregate(day: d.day, timezone: d.timezoneID, rule: d.ruleID, evidence: d.evidence.rawValue, language: d.language)
            row.keys = d.keys; row.edits = d.edits; row.composition = d.composition
            row.intervals = d.intervals; row.seconds = d.seconds; row.newIntervals = d.newIntervals; row.newSeconds = d.newSeconds
            row.characters = d.characters; row.ratedCharacters = d.ratedCharacters
            row.characterIntervals = d.characterIntervals; row.characterSeconds = d.characterSeconds
            accumulate(row)
        }
        if diagnosticsEnabled {
            // Bounded metadata only: no key names, values or text.
            pendingDiagnostics.append("\(input.category.rawValue) · \(input.evidence.rawValue) · \(input.source.rawValue) · context \(input.context)")
            if pendingDiagnostics.count > 60 { pendingDiagnostics.removeFirst(pendingDiagnostics.count - 60) }
        }
        scheduleUI()
    }
    func receiveCommit(english: Int, chinese: Int, language: String = "und", unratedCharacters: Int = 0) {
        guard !isPaused, !sleeping, !clearing, !ownedAdapterExcluded else { return }
        var row = StoredAggregate(day: Self.day(), timezone: TimeZone.current.identifier, rule: Self.rule(maximumGap), evidence: "confirmed", language: language)
        row.english = english; row.chinese = chinese; row.characters = max(0, unratedCharacters)
        accumulate(row); scheduleUI()
    }
    private func accumulate(_ row: StoredAggregate) {
        if cached[row.id] == nil { cached[row.id] = row } else { cached[row.id]!.merge(row) }
        if pending[row.id] == nil { pending[row.id] = row } else { pending[row.id]!.merge(row) }
        if pending.count >= 256 { flush() }
        if pending.count > 512 {
            isPaused = true; monitor.stop(); interruptEngine(); storageError = "待保存汇总达到容量上限，已暂停；请解决磁盘问题后重试。"
        }
        if saveWork == nil && retryCount == 0 { scheduleSave(after: 30) }
        if cached.count > 8192 {
            let cutoff = Self.day(Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
            cached = cached.filter { $0.value.day >= cutoff }
        }
    }
    private func scheduleSave(after delay: Double) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveWork = nil; self?.flush() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func flush() {
        saveWork?.cancel(); saveWork = nil
        guard inFlight.isEmpty, !pending.isEmpty, let store else { return }
        inFlight = pending; pending.removeAll(keepingCapacity: true)
        let rows = Array(inFlight.values), version = generation
        let receipt = WriteReceipt(); activeReceipt = receipt
        diskQueue.async { [weak self] in
            let result = Result { try store.save(rows) }
            if case .success = result { receipt.succeeded = true } else { receipt.succeeded = false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                if case let .failure(error) = result {
                    for row in self.inFlight.values {
                        if self.pending[row.id] == nil { self.pending[row.id] = row } else { self.pending[row.id]!.merge(row) }
                    }
                    self.storageError = "保存失败：\(error.localizedDescription)"
                    self.retryCount += 1
                } else { self.storageError = nil; self.retryCount = 0 }
                self.inFlight.removeAll(keepingCapacity: true)
                self.activeReceipt = nil
                if !self.pending.isEmpty && self.retryCount <= 3 { self.scheduleSave(after: self.retryCount == 0 ? 30 : Double(self.retryCount * 10)) }
            }
        }
    }
    func retrySave() {
        if store == nil {
            do {
                let restored = try AggregateStore(url: databaseURL)
                let start = Self.day(Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
                for row in try restored.query(since: start) {
                    if cached[row.id] == nil { cached[row.id] = row } else { cached[row.id]!.merge(row) }
                }
                store = restored; storageError = nil
            } catch { storageError = error.localizedDescription; return }
        }
        retryCount = 0; flush(); refreshSnapshot()
    }
    func flushBeforeExit() {
        stopUI(); saveWork?.cancel(); saveWork = nil; monitor.stop(); interruptEngine()
        if clearing { diskQueue.sync {}; return }
        // Serial ordering guarantees a previous in-flight transaction completes first.
        let rows = Array(pending.values), flightRows = Array(inFlight.values), receipt = activeReceipt, database = store
        diskQueue.sync {
            if let database {
                if receipt?.succeeded == false { try? database.save(flightRows) }
                try? database.save(rows)
            }
        }
        pending.removeAll()
    }
    func togglePause() {
        isPaused.toggle(); UserDefaults.standard.set(isPaused, forKey: "paused"); interruptEngine()
        if isPaused { estimatedRhythm.reset(); lastEstimatedInputTime = nil }
        if isPaused { monitor.stop(); status = "已暂停"; flush() } else if !sleeping { monitor.start(); status = "正在确认上下文" }
        refreshSnapshot()
    }
    func showStats() { openStats?() }
    func showSettings() { refreshInputLanguages(); openSettings?() }
    func setInterfaceLanguage(_ code: String) {
        let selected = code == "en" ? "en" : "zh-Hans"
        UserDefaults.standard.set(selected, forKey: "interfaceLanguage")
        interfaceLanguage = selected
        refreshInputLanguages()
        onInterfaceLanguageUpdate?()
        refreshSnapshot()
    }
    func setMonitorAllLanguages(_ enabled: Bool) {
        monitorAllLanguages = enabled
        saveLanguageSelection()
    }
    func setMonitoredLanguage(_ code: String, enabled: Bool) {
        var selected = Set(monitoredLanguages)
        if enabled { selected.insert(code) } else { selected.remove(code) }
        monitoredLanguages = selected.sorted()
        monitorAllLanguages = false
        saveLanguageSelection()
    }
    private func saveLanguageSelection() {
        if monitorAllLanguages { UserDefaults.standard.removeObject(forKey: "monitoredLanguages") }
        else { UserDefaults.standard.set(monitoredLanguages, forKey: "monitoredLanguages") }
        InputLanguages.reloadPolicy()
        interruptEngine()
        refreshInputLanguages()
        refreshSnapshot()
    }
    func refreshInputLanguages() {
        let codes = Set(InputLanguages.available().map(\.code)).union(monitoredLanguages)
        availableInputLanguages = codes.sorted().map { InputLanguageOption(id: $0, name: languageName($0)) }
        updateInputSource(InputLanguages.current)
    }
    /// Source identity includes the IME mode. Kept separate so isolated checks
    /// can exercise a language round trip without changing macOS or user prefs.
    fileprivate func updateInputSource(_ source: InputLanguages.Source) {
        if presentedInputSource != source {
            presentedInputSource = source
            interruptEngine()
        }
        currentInputLanguageCode = source.languageCode
        currentInputLanguage = "\(languageName(source.languageCode)) · \(source.name)"
    }
    func languageName(_ code: String) -> String {
        code == "und" ? L("未标注／未知语言") : (Locale(identifier: interfaceLanguage).localizedString(forLanguageCode: code) ?? code)
    }
    var historyLanguageOptions: [InputLanguageOption] {
        Set(history.map(\.language)).sorted().map { InputLanguageOption(id: $0, name: languageName($0)) }
    }
    func requestInputPermission() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func requestAccessibilityPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func refreshPermissions() {
        interruptEngine(); monitor.refreshPermissions()
        if !isPaused { monitor.stop(); monitor.start() }
        refreshSnapshot()
    }
    func updateExclusions() {
        let values = excludedAppsText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        ownedAdapterExcluded = values.contains(Bundle.main.bundleIdentifier ?? "local.benjamin.TypingSpeed")
        monitor.updateExcludedApps(Set(values))
    }
    func applySettings() {
        maximumGap = max(1, min(6, maximumGap))
        engine.updateConfig(SegmentationConfig(maximumGap: maximumGap, ruleID: Self.rule(maximumGap)))
        updateExclusions()
        monitor.diagnosticsEnabled = diagnosticsEnabled
        UserDefaults.standard.set(excludedAppsText, forKey: "excludedApps"); UserDefaults.standard.set(maximumGap, forKey: "maximumGap"); UserDefaults.standard.set(menuDisplay, forKey: "menuDisplay")
        if !diagnosticsEnabled { diagnostics.removeAll(); pendingDiagnostics.removeAll() }
        flush(); refreshSnapshot()
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { status = "请在系统设置的登录项中允许 Keytempo" }
        } catch { status = "登录项设置失败：\(error.localizedDescription)"; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    private func interruptEngine() {
        engine.interrupt()
        recentPresentationValid = false
        estimatedRhythmHasFreshInterval = false
        captureCompletion()
    }
    private func captureCompletion() {
        if let segment = engine.latestCompletedSegment, segment.revision != consumedCompletionRevision {
            consumedCompletionRevision = segment.revision
            let metric = CompletedMenuMetric(segment)
            // Short or uncovered segments keep the previous usable value.
            if metric.kpm != nil, completedKPMMetric != metric { completedKPMMetric = metric }
            if metric.primaryRate != nil, completedPrimaryMetric != metric { completedPrimaryMetric = metric }
        }
        if completionPending != engine.completionPending { completionPending = engine.completionPending }
    }
    private func scheduleUI() {
        guard uiTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSnapshot() } }
        timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); uiTimer = timer
    }
    private func stopUI() { uiTimer?.invalidate(); uiTimer = nil }
    func refreshSnapshot() {
        let now = ProcessInfo.processInfo.systemUptime
        let todayKey = Self.day()
        engine.advance(to: now)
        captureCompletion()
        let snap = engine.snapshot(now: now)
        if diagnosticsEnabled && !pendingDiagnostics.isEmpty {
            diagnostics = Array((diagnostics + pendingDiagnostics).suffix(60)); pendingDiagnostics.removeAll(keepingCapacity: true)
        }
        if phase != snap.phase.rawValue { phase = snap.phase.rawValue }
        if threshold != snap.threshold { threshold = snap.threshold }
        if modelMedian != (snap.median ?? 0) { modelMedian = snap.median ?? 0 }
        if modelMAD != (snap.mad ?? 0) { modelMAD = snap.mad ?? 0 }
        if modelSamples != snap.sampleCount { modelSamples = snap.sampleCount }
        if currentApp != monitor.currentAppName { currentApp = monitor.currentAppName }
        if contextDescription != monitor.contextSummary { contextDescription = monitor.contextSummary }
        if hasInputPermission != monitor.hasInputPermission { hasInputPermission = monitor.hasInputPermission }
        if hasAccessibilityPermission != monitor.hasAccessibilityPermission { hasAccessibilityPermission = monitor.hasAccessibilityPermission }
        func display(_ source: MetricSnapshot, evidence: String) -> MetricDisplay {
            let language = currentInputLanguageCode
            let today = cached.values.filter { $0.day == todayKey && $0.evidence == evidence && $0.language == language }
            let keys = today.reduce(0) { $0 + $1.keys }, edits = today.reduce(0) { $0 + $1.edits }, composition = today.reduce(0) { $0 + $1.composition }
            let intervals = today.reduce(0) { $0 + $1.intervals }, seconds = today.reduce(0) { $0 + $1.seconds }
            let newIntervals = today.reduce(0) { $0 + $1.newIntervals }, newSeconds = today.reduce(0) { $0 + $1.newSeconds }
            let characters = today.reduce(0) { $0 + $1.characters }
            let characterIntervals = today.reduce(0) { $0 + $1.characterIntervals }
            let characterSeconds = today.reduce(0) { $0 + $1.characterSeconds }
            let ratedCharacters = today.reduce(0) { $0 + $1.ratedCharacters }
            let mixed = Set(today.map(\.rule)).count > 1
            let sameLanguage = recentPresentationValid && recentEvidence.rawValue == evidence && source.recentLanguage == language
            return MetricDisplay(language: language, keys: keys, edits: edits, composition: composition, characters: characters,
                                 intervals: intervals, seconds: seconds,
                                 kpm: sameLanguage ? source.recentRhythmKPM : nil,
                                 todayKPM: !mixed && intervals >= 4 && seconds >= 0.5 ? 60 * intervals / seconds : nil,
                                 newKPM: !mixed && newIntervals >= 4 && newSeconds >= 0.5 ? 60 * newIntervals / newSeconds : nil,
                                 cpm: sameLanguage ? source.recentCharacterCPM : nil,
                                 todayCPM: !mixed && characterIntervals >= 4 && characterSeconds >= 0.5 && ratedCharacters > 0 ? 60 * ratedCharacters / characterSeconds : nil)
        }
        let c = display(snap.confirmed, evidence: "confirmed"), p = display(snap.probable, evidence: "probable")
        if c != confirmed { confirmed = c }; if p != probable { probable = p }
        let today = cached.values.filter { $0.day == todayKey }
        let estimatedToday = today.filter { $0.evidence == "probable" }
        let totalIntervals = estimatedToday.reduce(0.0) { $0 + $1.intervals }
        let totalSeconds = estimatedToday.reduce(0.0) { $0 + $1.seconds }
        let mixedEstimateRules = Set(estimatedToday.map(\.rule)).count > 1
        let recentEstimate = estimatedRhythmHasFreshInterval ? estimatedRhythm.kpm : nil
        if estimatedRecentKPM != recentEstimate { estimatedRecentKPM = recentEstimate }
        let combined = MetricDisplay(language: "und", keys: estimatedToday.reduce(0) { $0 + $1.keys },
                                     edits: estimatedToday.reduce(0) { $0 + $1.edits },
                                     composition: estimatedToday.reduce(0) { $0 + $1.composition },
                                     intervals: totalIntervals, seconds: totalSeconds,
                                     kpm: recentEstimate,
                                     todayKPM: !mixedEstimateRules && totalIntervals >= 4 && totalSeconds >= 0.5 ? 60 * totalIntervals / totalSeconds : nil)
        if dailyEstimate != combined { dailyEstimate = combined }
        let english = today.reduce(0) { $0 + $1.english }, chinese = today.reduce(0) { $0 + $1.chinese }
        if english != commitsEnglish { commitsEnglish = english }; if chinese != commitsChinese { commitsChinese = chinese }
        let localPath = !ownedAdapterExcluded && recentEvidence == .confirmed && NSApp.isActive && (NSApp.keyWindow?.firstResponder is ConfirmedTextView)
        let unavailable = ["权限", "安全输入", "无法", "中断", "排除", "未知"].contains { monitor.status.contains($0) }
        let nextStatus: String
        if isPaused { nextStatus = "已暂停" }
        else if ownedAdapterExcluded && NSApp.isActive { nextStatus = "本应用已排除" }
        else if !InputLanguages.allowsCurrent {
            nextStatus = !monitorAllLanguages && monitoredLanguages.isEmpty ? "未选择任何语言，统计已停止" : "输入源语言已排除"
        }
        else if !localPath && (!hasInputPermission || !hasAccessibilityPermission) { nextStatus = "权限不可用 · 全局估算已停止" }
        else if unavailable && !localPath { nextStatus = monitor.status }
        else if phase == "idle" { nextStatus = "已停止／未观察到输入 · 最近节奏已冻结" }
        else if phase == "typing" { nextStatus = "正在统计 · \(localPath ? "已确认" : "估算")输入段" }
        else { nextStatus = "候选输入段 · 数据不足" }
        if status != nextStatus { status = nextStatus }
        onMenuUpdate?()
        if snap.phase == .idle && !engine.completionPending { stopUI() }
    }
    /// Explicit range/view requests only; a typing UI tick never queries disk
    /// or re-aggregates the long-term history graph.
    func loadHistory(days: Int) {
        let selected = [7, 30, 90, 365, 1826].contains(days) ? days : 7
        historyDays = selected
        let range: HistoryDateRange
        if selected == 1826 { range = .years(5, endingOn: Date(), timeZone: .current) }
        else if selected == 365 { range = .years(1, endingOn: Date(), timeZone: .current) }
        else { range = .days(selected, endingOn: Date(), timeZone: .current) }
        let selection = HistorySelection(days: selected, startDay: range.startDay, endDay: range.endDay)
        historySelection = selection
        historyStartDay = selection.startDay; historyEndDay = selection.endDay
        historyError = nil
        refreshLoadedHistory()
        guard !clearing, store != nil else { historyLoading = false; return }
        // Reopening the same range while its read is still in flight reuses
        // that read and cancels an intervening pending range request.
        if let active = activeHistoryRead, active.generation == generation, active.selection == selection {
            pendingHistoryRead = nil; historyLoading = true; return
        }
        if let pending = pendingHistoryRead, pending.generation == generation, pending.selection == selection {
            historyLoading = true; return
        }
        historyReadToken &+= 1
        pendingHistoryRead = HistoryReadRequest(token: historyReadToken, generation: generation, selection: selection)
        historyLoading = true
        startHistoryRead()
    }
    func refreshHistoryIfVisible() {
        guard statisticsVisible && historyVisible else { return }
        loadHistory(days: historyDays)
    }
    func releaseHistory() {
        historyVisible = false
        invalidateHistoryReads(clearRows: true)
    }
    private func startHistoryRead() {
        guard !clearing, activeHistoryRead == nil, let request = pendingHistoryRead, let store else { return }
        pendingHistoryRead = nil
        activeHistoryRead = request
        diskQueue.async { [weak self] in
            let result = Result { try store.query(since: request.selection.startDay, until: request.selection.endDay) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeHistoryRead?.token == request.token else { return }
                self.activeHistoryRead = nil
                if !self.clearing && self.generation == request.generation && self.historySelection == request.selection {
                    switch result {
                    case let .success(rows):
                        self.loadedHistoryRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                        // cached rows are complete recent totals including any
                        // pending/in-flight writes; replace, never add twice.
                        self.refreshLoadedHistory()
                        self.historyError = nil
                    case let .failure(error): self.historyError = error.localizedDescription
                    }
                }
                if self.pendingHistoryRead != nil { self.startHistoryRead() }
                self.historyLoading = self.activeHistoryRead != nil || self.pendingHistoryRead != nil
            }
        }
    }
    private func refreshLoadedHistory() {
        guard let selection = historySelection else { return }
        var rows = loadedHistoryRows.filter { $0.value.day >= selection.startDay && $0.value.day <= selection.endDay }
        for row in cached.values where row.day >= selection.startDay && row.day <= selection.endDay { rows[row.id] = row }
        publishHistory(rows: Array(rows.values), selection: selection)
    }
    private func publishHistory(rows: [StoredAggregate], selection: HistorySelection) {
        let input = rows.map { row in
            HistoryMetricRow(day: row.day, language: row.language,
                             evidence: Evidence(rawValue: row.evidence) ?? .unknown,
                             rule: row.rule, timezone: row.timezone,
                             keys: row.keys, edits: row.edits, composition: row.composition,
                             characters: row.characters, intervals: row.intervals, seconds: row.seconds,
                             ratedCharacters: row.ratedCharacters, characterIntervals: row.characterIntervals,
                             characterSeconds: row.characterSeconds)
        }
        let buckets = HistoryAggregation.aggregate(input, granularity: historyGranularity, timeZone: .current,
                                                   startDay: selection.startDay, endDay: selection.endDay)
        let grouped = Dictionary(grouping: buckets, by: { $0.periodStart + "|" + $0.language })
        history = grouped.keys.sorted().compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let confirmed = group.first { $0.evidence == .confirmed }
            let estimated = group.first { $0.evidence == .probable }
            let rules = Set(group.flatMap(\.rules))
            let mixed = rules.count > 1
            return HistoryDay(day: first.periodStart, periodEnd: group.map(\.periodEnd).max() ?? first.periodEnd,
                              language: first.language, keys: confirmed?.keys ?? 0, estimatedKeys: estimated?.keys ?? 0,
                              edits: group.reduce(0) { $0 + $1.edits }, characters: confirmed?.characters ?? 0,
                              seconds: confirmed?.seconds ?? 0, estimatedSeconds: estimated?.seconds ?? 0,
                              intervals: confirmed?.intervals ?? 0, estimatedIntervals: estimated?.intervals ?? 0,
                              kpm: mixed ? nil : confirmed?.kpm, estimatedKPM: mixed ? nil : estimated?.kpm,
                              cpm: mixed ? nil : confirmed?.cpm, rules: rules.sorted().joined(separator: "; "),
                              rejectedRows: group.reduce(0) { $0 + $1.rejectedRows })
        }
    }
    private func invalidateHistoryReads(clearRows: Bool) {
        historyReadToken &+= 1
        historySelection = nil; pendingHistoryRead = nil
        historyLoading = false; historyError = nil
        if clearRows { loadedHistoryRows.removeAll(); history.removeAll() }
        // An existing disk read may finish, but its selection/generation can
        // no longer publish. Its completion releases the one in-flight slot.
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Keytempo-\(Self.day()).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        let recentSnapshot = Array(cached.values)
        flush()
        diskQueue.async {
            do {
                var merged = Dictionary(uniqueKeysWithValues: try store.query(since: "0000-01-01").map { ($0.id, $0) })
                // Cache contains complete recent aggregates, including any failed in-flight save.
                for row in recentSnapshot { merged[row.id] = row }
                try AggregateStore.csv(merged.values.sorted { $0.id < $1.id }).write(to: url, atomically: true, encoding: .utf8)
            } catch { DispatchQueue.main.async { self.storageError = "导出失败：\(error.localizedDescription)" } }
        }
    }
    /// Caller presents the destructive confirmation in SettingsView.
    func clearHistory() {
        guard let store else { return }
        clearing = true; saveWork?.cancel(); saveWork = nil; interruptEngine()
        invalidateHistoryReads(clearRows: false)
        diskQueue.async {
            let result = Result { try store.clear() }
            DispatchQueue.main.async {
                if case let .failure(error) = result { self.storageError = error.localizedDescription }
                else {
                    self.generation &+= 1; self.saveWork?.cancel(); self.saveWork = nil
                    self.pending.removeAll(); self.inFlight.removeAll()
                    self.cached.removeAll()
                    self.invalidateHistoryReads(clearRows: true)
                    self.completedPrimaryMetric = nil; self.completedKPMMetric = nil
                    self.consumedCompletionRevision = 0; self.completionPending = false
                    self.estimatedRhythm.reset(); self.lastEstimatedInputTime = nil; self.estimatedRhythmHasFreshInterval = false
                    self.estimatedRecentKPM = nil
                    self.engine = StatisticsEngine(config: SegmentationConfig(maximumGap: self.maximumGap, ruleID: Self.rule(self.maximumGap)), timeZone: .current)
                }
                self.clearing = false; self.refreshSnapshot(); self.loadHistory(days: self.historyDays)
            }
        }
    }
}

/// Isolated integration test of coordinator → core → SQLite → restart. No global capture.
@MainActor func runAppModelChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-model-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var failures: [String] = []
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false
    model.excludedAppsText = ""; model.updateExclusions()
    let now = ProcessInfo.processInfo.systemUptime, date = Date()
    let language = InputLanguages.current.languageCode
    for offset in [0.0, 0.2, 0.4, 0.6, 0.8, 10.0, 10.2, 10.4] {
        model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: 99, category: .textEntry, evidence: .confirmed, source: .adapter, language: language, committedCharacters: 1))
    }
    model.refreshSnapshot()
    if model.confirmed.keys != 8 || abs(model.confirmed.intervals - 6) > 1e-6 || abs(model.confirmed.seconds - 1.2) > 1e-6 {
        failures.append("FAIL: coordinator interval/count aggregation")
    }
    if model.confirmed.characters != 8 || abs((model.confirmed.todayCPM ?? 0) - 300) > 1e-4 {
        failures.append("FAIL: coordinator character coverage/rate aggregation")
    }
    let lastCompleted = model.completedKPMMetric
    if abs((lastCompleted?.kpm ?? 0) - 300) > 1e-4 || !model.completionPending {
        failures.append("FAIL: completed menu did not retain first burst during unfinished input")
    }
    model.interruptConfirmed()
    if model.completedKPMMetric != lastCompleted || model.completionPending {
        failures.append("FAIL: insufficient completed burst erased previous menu rate")
    }
    model.receiveCommit(english: 6, chinese: 2, language: language)
    model.flushBeforeExit()
    let restored = AppModel(dataDirectory: directory, monitoringEnabled: false)
    if restored.confirmed.keys != 8 || abs(restored.confirmed.seconds - 1.2) > 1e-6 || restored.commitsEnglish != 6 || restored.commitsChinese != 2 || restored.confirmed.characters != 8 {
        failures.append("FAIL: coordinator restart restoration")
    }
    if restored.confirmed.kpm != nil || restored.completedPrimaryMetric != nil || restored.completedKPMMetric != nil {
        failures.append("FAIL: restart reused a previous live/completed segment")
    }
    restored.isPaused = false
    restored.excludedAppsText = Bundle.main.bundleIdentifier ?? "local.benjamin.TypingSpeed"
    restored.updateExclusions()
    restored.receiveConfirmedInput(ClassifiedInput(time: now + 15, date: date.addingTimeInterval(15), context: 99, category: .textEntry, evidence: .confirmed, source: .adapter, language: language, committedCharacters: 1))
    restored.receiveCommit(english: 1, chinese: 1, language: language)
    restored.refreshSnapshot()
    if restored.confirmed.keys != 8 || restored.commitsEnglish != 6 || restored.commitsChinese != 2 { failures.append("FAIL: owned adapter bypassed app exclusion") }
    restored.excludedAppsText = ""; restored.updateExclusions()
    let otherLanguage = language == "zh" ? "en" : "zh"
    for (index, offset) in [20.0, 20.2, 20.4, 20.6, 20.8].enumerated() {
        restored.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: 99,
                                                       category: .composition, evidence: .confirmed, source: .adapter,
                                                       language: otherLanguage, committedCharacters: index == 4 ? 2 : 0))
    }
    restored.refreshSnapshot(); restored.loadHistory(days: 7)
    let populated = restored.history.filter { $0.keys > 0 }
    if populated.count != 2 || Set(populated.map(\.language)) != Set([language, otherLanguage]) || populated.first(where: { $0.language == otherLanguage })?.characters != 2 {
        failures.append("FAIL: per-language history separation")
    }
    if let row = populated.first(where: { $0.language == otherLanguage }), abs((row.cpm ?? 0) - 150) > 1e-3 {
        failures.append("FAIL: history CPM used keystroke count instead of whole character batch")
    }
    restored.interruptConfirmed()
    let completedOtherLanguage = restored.completedPrimaryMetric
    if completedOtherLanguage?.language != otherLanguage || abs((restored.completedKPMMetric?.kpm ?? 0) - 300) > 1e-3 {
        failures.append("FAIL: completed menu language/rate metadata")
    }
    restored.clearHistory()
    restored.flushBeforeExit()
    do {
        let database = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
        if !(try database.query(since: "0000")).isEmpty { failures.append("FAIL: quit resurrected data during clear") }
    } catch { failures.append("FAIL: clear/quit regression: \(error.localizedDescription)") }
    failures += runCurrentMenuChecks()
    failures += runCombinedEstimateChecks()
    failures += runHistoryProjectionChecks()
    return failures
}

/// Presentation regressions use an isolated database and synthetic classified
/// metadata. They do not post events, switch the system source or write prefs.
@MainActor private func runCurrentMenuChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-menu-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false; model.menuDisplay = "speed"
    model.excludedAppsText = ""; model.updateExclusions()
    let english = InputLanguages.Source(identifier: "test.abc", modeIdentifier: "", name: "ABC", languageCode: "en", inputMethod: false)
    let chinese = InputLanguages.Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
    var failures: [String] = []
    let now = ProcessInfo.processInfo.systemUptime, date = Date()
    func type(_ offsets: [Double], language: String, characters: Int? = nil, evidence: Evidence = .confirmed) {
        for offset in offsets {
            model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: 881,
                                                       category: .textEntry, evidence: evidence,
                                                       source: evidence == .confirmed ? .adapter : .global,
                                                       operationID: UInt64((offset * 1000).rounded()),
                                                       language: language, committedCharacters: characters))
        }
        model.refreshSnapshot()
    }
    model.updateInputSource(english); model.refreshSnapshot()
    type([0, 0.2, 0.4, 0.6, 0.8], language: "en", characters: 1)
    if model.completedPrimaryMetric != nil || abs((model.selectedMenuMetric.primaryRate ?? 0) - 60) > 1e-3 || model.selectedMenuMetric.primaryUnit != .wpm {
        failures.append("FAIL: current menu waits for a completed burst instead of showing live WPM")
    }
    model.updateInputSource(chinese); model.refreshSnapshot()
    if model.selectedMenuMetric.primaryUnit != .cpm || model.selectedMenuMetric.primaryRate != nil || model.selectedMenuMetric.kpm != nil {
        failures.append("FAIL: source change retained an English rate/unit under Chinese")
    }
    model.updateInputSource(english); model.refreshSnapshot()
    if model.selectedMenuMetric.primaryUnit != .wpm || model.selectedMenuMetric.primaryRate != nil || model.selectedMenuMetric.kpm != nil {
        failures.append("FAIL: switching back revived the previous source's old live rate")
    }
    type([0.8], language: "en", characters: 1)
    if model.selectedMenuMetric.primaryRate != nil { failures.append("FAIL: duplicate operation revived a stale rate after a source change") }
    type([10], language: "en", characters: 1)
    if model.selectedMenuMetric.primaryRate != nil { failures.append("FAIL: first event reused an old live speed") }
    type([10.2, 10.4, 10.6, 10.8], language: "en", characters: 1)
    if abs((model.selectedMenuMetric.primaryRate ?? 0) - 60) > 1e-3 { failures.append("FAIL: current WPM did not resume with a fresh sample") }
    model.updateInputSource(chinese); model.refreshSnapshot()
    type([20, 20.2, 20.4, 20.6, 20.8], language: "zh", evidence: .probable)
    if model.selectedMenuMetric.primaryUnit != .cpm || model.selectedMenuMetric.primaryRate != nil || abs((model.selectedMenuMetric.kpm ?? 0) - 300) > 1e-3 {
        failures.append("FAIL: global Chinese lost observed keystroke rhythm or fabricated CPM")
    }
    if model.selectedMenuSpeed.unit != "WPM" || !model.selectedMenuSpeed.estimated || abs((model.selectedMenuSpeed.value ?? 0) - 60) > 1e-3 || model.probable.cpm != nil {
        failures.append("FAIL: global Chinese did not show estimated WPM without inventing character output")
    }
    model.updateInputSource(english); model.refreshSnapshot()
    if model.selectedMenuSpeed.unit != "WPM" || model.selectedMenuSpeed.value != nil {
        failures.append("FAIL: language switch reused Chinese estimated WPM before new intervals")
    }
    model.updateInputSource(chinese); model.refreshSnapshot()
    if model.selectedMenuSpeed.value != nil {
        failures.append("FAIL: switching back revived a stale estimated WPM")
    }
    model.interruptConfirmed()
    type([30, 30.2, 30.4, 30.6, 30.8], language: "zh", characters: 1)
    if model.selectedMenuMetric.primaryUnit != .cpm || abs((model.selectedMenuMetric.primaryRate ?? 0) - 300) > 1e-3 {
        failures.append("FAIL: confirmed Chinese did not show current CPM")
    }
    if model.selectedMenuSpeed.unit != "CPM" || model.selectedMenuSpeed.estimated || abs((model.selectedMenuSpeed.value ?? 0) - 300) > 1e-3 {
        failures.append("FAIL: confirmed Chinese character rate was replaced by estimated WPM")
    }
    var alternateMode = chinese; alternateMode.modeIdentifier = "latin"
    model.updateInputSource(alternateMode); model.refreshSnapshot()
    if model.selectedMenuMetric.primaryRate != nil || model.selectedMenuMetric.kpm != nil {
        failures.append("FAIL: same-language IME mode change retained a previous mode's live rate")
    }
    model.flushBeforeExit()
    return failures
}

/// Daily quantities and recent KPM combine accepted probable intervals across
/// sources, while WPM/CPM retain the current language and evidence contract.
@MainActor private func runCombinedEstimateChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-combined-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false; model.menuDisplay = "kpm"
    model.excludedAppsText = ""; model.updateExclusions()
    let english = InputLanguages.Source(identifier: "test.abc", modeIdentifier: "", name: "ABC", languageCode: "en", inputMethod: false)
    let chinese = InputLanguages.Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
    let now = ProcessInfo.processInfo.systemUptime, date = Date()
    var failures = [String]()
    func type(_ times: [Double], language: String, evidence: Evidence = .probable) {
        for time in times {
            model.receiveConfirmedInput(ClassifiedInput(time: now + time, date: date.addingTimeInterval(time), context: 771,
                                                       category: .textEntry, evidence: evidence,
                                                       source: evidence == .probable ? .global : .adapter,
                                                       operationID: UInt64((time * 1000).rounded()),
                                                       language: language, committedCharacters: evidence == .confirmed ? 1 : nil))
        }
        model.refreshSnapshot()
    }
    model.updateInputSource(english)
    type([0, 0.1, 0.2, 0.3, 0.4], language: "en")
    if model.dailyEstimate.keys != 5 || model.estimatedRecentKPM != nil {
        failures.append("FAIL: combined estimate initial count or minimum time")
    }
    model.updateInputSource(chinese); model.refreshSnapshot()
    type([10], language: "zh")
    if model.estimatedRecentKPM != nil { failures.append("FAIL: first key after source change revived a previous interval window") }
    type([10.5, 11, 11.5, 12], language: "zh")
    if model.dailyEstimate.keys != 10 || model.probable.keys != 5 || abs((model.dailyEstimate.todayKPM ?? 0) - 200) > 1e-3 || abs((model.estimatedRecentKPM ?? 0) - 200) > 1e-3 {
        failures.append("FAIL: English and Chinese counts/KPM were not combined with interval weighting")
    }
    if abs((model.selectedMenuMetric.kpm ?? 0) - 200) > 1e-3 {
        failures.append("FAIL: KPM menu did not use the combined global estimate")
    }
    model.menuDisplay = "speed"
    if model.selectedMenuMetric.primaryUnit != .cpm || model.selectedMenuMetric.primaryRate != nil {
        failures.append("FAIL: combined KPM leaked into Chinese primary CPM")
    }
    if model.selectedMenuSpeed.unit != "WPM" || abs((model.selectedMenuSpeed.value ?? 0) - 24) > 1e-3 {
        failures.append("FAIL: Chinese WPM used mixed-language KPM instead of the current language's rhythm")
    }
    model.updateInputSource(english); model.refreshSnapshot()
    type([20], language: "en")
    if model.estimatedRecentKPM != nil { failures.append("FAIL: combined KPM appeared without a fresh accepted interval") }
    type([20.2, 20.4, 20.6, 20.8], language: "en")
    if model.dailyEstimate.keys != 15 || model.probable.keys != 10 || abs((model.estimatedRecentKPM ?? 0) - 225) > 1e-3 || abs((model.selectedMenuMetric.primaryRate ?? 0) - 60) > 1e-3 {
        failures.append("FAIL: mixed-language KPM changed current-language WPM or lost prior interval batches")
    }
    model.interruptConfirmed()
    type([30, 30.2, 30.4, 30.6, 30.8], language: "en", evidence: .confirmed)
    if model.dailyEstimate.keys != 15 || abs((model.dailyEstimate.todayKPM ?? 0) - 225) > 1e-3 || model.estimatedRecentKPM != nil {
        failures.append("FAIL: confirmed validation events contaminated global estimate counts or recent KPM")
    }
    type([40, 40.5, 41, 41.5, 42], language: "en")
    let beforeIdle = model.estimatedRecentKPM
    model.refreshSnapshot()
    if model.estimatedRecentKPM != beforeIdle { failures.append("FAIL: idle refresh changed the measured KPM") }
    type([100], language: "en")
    if model.estimatedRecentKPM != nil { failures.append("FAIL: first key after long idle inherited an old rhythm") }
    type([100.5, 101, 101.5, 102], language: "en")
    if abs((model.estimatedRecentKPM ?? 0) - 120) > 1e-3 { failures.append("FAIL: long-idle reset blended an older rhythm into the new burst") }
    type([90], language: "en")
    if model.estimatedRecentKPM != nil { failures.append("FAIL: a backwards event timestamp retained an old rhythm") }
    model.flushBeforeExit()
    return failures
}

/// Store → recent cache → monthly presentation stays synchronous for the first
/// frame; the complete older range is subsequently read on the utility queue.
@MainActor private func runHistoryProjectionChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-history-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
    let first: Date
    let second: Date
    if calendar.component(.day, from: today) >= 2 {
        first = calendar.dateInterval(of: .month, for: today)!.start
        second = calendar.date(byAdding: .day, value: 1, to: first)!
    } else {
        first = calendar.date(byAdding: .day, value: -2, to: today)!
        second = calendar.date(byAdding: .day, value: -1, to: today)!
    }
    do {
        let database = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
        var fast = StoredAggregate(day: AppModel.day(first), timezone: TimeZone.current.identifier, rule: "history-test", evidence: "probable", language: "en")
        fast.keys = 5; fast.intervals = 4; fast.seconds = 0.4
        var slow = fast; slow.day = AppModel.day(second); slow.seconds = 2
        var chinese = StoredAggregate(day: AppModel.day(second), timezone: TimeZone.current.identifier, rule: "history-test", evidence: "confirmed", language: "zh")
        chinese.keys = 5; chinese.intervals = 4; chinese.seconds = 0.8
        chinese.characters = 2; chinese.ratedCharacters = 2; chinese.characterIntervals = 4; chinese.characterSeconds = 0.8
        try database.save([fast, slow, chinese])
        let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
        model.loadHistory(days: 1826)
        var failures = [String]()
        let english = model.history.first { $0.language == "en" }
        let chineseRow = model.history.first { $0.language == "zh" }
        if model.historyGranularity != .month || model.history.count != 2 || english?.estimatedKeys != 10 || abs((english?.estimatedKPM ?? 0) - 200) > 1e-6 || abs((english?.estimatedPrimaryRate ?? 0) - 40) > 1e-6 {
            failures.append("FAIL: monthly history projection lost language/counts or averaged daily rates")
        }
        if chineseRow?.characters != 2 || abs((chineseRow?.cpm ?? 0) - 150) > 1e-6 {
            failures.append("FAIL: monthly history projection lost confirmed character coverage")
        }
        let range = HistoryDateRange.years(5, endingOn: today, timeZone: .current)
        if model.historyStartDay != range.startDay || model.historyEndDay != range.endDay || model.history.contains(where: { $0.periodEnd.isEmpty }) {
            failures.append("FAIL: history projection lost calendar range or bucket endpoints")
        }
        model.flushBeforeExit()
        return failures
    } catch { return ["FAIL: isolated history projection: \(error.localizedDescription)"] }
}
