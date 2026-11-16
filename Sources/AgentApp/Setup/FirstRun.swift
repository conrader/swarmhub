import Foundation

/// When the setup window opens by itself (P21 item 10). Decided only from the settings and the key store's
/// attributes (`hasKey`, never a decrypt), and written only from the UI layer: headless commands build `AppStore`
/// on the real settings and must write nothing.
enum FirstRun {
    static let stateKey = "setupState"
    enum State: String { case done, skipped }

    /// A box address is saved, or a main key exists in the key store, or a Herdr server was set up.
    static func boxConfigured(defaults: UserDefaults, keyStore: any HermesKeyStore) -> Bool {
        defaults.object(forKey: "hermesBaseURL") != nil || keyStore.hasKey(for: "hermes") || herdrConfigured(defaults: defaults, keyStore: keyStore)
    }

    /// A Herdr server was set up here: a saved list, the older single address, or an access token for the first
    /// server (saved, or passed to a development launch in the environment).
    static func herdrConfigured(defaults: UserDefaults, keyStore: any HermesKeyStore, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        defaults.string(forKey: HerdrServer.listKey)?.isEmpty == false || defaults.object(forKey: HerdrServerList.legacyAddressKey) != nil
            || keyStore.hasKey(for: HerdrServerList.legacyKeyAccount) || environment[HerdrBackend.tokenEnvironment]?.isEmpty == false
    }

    static func state(_ defaults: UserDefaults) -> State? { defaults.string(forKey: stateKey).flatMap(State.init) }

    /// Nothing configured, no real agent, and the window was never finished, skipped or cancelled.
    static func needsSetup(defaults: UserDefaults, keyStore: any HermesKeyStore, bots: [Bot]) -> Bool {
        state(defaults) == nil && !boxConfigured(defaults: defaults, keyStore: keyStore) && !hasRealAgents(bots)
    }

    static func hasRealAgents(_ bots: [Bot]) -> Bool { bots.contains { !$0.isDemo && !$0.isReadOnlyArchive && $0.backend != .mock } }

    /// While Herdr is the only software offered: the wizard opens by itself as long as there is no bot at all, which
    /// covers both a fresh install (no server set up) and a server that is set up with no bot on it. A finished setup
    /// whose bots were all removed opens it again; a window the person closed before finishing does not come back.
    static func needsWizard(defaults: UserDefaults, bots: [Bot]) -> Bool { state(defaults) != .skipped && !hasRealAgents(bots) }

    /// The one launch-time call from `ContentView`: an already configured install is marked done without a window;
    /// returns whether the window should open.
    @MainActor static func settle(_ store: AppStore) -> Bool {
        if !LegacySurface.isShown(store.defaults) {
            if needsWizard(defaults: store.defaults, bots: store.bots) { return true }
            if state(store.defaults) == nil { record(.done, in: store.defaults) }
            return false
        }
        guard state(store.defaults) == nil else { return false }
        if needsSetup(defaults: store.defaults, keyStore: store.keyStore, bots: store.bots) { return true }
        record(.done, in: store.defaults)
        return false
    }

    static func record(_ value: State, in defaults: UserDefaults) { defaults.set(value.rawValue, forKey: stateKey) }

    /// Closing the window without finishing counts as "skipped" so it never nags: on a first run, and whenever there
    /// is still no bot (the wizard would otherwise open again at the next launch). A finished setup stays done.
    static func dismissed(_ defaults: UserDefaults, hasBots: Bool = true) { if state(defaults) == nil || !hasBots { record(.skipped, in: defaults) } }
}

/// The person's name (D6): the saved "Your name", else the first word of the macOS account's full name.
/// Built at send time and never stored in transcripts.
enum UserIdentity {
    static let key = SidebarMetrics.accountNameKey

    static func name(defaults: UserDefaults, fullName: String = NSFullUserName()) -> String {
        let saved = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? fallback(fullName) : saved
    }

    /// The first word of the macOS account's full name; only used while "Your name" is empty.
    static func fallback(_ fullName: String = NSFullUserName()) -> String {
        fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? GroupRouting.defaultUserName
    }

    /// The sidebar's round button: the first letter of the saved name, else of the fallback.
    static func initial(of saved: String, fullName: String = NSFullUserName()) -> String {
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return SidebarMetrics.initial(of: trimmed.isEmpty ? fallback(fullName) : trimmed)
    }
}
