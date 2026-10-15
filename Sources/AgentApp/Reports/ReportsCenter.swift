import AppKit
import Foundation

/// P36: the Reports inbox and the SwarmHub account, observed by the inbox, Settings and the sidebar badge. The inbox is
/// kept in `reports.json` next to store.json; the token lives only in the key store. Session, browser and sleep are
/// injected for tests (a mock URLProtocol session; nothing reaches the network or the Keychain).
@MainActor final class ReportsCenter: ObservableObject {
    enum Account: Equatable {
        case signedOut
        case signingIn
        case signedIn(expires: Date)
        /// A 401 forgot the token.
        case signInAgain
    }

    @Published var inbox = ReportsInbox() { didSet { if inbox != oldValue { persist() } } }
    @Published var account: Account = .signedOut
    @Published var selectedID: String?
    @Published var lastError: String?
    @Published var sendingID: String?
    @Published var refreshing = false

    let fileURL: URL?
    let keyStore: any HermesKeyStore
    var session = URLSession(configuration: TestRunGuard.guarded(.ephemeral))
    var openURL: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var maxPolls = 600
    var signInTask: Task<Bool, Never>?
    /// Connections whose close-reports turn is running.
    var closing: Set<String> = []

    init(fileURL: URL?, keyStore: any HermesKeyStore, now: Date = .now) {
        self.fileURL = fileURL; self.keyStore = keyStore
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(ReportsInbox.self, from: data) { inbox = saved }
        if let token = storedToken, token.isValid(at: now) { account = .signedIn(expires: token.expiresAt) }
    }

    var selected: SwarmReport? { selectedID.flatMap(inbox.report) }

    // MARK: Account

    var storedToken: SwarmHubToken? {
        let raw = keyStore.key(for: SwarmHubToken.account)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SwarmHubToken.self, from: data)
    }

    func store(_ token: SwarmHubToken) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(token) else { return }
        keyStore.setKey(String(decoding: data, as: UTF8.self), for: SwarmHubToken.account)
        account = .signedIn(expires: token.expiresAt)
    }

    /// Sign out (or a 401): the token is forgotten.
    func forgetToken(signInAgain: Bool) {
        signInTask?.cancel(); signInTask = nil
        keyStore.setKey("", for: SwarmHubToken.account)
        account = signInAgain ? .signInAgain : .signedOut
    }

    func token(at now: Date = .now) -> String? {
        guard let token = storedToken else { return nil }
        guard token.isValid(at: now) else { forgetToken(signInAgain: true); return nil }
        return token.accessToken
    }

    /// Starts (or joins) the browser sign-in; true when signed in at the end.
    @discardableResult func signIn(service: SwarmHubService) async -> Bool {
        if let signInTask { return await signInTask.value }
        account = .signingIn; lastError = nil
        let task = Task { [openURL, sleep, maxPolls] () -> Bool in
            do {
                let token = try await SwarmHubSignIn.run(service, maxPolls: maxPolls, open: openURL, sleep: sleep)
                store(token); return true
            } catch let error as SwarmHubError {
                account = error == .unauthorized ? .signInAgain : .signedOut; lastError = error.message; return false
            } catch {
                account = .signedOut; return false
            }
        }
        signInTask = task
        let ok = await task.value
        signInTask = nil
        return ok
    }

    // MARK: Persistence

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(inbox) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
