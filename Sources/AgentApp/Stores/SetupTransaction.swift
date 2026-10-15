import Foundation

/// P38: the setup commit's rollback journal. Every change records how to undo itself before it is made; when a step
/// (in practice the store write) throws, `run` undoes them newest first and throws `saveFailed`, so settings, keys,
/// bots, bindings, hidden flags and the selection are as they were. One transaction per commit; no network inside.
@MainActor final class SetupTransaction {
    private let store: AppStore
    private var undo: [() -> Void] = []
    init(_ store: AppStore) { self.store = store }

    /// Records the current value of each settings key (absent stays absent).
    func captureDefaults(_ keys: [String]) {
        let defaults = store.defaults
        for key in keys {
            let old = defaults.object(forKey: key)
            undo.append { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
    }

    /// Writes a key, recording the one it replaces (an empty one is removed again).
    func setKey(_ value: String, for account: String) {
        let keyStore = store.keyStore, old = keyStore.key(for: account)
        undo.append { keyStore.setKey(old, for: account) }
        keyStore.setKey(value, for: account)
    }

    /// The bot list with each bot's profile binding and hidden flag, the selection and the ignored-prefix profiles.
    func captureBots() {
        let store = store
        let bots = store.bots, bindings = bots.map { ($0, $0.hermesProfile) }, hidden = bots.map { ($0, $0.isHidden) }
        let selection = (store.selectedBot, store.selectedGroup), ignored = store.prefixIgnoredHermesProfiles
        undo.append {
            store.bots = bots
            for (bot, profile) in bindings { bot.hermesProfile = profile }
            for (bot, flag) in hidden { bot.isHidden = flag }
            (store.selectedBot, store.selectedGroup) = selection
            store.prefixIgnoredHermesProfiles = ignored
        }
    }

    /// Any other undo step, run in journal order with the rest.
    func record(_ step: @escaping () -> Void) { undo.append(step) }

    /// Runs `body`; on a throw rolls everything back and throws `saveFailed`.
    func run<T>(_ body: () throws -> T) throws -> T {
        do { let value = try body(); undo = []; return value }
        catch { rollback(); throw AppStore.SetupCommitError.saveFailed }
    }

    func rollback() {
        for step in undo.reversed() { step() }
        undo = []
        store.objectWillChange.send()
    }
}
