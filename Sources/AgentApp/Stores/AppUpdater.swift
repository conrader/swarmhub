import Combine
import Foundation
import Sparkle

/// One controller for the lifetime of the app, shared by Settings and the application menu.
@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var unavailableReason: String?
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = CommandLine.arguments) {
        #if DEBUG
        if QAMode.enabled || UIAcceptanceMode.requested { unavailableReason = "Updates are disabled in QA test mode."; return }
        #endif
        unavailableReason = UpdateConfiguration.unavailableReason(bundleURL: bundle.bundleURL,
            info: bundle.infoDictionary ?? [:], environment: environment, arguments: arguments)
        guard unavailableReason == nil else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            let updater = controller.updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
            updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
            updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        } catch {
            unavailableReason = "Automatic updates could not start: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    // Sparkle persists these preferences; do not replace them with app-owned defaults on launch.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}
