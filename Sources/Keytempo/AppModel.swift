import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import TypingCore
import TypingStore

// Read/written only on diskQueue; retained by the main actor until completion.
private final class WriteReceipt: @unchecked Sendable { var succeeded: Bool? }
private enum RewardFeedbackEvent { case level(Int, Int), improvement(Int) }

/// One immutable checkpoint transaction. Retry it before newer work so a
/// failed callback can never combine old deltas under a fresh batch identity.
private struct MeasurementWrite: Sendable {
    let id: String
    let rows: [StoredAggregate]
    var activity: ActivityBatch
    let rewards: RewardWrite?
    var dailyRewards: DailyRewardWrite? = nil
}

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
    var primaryUnit: PrimaryTypingUnit { language == "mul" ? .wpm : TypingRate.primaryUnit(forLanguage: language) }
    var primaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: kpm); case .cpm: return cpm; case .unknown: return nil }
    }
    var todayPrimaryRate: Double? {
        switch primaryUnit { case .wpm: return TypingRate.estimatedWPM(fromKPM: todayKPM); case .cpm: return todayCPM; case .unknown: return nil }
    }
}

/// Global estimates and the menu's primary mode use five-operation WPM for every
/// language. Confirmed statistics retain their measured character-rate default.
struct MenuSpeedDisplay: Equatable {
    let value: Double?
    let unit: String
    let estimated: Bool
    let isCharacterFallback: Bool

    init(metric: MetricDisplay, evidence: Evidence, forceKPM: Bool = false, forceEstimatedWPM: Bool = false) {
        isCharacterFallback = !forceKPM && (forceEstimatedWPM || evidence == .probable) && metric.primaryUnit == .cpm
        if forceKPM {
            value = metric.kpm; unit = "KPM"; estimated = true
        } else if forceEstimatedWPM || evidence == .probable {
            value = metric.estimatedWPM; unit = "WPM"; estimated = true
        } else {
            value = metric.primaryRate; unit = metric.primaryUnit.rawValue
            estimated = metric.primaryUnit == .wpm
        }
    }
}

enum HybridMenuDisplay: Equatable {
    case wpm(Double?)
    case count
}

/// Display activity is independent of statistical segmentation. Only accepted
/// interval batches supply rates; context/source boundaries never create time.
private struct HybridMenuActivity {
    private var lastInputTime: Double?
    private var evidence: Evidence?
    private var rhythm = RecentIntervalRhythm()
    static let stoppedPlaceholderSeconds = 3.0

    mutating func record(time: Double, evidence: Evidence, intervals: Double, seconds: Double, idleGrace: Double) {
        guard time.isFinite else { return }
        if self.evidence != evidence || (lastInputTime.map({ time < $0 || time >= $0 + idleGrace }) ?? true) {
            reset()
        }
        self.evidence = evidence; lastInputTime = time
        rhythm.record(intervals: intervals, seconds: seconds)
    }
    func display(at now: Double, idleGrace: Double) -> HybridMenuDisplay {
        guard now.isFinite, let lastInputTime else { return .count }
        let stoppedAt = lastInputTime + idleGrace
        let countAt = stoppedAt + Self.stoppedPlaceholderSeconds
        if now < stoppedAt { return .wpm(TypingRate.estimatedWPM(fromKPM: rhythm.kpm)) }
        if now < countAt { return .wpm(nil) }
        return .count
    }
    func needsRefresh(at now: Double, idleGrace: Double) -> Bool {
        display(at: now, idleGrace: idleGrace) != .count
    }
    mutating func reset() {
        lastInputTime = nil; evidence = nil; rhythm.reset()
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
    var primaryUnit: PrimaryTypingUnit { language == "mul" ? .wpm : TypingRate.primaryUnit(forLanguage: language) }
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
    @Published private(set) var tenMinuteWPM: Double?
    @Published private(set) var tenMinuteKPM: Double?
    @Published private(set) var tenMinuteWindowComplete = true
    @Published private(set) var tenMinuteObservedSeconds = 0.0
    @Published private(set) var todayAverageWPM: Double?
    @Published private(set) var todayAverageIsPartial = false
    @Published private(set) var todayAverageCoveredKeys = 0
    @Published private(set) var activityHourly: [HourlyActivity] = []
    @Published private(set) var activitySessions: [TypingSession] = []
    @Published private(set) var activityScoreDays: [ActivityScoreDay] = []
    @Published private(set) var activityLoading = false
    @Published private(set) var activityError: String?
    @Published private(set) var activityActionError: String?
    @Published private(set) var activityCoverageStart: Date?
    @Published private(set) var rewardState: RewardState?
    @Published private(set) var rewardDays: [StoredRewardDay] = []
    @Published private(set) var rewardAwards: [RewardAward] = []
    @Published private var rewardFeedbackEvent: RewardFeedbackEvent?
    var rewardFeedback: String? {
        switch rewardFeedbackEvent {
        case .level(let level, let gain): return L("达到等级 %@（提升 %@ 级）", level.formatted(), gain.formatted())
        case .improvement(let xp): return L("进步已验证：+%@ XP", xp.formatted())
        case nil: return nil
        }
    }
    @Published private(set) var rewardError: String?
    @Published private(set) var dailyRewardState: DailyRewardState?
    @Published private(set) var dailySettlements: [DailySettlementReceipt] = []
    @Published private(set) var dailyRewardError: String?
    @Published private(set) var settlementReceipt: DailySettlementReceipt?
    @Published private(set) var settlementQueuePosition = 1
    @Published private(set) var settlementQueueCount = 0
    @Published private(set) var settlementAcknowledging = false
    var onSettlementAvailable: (() -> Void)?
    @Published var activityDate = Date()
    @Published private(set) var perAppTrackingEnabled = UserDefaults.standard.bool(forKey: "perAppTrackingEnabled")
    var activityVisible = false
    var activityCurrentRule: String { engine.config.ruleID }
    @Published private(set) var completedPrimaryMetric: CompletedMenuMetric?
    @Published private(set) var completedKPMMetric: CompletedMenuMetric?
    @Published private(set) var completionPending = false
    var selectedCompletedMetric: CompletedMenuMetric? { menuDisplay == "kpm" ? completedKPMMetric : completedPrimaryMetric }
    /// Global primary speed and optional KPM share the combined accepted-input
    /// rhythm. The local validation lane keeps its separate measured metadata.
    var selectedMenuMetric: MetricDisplay {
        if menuDisplay == "kpm" {
            return MetricDisplay(language: "und", kpm: estimatedRhythmHasFreshInterval ? estimatedRecentKPM : nil)
        }
        var metric = recentEvidence == .confirmed ? confirmed : probable
        if recentEvidence == .confirmed { metric.language = currentInputLanguageCode }
        if !recentPresentationValid { metric.kpm = nil; metric.cpm = nil }
        return metric
    }
    var selectedMenuSpeed: MenuSpeedDisplay {
        MenuSpeedDisplay(metric: selectedMenuMetric, evidence: recentEvidence,
                         forceKPM: menuDisplay == "kpm", forceEstimatedWPM: true)
    }
    /// A short no-input grace avoids reacting to candidate/context transients.
    /// Once fully stopped, show an empty WPM label for three seconds, then count.
    var hybridMenuDisplay: HybridMenuDisplay {
        let contextAvailable = recentEvidence == .confirmed
            ? !ownedAdapterExcluded && NSApp.isActive && (NSApp.keyWindow?.firstResponder is ConfirmedTextView)
            : globalPresentationCapabilitiesAvailable
        return hybridMenuDisplayIfAvailable(at: ProcessInfo.processInfo.systemUptime, capabilitiesAvailable: contextAvailable)
    }
    /// Scripted time/capability inputs avoid real waits or TCC dependencies in
    /// native checks. Classification phase does not decide the display mode.
    fileprivate func hybridMenuDisplayIfAvailable(at now: Double, capabilitiesAvailable: Bool) -> HybridMenuDisplay {
        guard capabilitiesAvailable, !isPaused, !sleeping, !clearing else { return .count }
        return hybridActivity.display(at: now, idleGrace: hybridIdleGrace)
    }
    fileprivate var hybridIdleGrace: Double { engine.config.maximumGap }
    fileprivate var isUIRefreshScheduled: Bool { uiTimer != nil }
    fileprivate func hybridMenuNeedsUI(at now: Double) -> Bool {
        menuDisplay == "hybrid" && !isPaused && !sleeping && !clearing &&
            hybridActivity.needsRefresh(at: now, idleGrace: hybridIdleGrace)
    }
    @Published private(set) var recentSpeedIsFrozen = false
    var selectedSpeedIsRecent: Bool {
        selectedMenuSpeed.value != nil && (recentSpeedIsFrozen || phase == "idle")
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
    @Published var menuDisplay = UserDefaults.standard.string(forKey: "menuDisplay") ?? "hybrid"
    @Published var diagnosticsEnabled = false
    @Published var suspectedInputFilteringEnabled = UserDefaults.standard.object(forKey: "suspectedInputFilteringEnabled") as? Bool ?? true
    // Preserve the saved opt-in from the original Chinese-only compatibility mode.
    @Published var globalKeyboardCompatibilityEnabled = UserDefaults.standard.bool(forKey: "chineseKeyboardCompatibilityEnabled")
    @Published private(set) var suspiciousRepeatEvents: UInt64 = 0
    @Published private(set) var suspiciousBurstEvents: UInt64 = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var storageError: String?
    @Published var interfaceLanguage = UserDefaults.standard.string(forKey: "interfaceLanguage") == "en" ? "en" : "zh-Hans"
    @Published private(set) var currentInputLanguage = ""
    @Published private(set) var currentInputLanguageCode = "und"
    @Published var diagnostics: [String] = []
    @Published var commitsEnglish = 0
    @Published var commitsChinese = 0
    private(set) var recentEvidence: Evidence = .probable
    @Published private(set) var appearanceMode = "system"
    @Published private(set) var appearanceTheme = "classic"
    @Published private(set) var menuBarStyle = "keyboard"
    @Published private(set) var menuIconMotionEnabled = true
    @Published private(set) var menuIconLowWPM: Double = 20
    @Published private(set) var menuIconHighWPM: Double = 120
    @Published var menuEffectPreviewWPM: Double?
    var menuIconSpeedRange: MenuIconSpeedRange {
        MenuIconSpeedRange(lowWPM: menuIconLowWPM, highWPM: menuIconHighWPM) ?? .default
    }
    @Published var statisticsPage = "today"
    private let appearanceStorage: UserDefaults?
    var onAppearanceUpdate: (() -> Void)?
    var onMenuEffectPreview: (() -> Void)?
    var appearanceLevel: Int { DailyLevelProgress(totalXP: dailyRewardState?.totalXP ?? 0)?.level ?? 1 }
    var effectiveAppearanceTheme: String { AppearancePolicy.effective(appearanceTheme, choice: .theme, level: appearanceLevel) }
    var effectiveMenuBarStyle: String { AppearancePolicy.effective(menuBarStyle, choice: .icon, level: appearanceLevel) }
    var appearanceMenuWPM: Double? {
        guard !isPaused, hasInputPermission, !selectedSpeedIsRecent, phase != "idle" else { return nil }
        let speed = selectedMenuSpeed
        if speed.unit == "WPM" { return speed.value }
        if speed.unit == "KPM" { return speed.value.map { $0 / 5 } }
        return nil
    }
    var onMenuUpdate: (() -> Void)?
    private(set) var menuSnapshotUptime: TimeInterval = 0
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
    private var inFlightWrite: MeasurementWrite?
    private var retryWrite: MeasurementWrite?
    private var rewardEngine: RewardEngine?
    private var dailyRewardEngine: DailyRewardEngine?
    private var loadedDailySettlements: [DailySettlementReceipt] = []
    private var dailyReadOverlay: [String: DailySettlementReceipt] = [:]
    private var dailyExportURL: URL?
    private var dailyExportRevision: Int64?
    private var durableDailyRevision: Int64 = 0
    private var settlementRequestVersion: UInt64 = 0
    private var dailyRewardsNeedSave: Bool { dailyRewardEngine?.error == nil && dailyRewardEngine?.hasPendingChanges == true }
    private var midnightWork: DispatchWorkItem?
    private var settlementPresentationRequested = false
    private var settlementReadInFlight = false
    private var loadedRewardDays: [StoredRewardDay] = []
    private var loadedRewardAwards: [RewardAward] = []
    private var rewardReadOverlay: [String: RewardAward] = [:]
    private var rewardExportURL: URL?
    private var rewardExportRevision: Int64?
    private var durableRewardRevision: Int64 = 0
    private let diskQueue = DispatchQueue(label: "local.keytempo.persistence", qos: .utility)
    private var uiTimer: Timer?
    private var windowExpiryWork: DispatchWorkItem?
    private var windowExpiryDeadline: Double?
    private var saveWork: DispatchWorkItem?
    private var retryCount = 0
    private var processingInput = false
    private var flushDeferred = false
    private var generation: UInt64 = 0
    private var clearing = false
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var pendingDiagnostics: [String] = []
    private let monitoringEnabled: Bool
    private var ownedAdapterExcluded = false
    private var appliedExclusions: Set<String>?
    private var presentedInputSource: InputLanguages.Source?
    private var recentPresentationValid = false
    private var hybridActivity = HybridMenuActivity()
    private var estimatedRhythm = RecentIntervalRhythm()
    private var tenMinuteWindow = RollingTypingWindow()
    private var tenMinuteObservationStart = ProcessInfo.processInfo.systemUptime
    private var estimatedRhythmHasFreshInterval = false
    private var lastEstimatedInputTime: Double?
    private var historySelection: HistorySelection?
    private var loadedHistoryRows: [String: StoredAggregate] = [:]
    private var historyReadToken: UInt64 = 0
    private var activeHistoryRead: HistoryReadRequest?
    private var pendingHistoryRead: HistoryReadRequest?
    private var activityTracker = ActivityTracker()
    private var pendingActivity = ActivityBuffer()
    private var inFlightActivity = ActivityBatch()
    private var activityReadOverlay = ActivityBuffer()
    private var activityLoadedHourly: [String: HourlyActivity] = [:]
    private var activityLoadedSessions: [String: TypingSession] = [:]
    private var activityReadInFlight = false
    private var activityReadRequested = false
    private var activityReadToken: UInt64 = 0
    private var activitySessionWork: DispatchWorkItem?
    private var activitySessionDeadline: Double?
    private var appNameCache: [String: String] = [:]
    private var clearingAppActivity = false

    static func rule(_ maximum: Double, suspectedInputFiltering: Bool = true, globalKeyboardCompatibility: Bool = false) -> String {
        "adaptive-v4-no-space-ime-quality-" + (suspectedInputFiltering ? "on" : "off") + "-max" + String(format: "%.1f", maximum) + (globalKeyboardCompatibility ? "-keyboard-fallback" : "")
    }
    static func day(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    init(dataDirectory: URL? = nil, monitoringEnabled: Bool = true, perAppTracking: Bool? = nil, appearancePreferences: UserDefaults? = nil) {
        self.monitoringEnabled = monitoringEnabled
        appearanceStorage = appearancePreferences ?? (monitoringEnabled ? .standard : nil)
        appearanceMode = AppearancePolicy.mode(appearanceStorage?.string(forKey: "appearanceMode") ?? "system")
        appearanceTheme = appearanceStorage?.string(forKey: "appearanceTheme") ?? "classic"
        menuBarStyle = appearanceStorage?.string(forKey: "menuBarStyle") ?? "keyboard"
        menuIconMotionEnabled = appearanceStorage?.object(forKey: "menuIconMotionEnabled") as? Bool ?? true
        if let stored = appearanceStorage?.dictionary(forKey: "menuIconSpeedRange"),
           let low = stored["lowWPM"] as? Double, let high = stored["highWPM"] as? Double,
           let range = MenuIconSpeedRange(lowWPM: low, highWPM: high) {
            menuIconLowWPM = range.lowWPM; menuIconHighWPM = range.highWPM
        }
        if let perAppTracking { perAppTrackingEnabled = perAppTracking }
        let gap = UserDefaults.standard.object(forKey: "maximumGap") as? Double ?? 3
        let filterSuspected = UserDefaults.standard.object(forKey: "suspectedInputFilteringEnabled") as? Bool ?? true
        let globalCompatibility = UserDefaults.standard.bool(forKey: "chineseKeyboardCompatibilityEnabled")
        engine = StatisticsEngine(config: SegmentationConfig(maximumGap: gap, ruleID: Self.rule(gap, suspectedInputFiltering: filterSuspected, globalKeyboardCompatibility: globalCompatibility)), timeZone: .current)
        // Keep the existing on-disk identity so renaming the app preserves history.
        let directory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TypingSpeed", isDirectory: true)
        databaseURL = directory.appendingPathComponent("statistics.sqlite")
        do {
            let db = try AggregateStore(url: databaseURL)
            store = db
            let start = Self.day(Calendar.current.date(byAdding: .day, value: -30, to: Date())!)
            for row in try db.query(since: start) { cached[row.id] = row }
            if let saved = try db.loadRewardState() {
                rewardEngine = try RewardEngine(restoring: saved, now: Date())
                durableRewardRevision = saved.revision
            } else { rewardEngine = RewardEngine() }
            rewardState = rewardEngine?.state
            try initializeDailyRewards(database: db)
        } catch { storageError = error.localizedDescription }
        monitor.onInput = { [weak self] input in self?.receive(input) }
        monitor.onInterruption = { [weak self] reason in
            guard let self else { return }
            self.handleMonitoringInterruption(reason, capabilitiesAvailable: self.globalPresentationCapabilitiesAvailable)
        }
        monitor.onStatus = { [weak self] value in
            self?.handleMonitoringStatus(value)
        }
        monitor.suspectedInputFilteringEnabled = filterSuspected
        monitor.globalKeyboardCompatibilityEnabled = globalCompatibility
        updateExclusions()
        refreshInputLanguages()
        for name in [InputLanguages.sourceChanged, InputLanguages.policyChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let sourceOnly = name == InputLanguages.sourceChanged
                    // FocusContext drains the old-source ring before its
                    // handoff. An observer-order-dependent flush here would
                    // discard that source's pending prefix before it can replay.
                    if !sourceOnly {
                        self.monitor.flushPendingInput()
                        self.interruptEngine()
                    }
                    // The global monitor and confirmed editor each interrupt
                    // after flushing their old-source input in capture order.
                    self.refreshInputLanguages()
                    self.refreshSnapshot()
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.monitor.flushPendingInput(); self.finishActivitySession("sleep"); self.sleeping = true; self.interruptEngine(); self.settleEndedDailyRewards(); self.monitor.stop(); self.flush(); self.status = "系统睡眠，统计已中断"; self.stopUI(); self.resetTenMinuteWindow()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.sleeping = false; self.interruptEngine(); self.settleEndedDailyRewards(); self.scheduleRewardMidnight(); self.resetTenMinuteWindow(); if !self.isPaused { self.monitor.start() }; self.refreshSnapshot()
            }
        })
        installDailyRewardLifecycle(center: center)
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitor.flushPendingInput()
                self.accumulateActivity(self.activityTracker.setTimeZone(.current))
                self.engine.updateTimeZone(.current); self.refreshSnapshot()
                if self.activityVisible { self.loadActivity(day: self.activityDate) }
            }
        })
        if !isPaused && monitoringEnabled { monitor.start() } else { status = "已暂停" }
        if rewardEngine?.hasPendingChanges == true || dailyRewardsNeedSave { scheduleSave(after: 30) }
        refreshSnapshot()
    }
    func receiveConfirmedInput(_ input: ClassifiedInput) {
        guard !ownedAdapterExcluded else { return }
        monitor.flushPendingInput()
        receive(input)
    }
    func interruptConfirmed() {
        let preserve = canPreserveRecentGlobalPresentation(capabilitiesAvailable: globalPresentationCapabilitiesAvailable)
        interruptEngine(preservingRecentPresentation: preserve, preservingHybridActivity: preserve)
        scheduleUI()
    }
    private func receive(_ input: ClassifiedInput) {
        guard !isPaused, !sleeping, !clearing else { return }
        processingInput = true
        defer {
            processingInput = false
            if flushDeferred { flushDeferred = false; flush() }
        }
        // Backwards event clocks cannot make an earlier session look recent.
        if let last = lastEstimatedInputTime, input.time < last { resetTenMinuteWindow() }
        let result = engine.recordWithIntervals(input)
        let deltas = result.deltas
        let activity = activityTracker.record(input: input, result: result, rule: engine.config.ruleID,
                                             applicationID: input.applicationID,
                                             perAppEnabled: perAppTrackingEnabled && !clearingAppActivity)
        accumulateActivity(activity)
        recordRewards(input, result: result)
        if input.source == .global && input.evidence == .probable && deltas.contains(where: { $0.keys > 0 }) {
            activitySessionDeadline = input.time + 300
            scheduleActivitySessionEnd()
        }
        tenMinuteWindow.record(result.acceptedIntervals, at: input.time)
        captureCompletion()
        if input.category.isEffective && input.evidence != .unknown {
            // A deduplicated or invalid event cannot revive the old lane after
            // an input-source change. Accepted events always emit a key delta.
            if deltas.contains(where: { $0.keys > 0 }) {
                if recentEvidence != input.evidence {
                    estimatedRhythm.reset(); estimatedRhythmHasFreshInterval = false; lastEstimatedInputTime = nil
                }
                recentEvidence = input.evidence
                recentPresentationValid = input.evidence == .probable || input.language == currentInputLanguageCode
                recentSpeedIsFrozen = false
                hybridActivity.record(time: input.time, evidence: input.evidence,
                                      intervals: deltas.reduce(0) { $0 + $1.intervals },
                                      seconds: deltas.reduce(0) { $0 + $1.seconds }, idleGrace: hybridIdleGrace)
            }
        } else {
            finishRecentPresentation(preserving: canPreserveRecentGlobalPresentation(capabilitiesAvailable: globalPresentationCapabilitiesAvailable))
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
        var row = StoredAggregate(day: Self.day(), timezone: TimeZone.current.identifier, rule: Self.rule(maximumGap, suspectedInputFiltering: suspectedInputFilteringEnabled, globalKeyboardCompatibility: globalKeyboardCompatibilityEnabled), evidence: "confirmed", language: language)
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
    private func accumulateActivity(_ batch: ActivityBatch) {
        guard !batch.isEmpty else { return }
        pendingActivity.merge(batch)
        // The read is queued before later writes. Its overlay starts with the
        // unsaved batch and receives each later delta once, even if it saves.
        if activityReadInFlight { activityReadOverlay.merge(batch) }
        if activityVisible && !activityLoading && activityError == nil { mergeLoadedActivity(batch) }
        if pendingActivity.count >= 512 { flush() }
        if pendingActivity.count > 1024 {
            isPaused = true; monitor.stop(); interruptEngine()
            storageError = "待保存汇总达到容量上限，已暂停；请解决磁盘问题后重试。"
        }
        if saveWork == nil && retryCount == 0 { scheduleSave(after: 30) }
    }
    private func scheduleActivitySessionEnd() {
        guard activitySessionWork == nil, let deadline = activitySessionDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activitySessionWork = nil
            guard let deadline = self.activitySessionDeadline else { return }
            if ProcessInfo.processInfo.systemUptime < deadline { self.scheduleActivitySessionEnd(); return }
            self.finishActivitySession("idle")
            self.publishActivitySnapshot()
        }
        activitySessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    private func finishActivitySession(_ reason: String) {
        activitySessionWork?.cancel(); activitySessionWork = nil; activitySessionDeadline = nil
        accumulateActivity(activityTracker.finish(reason: reason))
        rewardEngine?.interrupt(at: Date(), reason: reason)
        dailyRewardEngine?.interrupt(at: Date(), reason: reason)
    }
    func loadActivity(day: Date) {
        let selection = Calendar.current.startOfDay(for: day)
        activityDate = selection; activityVisible = true
        activityReadToken &+= 1; activityReadRequested = true
        activityLoading = true; activityError = nil
        activityHourly.removeAll(); activitySessions.removeAll(); activityScoreDays.removeAll()
        startActivityReadIfPossible()
    }
    func releaseActivity() {
        activityVisible = false; activityReadToken &+= 1; activityReadRequested = false
        activityLoading = false; activityError = nil
        activityLoadedHourly.removeAll(); activityLoadedSessions.removeAll()
        activityHourly.removeAll(); activitySessions.removeAll(); activityScoreDays.removeAll()
        appNameCache.removeAll()
        loadedRewardDays.removeAll(); loadedRewardAwards.removeAll(); rewardAwards.removeAll()
        loadedDailySettlements.removeAll(); dailySettlements.removeAll(); dailyReadOverlay.removeAll()
        rewardReadOverlay.removeAll()
    }
    private func startActivityReadIfPossible() {
        if activityVisible && activityReadRequested && store == nil {
            activityLoading = false
            activityError = storageError ?? "SQLite unavailable"
            return
        }
        guard activityVisible, activityReadRequested, !activityReadInFlight,
              !clearing, !clearingAppActivity, activeReceipt == nil, let store else { return }
        let calendar = Calendar.current, day = calendar.startOfDay(for: activityDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: day),
              let start = calendar.date(byAdding: .day, value: -29, to: day) else { return }
        let token = activityReadToken, version = generation, applications = perAppTrackingEnabled
        let rewardStart = rewardDayKey(start), rewardEnd = rewardDayKey(end), rewardSelection = rewardDayKey(activityDate)
        activityReadRequested = false; activityReadInFlight = true
        activityReadOverlay = pendingActivity
        if let retryWrite { activityReadOverlay.merge(retryWrite.activity) }
        rewardReadOverlay = Dictionary(((inFlightWrite?.rewards?.awards ?? []) + (retryWrite?.rewards?.awards ?? []) +
                                       (rewardEngine?.unpersistedAwards ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        diskQueue.async { [weak self] in
            let result = Result { () -> ([HourlyActivity], [TypingSession], Date?, [StoredRewardDay], [RewardAward], [DailySettlementReceipt]) in
                var hours = try store.queryHourly(since: start, until: end)
                if applications { hours += try store.queryHourly(since: day, until: end, includeApplications: true) }
                var rewards = Dictionary(try store.queryRewardAwards(day: rewardSelection).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
                for award in try store.queryRewardAwards(attributedSince: day, until: end) { rewards[award.id] = award }
                return (hours, try store.querySessions(since: day, until: end), try store.activityCoverageStart(),
                        try store.queryRewardDays(since: rewardStart, until: rewardEnd),
                        Array(rewards.values), try store.queryDailyRewardReceipts(since: rewardStart, until: rewardEnd))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activityReadInFlight = false
                if self.activityVisible && !self.clearing && !self.clearingAppActivity &&
                    version == self.generation && token == self.activityReadToken && applications == self.perAppTrackingEnabled {
                    switch result {
                    case let .success((hours, sessions, coverage, rewardDays, rewardAwards, dailyReceipts)):
                        self.activityLoadedHourly = Dictionary(hours.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                        self.activityLoadedSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                        self.mergeLoadedActivity(self.activityReadOverlay.batch)
                        self.activityCoverageStart = coverage ?? self.activityLoadedHourly.values.map(\.bucketStart).min()
                        self.activityError = nil
                        self.loadedRewardDays = rewardDays
                        var mergedDaily = Dictionary(dailyReceipts.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
                        for receipt in self.dailyReadOverlay.values where receipt.day >= rewardStart && receipt.day < rewardEnd { mergedDaily[receipt.id] = receipt }
                        self.loadedDailySettlements = mergedDaily.values.sorted { $0.day < $1.day }
                        var mergedAwards = Dictionary(rewardAwards.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
                        for award in self.rewardReadOverlay.values where self.isRewardAwardVisible(award) { mergedAwards[award.id] = award }
                        self.loadedRewardAwards = Array(mergedAwards.values)
                        self.publishRewards()
                    case let .failure(error):
                        self.activityLoadedHourly.removeAll(); self.activityLoadedSessions.removeAll()
                        self.activityError = error.localizedDescription
                    }
                    self.activityLoading = false
                    self.publishActivitySnapshot()
                }
                self.activityReadOverlay.removeAll()
                self.rewardReadOverlay.removeAll(); self.dailyReadOverlay.removeAll()
                self.startActivityReadIfPossible()
            }
        }
    }
    private func mergeLoadedActivity(_ batch: ActivityBatch) {
        let calendar = Calendar.current, day = calendar.startOfDay(for: activityDate)
        guard let start = calendar.date(byAdding: .day, value: -29, to: day),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return }
        var buffer = ActivityBuffer(hourly: activityLoadedHourly, sessions: activityLoadedSessions)
        buffer.merge(ActivityBatch(hourly: batch.hourly.filter {
            $0.bucketStart >= start && $0.bucketStart < end &&
            ($0.applicationID.isEmpty || (perAppTrackingEnabled && !clearingAppActivity && $0.bucketStart >= day))
        }, sessions: batch.sessions.filter { ($0.end > day || ($0.start == $0.end && $0.start >= day)) && $0.start < end }))
        activityLoadedHourly = buffer.hourly; activityLoadedSessions = buffer.sessions
    }
    private func publishActivitySnapshot() {
        guard activityVisible, !activityLoading, activityError == nil else { return }
        let calendar = Calendar.current, day = calendar.startOfDay(for: activityDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return }
        let hours = activityLoadedHourly.values.filter {
            $0.bucketStart >= day && $0.bucketStart < end &&
            ($0.applicationID.isEmpty || (perAppTrackingEnabled && !clearingAppActivity))
        }.sorted { $0.id < $1.id }
        let sessions = activityLoadedSessions.values.filter { ($0.end > day || ($0.start == $0.end && $0.start >= day)) && $0.start < end }.sorted { $0.start > $1.start }
        let grouped = Dictionary(grouping: activityLoadedHourly.values.filter { $0.applicationID.isEmpty }, by: { calendar.startOfDay(for: $0.bucketStart) })
        let scores = grouped.keys.sorted().map { date in
            let rows = grouped[date]!
            var totals = RhythmTotals(); for row in rows { totals.merge(row.totals) }
            return ActivityScoreDay(day: date, totals: totals, hasMixedRules: Set(rows.map(\.rule)).count > 1)
        }
        if activityHourly != hours { activityHourly = hours }
        if activitySessions != sessions { activitySessions = sessions }
        if activityScoreDays != scores { activityScoreDays = scores }
    }
    func setPerAppTracking(_ enabled: Bool) {
        guard enabled != perAppTrackingEnabled else { return }
        monitor.flushPendingInput()
        activityTracker.resetApplicationAttribution()
        perAppTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "perAppTrackingEnabled")
        if activityVisible { loadActivity(day: activityDate) }
    }
    /// The view confirms deletion. Combined hours, sessions and daily history
    /// remain intact; a serial clear follows any already captured transaction.
    func clearAppActivity() {
        guard !clearingAppActivity, !clearing, let store else { return }
        monitor.flushPendingInput(); activityTracker.resetApplicationAttribution()
        clearingAppActivity = true; activityReadToken &+= 1
        activityActionError = nil
        pendingActivity.removeApplications()
        inFlightActivity.hourly.removeAll { !$0.applicationID.isEmpty }
        inFlightWrite?.activity.hourly.removeAll { !$0.applicationID.isEmpty }
        retryWrite?.activity.hourly.removeAll { !$0.applicationID.isEmpty }
        activityReadOverlay.removeApplications()
        activityLoadedHourly = activityLoadedHourly.filter { $0.value.applicationID.isEmpty }
        appNameCache.removeAll(); publishActivitySnapshot()
        diskQueue.async { [weak self] in
            let result = Result { try store.clearAppActivity() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearingAppActivity = false; self.activityTracker.resetApplicationAttribution()
                if case let .failure(error) = result {
                    self.storageError = error.localizedDescription
                    self.activityActionError = error.localizedDescription
                }
                if self.activityVisible { self.loadActivity(day: self.activityDate) }
            }
        }
    }
    func activityAppName(_ identifier: String) -> String {
        if let name = appNameCache[identifier] { return name }
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).flatMap { Bundle(url: $0) }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? identifier
        if appNameCache.count >= 256 { appNameCache.removeAll(keepingCapacity: true) }
        appNameCache[identifier] = name
        return name
    }
    private func recordRewards(_ input: ClassifiedInput, result: StatisticsRecordResult) {
        let context = ImprovementContext(language: input.language, inputMethodID: input.inputMethodID,
                                         usesInputMethod: input.usesInputMethod, measurementPolicy: engine.config.ruleID)
        rewardEngine?.record(input: input, result: result, context: context,
                             sessionID: activityTracker.currentSession?.id,
                             pendingIntervalCount: engine.pendingProbableIntervals)
        dailyRewardEngine?.record(input: input, result: result, rule: engine.config.ruleID)
        observeDailyImprovement()
        if rewardEngine?.error != nil { rewardError = "奖励数据异常，已停止新增奖励；输入统计仍保留。请重新启动并重试。" }
    }
    func rewardDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: rewardState?.progressionTimezone ?? "") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    var selectedRewardDay: StoredRewardDay? { rewardDays.first { $0.day == rewardDayKey(activityDate) } }
    var todayReward: RewardDayBudget? { rewardState.flatMap { $0.days[$0.currentDay] } }
    private var recentRewardWeek: [RewardDayBudget] {
        guard let state = rewardState else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: state.progressionTimezone) ?? .current
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = formatter.date(from: state.currentDay) ?? Date()
        let start = rewardDayKey(calendar.date(byAdding: .day, value: -6, to: today) ?? today)
        return state.days.values.filter { $0.day >= start && $0.day <= state.currentDay }
    }
    var weekRewardScore: Double { recentRewardWeek.reduce(0) { $0 + $1.components.total } }
    var weekRewardXP: Int? {
        var sum = 0
        for day in recentRewardWeek {
            let next = sum.addingReportingOverflow(day.xp.total)
            guard !next.overflow else { return nil }; sum = next.partialValue
        }
        return sum
    }
    func rewardPoints(hour: Date? = nil, sessionID: String? = nil) -> Double? {
        guard let state = rewardState, rewardDayKey(activityDate) >= rewardDayKey(state.coverageStart) else { return nil }
        if let hour {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: state.progressionTimezone) ?? .current
            guard calendar.dateInterval(of: .hour, for: hour)?.start == hour else { return nil }
        }
        return rewardAwards.flatMap(\.attributions).filter {
            (hour == nil || $0.hour == hour) && (sessionID == nil || $0.sessionID == sessionID)
        }.reduce(0) { $0 + $1.components.total }
    }
    private func publishRewards() {
        guard let state = rewardEngine?.state else { return }
        if let prior = rewardState, let old = LevelProgress(totalXP: prior.xpProgress.totalXP),
           let next = LevelProgress(totalXP: state.xpProgress.totalXP), next.level > old.level {
            rewardFeedbackEvent = .level(next.level, next.level - old.level)
        } else if let prior = rewardState, state.xpProgress.improvementXP > prior.xpProgress.improvementXP {
            rewardFeedbackEvent = .improvement(state.xpProgress.improvementXP - prior.xpProgress.improvementXP)
        }
        if rewardState != state { rewardState = state }
        publishDailyRewards()
        var days = Dictionary(loadedRewardDays.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        for day in state.days.values {
            days[day.day] = StoredRewardDay(day: day.day, components: day.components, xp: day.xp)
        }
        let sorted = days.values.sorted { $0.day < $1.day }
        if rewardDays != sorted { rewardDays = sorted }
        var awards = Dictionary(loadedRewardAwards.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for award in (inFlightWrite?.rewards?.awards ?? []) + (retryWrite?.rewards?.awards ?? []) + (rewardEngine?.unpersistedAwards ?? []) {
            awards[award.id] = award
        }
        let visible = activityVisible ? awards.values.filter { isRewardAwardVisible($0) }.sorted { $0.id < $1.id } : []
        if rewardAwards != visible { rewardAwards = visible }
    }
    func exportRewards() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Keytempo-rewards.csv"
        guard panel.runModal() == .OK, let url = panel.url, store != nil else { return }
        rewardExportURL = url
        let needsCheckpoint = !pending.isEmpty || !pendingActivity.isEmpty || rewardEngine?.hasPendingChanges == true
        let revision = (rewardEngine?.state.revision ?? 0).addingReportingOverflow(needsCheckpoint ? 1 : 0)
        guard !revision.overflow else { rewardError = "奖励数据异常，已停止新增奖励；输入统计仍保留。请重新启动并重试。"; return }
        rewardExportRevision = revision.partialValue
        flush(); finishRewardExportIfReady()
    }
    private func retainRewardAwards(_ awards: [RewardAward]) {
        if activityReadInFlight { for award in awards { rewardReadOverlay[award.id] = award } }
        guard activityVisible else { return }
        var merged = Dictionary(loadedRewardAwards.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for award in awards where isRewardAwardVisible(award) { merged[award.id] = award }
        loadedRewardAwards = Array(merged.values)
    }
    private func isRewardAwardVisible(_ award: RewardAward) -> Bool {
        let start = Calendar.current.startOfDay(for: activityDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return award.day == rewardDayKey(activityDate) || award.attributions.contains { $0.hour >= start && $0.hour < end }
    }
    private func finishRewardExportIfReady() {
        guard let url = rewardExportURL, let target = rewardExportRevision, let store else { return }
        guard durableRewardRevision >= target else {
            if activeReceipt == nil && retryCount == 0 { flush() }
            return
        }
        rewardExportURL = nil; rewardExportRevision = nil
        diskQueue.async { [weak self] in
            do { try store.exportRewardCSV(since: .distantPast, until: .distantFuture).write(to: url, atomically: true, encoding: .utf8) }
            catch { DispatchQueue.main.async { self?.storageError = "导出失败：\(error.localizedDescription)" } }
        }
    }
    func flush() {
        guard !processingInput else { flushDeferred = true; return }
        saveWork?.cancel(); saveWork = nil
        guard !clearing, activeReceipt == nil,
              retryWrite != nil || !pending.isEmpty || !pendingActivity.isEmpty || rewardEngine?.hasPendingChanges == true || dailyRewardsNeedSave,
              let store else { return }
        let payload: MeasurementWrite
        if let retryWrite { payload = retryWrite }
        else {
            let rewards = rewardEngine?.error == nil ? rewardEngine?.checkpoint(at: Date()) : nil
            observeDailyImprovement()
            let daily = dailyRewardEngine?.error == nil ? dailyRewardEngine?.checkpoint(at: Date()) : nil
            payload = MeasurementWrite(id: UUID().uuidString, rows: Array(pending.values), activity: pendingActivity.batch, rewards: rewards, dailyRewards: daily)
            pending.removeAll(keepingCapacity: true); pendingActivity.removeAll()
        }
        inFlight = Dictionary(payload.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        inFlightActivity = payload.activity; inFlightWrite = payload
        retainRewardAwards(payload.rewards?.awards ?? [])
        let version = generation, receipt = WriteReceipt(); activeReceipt = receipt
        diskQueue.async { [weak self] in
            let result = Result { try store.save(payload.rows, activity: payload.activity, progression: payload.rewards, dailyRewards: payload.dailyRewards, batchID: payload.id) }
            if case .success = result { receipt.succeeded = true } else { receipt.succeeded = false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                if case let .failure(error) = result {
                    self.retryWrite = self.inFlightWrite ?? payload
                    self.storageError = "保存失败：\(error.localizedDescription)"; self.retryCount += 1
                } else {
                    if self.retryWrite?.id == payload.id { self.retryWrite = nil }
                    self.storageError = nil; self.retryCount = 0
                    self.durableRewardRevision = payload.rewards?.state.revision ?? self.durableRewardRevision
                    self.durableDailyRevision = payload.dailyRewards?.state.revision ?? self.durableDailyRevision
                    self.retainRewardAwards(payload.rewards?.awards ?? [])
                    self.retainDailySettlements(payload.dailyRewards?.receipts ?? [])
                }
                self.inFlight.removeAll(keepingCapacity: true)
                self.inFlightActivity = ActivityBatch(); self.inFlightWrite = nil; self.activeReceipt = nil
                if (self.retryWrite != nil || !self.pending.isEmpty || !self.pendingActivity.isEmpty || self.rewardEngine?.hasPendingChanges == true || self.dailyRewardsNeedSave) && self.retryCount <= 3 {
                    self.scheduleSave(after: self.retryCount == 0 ? 30 : Double(self.retryCount * 10))
                }
                self.publishRewards(); self.startActivityReadIfPossible(); self.finishRewardExportIfReady(); self.finishDailyRewardExportIfReady()
                // A midnight receipt must follow an older write immediately,
                // even with every window closed. Retry failures retain backoff.
                if self.retryCount == 0 && self.retryWrite == nil && self.dailyRewardsNeedSave &&
                    self.dailyRewardEngine?.unpersistedReceipts.isEmpty == false { self.flush() }
                if self.settlementPresentationRequested {
                    if self.retryCount == 0 && self.retryWrite == nil && self.dailyRewardsNeedSave { self.flush() }
                    self.readNextSettlement()
                }
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
                if let saved = try restored.loadRewardState() {
                    rewardEngine = try RewardEngine(restoring: saved, now: Date()); durableRewardRevision = saved.revision
                }
                else { rewardEngine = RewardEngine() }
                store = restored; storageError = nil
                try initializeDailyRewards(database: restored)
            } catch { storageError = error.localizedDescription; return }
        }
        retryCount = 0; flush(); startActivityReadIfPossible(); refreshSnapshot()
    }
    func flushBeforeExit() {
        monitor.flushPendingInput(); finishActivitySession("appExit")
        stopUI(); midnightWork?.cancel(); midnightWork = nil; windowExpiryWork?.cancel(); windowExpiryWork = nil; windowExpiryDeadline = nil
        saveWork?.cancel(); saveWork = nil; monitor.stop(); interruptEngine()
        if clearing { diskQueue.sync {}; return }
        let rewards = rewardEngine?.error == nil ? rewardEngine?.checkpoint(at: Date()) : nil
        observeDailyImprovement()
        let daily = dailyRewardEngine?.error == nil ? dailyRewardEngine?.checkpoint(at: Date()) : nil
        let tail = MeasurementWrite(id: UUID().uuidString, rows: Array(pending.values), activity: pendingActivity.batch, rewards: rewards, dailyRewards: daily)
        let flight = inFlightWrite, retry = retryWrite, receipt = activeReceipt, database = store
        diskQueue.sync {
            guard let database else { return }
            do {
                if let flight, receipt?.succeeded == false {
                    try database.save(flight.rows, activity: flight.activity, progression: flight.rewards, dailyRewards: flight.dailyRewards, batchID: flight.id)
                } else if flight == nil, let retry {
                    try database.save(retry.rows, activity: retry.activity, progression: retry.rewards, dailyRewards: retry.dailyRewards, batchID: retry.id)
                }
                try database.save(tail.rows, activity: tail.activity, progression: tail.rewards, dailyRewards: tail.dailyRewards, batchID: tail.id)
            } catch { fputs("Keytempo: final checkpoint failed: \(error.localizedDescription)\n", stderr) }
        }
        pending.removeAll(); pendingActivity.removeAll()
    }
    func togglePause() {
        monitor.flushPendingInput()
        isPaused.toggle(); UserDefaults.standard.set(isPaused, forKey: "paused"); interruptEngine()
        if isPaused { finishActivitySession("paused") }
        resetTenMinuteWindow()
        if isPaused { estimatedRhythm.reset(); lastEstimatedInputTime = nil }
        if isPaused { monitor.stop(); status = "已暂停"; flush() } else if !sleeping { monitor.start(); status = "正在确认上下文" }
        refreshSnapshot()
    }
    func showStats() { openStats?() }
    func showSettings() { refreshInputLanguages(); openSettings?() }
    func showAppearance() { statisticsPage = "appearance"; openStats?() }
    func setAppearanceMode(_ value: String) {
        appearanceMode = AppearancePolicy.mode(value)
        appearanceStorage?.set(appearanceMode, forKey: "appearanceMode"); onAppearanceUpdate?()
    }
    func setAppearanceTheme(_ value: String) {
        guard AppearancePolicy.effective(value, choice: .theme, level: appearanceLevel) == value else { return }
        appearanceTheme = value; appearanceStorage?.set(value, forKey: "appearanceTheme"); onAppearanceUpdate?()
    }
    func setMenuBarStyle(_ value: String) {
        guard AppearancePolicy.effective(value, choice: .icon, level: appearanceLevel) == value else { return }
        menuBarStyle = value; appearanceStorage?.set(value, forKey: "menuBarStyle"); onAppearanceUpdate?()
    }
    func setMenuIconMotionEnabled(_ enabled: Bool) {
        menuIconMotionEnabled = enabled
        appearanceStorage?.set(enabled, forKey: "menuIconMotionEnabled")
        onAppearanceUpdate?()
    }
    @discardableResult func setMenuIconSpeedRange(lowWPM: Double, highWPM: Double) -> Bool {
        guard let range = MenuIconSpeedRange(lowWPM: lowWPM, highWPM: highWPM) else { return false }
        guard range != menuIconSpeedRange else { return true }
        // Save the pair together so a restart cannot load half of a new range.
        appearanceStorage?.set(["lowWPM": range.lowWPM, "highWPM": range.highWPM], forKey: "menuIconSpeedRange")
        menuIconLowWPM = range.lowWPM; menuIconHighWPM = range.highWPM
        onAppearanceUpdate?()
        return true
    }
    func previewMenuEffects() {
        guard menuIconMotionEnabled else { return }
        onMenuEffectPreview?()
    }
    func setInterfaceLanguage(_ code: String) {
        let selected = code == "en" ? "en" : "zh-Hans"
        UserDefaults.standard.set(selected, forKey: "interfaceLanguage")
        interfaceLanguage = selected
        refreshInputLanguages()
        onInterfaceLanguageUpdate?()
        refreshSnapshot()
    }
    func refreshInputLanguages() {
        // Capture owners flush and interrupt source changes in event order.
        // Refreshing the labels must not discard their pending old-source keys.
        updateInputSource(InputLanguages.current, interrupting: false)
    }
    /// Source identity includes the IME mode. Kept separate so isolated checks
    /// can exercise a language round trip without changing macOS or user prefs.
    fileprivate func updateInputSource(_ source: InputLanguages.Source, interrupting: Bool = true) {
        if presentedInputSource != source {
            if interrupting { monitor.flushPendingInput() }
            presentedInputSource = source
            if interrupting {
                interruptEngine(preservingRecentPresentation: recentEvidence == .probable && recentPresentationValid,
                                preservingHybridActivity: true)
            }
        }
        currentInputLanguageCode = source.languageCode
        currentInputLanguage = "\(languageName(source.languageCode)) · \(source.name)"
    }
    func languageName(_ code: String) -> String {
        code == "und" ? L("未标注／未知语言") : (Locale(identifier: interfaceLanguage).localizedString(forLanguageCode: code) ?? code)
    }
    func requestInputPermission() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func requestAccessibilityPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func refreshPermissions() {
        monitor.flushPendingInput()
        interruptEngine(); monitor.refreshPermissions()
        if !isPaused { monitor.stop(); monitor.start() }
        refreshSnapshot()
    }
    func updateExclusions() {
        let values = excludedAppsText.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        ownedAdapterExcluded = values.contains(Bundle.main.bundleIdentifier ?? "local.benjamin.TypingSpeed")
        let selection = Set(values)
        guard selection != appliedExclusions else { return }
        appliedExclusions = selection
        monitor.updateExcludedApps(selection)
        interruptEngine()
    }
    func applySettings() {
        monitor.flushPendingInput()
        maximumGap = max(1, min(6, maximumGap))
        let countingRule = Self.rule(maximumGap, suspectedInputFiltering: suspectedInputFilteringEnabled, globalKeyboardCompatibility: globalKeyboardCompatibilityEnabled)
        let countingRuleChanged = engine.config.ruleID != countingRule
        if countingRuleChanged { resetTenMinuteWindow() }
        engine.updateConfig(SegmentationConfig(maximumGap: maximumGap, ruleID: countingRule))
        monitor.suspectedInputFilteringEnabled = suspectedInputFilteringEnabled
        monitor.globalKeyboardCompatibilityEnabled = globalKeyboardCompatibilityEnabled
        updateExclusions()
        if countingRuleChanged { finishActivitySession("settingsChanged"); interruptEngine() }
        monitor.diagnosticsEnabled = diagnosticsEnabled
        UserDefaults.standard.set(excludedAppsText, forKey: "excludedApps"); UserDefaults.standard.set(maximumGap, forKey: "maximumGap"); UserDefaults.standard.set(menuDisplay, forKey: "menuDisplay")
        UserDefaults.standard.set(suspectedInputFilteringEnabled, forKey: "suspectedInputFilteringEnabled")
        UserDefaults.standard.set(globalKeyboardCompatibilityEnabled, forKey: "chineseKeyboardCompatibilityEnabled")
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
    private var globalPresentationCapabilitiesAvailable: Bool {
        monitor.hasInputPermission && monitor.hasAccessibilityPermission && !IsSecureEventInputEnabled() &&
            !Self.isHardMonitoringStatus(monitor.status)
    }
    private static func isHardMonitoringStatus(_ value: String) -> Bool {
        ["权限", "安全输入", "排除", "本应用仅在确认输入区统计", "监听创建失败"].contains { value.contains($0) }
    }
    /// Resolved exclusions can arrive without another keyboard event. Unknown
    /// AX/revalidation statuses remain soft; they must not make WPM flicker.
    fileprivate func handleMonitoringStatus(_ value: String) {
        if ["权限", "安全输入", "监听创建失败"].contains(where: { value.contains($0) }) { finishActivitySession("monitorUnavailable") }
        if Self.isHardMonitoringStatus(value) { interruptEngine() }
        if !isPaused { status = value }
        scheduleUI()
    }
    private func canPreserveRecentGlobalPresentation(capabilitiesAvailable: Bool, source: InputLanguages.Source = InputLanguages.current) -> Bool {
        capabilitiesAvailable && !isPaused && !sleeping && !clearing &&
            recentEvidence == .probable && recentPresentationValid
    }
    /// Capability metadata is supplied explicitly so isolated checks do not
    /// depend on this Mac's TCC state. No input classification is changed here.
    fileprivate func handleMonitoringInterruption(_ reason: String, capabilitiesAvailable: Bool, source: InputLanguages.Source = InputLanguages.current) {
        let hardBoundary = !capabilitiesAvailable || ["权限", "安全输入", "排除"].contains { reason.contains($0) }
        let preserveActivity = !hardBoundary && recentEvidence == .probable && !isPaused && !sleeping && !clearing
        interruptEngine(preservingRecentPresentation: !hardBoundary && canPreserveRecentGlobalPresentation(capabilitiesAvailable: capabilitiesAvailable, source: source),
                        preservingHybridActivity: preserveActivity)
        status = reason; scheduleUI()
        if diagnosticsEnabled {
            pendingDiagnostics.append("中断 · \(reason)")
            if pendingDiagnostics.count > 60 { pendingDiagnostics.removeFirst(pendingDiagnostics.count - 60) }
        }
    }
    private func finishRecentPresentation(preserving: Bool) {
        if preserving { recentSpeedIsFrozen = true }
        else {
            recentPresentationValid = false
            estimatedRhythmHasFreshInterval = false
            recentSpeedIsFrozen = false
        }
    }
    private func interruptEngine(preservingRecentPresentation: Bool = false, preservingHybridActivity: Bool = false) {
        engine.interrupt()
        activityTracker.interruptConsistency()
        rewardEngine?.interrupt(at: Date())
        dailyRewardEngine?.interrupt(at: Date())
        finishRecentPresentation(preserving: preservingRecentPresentation)
        if !preservingHybridActivity { hybridActivity.reset() }
        if !preservingRecentPresentation {
            estimatedRhythm.reset(); estimatedRhythmHasFreshInterval = false; lastEstimatedInputTime = nil
        }
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
    private func resetTenMinuteWindow() {
        tenMinuteWindow.reset()
        tenMinuteObservationStart = ProcessInfo.processInfo.systemUptime
        windowExpiryWork?.cancel(); windowExpiryWork = nil; windowExpiryDeadline = nil
        tenMinuteWPM = nil; tenMinuteKPM = nil; tenMinuteWindowComplete = true; tenMinuteObservedSeconds = 0
    }
    private func refreshTenMinuteWindow(at now: Double) {
        let window = tenMinuteWindow.snapshot(at: now)
        let observed = isPaused || sleeping ? 0 : min(600, max(0, now - tenMinuteObservationStart))
        if tenMinuteObservedSeconds != observed { tenMinuteObservedSeconds = observed }
        if tenMinuteKPM != window.kpm { tenMinuteKPM = window.kpm }
        if tenMinuteWPM != window.estimatedWPM { tenMinuteWPM = window.estimatedWPM }
        if tenMinuteWindowComplete != window.isComplete { tenMinuteWindowComplete = window.isComplete }
        let deadline = window.nextExpiry
        guard deadline != windowExpiryDeadline else { return }
        windowExpiryWork?.cancel(); windowExpiryWork = nil; windowExpiryDeadline = deadline
        guard let deadline, !sleeping else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.windowExpiryWork = nil; self.windowExpiryDeadline = nil
            self.refreshSnapshot()
        }
        windowExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline - now), execute: work)
    }
    func refreshSnapshot() {
        refreshSnapshot(at: ProcessInfo.processInfo.systemUptime)
    }
    fileprivate func refreshSnapshot(at now: Double) {
        menuSnapshotUptime = now
        rewardEngine?.advance(to: Date())
        dailyRewardEngine?.advance(to: Date())
        observeDailyImprovement()
        refreshTenMinuteWindow(at: now)
        let todayKey = Self.day()
        let wasResolving = engine.completionPending
        engine.advance(to: now)
        if wasResolving && !engine.completionPending { rewardEngine?.interrupt(at: Date(), reason: "idle-resolution") }
        if (rewardEngine?.hasPendingChanges == true || dailyRewardsNeedSave) && saveWork == nil && retryCount == 0 { scheduleSave(after: 30) }
        publishRewards()
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
        if suspiciousRepeatEvents != monitor.suspiciousRepeatEvents { suspiciousRepeatEvents = monitor.suspiciousRepeatEvents }
        if suspiciousBurstEvents != monitor.suspiciousBurstEvents { suspiciousBurstEvents = monitor.suspiciousBurstEvents }
        func display(_ source: MetricSnapshot, evidence: String) -> MetricDisplay {
            let global = evidence == Evidence.probable.rawValue
            let language = global ? "mul" : currentInputLanguageCode
            let today = cached.values.filter { $0.day == todayKey && $0.evidence == evidence && (global || $0.language == language) }
            let keys = today.reduce(0) { $0 + $1.keys }, edits = today.reduce(0) { $0 + $1.edits }, composition = today.reduce(0) { $0 + $1.composition }
            let intervals = today.reduce(0) { $0 + $1.intervals }, seconds = today.reduce(0) { $0 + $1.seconds }
            let newIntervals = today.reduce(0) { $0 + $1.newIntervals }, newSeconds = today.reduce(0) { $0 + $1.newSeconds }
            let characters = today.reduce(0) { $0 + $1.characters }
            let characterIntervals = today.reduce(0) { $0 + $1.characterIntervals }
            let characterSeconds = today.reduce(0) { $0 + $1.characterSeconds }
            let ratedCharacters = today.reduce(0) { $0 + $1.ratedCharacters }
            let mixed = Set(today.map(\.rule)).count > 1
            let sameLanguage = recentPresentationValid && recentEvidence.rawValue == evidence && (global || source.recentLanguage == language)
            return MetricDisplay(language: language, keys: keys, edits: edits, composition: composition, characters: characters,
                                 intervals: intervals, seconds: seconds,
                                 kpm: sameLanguage ? (global ? (estimatedRhythmHasFreshInterval ? estimatedRhythm.kpm : nil) : source.recentRhythmKPM) : nil,
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
        // Preserve all quantities, while comparing rates only under the
        // current counting/segmentation rule. Legacy time is never silently
        // blended into a newer numerator definition.
        let currentRule = Self.rule(maximumGap, suspectedInputFiltering: suspectedInputFilteringEnabled, globalKeyboardCompatibility: globalKeyboardCompatibilityEnabled)
        let currentEstimatedToday = estimatedToday.filter { $0.rule == currentRule }
        let ratedIntervals = currentEstimatedToday.reduce(0.0) { $0 + $1.intervals }
        let ratedSeconds = currentEstimatedToday.reduce(0.0) { $0 + $1.seconds }
        let todayKPM = ratedIntervals >= 4 && ratedSeconds >= 0.5 ? 60 * ratedIntervals / ratedSeconds : nil
        let averageWPM = TypingRate.estimatedWPM(fromKPM: todayKPM)
        let partial = estimatedToday.contains { $0.rule != currentRule }
        let coveredKeys = currentEstimatedToday.reduce(0) { $0 + $1.keys }
        if todayAverageWPM != averageWPM { todayAverageWPM = averageWPM }
        if todayAverageIsPartial != partial { todayAverageIsPartial = partial }
        if todayAverageCoveredKeys != coveredKeys { todayAverageCoveredKeys = coveredKeys }
        let recentEstimate = estimatedRhythmHasFreshInterval ? estimatedRhythm.kpm : nil
        if estimatedRecentKPM != recentEstimate { estimatedRecentKPM = recentEstimate }
        let combined = MetricDisplay(language: "mul", keys: estimatedToday.reduce(0) { $0 + $1.keys },
                                     edits: estimatedToday.reduce(0) { $0 + $1.edits },
                                     composition: estimatedToday.reduce(0) { $0 + $1.composition },
                                     intervals: totalIntervals, seconds: totalSeconds,
                                     kpm: recentEstimate,
                                     todayKPM: todayKPM)
        if dailyEstimate != combined { dailyEstimate = combined }
        let english = today.reduce(0) { $0 + $1.english }, chinese = today.reduce(0) { $0 + $1.chinese }
        if english != commitsEnglish { commitsEnglish = english }; if chinese != commitsChinese { commitsChinese = chinese }
        let localPath = !ownedAdapterExcluded && recentEvidence == .confirmed && NSApp.isActive && (NSApp.keyWindow?.firstResponder is ConfirmedTextView)
        let unavailable = ["权限", "安全输入", "无法", "中断", "排除", "未知"].contains { monitor.status.contains($0) }
        let nextStatus: String
        if isPaused { nextStatus = "已暂停" }
        else if ownedAdapterExcluded && NSApp.isActive { nextStatus = "本应用已排除" }
        else if !localPath && (!hasInputPermission || !hasAccessibilityPermission) { nextStatus = "权限不可用 · 全局估算已停止" }
        else if unavailable && !localPath { nextStatus = monitor.status }
        else if monitor.usesGlobalKeyboardEstimate && !localPath { nextStatus = monitor.status }
        else if phase == "idle" { nextStatus = "已停止／未观察到输入 · 最近节奏已冻结" }
        else if phase == "typing" { nextStatus = "正在统计 · \(localPath ? "已确认" : "估算")输入段" }
        else { nextStatus = "候选输入段 · 数据不足" }
        if status != nextStatus { status = nextStatus }
        publishActivitySnapshot()
        onMenuUpdate?()
        if snap.phase == .idle && !engine.completionPending && !hybridMenuNeedsUI(at: now) { stopUI() }
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
        if statisticsVisible && activityVisible { loadActivity(day: activityDate) }
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
                                                   startDay: selection.startDay, endDay: selection.endDay, combineLanguages: true)
        let grouped = Dictionary(grouping: buckets, by: { $0.periodStart + "|" + $0.language })
        history = grouped.keys.sorted().compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let confirmed = group.first { $0.evidence == .confirmed }
            let estimated = group.first { $0.evidence == .probable }
            let rules = Set(group.flatMap(\.rules))
            return HistoryDay(day: first.periodStart, periodEnd: group.map(\.periodEnd).max() ?? first.periodEnd,
                              language: first.language, keys: confirmed?.keys ?? 0, estimatedKeys: estimated?.keys ?? 0,
                              edits: group.reduce(0) { $0 + $1.edits }, characters: confirmed?.characters ?? 0,
                              seconds: confirmed?.seconds ?? 0, estimatedSeconds: estimated?.seconds ?? 0,
                              intervals: confirmed?.intervals ?? 0, estimatedIntervals: estimated?.intervals ?? 0,
                              kpm: confirmed?.kpm, estimatedKPM: estimated?.kpm,
                              cpm: confirmed?.cpm, rules: rules.sorted().joined(separator: "; "),
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
        guard !clearing, let store else { return }
        monitor.flushPendingInput()
        clearing = true; saveWork?.cancel(); saveWork = nil; interruptEngine()
        activityReadToken &+= 1
        activitySessionWork?.cancel(); activitySessionWork = nil; activitySessionDeadline = nil
        invalidateHistoryReads(clearRows: false)
        diskQueue.async {
            let result = Result { try store.clear() }
            DispatchQueue.main.async {
                if case let .failure(error) = result { self.storageError = error.localizedDescription }
                else {
                    self.generation &+= 1; self.saveWork?.cancel(); self.saveWork = nil
                    self.pending.removeAll(); self.inFlight.removeAll()
                    self.activeReceipt = nil
                    self.inFlightWrite = nil; self.retryWrite = nil
                    self.rewardEngine = RewardEngine(); self.rewardState = self.rewardEngine?.state
                    self.dailyRewardEngine = DailyRewardEngine()
                    self.dailyRewardState = self.dailyRewardEngine?.state
                    self.dailyRewardError = nil
                    self.loadedDailySettlements.removeAll(); self.dailySettlements.removeAll(); self.dailyReadOverlay.removeAll()
                    self.durableDailyRevision = 0; self.dailyExportURL = nil; self.dailyExportRevision = nil
                    self.closeSettlementPresentation()
                    self.rewardFeedbackEvent = nil; self.rewardError = nil
                    self.durableRewardRevision = 0; self.rewardExportURL = nil; self.rewardExportRevision = nil
                    self.rewardReadOverlay.removeAll(); self.dailyReadOverlay.removeAll()
                    self.loadedRewardDays.removeAll(); self.loadedRewardAwards.removeAll()
                    self.rewardDays.removeAll(); self.rewardAwards.removeAll()
                    self.pendingActivity.removeAll(); self.inFlightActivity = ActivityBatch()
                    self.activityTracker = ActivityTracker()
                    self.activityReadOverlay.removeAll()
                    self.activityLoadedHourly.removeAll(); self.activityLoadedSessions.removeAll()
                    self.activityHourly.removeAll(); self.activitySessions.removeAll(); self.activityScoreDays.removeAll()
                    self.activityCoverageStart = nil; self.appNameCache.removeAll()
                    self.activityActionError = nil
                    self.cached.removeAll()
                    self.invalidateHistoryReads(clearRows: true)
                    self.completedPrimaryMetric = nil; self.completedKPMMetric = nil
                    self.consumedCompletionRevision = 0; self.completionPending = false
                    self.estimatedRhythm.reset(); self.lastEstimatedInputTime = nil; self.estimatedRhythmHasFreshInterval = false
                    self.estimatedRecentKPM = nil
                    self.resetTenMinuteWindow()
                    self.engine = StatisticsEngine(config: SegmentationConfig(maximumGap: self.maximumGap, ruleID: Self.rule(self.maximumGap, suspectedInputFiltering: self.suspectedInputFilteringEnabled, globalKeyboardCompatibility: self.globalKeyboardCompatibilityEnabled)), timeZone: .current)
                }
                self.clearing = false; self.refreshSnapshot(); self.loadHistory(days: self.historyDays)
                if self.activityVisible { self.loadActivity(day: self.activityDate) }
            }
        }
    }
}

/// Isolated integration test of coordinator → core → SQLite → restart. No global capture.
@MainActor func runAppModelChecks(settlementHandoffCheck: (@MainActor (AppModel) -> [String])? = nil) -> [String] {
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
    if populated.count != 1 || populated.first?.language != "mul" || populated.first?.keys != 13 || populated.first?.characters != 10 {
        failures.append("FAIL: combined-language history quantities")
    }
    if let row = populated.first, abs((row.cpm ?? 0) - 240) > 1e-3 {
        failures.append("FAIL: history CPM lost weighted real character batches while combining languages")
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
    failures += runFrozenSpeedVisibilityChecks()
    failures += runHybridMenuChecks()
    failures += runCombinedEstimateChecks()
    failures += runRollingEstimateChecks()
    failures += runHistoryProjectionChecks()
    failures += AppModel.runActivityIntegrationChecks()
    failures += AppModel.runRewardIntegrationChecks()
    failures += AppModel.runDailyRewardIntegrationChecks(settlementHandoffCheck: settlementHandoffCheck)
    return failures
}

private extension AppModel {
    static func runDailyRewardIntegrationChecks(settlementHandoffCheck: (@MainActor (AppModel) -> [String])?) -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-daily-reward-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append("FAIL: daily reward integration \(message)") }
        }
        func waitFor(_ condition: () -> Bool, _ message: String) {
            let limit = Date().addingTimeInterval(6)
            while !condition() && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            expect(condition(), message)
        }
        let calendar = Calendar.current, midnight = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight),
              let base = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday) else {
            return ["FAIL: daily reward integration calendar fixture"]
        }
        let model = AppModel(dataDirectory: directory, monitoringEnabled: false, perAppTracking: false)
        model.isPaused = false; model.excludedAppsText = ""; model.updateExclusions()
        model.rewardEngine = RewardEngine(coverageStart: base); model.rewardState = model.rewardEngine?.state
        model.dailyRewardEngine = DailyRewardEngine(coverageStart: base)
        model.dailyRewardState = model.dailyRewardEngine?.state
        let monotonic = ProcessInfo.processInfo.systemUptime - 40
        for index in 0..<100 {
            let offset = Double(index) / 5
            model.receive(ClassifiedInput(time: monotonic + offset, date: base.addingTimeInterval(offset), context: 8510,
                                          category: .textEntry, evidence: .probable, source: .global, language: "en",
                                          applicationID: "org.example.DailyRewardEditor", inputMethodID: "test.direct"))
        }
        let rewardDay = model.rewardDayKey(base)
        let measured = model.dailyRewardEngine?.state.days[rewardDay]
        guard let score = measured?.score, score > 0 else {
            model.flushBeforeExit()
            return ["FAIL: daily reward integration accepted metadata did not produce a score"]
        }
        expect(measured?.totals.keys == 100 && measured?.totals.consistency == 100,
               "accepted metadata supplies measured volume and pooled consistency")
        expect(model.dailyRewardEngine?.state.totalXP == 0, "live score does not prematurely credit lifetime XP")
        model.dailyRewardEngine?.advance(to: midnight); model.publishDailyRewards()
        expect(model.dailyRewardState?.days[rewardDay]?.sealed == true && model.dailyRewardState?.totalXP == 0 &&
               model.dailyRewardEngine?.unpersistedReceipts.isEmpty == true,
               "low-level day rollover seals before the coordinator commits XP")

        // Midnight can arrive while an older canonical checkpoint is queued.
        // Both writes must complete promptly, without opening any view.
        let writeGate = DispatchSemaphore(value: 0)
        model.diskQueue.async { _ = writeGate.wait(timeout: .now() + 8) }
        model.flush()
        expect(model.activeReceipt != nil, "fixture holds a real checkpoint in flight")
        model.handleRewardMidnight(at: midnight)
        expect(model.dailyRewardState?.totalXP == score && model.dailyRewardEngine?.unpersistedReceipts.count == 1,
               "awake midnight credits the ended day without a rest notification")
        expect(model.dailyRewardEngine?.unpersistedReceipts.first?.settledAt == midnight,
               "the midnight callback uses the reward-day boundary")
        var presentations = 0
        model.onSettlementAvailable = { if model.settlementReceipt != nil { presentations += 1 } }
        defer { model.onSettlementAvailable = nil }
        writeGate.signal()
        waitFor({ model.activeReceipt == nil && !model.dailyRewardsNeedSave }, "midnight receipt commits after the older write without a view")
        expect(model.settlementReceipt == nil && presentations == 0 && !model.settlementPresentationRequested,
               "midnight credits XP without interrupting the user with an animation")
        model.requestSettlementPresentation()
        waitFor({ model.settlementReceipt != nil }, "next opening presents the committed midnight receipt")
        expect(model.settlementReceipt?.day == rewardDay && model.settlementReceipt?.afterXP == score && presentations == 1,
               "popup receives the immutable settled-day balance")
        do {
            let db = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            let saved = try db.loadDailyRewardState(), unseen = try db.queryUnseenDailyRewardReceipts()
            expect(saved?.totalXP == score, "popup waits for the XP checkpoint to become durable")
            expect(unseen.count == 1, "popup waits for its receipt to become durable")
        } catch { failures.append("FAIL: daily reward integration durable popup: \(error.localizedDescription)") }

        failures += settlementHandoffCheck?(model) ?? []

        // Closing before an asynchronous read completes leaves the receipt
        // unseen and must not cause a late popup or acknowledgment.
        model.closeSettlementPresentation()
        let readGate = DispatchSemaphore(value: 0)
        model.diskQueue.async { _ = readGate.wait(timeout: .now() + 8) }
        model.requestSettlementPresentation()
        expect(model.settlementReadInFlight, "fixture starts an asynchronous queue read")
        model.closeSettlementPresentation(); readGate.signal()
        waitFor({ !model.settlementReadInFlight }, "cancelled presentation releases its read slot")
        expect(model.settlementReceipt == nil && presentations == 1 && model.dailyRewardState?.totalXP == score,
               "closed queue cannot publish a late popup or change XP")
        model.requestSettlementPresentation()
        waitFor({ model.settlementReceipt != nil }, "unseen receipt remains available after cancellation")
        model.acknowledgeSettlement()
        waitFor({ !model.settlementAcknowledging && !model.settlementReadInFlight && !model.settlementPresentationRequested },
                "acknowledgment drains the visible queue")
        expect(model.settlementReceipt == nil && model.dailyRewardState?.totalXP == score,
               "acknowledgment never awards the settled XP again")
        model.settleEndedDailyRewards(at: midnight.addingTimeInterval(120))
        expect(model.dailyRewardState?.totalXP == score && model.dailyRewardEngine?.unpersistedReceipts.isEmpty == true,
               "repeated lifecycle checks cannot double-credit XP")
        model.flushBeforeExit()
        let restored = AppModel(dataDirectory: directory, monitoringEnabled: false, perAppTracking: false)
        expect(restored.dailyRewardState?.totalXP == score && restored.dailyRewardState?.settledThroughDay == rewardDay,
               "restart preserves the credited balance and settlement watermark")
        do {
            let db = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            let unseen = try db.dailyRewardReceiptCount(), all = try db.dailyRewardReceiptCount(unseenOnly: false)
            expect(unseen == 0 && all == 1,
                   "restart preserves acknowledgment without deleting immutable history")
        } catch { failures.append("FAIL: daily reward integration restore: \(error.localizedDescription)") }
        restored.flushBeforeExit()

        // Missed midnight: an awake launch must catch up without a sleep event,
        // and the same open hook must also cover a delayed scheduler callback.
        let catchupDirectory = directory.appendingPathComponent("awake-catchup")
        do {
            var saved = DailyRewardState(coverageStart: base, progressionTimezone: calendar.timeZone.identifier,
                                         currentDay: rewardDay)
            saved.days[rewardDay] = measured; saved.revision = 1
            let db = try AggregateStore(url: catchupDirectory.appendingPathComponent("statistics.sqlite"))
            try db.save([], dailyRewards: DailyRewardWrite(state: saved), batchID: "before-missed-midnight")
            let catchup = AppModel(dataDirectory: catchupDirectory, monitoringEnabled: false, perAppTracking: false)
            expect(catchup.dailyRewardState?.totalXP == score && catchup.settlementReceipt == nil,
                   "awake startup credits overdue XP without presenting an animation")
            catchup.requestSettlementPresentation()
            waitFor({ catchup.activeReceipt == nil && catchup.settlementReceipt != nil }, "startup receipt presents after persistence on opening")
            catchup.closeSettlementPresentation(); catchup.flushBeforeExit()

            let openOnly = AppModel(dataDirectory: directory.appendingPathComponent("open-catchup"), monitoringEnabled: false, perAppTracking: false)
            saved.revision = 0
            openOnly.dailyRewardEngine = try DailyRewardEngine(restoring: saved, now: Date())
            openOnly.dailyRewardState = openOnly.dailyRewardEngine?.state
            let openGate = DispatchSemaphore(value: 0)
            openOnly.diskQueue.async { _ = openGate.wait(timeout: .now() + 8) }
            openOnly.requestSettlementPresentation()
            expect(openOnly.dailyRewardState?.totalXP == score && openOnly.settlementReceipt == nil,
                   "opening catches up a missed midnight and waits for a durable receipt")
            openGate.signal()
            waitFor({ openOnly.settlementReceipt != nil }, "opening presents its overdue receipt without sleep")
            openOnly.requestSettlementPresentation()
            expect(openOnly.dailyRewardState?.totalXP == score, "repeated opening cannot re-award overdue XP")
            openOnly.closeSettlementPresentation(); openOnly.flushBeforeExit()
        } catch { failures.append("FAIL: daily reward integration awake catch-up: \(error.localizedDescription)") }
        return failures
    }

    static func runRewardIntegrationChecks() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-reward-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append("FAIL: reward integration \(name)") }
        }
        func waitFor(_ condition: () -> Bool, _ name: String) {
            let until = Date().addingTimeInterval(6)
            while !condition() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            expect(condition(), name)
        }
        let base = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let monotonic = ProcessInfo.processInfo.systemUptime
        func event(_ index: Int, start: Double = 0) -> ClassifiedInput {
            let offset = start + Double(index) / 5
            return ClassifiedInput(time: monotonic + offset, date: base.addingTimeInterval(offset), context: 7201,
                                   category: .textEntry, evidence: .probable, source: .global,
                                   language: "en", applicationID: "org.example.RewardEditor",
                                   inputMethodID: "test.direct", usesInputMethod: false)
        }
        let model = AppModel(dataDirectory: directory, monitoringEnabled: false, perAppTracking: true)
        model.isPaused = false
        model.rewardEngine = RewardEngine(coverageStart: base); model.rewardState = model.rewardEngine?.state
        model.loadActivity(day: base)
        for i in 0..<60 { model.receive(event(i)) }
        model.flush()
        // Export requested behind a live write must include this newer prefix,
        // not merely the transaction that was already in flight.
        for i in 60..<100 { model.receive(event(i)) }
        let export = directory.appendingPathComponent("rewards.csv")
        model.rewardExportURL = export; model.rewardExportRevision = (model.rewardEngine?.state.revision ?? 0) + 1
        model.finishRewardExportIfReady()
        waitFor({ model.activeReceipt == nil && model.rewardExportURL == nil && FileManager.default.fileExists(atPath: export.path) },
                "export barrier persists the requested prefix")
        waitFor({ !model.activityLoading }, "activity reward read completes")
        model.refreshSnapshot()
        let score = model.rewardState?.lifetimeScore.total ?? 0
        expect(abs(score - 0.9293458663450304) < 1e-6, "canonical100-key fixture agrees with UI state")
        expect(model.rewardState?.xpProgress.eligibleKeys == 100 && model.rewardState?.xpProgress.totalXP == 0,
               "XP counts accepted keys independently without early thresholds")
        expect(abs((model.rewardState?.xpProgress.eligibleSeconds ?? 0) - 19.8) < 1e-6,
               "only accepted measured intervals enter progression")
        let session = model.activitySessions.first?.id
        expect(abs((model.rewardPoints(sessionID: session) ?? 0) - score) < 1e-6,
               "session award attribution survives successful checkpoint drain and async read")
        model.loadActivity(day: base)
        waitFor({ !model.activityLoading }, "award reload completes")
        expect(abs((model.rewardPoints(sessionID: session) ?? 0) - score) < 1e-6,
               "reloading does not duplicate or drop award attribution")
        do {
            let db = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            let saved = try db.loadRewardState()
            expect(saved?.xpProgress.eligibleKeys == 100, "export waited for the100-key checkpoint")
            let csv = try String(contentsOf: export)
            expect(csv.contains("score-v2") && csv.contains("xp-v1") && csv.contains("coverage"), "separate export exposes policies and coverage")
        } catch { failures.append("FAIL: reward integration export: \(error.localizedDescription)") }
        model.interruptEngine()
        for i in 0..<30 { model.receive(event(i, start: 40)) }
        model.flushBeforeExit()
        let restarted = AppModel(dataDirectory: directory, monitoringEnabled: false, perAppTracking: false)
        restarted.isPaused = false
        let before = restarted.rewardEngine!.state
        restarted.receive(event(0, start: 500))
        restarted.refreshSnapshot()
        expect(restarted.rewardState?.xpProgress.eligibleKeys == 131 && restarted.rewardState?.pendingBlockKeys == 31,
               "incomplete100-key block survives restart")
        expect(abs((restarted.rewardState?.xpProgress.eligibleSeconds ?? 0) - before.xpProgress.eligibleSeconds) < 1e-6,
               "restart first key earns volume without bridging old timing")
        restarted.clearAppActivity()
        waitFor({ !restarted.clearingAppActivity }, "app-only clear completes")
        expect(restarted.rewardEngine!.state.xpProgress.eligibleKeys == 131, "app-only deletion preserves global progression")
        restarted.clearHistory()
        waitFor({ !restarted.clearing }, "full clear completes")
        expect(restarted.rewardState?.lifetimeScore.total == 0 && restarted.rewardState?.xpProgress.totalXP == 0 &&
               restarted.durableRewardRevision == 0 && restarted.rewardReadOverlay.isEmpty,
               "full clear resets progression, export barriers and claim state")
        restarted.flushBeforeExit(); model.releaseActivity()

        // Published reward values must update on the existing UI snapshot,
        // before a disk checkpoint or the end of a reward day. The selected
        // date and lifetime XP are deliberately checked as separate values.
        let live = AppModel(dataDirectory: directory.appendingPathComponent("live-publication"),
                            monitoringEnabled: false, perAppTracking: false)
        live.isPaused = false; live.activityDate = base
        live.rewardEngine = RewardEngine(coverageStart: base); live.rewardState = live.rewardEngine?.state
        for index in 0..<1_500 { live.receive(event(index)) }
        live.refreshSnapshot(at: monotonic + 299.8)
        let beforeTimeThreshold = live.selectedRewardDay?.components.total ?? 0
        expect(beforeTimeThreshold > 0 && live.selectedRewardDay?.xp.total == 0 &&
               live.rewardState?.xpProgress.totalXP == 0,
               "live score accrues independently before the first whole XP")
        expect(live.durableRewardRevision == 0 && live.activeReceipt == nil,
               "live reward cards do not wait for a persistence checkpoint")
        live.receive(event(1_500))
        live.refreshSnapshot(at: monotonic + 300)
        expect(live.selectedRewardDay?.xp.time == 1 && live.selectedRewardDay?.xp.total == 1 &&
               live.rewardState?.xpProgress.totalXP == 1,
               "300 measured seconds immediately publish daily and lifetime time XP")
        for index in 1_501..<1_999 { live.receive(event(index)) }
        live.refreshSnapshot(at: monotonic + 399.6)
        expect(live.rewardState?.xpProgress.eligibleKeys == 1_999 &&
               live.selectedRewardDay?.xp.volume == 0 && live.rewardState?.xpProgress.totalXP == 1,
               "volume progress remains distinct from already awarded time XP")
        live.receive(event(1_999))
        live.refreshSnapshot(at: monotonic + 399.8)
        expect(live.selectedRewardDay?.xp.volume == 1 && live.selectedRewardDay?.xp.total == 2 &&
               live.rewardState?.xpProgress.totalXP == 2,
               "2000 accepted keys immediately publish daily and lifetime volume XP")
        expect(live.rewardState?.xpProgress.improvementXP == 0,
               "a fresh burst cannot award personal-improvement XP")
        let frozenScore = live.selectedRewardDay?.components.total
        let frozenXP = live.rewardState?.xpProgress.totalXP
        live.refreshSnapshot(at: monotonic + 429.8)
        expect(live.selectedRewardDay?.components.total == frozenScore &&
               live.rewardState?.xpProgress.totalXP == frozenXP,
               "idle publication adds neither score nor XP")
        live.activityDate = Calendar.current.date(byAdding: .day, value: -1, to: base)!
        expect(live.selectedRewardDay == nil && live.rewardState?.xpProgress.totalXP == 2,
               "uncovered historical dates never borrow today's XP gained")
        live.flushBeforeExit()

        let capacity = AppModel(dataDirectory: directory.appendingPathComponent("capacity"), monitoringEnabled: false, perAppTracking: false)
        capacity.isPaused = false; capacity.rewardEngine = RewardEngine(coverageStart: base)
        let hour = Calendar.current.dateInterval(of: .hour, for: base)!
        for index in 0..<512 {
            let row = HourlyActivity(bucketStart: hour.start, bucketEnd: hour.end, timezone: TimeZone.current.identifier,
                                     rule: "capacity-padding-\(index)")
            capacity.pendingActivity.hourly[row.id] = row
        }
        capacity.receive(event(0))
        if let batch = capacity.inFlightWrite {
            expect(batch.rows.reduce(0) { $0 + $1.keys } == 1 &&
                   batch.activity.hourly.filter { $0.applicationID.isEmpty }.reduce(0) { $0 + $1.totals.keys } == 1 &&
                   batch.rewards?.state.xpProgress.eligibleKeys == 1,
                   "capacity flush waits for every stream of the canonical event")
        } else { failures.append("FAIL: reward integration capacity checkpoint missing") }
        waitFor({ capacity.activeReceipt == nil }, "capacity checkpoint completes")
        capacity.flushBeforeExit()
        return failures
    }
    /// Exercises asynchronous snapshots against a real isolated SQLite store.
    /// No events are posted, no global capture starts, and user prefs stay intact.
    static func runActivityIntegrationChecks() -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-activity-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = [String]()
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append("FAIL: activity integration \(message)") }
        }
        let model = AppModel(dataDirectory: directory, monitoringEnabled: false, perAppTracking: true)
        model.isPaused = false; model.excludedAppsText = ""; model.updateExclusions()
        let time = ProcessInfo.processInfo.systemUptime
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func type(_ range: Range<Int>, source: InputSource = .global) {
            for index in range {
                let offset = Double(index) * 0.2
                model.receive(ClassifiedInput(time: time + offset, date: date.addingTimeInterval(offset), context: 4001,
                                              category: .textEntry, evidence: source == .global ? .probable : .confirmed,
                                              source: source, operationID: UInt64(index + 100), language: "en",
                                              committedCharacters: source == .adapter ? 1 : nil,
                                              applicationID: "org.example.CapturedEditor"))
            }
        }
        func waitFor(_ condition: () -> Bool, _ message: String) {
            let limit = Date().addingTimeInterval(5)
            while !condition() && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            expect(condition(), message)
        }
        // Aggregate deltas arriving during an asynchronous disk read must be
        // overlaid once, even when a later transaction persists them.
        type(0..<31)
        model.loadActivity(day: date)
        type(31..<51)
        model.flush()
        waitFor({ !model.activityLoading && model.activeReceipt == nil }, "read/write completed")
        model.refreshSnapshot()
        var combined = model.activityHourly.filter { $0.applicationID.isEmpty }.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
        expect(combined.keys == 51 && abs(combined.intervals - 50) < 1e-6 && abs(combined.seconds - 10) < 1e-4,
               "in-flight read overlay neither doubles nor drops deltas")
        expect(abs((combined.wpm ?? 0) - 60) < 1e-3 && combined.score != nil, "weighted WPM and sufficient score")
        expect(combined.rateConsistency.count == 10 && combined.rateConsistency.intervals == 49 && combined.consistency == 100,
               "complete second samples survive the asynchronous read/write overlay")
        expect(combined.score?.consistency == combined.legacyIntervalConsistency,
               "standalone rate consistency does not change the pending score formula")
        let initialRateMoments = combined.rateConsistency
        expect(model.activityHourly.contains { $0.applicationID == "org.example.CapturedEditor" && $0.totals.keys == 51 && $0.totals.rateConsistency == initialRateMoments },
               "original event application attributed")
        expect(model.activitySessions.count == 1 && model.activitySessions.first?.totals.keys == 51 &&
               model.activitySessions.first?.totals.rateConsistency == initialRateMoments,
               "one absolute session checkpoint")
        // A subsequent confirmed adapter lane must never enter practice stats.
        type(50..<55, source: .adapter)
        model.refreshSnapshot()
        expect(model.activityHourly.filter { $0.applicationID.isEmpty }.reduce(0) { $0 + $1.totals.keys } == 51,
               "confirmed validation lane excluded")
        model.loadActivity(day: date.addingTimeInterval(-86400)); model.loadActivity(day: date)
        waitFor({ !model.activityLoading }, "latest date selection wins")
        expect(model.activityHourly.filter { $0.applicationID.isEmpty }.reduce(0) { $0 + $1.totals.keys } == 51,
               "stale read cannot publish another day")
        type(60..<65); model.flush()
        model.clearAppActivity()
        type(65..<70); model.flush()
        waitFor({ !model.clearingAppActivity && model.activeReceipt == nil && !model.activityLoading }, "app-only clear completed")
        model.flushBeforeExit()
        do {
            let database = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            let start = Calendar.current.startOfDay(for: date), end = start.addingTimeInterval(86400)
            let rows = try database.queryHourly(since: start, until: end, includeApplications: true)
            combined = rows.filter { $0.applicationID.isEmpty }.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
            expect(rows.allSatisfy { $0.applicationID.isEmpty } && combined.keys == 61,
                   "app deletion survives in-flight saves and keeps combined totals")
            expect(combined.rateConsistency.count >= initialRateMoments.count && combined.consistency != nil,
                   "new consistency moments survive persistence and app-only deletion")
            let savedSessions = try database.querySessions(since: start, until: end)
            expect(savedSessions.reduce(0) { $0 + $1.totals.keys } == 61,
                   "app-only deletion preserves sessions")
            expect(savedSessions.reduce(into: RhythmTotals()) { $0.merge($1.totals) }.rateConsistency == combined.rateConsistency,
                   "hourly and session rate moments agree after restart")
        } catch { failures.append("FAIL: activity integration store read: \(error.localizedDescription)") }
        model.clearHistory(); model.flush(); model.clearHistory(); model.flushBeforeExit()
        do {
            let database = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
            let clearedHours = try database.queryHourly(since: date.addingTimeInterval(-86400), until: date.addingTimeInterval(86400), includeApplications: true)
            let clearedSessions = try database.querySessions(since: date.addingTimeInterval(-86400), until: date.addingTimeInterval(86400))
            expect(clearedHours.isEmpty,
                   "full clear/quit cannot resurrect hourly data")
            expect(clearedSessions.isEmpty,
                   "full clear/quit cannot resurrect sessions")
        } catch { failures.append("FAIL: activity integration clear read: \(error.localizedDescription)") }
        let offDirectory = directory.appendingPathComponent("opt-out")
        let off = AppModel(dataDirectory: offDirectory, monitoringEnabled: false, perAppTracking: false)
        off.isPaused = false
        off.receive(ClassifiedInput(time: time, date: date, context: 5001, category: .textEntry, evidence: .probable,
                                    source: .global, language: "zh", applicationID: "org.example.NeverPersist"))
        off.flushBeforeExit()
        do {
            let database = try AggregateStore(url: offDirectory.appendingPathComponent("statistics.sqlite"))
            let rows = try database.queryHourly(since: date.addingTimeInterval(-86400), until: date.addingTimeInterval(86400), includeApplications: true)
            expect(rows.count == 1 && rows[0].applicationID.isEmpty && rows[0].totals.keys == 1 && rows[0].totals.wpm == nil,
                   "opt-out saves no app IDs and isolated key creates no rate")
        } catch { failures.append("FAIL: activity integration opt-out read: \(error.localizedDescription)") }
        let day = Calendar.current.startOfDay(for: date)
        off.activityVisible = true; off.activityDate = day
        off.mergeLoadedActivity(ActivityBatch(sessions: [
            TypingSession(id: "prior-day", start: day.addingTimeInterval(-1), end: day,
                          timezone: TimeZone.current.identifier, rule: off.activityCurrentRule, totals: RhythmTotals(keys: 2), endReason: "dayBoundary"),
            TypingSession(id: "midnight-point", start: day, end: day,
                          timezone: TimeZone.current.identifier, rule: off.activityCurrentRule, totals: RhythmTotals(keys: 1))
        ]))
        off.publishActivitySnapshot()
        expect(off.activitySessions.map(\.id) == ["midnight-point"], "midnight overlay uses half-open session range")
        off.releaseActivity()

        let bilingual = AppModel(dataDirectory: directory.appendingPathComponent("bilingual"), monitoringEnabled: false, perAppTracking: false)
        bilingual.isPaused = false
        for (start, language, context) in [(0, "en", UInt64(6001)), (10, "zh", UInt64(6002))] {
            if start > 0 { bilingual.interruptEngine() }
            for index in 0..<5 {
                let offset = Double(start) + Double(index) * 0.2
                bilingual.receive(ClassifiedInput(time: time + offset, date: date.addingTimeInterval(offset), context: context,
                                                  category: language == "zh" ? .composition : .textEntry,
                                                  evidence: .probable, source: .global, language: language))
            }
        }
        bilingual.flushBeforeExit()
        do {
            let database = try AggregateStore(url: directory.appendingPathComponent("bilingual/statistics.sqlite"))
            let rows = try database.queryHourly(since: day, until: day.addingTimeInterval(86400))
            let totals = rows.reduce(into: RhythmTotals()) { $0.merge($1.totals) }
            let sessions = try database.querySessions(since: day, until: day.addingTimeInterval(86400))
            expect(totals.keys == 10 && abs(totals.intervals - 8) < 1e-9 && abs(totals.seconds - 1.6) < 1e-4 &&
                   abs((totals.wpm ?? 0) - 60) < 1e-3 && sessions.count == 1 && sessions[0].totals.keys == 10,
                   "bilingual source boundary combines session quantities without timing the switch")
        } catch { failures.append("FAIL: activity integration bilingual read: \(error.localizedDescription)") }
        model.releaseActivity()
        return failures
    }
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
    let now = ProcessInfo.processInfo.systemUptime, date = Date()
    var failures = [String]()
    func expect(_ value: @autoclosure () -> Bool, _ name: String) { if !value() { failures.append("FAIL: current menu \(name)") } }
    func type(_ offsets: [Double], language: String, evidence: Evidence = .probable) {
        for offset in offsets {
            model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: 881,
                                                       category: .textEntry, evidence: evidence,
                                                       source: evidence == .confirmed ? .adapter : .global,
                                                       language: language, committedCharacters: evidence == .confirmed ? 1 : nil))
        }
        model.refreshSnapshot()
    }
    model.updateInputSource(english)
    type([0, 0.2, 0.4, 0.6, 0.8], language: "en")
    expect(model.completedPrimaryMetric == nil && abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && model.selectedMenuSpeed.unit == "WPM",
           "shows live estimated WPM before the input segment completes")
    let quantity = model.dailyEstimate
    model.updateInputSource(chinese); model.refreshSnapshot()
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && model.probable.language == "mul" && model.dailyEstimate == quantity,
           "source switch retains combined WPM without adding keys or timing")
    type([1], language: "zh")
    expect(model.dailyEstimate.keys == 6 && abs(model.dailyEstimate.intervals - 4) < 1e-9 && abs(model.dailyEstimate.seconds - 0.8) < 1e-6,
           "first Chinese key does not bridge the source boundary")
    type([1.5, 2, 2.5, 3], language: "zh")
    let mergedKPM = 60 * 8 / 2.8
    expect(model.probable.keys == 10 && abs((model.probable.kpm ?? 0) - mergedKPM) < 1e-3 && abs((model.selectedMenuSpeed.value ?? 0) - mergedKPM / 5) < 1e-3,
           "combines English and Chinese accepted intervals with duration weighting")
    model.updateInputSource(english); model.refreshSnapshot()
    expect(abs((model.selectedMenuSpeed.value ?? 0) - mergedKPM / 5) < 1e-3,
           "language round trip does not erase the combined primary rate")
    model.updateInputSource(chinese)
    type([10, 10.2, 10.4, 10.6, 10.8], language: "zh", evidence: .confirmed)
    expect(model.selectedMenuMetric.primaryUnit == .cpm && abs((model.selectedMenuMetric.primaryRate ?? 0) - 300) < 1e-3,
           "confirmed validation metadata retains actual CPM")
    expect(model.selectedMenuSpeed.unit == "WPM" && model.selectedMenuSpeed.estimated && abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3,
           "confirmed Chinese menu uses estimated operation WPM")
    let confirmedStatistics = MenuSpeedDisplay(metric: model.confirmed, evidence: .confirmed)
    expect(confirmedStatistics.unit == "CPM" && !confirmedStatistics.estimated && abs((confirmedStatistics.value ?? 0) - 300) < 1e-3,
           "unified menu WPM preserves the confirmed statistics CPM default")
    let characterOnly = MetricDisplay(language: "zh", cpm: 600)
    let characterOnlyMenu = MenuSpeedDisplay(metric: characterOnly, evidence: .confirmed, forceEstimatedWPM: true)
    expect(characterOnlyMenu.unit == "WPM" && characterOnlyMenu.estimated && characterOnlyMenu.value == nil,
           "never fabricates WPM from character-only samples")
    var alternateMode = chinese; alternateMode.modeIdentifier = "latin"
    model.updateInputSource(alternateMode); model.refreshSnapshot()
    expect(model.selectedMenuMetric.primaryRate == nil && model.selectedMenuMetric.kpm == nil,
           "confirmed character coverage does not leak across IME modes")
    model.flushBeforeExit()
    return failures
}

/// A real focus/command boundary must end timing without erasing the rate the
/// user is about to inspect. All source/capability metadata is scripted here.
@MainActor private func runFrozenSpeedVisibilityChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-frozen-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false; model.menuDisplay = "speed"
    model.excludedAppsText = ""; model.updateExclusions()
    let chinese = InputLanguages.Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
    let english = InputLanguages.Source(identifier: "test.abc", modeIdentifier: "", name: "ABC", languageCode: "en", inputMethod: false)
    let now = ProcessInfo.processInfo.systemUptime, date = Date()
    var failures = [String]()
    func expect(_ value: @autoclosure () -> Bool, _ name: String) { if !value() { failures.append("FAIL: frozen speed \(name)") } }
    func type(from start: Double, context: UInt64, evidence: Evidence = .probable) {
        for index in 0..<5 {
            let offset = start + Double(index) * 0.2
            model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: context,
                                                       category: .textEntry, evidence: evidence,
                                                       source: evidence == .probable ? .global : .adapter,
                                                       operationID: UInt64((offset * 1000).rounded()), language: "zh",
                                                       committedCharacters: evidence == .confirmed ? 1 : nil))
        }
        model.refreshSnapshot()
    }
    model.updateInputSource(chinese)
    type(from: 0, context: 981)
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && !model.selectedSpeedIsRecent, "live Chinese WPM starts current")
    let seconds = model.dailyEstimate.seconds
    for reason in ["前台应用已变化", "焦点已变化", "快捷命令", "光标导航", "未知输入上下文"] {
        model.handleMonitoringInterruption(reason, capabilitiesAvailable: true, source: chinese)
        model.refreshSnapshot()
        expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && abs((model.probable.kpm ?? 0) - 300) < 1e-3 && model.selectedSpeedIsRecent,
               "same-source inspection and boundary retain clearly recent primary rate")
        expect(model.dailyEstimate.keys == 5 && abs(model.dailyEstimate.seconds - seconds) < 1e-9, "inspection never adds count or waiting time")
    }
    model.menuDisplay = "kpm"
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 300) < 1e-3 && model.selectedSpeedIsRecent, "optional KPM remains frozen too")
    model.menuDisplay = "speed"
    type(from: 10, context: 982)
    expect(model.dailyEstimate.keys == 10 && abs(model.dailyEstimate.intervals - 8) < 1e-9 && abs(model.dailyEstimate.seconds - 1.6) < 1e-6,
           "next context is a distinct segment without a timing bridge")
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && !model.recentSpeedIsFrozen, "new accepted burst resumes current presentation")
    model.updateInputSource(english); model.refreshSnapshot()
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && abs((model.estimatedRecentKPM ?? 0) - 300) < 1e-3,
           "source change retains combined primary and KPM without bridging statistics")
    model.updateInputSource(chinese); model.refreshSnapshot()
    model.handleMonitoringInterruption("焦点已变化", capabilitiesAvailable: true, source: chinese); model.refreshSnapshot()
    expect(abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3, "source round trip keeps the merged recent estimate")
    type(from: 20, context: 983)
    model.handleMonitoringInterruption("系统权限不可用", capabilitiesAvailable: false, source: chinese); model.refreshSnapshot()
    expect(model.selectedMenuSpeed.value == nil && model.estimatedRecentKPM == nil, "lost capabilities clear the retained rate")
    type(from: 30, context: 984, evidence: .confirmed)
    expect(model.selectedMenuSpeed.unit == "WPM" && model.selectedMenuSpeed.estimated && abs((model.selectedMenuSpeed.value ?? 0) - 60) < 1e-3 && abs((model.confirmed.cpm ?? 0) - 300) < 1e-3,
           "confirmed adapter menu uses estimated WPM while its actual CPM remains available")
    model.handleMonitoringInterruption("前台应用已变化", capabilitiesAvailable: true, source: chinese); model.refreshSnapshot()
    expect(model.selectedMenuSpeed.value == nil, "confirmed editor rate is not carried into another app")
    expect(AppModel.rule(3) == "adaptive-v4-no-space-ime-quality-on-max3.0" && AppModel.rule(3, globalKeyboardCompatibility: true).hasSuffix("-keyboard-fallback"),
           "Global keyboard fallback has a separate rule without rewriting ordinary or Chinese-only history")
    func deliverSourceEvent(_ offset: Double, language: String) {
        model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset),
            context: 985, category: .textEntry, evidence: .probable, source: .global, language: language))
        model.refreshSnapshot()
    }
    model.updateInputSource(english)
    deliverSourceEvent(40, language: "en")
    deliverSourceEvent(40.2, language: "en")
    let beforeSourceLabel = model.dailyEstimate
    model.updateInputSource(chinese, interrupting: false)
    deliverSourceEvent(40.4, language: "en")
    expect(model.dailyEstimate.keys == beforeSourceLabel.keys + 1 &&
           abs(model.dailyEstimate.intervals - beforeSourceLabel.intervals - 1) < 1e-9 &&
           abs(model.dailyEstimate.seconds - beforeSourceLabel.seconds - 0.2) < 1e-6,
           "early source-label notification preserves the captured old-source prefix and its interval")
    model.handleMonitoringInterruption("输入源已变化", capabilitiesAvailable: true, source: chinese)
    let beforeSourceBoundary = model.dailyEstimate
    deliverSourceEvent(41, language: "zh")
    expect(model.dailyEstimate.keys == beforeSourceBoundary.keys + 1 &&
           model.dailyEstimate.intervals == beforeSourceBoundary.intervals,
           "ordered capture handoff interrupts timing only after the previous source prefix is delivered")
    model.flushBeforeExit()
    return failures
}

/// Display transitions use scripted monotonic time. Statistical durations only
/// change when the core accepts real intervals, including across short segments.
@MainActor private func runHybridMenuChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-hybrid-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false; model.menuDisplay = "hybrid"
    model.excludedAppsText = ""; model.updateExclusions()
    let chinese = InputLanguages.Source(identifier: "test.pinyin", modeIdentifier: "pinyin", name: "Pinyin", languageCode: "zh", inputMethod: true)
    let english = InputLanguages.Source(identifier: "test.abc", modeIdentifier: "", name: "ABC", languageCode: "en", inputMethod: false)
    let now = ProcessInfo.processInfo.systemUptime, date = Date(), grace = model.hybridIdleGrace
    var failures = [String]()
    func expect(_ value: @autoclosure () -> Bool, _ name: String) { if !value() { failures.append("FAIL: hybrid menu \(name)") } }
    func display(_ offset: Double, available: Bool = true) -> HybridMenuDisplay {
        model.hybridMenuDisplayIfAvailable(at: now + offset, capabilitiesAvailable: available)
    }
    func hasRate(_ offset: Double, _ expected: Double = 60) -> Bool {
        guard case let .wpm(value) = display(offset), let value else { return false }
        return abs(value - expected) < 1e-3
    }
    func type(_ offsets: [Double], context: UInt64 = 991, language: String = "zh", evidence: Evidence = .probable) {
        for offset in offsets {
            model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset), context: context,
                                                       category: .textEntry, evidence: evidence,
                                                       source: evidence == .probable ? .global : .adapter,
                                                       language: language, committedCharacters: evidence == .confirmed ? 2 : nil))
        }
        if let last = offsets.last { model.refreshSnapshot(at: now + last) }
    }
    expect(display(0) == .count, "no input starts in daily-count mode")
    model.updateInputSource(chinese)
    type([0])
    expect(display(0) == .wpm(nil) && model.dailyEstimate.keys == 1 && model.dailyEstimate.seconds == 0,
           "first accepted key immediately enters WPM placeholder without a fabricated rate")
    type([0.2, 0.4, 0.6, 0.8])
    expect(hasRate(0.8) && model.dailyEstimate.keys == 5 && abs(model.dailyEstimate.seconds - 0.8) < 1e-6,
           "five Chinese keys produce 60 WPM from four real intervals")
    let quantity = model.dailyEstimate
    model.refreshSnapshot(at: now + 0.8 + grace - 0.001)
    expect(hasRate(0.8 + grace - 0.001) && model.isUIRefreshScheduled,
           "adaptive phase idle does not prematurely end WPM display or its bounded timer")
    model.refreshSnapshot(at: now + 0.8 + grace)
    expect(display(0.8 + grace) == .wpm(nil) && model.isUIRefreshScheduled,
           "full-stop boundary begins the three-second empty WPM display")
    model.refreshSnapshot(at: now + 0.8 + grace + 2.999)
    expect(display(0.8 + grace + 2.999) == .wpm(nil), "placeholder lasts the full three seconds")
    model.refreshSnapshot(at: now + 0.8 + grace + 3)
    expect(display(0.8 + grace + 3) == .count && !model.isUIRefreshScheduled,
           "placeholder deadline switches to daily count and stops the UI timer")
    expect(model.dailyEstimate == quantity, "all waiting leaves cumulative count, intervals and duration unchanged")

    let restart = 0.8 + grace + 3.2
    type([restart], context: 992)
    expect(display(restart) == .wpm(nil) && model.isUIRefreshScheduled,
           "new input cancels count mode immediately without reviving an old rate")
    type((1...4).map { restart + Double($0) * 0.2 }, context: 992)
    var last = restart + 0.8
    expect(hasRate(last), "fresh restart samples restore measured WPM")
    let restartQuantity = model.dailyEstimate
    model.refreshSnapshot(at: now + last + grace + 1)
    expect(display(last + grace + 1) == .wpm(nil), "stopped restart enters placeholder")
    last += grace + 1.2
    type([last], context: 993)
    expect(display(last) == .wpm(nil), "input during placeholder cancels its old return deadline")
    type((1...4).map { last + Double($0) * 0.2 }, context: 993)
    last += 0.8
    expect(hasRate(last) && model.dailyEstimate.keys == restartQuantity.keys + 5,
           "resumed placeholder input becomes a fresh measured burst")

    for reason in ["焦点已变化", "AX 查询失败", "未知输入上下文", "光标导航", "快捷命令"] {
        let before = model.dailyEstimate
        model.handleMonitoringInterruption(reason, capabilitiesAvailable: true, source: chinese)
        model.refreshSnapshot(at: now + last + 0.05)
        expect(hasRate(last + 0.05) && model.dailyEstimate == before,
               "\(reason) keeps recent WPM without counting operation time")
        last += 0.2
        type([last], context: UInt64(1_000 + model.dailyEstimate.keys))
        expect(hasRate(last), "same-language restart candidate retains usable measured WPM")
    }
    let beforeSource = model.dailyEstimate
    model.updateInputSource(english); model.refreshSnapshot(at: now + last + 0.05)
    expect(hasRate(last + 0.05), "language switch retains combined WPM display")
    last += 0.2
    type([last], context: 1006, language: "en")
    expect(hasRate(last) && model.dailyEstimate.keys == beforeSource.keys + 1 && model.dailyEstimate.intervals == beforeSource.intervals && model.dailyEstimate.seconds == beforeSource.seconds,
           "new language joins display while first source key adds no timing bridge")
    expect(display(last, available: false) == .count, "unavailable capabilities show daily count")
    model.isPaused = true
    expect(display(last) == .count, "pause shows daily count")
    model.isPaused = false

    // Start with no usable rate, then reset context before any individual
    // segment reaches the four-interval display minimum. Accepted intervals
    // across those segments must still accumulate a usable combined estimate.
    model.handleMonitoringInterruption("输入监控权限不可用", capabilitiesAvailable: false, source: english)
    expect(display(last) == .count, "permission loss clears display activity rather than reviving it later")
    last += 1
    var acceptedSegments = model.dailyEstimate
    for index in 0..<3 {
        if index > 0 { model.handleMonitoringInterruption("AX 查询暂不可用", capabilitiesAvailable: true, source: english) }
        type([last, last + 0.2, last + 0.4], context: UInt64(1100 + index), language: "en")
        last += 0.4
        expect(model.phase == "typing" && (index == 0 ? display(last) == .wpm(nil) : hasRate(last)),
               "short repeatedly revalidated segments build a rate from accepted intervals only")
        last += 0.2
    }
    last -= 0.2
    expect(model.dailyEstimate.keys == acceptedSegments.keys + 9 && abs(model.dailyEstimate.intervals - acceptedSegments.intervals - 6) < 1e-9 && abs(model.dailyEstimate.seconds - acceptedSegments.seconds - 1.2) < 1e-6,
           "context revalidation never bridges the gaps between short segments")
    acceptedSegments = model.dailyEstimate
    model.receiveConfirmedInput(ClassifiedInput(time: now + last + 0.1, date: date.addingTimeInterval(last + 0.1), context: 1103,
                                               category: .command, evidence: .unknown, source: .global, language: "en"))
    model.refreshSnapshot(at: now + last + 0.1)
    expect(model.dailyEstimate.keys == acceptedSegments.keys && model.dailyEstimate.intervals == acceptedSegments.intervals && model.dailyEstimate.seconds == acceptedSegments.seconds && display(last + grace) == .wpm(nil) && display(last + grace + 3) == .count,
           "excluded commands do not extend accepted-input activity or add duration")
    model.handleMonitoringStatus("应用已排除")
    expect(display(last + 0.1) == .count && model.dailyEstimate.keys == acceptedSegments.keys && model.dailyEstimate.intervals == acceptedSegments.intervals && model.dailyEstimate.seconds == acceptedSegments.seconds,
           "resolved excluded-app status clears WPM even without a subsequent key")
    for mode in ["speed", "kpm", "count", "icon"] {
        model.menuDisplay = mode
        let expected = model.selectedMenuSpeed
        model.menuDisplay = "hybrid"; model.menuDisplay = mode
        expect(model.selectedMenuSpeed == expected && !model.hybridMenuNeedsUI(at: now + last), "existing \(mode) selection does not acquire a hybrid idle timer")
    }
    model.menuDisplay = "hybrid"
    model.updateInputSource(chinese)
    last += grace + 4
    type([last], context: 1200, evidence: .confirmed)
    expect(display(last) == .wpm(nil), "confirmed evidence cannot reuse global estimator samples")
    type((1...4).map { last + Double($0) * 0.2 }, context: 1200, evidence: .confirmed)
    last += 0.8
    expect(hasRate(last) && abs((model.confirmed.cpm ?? 0) - 600) < 1e-3,
           "confirmed hybrid uses operation WPM while real character CPM stays independent")
    model.interruptConfirmed()
    expect(display(last) == .count, "leaving the confirmed input context clears its display activity")
    model.flushBeforeExit()
    return failures
}

/// Global quantities, KPM and primary WPM combine accepted probable intervals
/// across languages. Confirmed validation stays in its separate evidence lane.
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
    if model.dailyEstimate.keys != 10 || model.probable.keys != 10 || abs((model.dailyEstimate.todayKPM ?? 0) - 200) > 1e-3 || abs((model.estimatedRecentKPM ?? 0) - 200) > 1e-3 {
        failures.append("FAIL: English and Chinese counts/KPM were not combined with interval weighting")
    }
    if abs((model.selectedMenuMetric.kpm ?? 0) - 200) > 1e-3 {
        failures.append("FAIL: KPM menu did not use the combined global estimate")
    }
    model.menuDisplay = "speed"
    if model.selectedMenuMetric.primaryUnit != .wpm || abs((model.selectedMenuMetric.primaryRate ?? 0) - 40) > 1e-3 {
        failures.append("FAIL: combined primary metric did not use merged WPM")
    }
    if model.selectedMenuSpeed.unit != "WPM" || abs((model.selectedMenuSpeed.value ?? 0) - 40) > 1e-3 {
        failures.append("FAIL: Chinese and English primary WPM were not merged")
    }
    model.updateInputSource(english); model.refreshSnapshot()
    type([20], language: "en")
    if abs((model.estimatedRecentKPM ?? 0) - 200) > 1e-3 { failures.append("FAIL: source switch erased the merged KPM sample") }
    type([20.2, 20.4, 20.6, 20.8], language: "en")
    if model.dailyEstimate.keys != 15 || model.probable.keys != 15 || abs((model.estimatedRecentKPM ?? 0) - 225) > 1e-3 || abs((model.selectedMenuMetric.primaryRate ?? 0) - 45) > 1e-3 {
        failures.append("FAIL: merged KPM/WPM lost interval weighting or language coverage")
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

/// Current-rule daily averages survive legacy rows, while recent averages are
/// genuinely session-only and exclude the confirmed validation adapter.
@MainActor private func runRollingEstimateChecks() -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Keytempo-window-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var failures = [String]()
    do {
        let store = try AggregateStore(url: directory.appendingPathComponent("statistics.sqlite"))
        var legacy = StoredAggregate(day: AppModel.day(), timezone: TimeZone.current.identifier,
                                     rule: "legacy-counting-rule", evidence: "probable", language: "en")
        legacy.keys = 1_000; legacy.intervals = 999; legacy.seconds = 1_000
        try store.save([legacy])
    } catch { return ["FAIL: rolling estimate setup: \(error.localizedDescription)"] }
    let model = AppModel(dataDirectory: directory, monitoringEnabled: false)
    model.isPaused = false; model.excludedAppsText = ""; model.updateExclusions()
    if model.tenMinuteWPM != nil || model.todayAverageWPM != nil || !model.todayAverageIsPartial {
        failures.append("FAIL: session window or current-rule daily rate fabricated from legacy history")
    }
    let now = ProcessInfo.processInfo.systemUptime - 30
    let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    for (times, language) in [([0.0, 0.1, 0.2, 0.3, 0.4], "en"), ([10.0, 10.5, 11, 11.5, 12], "zh")] {
        for time in times {
            model.receiveConfirmedInput(ClassifiedInput(time: now + time, date: date.addingTimeInterval(time),
                                                        context: 782, category: .textEntry, evidence: .probable,
                                                        source: .global, language: language))
        }
    }
    model.refreshSnapshot()
    if abs((model.tenMinuteKPM ?? 0) - 200) > 1e-3 || abs((model.tenMinuteWPM ?? 0) - 40) > 1e-3 {
        failures.append("FAIL: coordinator ten-minute estimate lost interval weighting or language coverage")
    }
    if model.dailyEstimate.keys != 1_010 || abs(model.dailyEstimate.seconds - 1_002.4) > 1e-3 ||
        abs((model.todayAverageWPM ?? 0) - 40) > 1e-3 || abs((model.dailyEstimate.todayKPM ?? 0) - 200) > 1e-3 ||
        !model.todayAverageIsPartial || model.todayAverageCoveredKeys != 10 {
        failures.append("FAIL: legacy quantities were lost or incompatible rules contaminated today's average")
    }
    for offset in [20.0, 20.2, 20.4, 20.6, 20.8] {
        model.receiveConfirmedInput(ClassifiedInput(time: now + offset, date: date.addingTimeInterval(offset),
                                                    context: 783, category: .textEntry, evidence: .confirmed,
                                                    source: .adapter, language: "zh", committedCharacters: 1))
    }
    model.refreshSnapshot()
    if abs((model.tenMinuteWPM ?? 0) - 40) > 1e-3 || abs((model.todayAverageWPM ?? 0) - 40) > 1e-3 {
        failures.append("FAIL: confirmed validation adapter contaminated estimated averages")
    }
    model.flushBeforeExit()
    let restored = AppModel(dataDirectory: directory, monitoringEnabled: false)
    if restored.tenMinuteWPM != nil || restored.tenMinuteKPM != nil || abs((restored.todayAverageWPM ?? 0) - 40) > 1e-3 {
        failures.append("FAIL: restart reconstructed a rolling window from daily aggregates or lost today's average")
    }
    restored.flushBeforeExit()
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
        let combined = model.history.first { $0.language == "mul" }
        if model.historyGranularity != .month || model.history.count != 1 || combined?.estimatedKeys != 10 || abs((combined?.estimatedKPM ?? 0) - 200) > 1e-6 || abs((combined?.estimatedPrimaryRate ?? 0) - 40) > 1e-6 {
            failures.append("FAIL: monthly history projection lost merged counts or averaged daily rates")
        }
        if combined?.characters != 2 || abs((combined?.cpm ?? 0) - 150) > 1e-6 {
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

// The daily ledger is independent of its presentation. All database work runs
// on diskQueue; opening a window catches up ended days without re-awarding XP.
extension AppModel {
    var selectedDailyRewardDay: DailyRewardDay? {
        let key = rewardDayKey(activityDate)
        return dailyRewardState?.days[key] ?? dailySettlements.first(where: { $0.day == key })?.dailyRewardDay
    }

    private func initializeDailyRewards(database: AggregateStore) throws {
        if let saved = try database.loadDailyRewardState() {
            dailyRewardEngine = try DailyRewardEngine(restoring: saved, now: Date())
            durableDailyRevision = saved.revision
        } else {
            dailyRewardEngine = DailyRewardEngine(legacyTotalXP: rewardEngine?.state.xpProgress.totalXP ?? 0,
                legacyImprovementXP: rewardEngine?.state.xpProgress.improvementXP ?? 0,
                progressionTimeZone: TimeZone(identifier: rewardEngine?.state.progressionTimezone ?? "") ?? .current)
        }
        dailyRewardState = dailyRewardEngine?.state
        if dailyRewardEngine?.error != nil { dailyRewardError = "每日奖励数据异常，已停止新增奖励；输入统计仍保留。" }
    }

    private func observeDailyImprovement() {
        if let total = rewardEngine?.state.xpProgress.improvementXP { dailyRewardEngine?.observeLegacyImprovement(total: total) }
        if dailyRewardEngine?.error != nil { dailyRewardError = "每日奖励数据异常，已停止新增奖励；输入统计仍保留。" }
    }

    private func publishDailyRewards() {
        guard let state = dailyRewardEngine?.state else { return }
        if dailyRewardState != state {
            let changedXP = dailyRewardState?.totalXP != state.totalXP
            dailyRewardState = state
            if changedXP { onAppearanceUpdate?() }
        }
        var rows = Dictionary(loadedDailySettlements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for receipt in (inFlightWrite?.dailyRewards?.receipts ?? []) + (retryWrite?.dailyRewards?.receipts ?? []) + (dailyRewardEngine?.unpersistedReceipts ?? []) {
            rows[receipt.id] = receipt
        }
        let values = activityVisible ? rows.values.sorted { $0.day < $1.day } : []
        if dailySettlements != values { dailySettlements = values }
    }

    private func retainDailySettlements(_ receipts: [DailySettlementReceipt]) {
        if activityReadInFlight { for receipt in receipts { dailyReadOverlay[receipt.id] = receipt } }
        guard activityVisible, !receipts.isEmpty else { return }
        var values = Dictionary(loadedDailySettlements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for receipt in receipts { values[receipt.id] = receipt }
        loadedDailySettlements = values.values.sorted { $0.day < $1.day }
    }

    private func installDailyRewardLifecycle(center: NotificationCenter) {
        // Catch up dates missed while the process was asleep or closed. XP
        // does not depend on observing a rest notification or opening a view.
        settleEndedDailyRewards()
        guard monitoringEnabled else { return }
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // NSWorkspace posts the display-power notification; verify all
                // online displays where that metadata is available.
                guard SystemRestState.allDisplaysAsleep != false else { return }
                self.monitor.flushPendingInput()
                self.interruptEngine(); self.settleEndedDailyRewards()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleEndedDailyRewards()
                self.scheduleRewardMidnight(); self.refreshSnapshot()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitor.flushPendingInput(); self.interruptEngine(); self.settleEndedDailyRewards()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleEndedDailyRewards(); self?.refreshSnapshot(); self?.scheduleRewardMidnight() }
        })
        scheduleRewardMidnight()
    }

    private func scheduleRewardMidnight() {
        midnightWork?.cancel(); midnightWork = nil
        guard monitoringEnabled, let state = dailyRewardEngine?.state else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: state.progressionTimezone) ?? .current
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.midnightWork = nil
            self.handleRewardMidnight()
            self.scheduleRewardMidnight()
        }
        midnightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow), execute: work)
    }

    fileprivate func handleRewardMidnight(at date: Date = Date()) {
        settleEndedDailyRewards(at: date)
        refreshSnapshot()
    }

    fileprivate func settleEndedDailyRewards(at date: Date = Date()) {
        guard !clearing, dailyRewardEngine?.hasEndedDays(at: date) == true else { return }
        // Do not flush the monitor on an ordinary same-day opening. Drain
        // ended-day input before advancing its calendar attribution.
        monitor.flushPendingInput()
        // Resolve old candidate evidence before completed-day improvement is
        // evaluated, so its bonus belongs to this receipt rather than tomorrow.
        rewardEngine?.interrupt(at: date, reason: "daily-settlement")
        rewardEngine?.advance(to: date); observeDailyImprovement()
        dailyRewardEngine?.settleEndedDays(at: date)
        publishDailyRewards(); flush()
    }

    func requestSettlementPresentation() {
        guard !clearing else { return }
        // Also handles a delayed midnight callback or an awake app relaunch.
        // Settlement is idempotent and the current day remains open.
        settleEndedDailyRewards()
        if !settlementPresentationRequested { settlementQueuePosition = 1; settlementQueueCount = 0 }
        settlementPresentationRequested = true
        flush(); readNextSettlement()
    }

    private func readNextSettlement() {
        guard settlementPresentationRequested, !settlementReadInFlight, !settlementAcknowledging,
              settlementReceipt == nil, activeReceipt == nil, retryWrite == nil,
              !clearing, let store else { return }
        settlementReadInFlight = true
        let version = generation, requestVersion = settlementRequestVersion
        diskQueue.async { [weak self] in
            let result = Result { (try store.queryUnseenDailyRewardReceipts(limit: 1).first,
                                   try store.dailyRewardReceiptCount()) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.settlementReadInFlight = false
                guard version == self.generation, requestVersion == self.settlementRequestVersion,
                      self.settlementPresentationRequested, !self.clearing else {
                    self.readNextSettlement(); return
                }
                switch result {
                case let .success((receipt, count)):
                    self.settlementQueueCount = max(self.settlementQueueCount, self.settlementQueuePosition - 1 + count)
                    self.settlementReceipt = receipt
                    if receipt != nil { self.onSettlementAvailable?() }
                    else { self.settlementPresentationRequested = false; self.onSettlementAvailable?() }
                case let .failure(error): self.dailyRewardError = error.localizedDescription
                }
            }
        }
    }

    func acknowledgeSettlement(skipAll: Bool = false) {
        guard !settlementAcknowledging, let receipt = settlementReceipt, let store else { return }
        settlementAcknowledging = true
        let version = generation, requestVersion = settlementRequestVersion
        diskQueue.async { [weak self] in
            let result = Result {
                if skipAll { try store.acknowledgeAllDailyRewardReceipts() }
                else { try store.acknowledgeDailyRewardReceipt(id: receipt.id) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.settlementAcknowledging = false
                guard version == self.generation, !self.clearing else { return }
                switch result {
                case .success:
                    self.settlementReceipt = nil
                    if requestVersion == self.settlementRequestVersion { self.settlementQueuePosition += 1 }
                    self.readNextSettlement()
                case let .failure(error): self.dailyRewardError = error.localizedDescription
                }
            }
        }
    }

    func closeSettlementPresentation() {
        settlementRequestVersion &+= 1
        settlementPresentationRequested = false; settlementReceipt = nil
    }

    func exportDailyRewards() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Keytempo-daily-rewards.csv"
        guard panel.runModal() == .OK, let url = panel.url, store != nil else { return }
        dailyExportURL = url
        let needsCheckpoint = !pending.isEmpty || !pendingActivity.isEmpty || rewardEngine?.hasPendingChanges == true || dailyRewardsNeedSave
        let revision = (dailyRewardEngine?.state.revision ?? 0).addingReportingOverflow(needsCheckpoint ? 1 : 0)
        guard !revision.overflow else { dailyRewardError = "每日奖励数据异常，已停止新增奖励；输入统计仍保留。"; return }
        dailyExportRevision = revision.partialValue
        flush(); finishDailyRewardExportIfReady()
    }

    private func finishDailyRewardExportIfReady() {
        guard let url = dailyExportURL, let target = dailyExportRevision, let store else { return }
        guard durableDailyRevision >= target else {
            if activeReceipt == nil && retryCount == 0 { flush() }
            return
        }
        dailyExportURL = nil; dailyExportRevision = nil
        diskQueue.async { [weak self] in
            do { try store.exportDailyRewardCSV().write(to: url, atomically: true, encoding: .utf8) }
            catch { DispatchQueue.main.async { self?.storageError = "导出失败：\(error.localizedDescription)" } }
        }
    }
}
