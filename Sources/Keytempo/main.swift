import AppKit
import SwiftUI
import TypingCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var model: AppModel!
    private var statsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settlementWindow: NSWindow?
    private var handingOffSettlement = false
    private var displayOptionsObserver: NSObjectProtocol?
    private var menuIconEffects: MenuIconEffects?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test-editor") {
            let failures = runConfirmedEditorChecks() + runInputBufferChecks() + runAppModelChecks(settlementHandoffCheck: AppDelegate.runSettlementHandoffChecks) + runInputLanguageChecks() + runLocalizationChecks() + runDisplayFormattingChecks() + runAppearanceChecks() + runMenuIconEffectChecks()
            print(failures.isEmpty ? "PASS: editor, language, localization, buffer and coordinator/persistence integration checks" : failures.joined(separator: "\n"))
            exit(failures.isEmpty ? 0 : 1)
        }
        installApplicationMenu()
        model = AppModel()
        model.updates.beforeInstall = { [weak self] in self?.model.flush() }
        model.updates.start()
        model.openStats = { [weak self] in self?.showStatistics() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.onAppearanceUpdate = { [weak self] in self?.menuIconEffects?.cancel(); self?.applyAppearance(); self?.updateMenu() }
        model.onMenuEffectPreview = { [weak self] in
            guard let self, self.statusItem?.button != nil else { return }
            self.menuIconEffects?.preview(
                permitted: !self.model.isPaused && self.model.hasInputPermission && self.model.hasAccessibilityPermission,
                level: self.model.appearanceLevel, color: NSColor.labelColor, enabled: self.model.menuIconMotionEnabled,
                lowWPM: self.model.menuIconLowWPM, highWPM: self.model.menuIconHighWPM) { [weak self] sample in
                    self?.model.menuEffectPreviewWPM = sample
                    self?.updateMenu()
                }
        }
        applyAppearance()
        model.onMenuUpdate = { [weak self] in self?.updateMenu() }
        model.onSettlementAvailable = { [weak self] in self?.presentPendingSettlement() }
        model.onInterfaceLanguageUpdate = { [weak self] in
            guard let self else { return }
            self.installApplicationMenu()
            self.statsWindow?.title = L("Keytempo · 输入统计")
            self.settingsWindow?.title = L("Keytempo · 设置")
            self.updateMenu()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.font = StatusItemPresentation.font
        statusItem.button?.cell?.usesSingleLineMode = true
        if let button = statusItem.button {
            menuIconEffects = MenuIconEffects(button: button)
            let observer = MenuAppearanceObserver(frame: .zero)
            observer.onAppearanceChange = { [weak self] in self?.updateMenu() }
            button.addSubview(observer)
        }
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMenu() }
            }
        popover.behavior = .transient
        popover.delegate = self
        updateMenu()
        if CommandLine.arguments.contains("--show-stats") { showStatistics() }
    }
    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu(title: "Keytempo")
        let settingsItem = applicationMenu.addItem(withTitle: L("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let updatesItem = applicationMenu.addItem(withTitle: L("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("退出 Keytempo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
    }
    private func applyAppearance() {
        guard let model else { return }
        switch model.appearanceMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    @objc private func checkForUpdates() { model?.updates.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? (model?.updates.canCheckForUpdates ?? false) : true
    }
    private func updateMenu() {
        guard let statusItem else { return }
        var title = ""
        if model.menuDisplay == "hybrid" {
            switch model.hybridMenuDisplay {
            case .wpm(let value):
                title += value.map { " ≈\($0.formatted(.number.precision(.fractionLength(0)))) WPM" } ?? " — WPM"
            case .count:
                title += " ≈\(compactKeystrokeCount(model.dailyEstimate.keys))"
                if model.isPaused { title += " Ⅱ" }
            }
        }
        else if model.isPaused { title += " Ⅱ" }
        else if model.menuDisplay == "count" { title += " ≈\(compactKeystrokeCount(model.dailyEstimate.keys))" }
        else if model.menuDisplay == "speed" || model.menuDisplay == "kpm" {
            let metric = model.selectedMenuSpeed
            let value = metric.value
            let unit = metric.unit
            let prefix = metric.estimated ? "≈" : ""
            if unit == "—" { title += " —" }
            else { title += value.map { " \(prefix)\($0.formatted(.number.precision(.fractionLength(0)))) \(unit)" } ?? " — \(unit)" }
            if model.phase == "idle", value != nil { title += " ·" }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if let button = statusItem.button {
            let width = StatusItemPresentation.width(for: title, mode: model.menuDisplay)
            if statusItem.length != width { statusItem.length = width }
            let foreground = NSColor.labelColor
            let attributed = NSAttributedString(string: title, attributes: [.font: StatusItemPresentation.font, .foregroundColor: foreground])
            if !button.attributedTitle.isEqual(to: attributed) { button.attributedTitle = attributed }
            let level = model.dailyRewardState.flatMap { DailyLevelProgress(totalXP: $0.totalXP) }?.level ?? 1
            let iconWPM = model.menuEffectPreviewWPM ?? model.appearanceMenuWPM
            let icon = MenuIconRenderer.image(style: model.effectiveMenuBarStyle, level: level, wpm: iconWPM,
                lowWPM: model.menuIconLowWPM, highWPM: model.menuIconHighWPM)
            if button.image !== icon { menuIconEffects?.iconDidChange(); button.image = icon }
            button.contentTintColor = nil
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            menuIconEffects?.update(typing: model.phase == "typing" && !model.selectedSpeedIsRecent,
                permitted: !model.isPaused && model.hasInputPermission && model.hasAccessibilityPermission,
                level: level, color: foreground, wpm: model.appearanceMenuWPM,
                lowWPM: model.menuIconLowWPM, highWPM: model.menuIconHighWPM,
                enabled: model.menuIconMotionEnabled, sampledAt: model.menuSnapshotUptime)
        }
        var tooltip = L("Keytempo · %@ · %@ · 输入速度约每秒更新。停止后保留最近值，等待不计时。WPM 为按键折算估算；KPM 可在设置中选择。", L(model.status), L("合并全部输入语言"))
        if model.menuDisplay == "hybrid" {
            tooltip = L("Keytempo · %@ · %@", L(model.status), L("合并全部输入语言"))
            tooltip += "\n" + L("输入和预热时保持 WPM，样本不足显示 — WPM；确认停打后显示 — WPM 三秒，再显示今日敲键数。暂停或权限失效等情况立即显示数量。约每秒更新，等待不计入输入时长。")
        }
        if model.menuDisplay == "count" || model.menuDisplay == "hybrid" { tooltip += "\n" + L("敲键数量为其他 App 中的日常输入估算；快捷键不计入。") }
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(L("Keytempo 打字统计 %@ · %@", title, L(model.status)))
    }
    @objc private func togglePopover() {
        menuIconEffects?.cancel()
        model.monitor.checkSystemState()
        model.refreshSnapshot()
        if popover.isShown { popover.performClose(nil); model.closeSettlementPresentation() }
        else if let button = statusItem.button {
            // The menu graph exists only while visible; background snapshots
            // should not rebuild a hidden SwiftUI hierarchy.
            popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            model.requestSettlementPresentation()
        }
    }
    func popoverDidClose(_ notification: Notification) {
        menuIconEffects?.cancel()
        popover.contentViewController = nil
        // The animated close callback can arrive after the synchronous handoff
        // finishes. Once the panel owns the queue, closing the popover must not
        // clear its receipt and strand the panel in its loading state.
        if settlementWindow == nil && !handingOffSettlement { model.closeSettlementPresentation() }
    }
    private func window<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.minSize = NSSize(width: min(size.width, 640), height: min(size.height, 520))
        return window
    }
    private func showStatistics() {
        popover.performClose(nil)
        if statsWindow == nil { statsWindow = window(title: L("Keytempo · 输入统计"), view: StatisticsView(model: model), size: NSSize(width: 940, height: 700)) }
        model.statisticsVisible = true
        if model.historyVisible { model.loadHistory(days: model.historyDays) }
        NSApp.activate(ignoringOtherApps: true); statsWindow?.makeKeyAndOrderFront(nil)
        model.requestSettlementPresentation()
    }
    @objc private func showSettings() {
        model.refreshInputLanguages()
        popover.performClose(nil)
        if settingsWindow == nil { settingsWindow = window(title: L("Keytempo · 设置"), view: SettingsView(model: model), size: NSSize(width: 700, height: 700)) }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        model.requestSettlementPresentation()
    }
    private func presentPendingSettlement() {
        guard model.settlementReceipt != nil else { dismissSettlement(); return }
        handingOffSettlement = true
        defer { handingOffSettlement = false }
        popover.performClose(nil)
        if settlementWindow == nil {
            let value = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            value.title = L("Keytempo · 每日结算"); value.titleVisibility = .hidden
            value.titlebarAppearsTransparent = true; value.isMovableByWindowBackground = true
            value.standardWindowButton(.closeButton)?.isHidden = true
            value.standardWindowButton(.miniaturizeButton)?.isHidden = true
            value.standardWindowButton(.zoomButton)?.isHidden = true
            value.isReleasedWhenClosed = false; value.delegate = self
            value.contentViewController = NSHostingController(rootView: SettlementQueueHost(model: model, close: { [weak self] in self?.dismissSettlement() }))
            value.center(); settlementWindow = value
        }
        NSApp.activate(ignoringOtherApps: true); settlementWindow?.makeKeyAndOrderFront(nil)
    }
    private func dismissSettlement() {
        let window = settlementWindow; settlementWindow = nil
        model?.closeSettlementPresentation()
        window?.contentViewController = nil; window?.close()
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settlementWindow { dismissSettlement() }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === statsWindow {
            menuIconEffects?.cancel()
            if settlementWindow == nil { model.closeSettlementPresentation() }
            model.statisticsVisible = false; model.historyVisible = false; model.releaseHistory(); model.releaseActivity(); model.interruptConfirmed()
            // Drop editor/Charts state after closing; the menu does not retain a hidden dashboard.
            window.contentViewController = nil; statsWindow = nil
        } else if window === settingsWindow {
            menuIconEffects?.cancel()
            if settlementWindow == nil { model.closeSettlementPresentation() }
            window.contentViewController = nil; settingsWindow = nil
        }
        else if window === settlementWindow { dismissSettlement() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStatistics() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.monitor.checkSystemState(); model?.refreshSnapshot()
        model?.refreshHistoryIfVisible()
        if settlementWindow == nil && (statsWindow?.isVisible == true || settingsWindow?.isVisible == true) { model?.requestSettlementPresentation() }
    }
    func applicationDidResignActive(_ notification: Notification) {
        if settlementWindow == nil && !handingOffSettlement { model?.closeSettlementPresentation() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        menuIconEffects?.shutdown()
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        model.flushBeforeExit()
    }
}

extension AppDelegate {
    /// Runs against the isolated daily-reward fixture, without showing a window.
    /// Both notification orders exercise the real popover delegate callback.
    static func runSettlementHandoffChecks(model: AppModel) -> [String] {
        guard let receipt = model.settlementReceipt else {
            return ["FAIL: settlement handoff fixture has no committed receipt"]
        }
        let owner = AppDelegate()
        owner.model = model
        let notification = Notification(name: NSPopover.didCloseNotification, object: owner.popover)
        let totalXP = model.dailyRewardState?.totalXP
        var failures = [String]()
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append("FAIL: settlement handoff \(message)") }
        }

        owner.handingOffSettlement = true
        owner.popoverDidClose(notification)
        expect(model.settlementReceipt?.id == receipt.id, "synchronous popover close preserves the pending receipt")

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                            styleMask: .borderless, backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        owner.settlementWindow = panel
        owner.handingOffSettlement = false
        owner.popoverDidClose(notification)
        expect(model.settlementReceipt?.id == receipt.id, "delayed popover close preserves the panel's receipt")
        owner.popoverDidClose(notification)
        expect(model.settlementReceipt?.id == receipt.id, "repeated popover close cannot empty the settlement panel")

        owner.settlementWindow = nil
        panel.close()
        owner.popoverDidClose(notification)
        expect(model.settlementReceipt == nil, "ordinary popover dismissal still cancels its presentation request")
        expect(model.dailyRewardState?.totalXP == totalXP, "handoff and dismissal never alter credited XP")
        return failures
    }
}

/// Inherits the status button's actual appearance, including system changes
/// while idle. No distributed/private notification or polling is required.
@MainActor private final class MenuAppearanceObserver: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); onAppearanceChange?()
    }
}

private struct SettlementQueueHost: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        Group {
            if let receipt = model.settlementReceipt {
                SettlementView(presentation: SettlementPresentation(receipt), theme: model.effectiveAppearanceTheme,
                               position: model.settlementQueuePosition,
                               count: model.settlementQueueCount,
                               onNext: { model.acknowledgeSettlement() },
                               onSkipAll: { model.acknowledgeSettlement(skipAll: true) }, onClose: close)
                    .id(receipt.id).disabled(model.settlementAcknowledging)
            } else {
                VStack(spacing: 16) {
                    if let error = model.dailyRewardError {
                        Image(systemName: "exclamationmark.circle").font(.title2).foregroundStyle(.secondary)
                        Text(error).font(.callout).multilineTextAlignment(.center)
                        Button(L("重试加载"), action: model.requestSettlementPresentation)
                    } else {
                        ProgressView()
                    }
                    Button(L("关闭"), action: close).keyboardShortcut(.cancelAction)
                }.padding(32).frame(width: 460, height: 560)
            }
        }.environment(\.locale, Locale(identifier: model.interfaceLanguage)).keytempoAppearance(model: model)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
