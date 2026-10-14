import Foundation

/// A key store that lives only in memory: `--setup-preview` and `--render-setup` never touch the Keychain.
final class MemoryKeyStore: HermesKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String] = [:]
    func key(for account: String) -> String { lock.withLock { values[account] ?? "" } }
    func setKey(_ value: String, for account: String) { lock.withLock { values[account] = value.isEmpty ? nil : value } }
}

/// `--setup-preview` (P21 item 16): the real app on a temporary store, an in-memory key store and a throwaway settings
/// suite, so the wizard can be clicked through without touching the real agents. Settings show "off in preview".
@MainActor enum SetupPreview {
    static let flag = "--setup-preview"

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool { arguments.contains(flag) }

    /// `backendFactory`: P28 D6, shots whose bots must never reach a server (the activity shots render a Hermes chat).
    static func makeStore(backendFactory: ((Bot) throws -> any AgentBackend)? = nil) -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentApp-setup-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "AgentApp-setup-preview-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("no throwaway settings suite") }
        defaults.removePersistentDomain(forName: suite)
        let store = AppStore(storeURL: directory.appending(path: "store.json"), autoConfigureHermes: false, backendFactory: backendFactory, keyStore: MemoryKeyStore(), defaults: defaults)
        store.isSetupPreview = true
        return store
    }
}
