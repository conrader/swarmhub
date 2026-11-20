import Combine
import Foundation
import Sparkle

/// What the app shows about updates outside Settings (the sidebar's line): one shared instance, so a view needs
/// nothing in its environment to read it.
@MainActor final class UpdateNotice: ObservableObject {
    static let shared = UpdateNotice()
    /// The version of the app a check found and the person has neither installed nor skipped.
    @Published var appVersion: String?
    @Published var manualCheckQueued = false
    /// How many servers have a workspace update ready, or need one by hand.
    @Published var serversBehind = 0

    /// "SwarmHub 0.7.1 is available", "2 server updates", or nil when there is nothing to say.
    var line: String? {
        if manualCheckQueued { return "Update check queued" }
        if let appVersion { return serversBehind > 0 ? "Updates are available" : "\(AppConstants.name) \(appVersion) is available" }
        if serversBehind > 0 { return serversBehind == 1 ? "A server update is available" : "\(serversBehind) server updates are available" }
        return nil
    }
}

/// One controller for the lifetime of the app, shared by Settings and the application menu.
///
/// Scheduled checks are quiet: Sparkle looks once a day in the background, and what it finds shows as a line in the
/// sidebar and in Settings → Software Update instead of a window over the person's work. Choosing it (or Check for
/// Updates…) opens Sparkle's own window with the release notes and Install. With automatic installing on, Sparkle
/// downloads in the background and installs when the app quits. Every archive is checked against the EdDSA key in
/// Info.plist before it is unpacked.
@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var manualCheckQueued = false
    let automaticInstallPreferenceAvailable: Bool

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var unavailableReason: String?
    /// A check without a window is running (`checkQuietly`).
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    /// The version a check found; nil when the app is the newest, or nothing has been checked.
    @Published private(set) var available: String?
    /// Why the last check could not finish, in Sparkle's words.
    @Published private(set) var problem: String?
    private var controller: SPUStandardUpdaterController?
    private var events: UpdaterEvents?
    private var pendingManualCheck: AnyCancellable?
    private var pendingManualCheckTimeout: Task<Void, Never>?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = CommandLine.arguments) {
        automaticInstallPreferenceAvailable = (bundle.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool) != false
        unavailableReason = UpdateConfiguration.unavailableReason(bundleURL: bundle.bundleURL,
            info: bundle.infoDictionary ?? [:], environment: environment, arguments: arguments)
        guard unavailableReason == nil else { return }

        let events = UpdaterEvents()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: events, userDriverDelegate: events)
        events.owner = self
        do {
            try controller.updater.start()
            self.controller = controller; self.events = events
            let updater = controller.updater
            observeSparkleUpdater(updater)
            // A rehearsal does not wait a day for the scheduled check.
            if environment["SWARMHUB_UPDATE_CHECK_ON_LAUNCH"] == "1" { updater.checkForUpdatesInBackground() }
        } catch {
            unavailableReason = "Automatic updates could not start: \(error.localizedDescription)"
        }
    }

    func observeSparkleUpdater(_ updater: SPUUpdater) {
        lastCheck = updater.lastUpdateCheckDate
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
    }

    /// Sparkle's own window: the release notes, Install, and its progress. Also brings a found update into view.
    func checkForUpdates() {
        guard let controller else { return }
        if controller.updater.canCheckForUpdates {
            clearQueuedCheck()
            isChecking = true; problem = nil
            controller.checkForUpdates(nil)
        } else {
            queueManualCheck(readiness: $canCheckForUpdates.eraseToAnyPublisher(),
                             isReady: { [weak controller] in controller?.updater.canCheckForUpdates == true },
                             start: { [weak self] in self?.checkForUpdates() })
        }
    }

    func queueManualCheck(readiness: AnyPublisher<Bool, Never>, timeout: Duration = .seconds(60),
                          isReady: @escaping () -> Bool, start: @escaping () -> Void) {
        guard pendingManualCheck == nil else { return }
        manualCheckQueued = true
        UpdateNotice.shared.manualCheckQueued = true
        problem = nil
        // Sparkle can briefly report ready before starting another phase of the same check.
        pendingManualCheck = readiness.receive(on: DispatchQueue.main)
            .filter { $0 && isReady() }.first()
            .sink { [weak self] _ in
                guard let self, self.manualCheckQueued else { return }
                self.clearQueuedCheck()
                start()
            }
        pendingManualCheckTimeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.manualCheckQueued else { return }
            self.clearQueuedCheck()
            self.problem = "The updater stayed busy. Try checking for updates again."
        }
    }

    private func clearQueuedCheck() {
        pendingManualCheck = nil
        pendingManualCheckTimeout?.cancel()
        pendingManualCheckTimeout = nil
        manualCheckQueued = false
        UpdateNotice.shared.manualCheckQueued = false
    }

    /// Asks the feed without opening a window; `available`, `lastCheck` and `problem` say what came of it.
    func checkQuietly() {
        guard let updater = controller?.updater, updater.canCheckForUpdates, !updater.sessionInProgress, !isChecking else { return }
        isChecking = true; problem = nil
        updater.checkForUpdateInformation()
    }

    // Sparkle persists these preferences; do not replace them with app-owned defaults on launch.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard automaticInstallPreferenceAvailable, let updater = controller?.updater else { return }
        if enabled, !updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = true }
        updater.automaticallyDownloadsUpdates = enabled
    }

    // MARK: What Sparkle reports (`UpdaterEvents`)

    fileprivate func found(_ version: String) {
        lastCheck = .now; problem = nil
        available = version; UpdateNotice.shared.appVersion = version
    }
    fileprivate func foundNone() { available = nil; UpdateNotice.shared.appVersion = nil }
    fileprivate func noUpdate() { lastCheck = .now; problem = nil; foundNone() }
    fileprivate func finished(_ failure: String?) {
        isChecking = false; problem = failure
        if failure != nil { foundNone() }
    }
}

/// Sparkle's delegate callbacks, passed on to the updater. Sparkle calls all of them on the main thread.
@MainActor private final class UpdaterEvents: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    weak var owner: AppUpdater?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { owner?.found(item.displayVersionString) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) { owner?.noUpdate() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        owner?.finished(error.flatMap(UpdateConfiguration.problem(from:)))
    }

    /// Installed, or skipped for good: the line about it goes. "Later" keeps it.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice != .dismiss { owner?.foundNone() }
    }

    // A scheduled check never opens a window by itself: the app shows its own line instead (`UpdateNotice`).
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { owner?.found(update.displayVersionString) }
    }
}
