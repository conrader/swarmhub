import AppKit
import Foundation
import Security

/// `SwarmHub --e2e-live <dir>` (uxfix1-e2e): the normal app (uxfix3: hidden, off screen), run against a throwaway store in `<dir>`
/// that holds fresh copies of every Hermes bot in the real store (profile, server, persona, manager role; no messages,
/// no sessions, no recorded skills). The real store is read once and never written; settings go to their own defaults
/// suite; keys are read from the Keychain silently and never written. Hermes traffic goes through `E2ELiveNetwork`, a
/// real session the run can take offline (in-flight requests lost, new ones refused) the way macOS reports a drop. The run drives the same `AppStore` calls the
/// buttons and the composer make, writes `<dir>/report.txt` and quits. Every session it opens is `swarmhub-selftest-…`.
@MainActor enum E2ELive {
    static let flag = "--e2e-live"
    static let defaultsSuite = "com.konrad.agentapp.e2e-live"

    static func directory(arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The run's state, kept for the report and read by the monitor.
    final class Run {
        let directory: URL; let network: E2ELiveNetwork
        var tag: String { E2ELive.tag }
        var lines: [String] = []; var failed = 0
        var modals: [String] = []; var sheets = 0; var notices: Set<String> = []; var onScreen = 0
        init(directory: URL, network: E2ELiveNetwork) { self.directory = directory; self.network = network }
        func note(_ text: String) {
            lines.append(text); print(text); fflush(stdout)
            try? (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        func check(_ id: String, _ passed: Bool, _ detail: String) {
            if !passed { failed += 1 }
            note("\(passed ? "PASS" : "FAIL") \(id) | \(detail)")
        }
    }

    static var current: Run?
    /// Hermes refuses a second session with the same title: the manager's copy and every copy a turn step makes carry it.
    nonisolated static let tag = String(UUID().uuidString.prefix(8)).lowercased()

    /// The throwaway store, or nil (with the reason printed) when the run cannot start safely.
    static func makeStore(directory: URL) -> AppStore? {
        SecKeychainSetUserInteractionAllowed(false)
        let realURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp/store.json")
        guard directory.standardizedFileURL.path != realURL.deletingLastPathComponent().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: directory.appending(path: "store.json").path) else {
            print("E2E-LIVE STOP: \(directory.path) must be a new folder, not the real store's"); return nil
        }
        let saved: StoreFile
        do { saved = try StoreFile.decode(Data(contentsOf: realURL)) } catch { print("E2E-LIVE STOP: cannot read the real store: \(error.localizedDescription)"); return nil }
        let network = E2ELiveNetwork.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else { print("E2E-LIVE STOP: no defaults suite"); return nil }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let store = AppStore(storeURL: directory.appending(path: "store.json"), autoConfigureHermes: false, keyStore: E2ELiveKeys(defaults: defaults),
                             defaults: defaults, hermesSession: network.session())
        store.sessionNamespace = HeadlessE2E.namespace
        let sources = saved.bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly }
        store.bots = sources.map(copy); store.groups = []; store.selectedBot = store.bots.first { $0.canManageBots }
        store.save()
        current = Run(directory: directory, network: network)
        current?.note("E2E-LIVE: store \(directory.path) with \(store.bots.count) bot copies of \(saved.bots.count) in the real store (read only); Hermes traffic through the e2e network")
        return store
    }

    /// A copy that talks to the same profile with the same key: persona, manager role and model settings; nothing else.
    static func copy(_ bot: Bot) -> Bot {
        // Only the manager's copy opens a chat session of its own (queued A and B); its title must be new on every run.
        let copy = HeadlessE2E.copy(bot, name: bot.canManageBots ? "\(bot.name) \(HeadlessE2E.namespace)\(tag)" : nil)
        copy.canManageBots = bot.canManageBots; copy.modelSettings = bot.modelSettings
        copy.notificationsEnabled = false
        return copy
    }

    static func start(store: AppStore) {
        guard let run = current else { return }
        Task { @MainActor in
            keepOffScreen()
            let monitor = Task { @MainActor in await watch(store: store, run: run) }
            await steps(store: store, run: run)
            _ = await HeadlessE2E.wait(.seconds(300), poll: .milliseconds(200)) { !store.anyTurnRunning }
            await cleanSelfTestSessions(store: store, run: run, phase: "after")
            monitor.cancel()
            run.check("modal", run.modals.isEmpty && run.sheets == 0, "alerts shown: \(run.modals.count) \(run.modals.prefix(3)); sheets seen: \(run.sheets); connection lines seen: \(run.notices.count)")
            run.check("offscreen", run.onScreen == 0, "samples with a window on screen: \(run.onScreen)")
            run.note("E2E-LIVE: \(run.lines.filter { $0.hasPrefix("PASS") }.count) passed, \(run.failed) failed")
            run.note("E2E-LIVE RESULT: \(run.failed == 0 ? "PASS" : "FAIL")")
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
            run.network.stop()
            NSApp.terminate(nil)
        }
    }

    /// Every alert the window would show (`modalErrorMessage`) and any sheet on a window, sampled every 100 ms.
    static func watch(store: AppStore, run: Run) async {
        var last: String?
        while !Task.isCancelled {
            if let text = store.modalErrorMessage, text != last { run.modals.append(text); run.note("ALERT \(text)") }
            if let notice = store.connectionNotice { run.notices.insert(notice) }
            last = store.modalErrorMessage
            if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { run.sheets += 1 }
            if windowsOnScreen > 0 { run.onScreen += 1 }
            keepOffScreen()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func steps(store: AppStore, run: Run) async {
        _ = await HeadlessE2E.wait(.seconds(30), poll: .milliseconds(200)) { !NSApp.windows.isEmpty }
        guard let manager = store.bots.first(where: { store.isManager($0) }) else { run.check("setup", false, "no manager bot among the copies"); return }
        await cleanSelfTestSessions(store: store, run: run, phase: "before")
        run.note("E2E-LIVE: manager \(manager.name) (\(manager.hermesProfile ?? "default")); \(store.bots.count) bots on \(Set(store.bots.map(store.connection(of:))).count) connection(s)")
        // Turns first (minutes), then installs (the long part). The turn steps' extra copies leave before the installs.
        let copies = Set(store.bots.map(\.id))
        await turnSteps(store: store, manager: manager, run: run)
        _ = await HeadlessE2E.wait(.seconds(300), poll: .milliseconds(200)) { !store.anyTurnRunning }
        store.bots.removeAll { !copies.contains($0.id) }; HeadlessE2E.select(manager, in: store)
        await installSteps(store: store, manager: manager, run: run)
    }
}

/// Keys for the run: read silently from the Keychain (never copied, never written); anything the run sets stays in memory.
final class E2ELiveKeys: HermesKeyStore, @unchecked Sendable {
    private let vault: KeyVault
    private let lock = NSLock(); private var overrides: [String: String] = [:]
    init(defaults: UserDefaults) { vault = KeyVault(backend: SecKeychainBackend(), defaults: defaults, copiesLegacy: false) }
    func key(for account: String) -> String { lock.withLock { overrides[account] } ?? vault.get(account: account) }
    func setKey(_ value: String, for account: String) { lock.withLock { overrides[account] = value } }
    func hasKey(for account: String) -> Bool { !key(for: account).isEmpty }
    func needsReentry(_ account: String) -> Bool { lock.withLock { overrides[account] } == nil && vault.needsReentry(account: account) }
    func claimRecovery(_ account: String) -> Bool { vault.claimRecovery(account: account) }
    func storeVerified(_ value: String, for account: String) -> Bool { setKey(value, for: account); return true }
}
