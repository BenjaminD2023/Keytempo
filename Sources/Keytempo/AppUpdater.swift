import AppKit
import Combine
import Sparkle

/// Sparkle owns scheduling, preferences, verified downloads and installation.
/// Constructing this object does not start networking (including in self-tests).
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticDownloads = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var startupError: String?

    var beforeInstall: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    var signingChannel: String {
        Bundle.main.object(forInfoDictionaryKey: "KeytempoSigningChannel") as? String ?? "adhoc"
    }

    func start() {
        guard controller == nil else { return }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = value
        let updater = value.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheck)
        do { try updater.start() }
        catch { startupError = error.localizedDescription }
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        guard !enabled || allowsAutomaticDownloads else { return }
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beforeInstall?()
    }
}
