import AppKit
import SwiftUI
import TypingCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var model: AppModel!
    private var statsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test-editor") {
            let failures = runConfirmedEditorChecks() + runInputBufferChecks() + runAppModelChecks() + runInputLanguageChecks() + runLocalizationChecks() + runDisplayFormattingChecks()
            print(failures.isEmpty ? "PASS: editor, language, localization, buffer and coordinator/persistence integration checks" : failures.joined(separator: "\n"))
            exit(failures.isEmpty ? 0 : 1)
        }
        installApplicationMenu()
        model = AppModel()
        model.updates.beforeInstall = { [weak self] in self?.model.flush() }
        model.updates.start()
        model.openStats = { [weak self] in self?.showStatistics() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.onMenuUpdate = { [weak self] in self?.updateMenu() }
        model.onInterfaceLanguageUpdate = { [weak self] in
            guard let self else { return }
            self.installApplicationMenu()
            self.statsWindow?.title = L("Keytempo · 输入统计")
            self.settingsWindow?.title = L("Keytempo · 设置")
            self.updateMenu()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
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
    @objc private func checkForUpdates() { model?.updates.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? (model?.updates.canCheckForUpdates ?? false) : true
    }
    private func updateMenu() {
        guard let statusItem else { return }
        var title = "⌨"
        if model.menuDisplay == "hybrid" {
            if let wpm = model.hybridMenuWPM {
                title += " ≈\(wpm.formatted(.number.precision(.fractionLength(0)))) WPM"
            } else {
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
        if statusItem.button?.title != title { statusItem.button?.title = title }
        var tooltip = L("Keytempo · %@ · %@ · 当前输入段约每秒更新。停止后保留最近值，等待不计时。WPM 为按键折算估算；CPM 需要真实提交字符。KPM 可在设置中选择。", L(model.status), model.currentInputLanguage)
        if model.menuDisplay == "hybrid" {
            tooltip = L("Keytempo · %@ · %@", L(model.status), model.currentInputLanguage)
            tooltip += "\n" + L("输入时显示实时估算 WPM；候选、停打、暂停或统计不可用时显示今日敲键数。约每秒更新，等待不计入输入时长。")
        }
        if model.menuDisplay == "count" || model.menuDisplay == "hybrid" { tooltip += "\n" + L("敲键数量为其他 App 中的日常输入估算；快捷键不计入。") }
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(L("Keytempo 打字统计 %@ · %@", title, L(model.status)))
    }
    @objc private func togglePopover() {
        model.monitor.checkSystemState()
        model.refreshSnapshot()
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            // The menu graph exists only while visible; background snapshots
            // should not rebuild a hidden SwiftUI hierarchy.
            popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
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
    }
    @objc private func showSettings() {
        model.refreshInputLanguages()
        popover.performClose(nil)
        if settingsWindow == nil { settingsWindow = window(title: L("Keytempo · 设置"), view: SettingsView(model: model), size: NSSize(width: 700, height: 700)) }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === statsWindow {
            model.statisticsVisible = false; model.historyVisible = false; model.releaseHistory(); model.interruptConfirmed()
            // Drop editor/Charts state after closing; the menu does not retain a hidden dashboard.
            window.contentViewController = nil; statsWindow = nil
        } else if window === settingsWindow { window.contentViewController = nil; settingsWindow = nil }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStatistics() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.monitor.checkSystemState(); model?.refreshSnapshot()
        model?.refreshHistoryIfVisible()
    }
    func applicationWillTerminate(_ notification: Notification) { model.flushBeforeExit() }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
