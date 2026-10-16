import Combine
import Foundation

struct ConnectedAppsConfiguration: Codable, Sendable, Equatable {
    var userID = "swarmhub_" + UUID().uuidString.lowercased()
    var projectID: String?
    /// Bot UUID → explicit connected-account IDs. An import request never becomes a grant.
    var grants: [String: [String]] = [:]
    /// Non-secret app names for granted accounts, available before the first network request after restart.
    var appToolkits: [String: String]?
}

enum AppApprovalOrigin: Equatable, Sendable {
    /// The chat tool loop is waiting on `AppToolApprovalBroker`.
    case chat
    /// The SwarmHub worker inbox's request id.
    case background(requestID: String)
}

/// P48: app → this bot's granted account ids (1–10 each) and each account's name at the time the run started.
struct ComposioRunScope: Sendable {
    let client: ComposioClient; let userID: String; let accounts: [String: [String]]
    var labels: [String: String] = [:]
    let revision: UUID
    /// Any app with several accounts makes the whole session multi-account; then every execute names its account.
    var isMultiAccount: Bool { accounts.values.contains { $0.count > 1 } }
}

/// P38 B: Composio app connections. The project key lives in the key store (`keyAccount`); `connected-apps.json` holds
/// only the Composio user id, the project id and which bot may use which connected account. Receipts and full results
/// of app actions sit beside it (`ToolExecutionReceipt.swift`).
@MainActor final class ConnectedAppsStore: ObservableObject {
    static let keyAccount = "composio.project-key"
    @Published private(set) var configuration = ConnectedAppsConfiguration()
    @Published var accounts: [ComposioAccount] = []
    @Published private(set) var catalog = ComposioToolkit.popular
    @Published private(set) var nextCursor: String?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var pendingLink: URL?
    /// Set when the SwarmHub connection service answered that it is not set up (`/health` 503).
    @Published var serviceNote: String?
    /// P40: the app whose first connection failed while getting the project key; Settings offers Retry for it.
    @Published private(set) var retryToolkit: String?
    /// P47: the app a Settings connection just turned on for every eligible bot (the pane says so once).
    @Published private(set) var grantedToAllToolkit: String?
    /// P48: that account, so the line can name it ("Gmail · konrad@…").
    @Published private(set) var grantedToAllAccountID: String?
    /// P48: accounts whose name SwarmHub is reading now ("Getting the account name…"), and those it tried this launch.
    @Published var namingAccounts: Set<String> = []
    var namingAttempted: Set<String> = []
    /// P52: read or write per tool slug (`access(of:)`), memory only.
    var toolAccess: [String: AppToolAccess] = [:]
    let approvals = AppToolApprovalBroker()
    /// The app action cards SwarmHub made itself (by card id). Only these are decided locally; an approval from a bot's
    /// server is never treated as an app action, whatever its action kind says.
    var localApprovals: [UUID: AppApprovalOrigin] = [:]
    @Published var receipts: [ToolExecutionReceipt] = []
    let directory: URL
    private let fileURL: URL; private let keyStore: any HermesKeyStore; private let session: URLSession
    private let apiURL: URL
    let provisioner: (any ComposioProvisioning)?
    private var revision = UUID(); private var searchToken = UUID(); private var persistenceEnabled: Bool
    private var catalogQuery = ""
    private var authSession: (client: ComposioClient, id: String, toolkit: String)?
    /// P47: a connection started in Settings → Connected apps: the accounts that existed before it, and the bots its new
    /// account is granted to when it first appears. Cleared once granted, so a later refresh never grants again.
    private var settingsConnection: (toolkit: String, known: Set<String>, bots: [UUID])?

    init(directory: URL, keyStore: any HermesKeyStore, session: URLSession = ComposioClient.defaultSession, apiURL: URL = ComposioClient.productionURL,
         provisioner: (any ComposioProvisioning)? = nil, persistenceEnabled: Bool = true) {
        self.directory = directory
        fileURL = directory.appending(path: "connected-apps.json"); self.keyStore = keyStore; self.session = session
        self.apiURL = apiURL
        self.provisioner = provisioner
        self.persistenceEnabled = persistenceEnabled
        if persistenceEnabled, FileManager.default.fileExists(atPath: fileURL.path) {
            do { configuration = try JSONDecoder().decode(ConnectedAppsConfiguration.self, from: Data(contentsOf: fileURL)) }
            catch { self.persistenceEnabled = false; self.error = "Connected app settings could not be read. The saved file has been preserved." }
        }
        if self.persistenceEnabled { loadReceipts() }
    }

    /// Something can connect: a key is saved, or this build has the SwarmHub connection service.
    var isAvailable: Bool { hasKey || provisioner != nil }
    var hasKey: Bool { keyStore.hasKey(for: Self.keyAccount) }
    /// The user's own Composio key (Advanced), not the project key SwarmHub provisioned, which always records its project.
    var usesOwnKey: Bool { hasKey && configuration.projectID == nil }
    var canConfigure: Bool { persistenceEnabled }
    func savedKey() -> String { keyStore.key(for: Self.keyAccount) }
    var client: ComposioClient { .init(apiKey: savedKey(), session: session, baseURL: apiURL) }

    @discardableResult func saveKey(_ value: String) -> Bool {
        guard persistenceEnabled, !busy else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = savedKey()
        keyStore.setKey(key, for: Self.keyAccount)
        guard savedKey() == key else { error = "The Composio key could not be saved to Keychain."; return false }
        if key != previous {
            if let authSession { Task { await authSession.client.deleteSession(authSession.id) }; self.authSession = nil }
            configuration.grants = [:]; configuration.projectID = nil; configuration.appToolkits = nil
            settingsConnection = nil; grantedToAllToolkit = nil; grantedToAllAccountID = nil
            accounts = []; catalog = key.isEmpty ? ComposioToolkit.popular : []; nextCursor = nil; pendingLink = nil
            revision = UUID(); searchToken = UUID()
        }
        error = nil; return persist()
    }

    func refresh() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let service = client
            accounts = try await service.accounts(userID: configuration.userID)
            grantSettingsConnection()
            await nameUnnamedAccounts(using: service)
            if let authSession, accounts.contains(where: { $0.toolkit == authSession.toolkit && $0.isActive }) {
                await authSession.client.deleteSession(authSession.id); self.authSession = nil; pendingLink = nil
            }
        }
        catch { self.error = describe(error) }
    }

    func search(_ query: String, more: Bool = false) async {
        if !hasKey {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            catalog = ComposioToolkit.popular.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.id.localizedCaseInsensitiveContains(term) }
            nextCursor = nil; return
        }
        let token = UUID(); searchToken = token
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more { catalogQuery = trimmed; nextCursor = nil }
        do {
            let page = try await client.catalog(search: catalogQuery, cursor: more ? nextCursor : nil)
            guard searchToken == token else { return }
            catalog = more ? catalog + page.items.filter { item in !catalog.contains(where: { $0.id == item.id }) } : page.items
            nextCursor = page.cursor; error = nil
        } catch { if searchToken == token { self.error = describe(error) } }
    }

    /// Open this link on the user's Mac. Tokens stay with Composio, not in bot prompts or local JSON.
    /// P47: `grantingTo` is Settings' connect: the new account is turned on for these bots when it appears (a chat's
    /// connect card passes nil and grants its one bot itself).
    func connect(_ toolkit: String, grantingTo bots: [UUID]? = nil) async -> URL? {
        guard !busy, persistenceEnabled else { return nil }; busy = true; error = nil; retryToolkit = nil; defer { busy = false }
        settingsConnection = nil; grantedToAllToolkit = nil; grantedToAllAccountID = nil
        do {
            do { try await ensureKeyForFirstConnection(toolkit) } catch { retryToolkit = toolkit; throw error }
            let service = client
            let known = try await service.accounts(userID: configuration.userID)
            // The accounts that exist now are never granted by this connection, whatever the pane had loaded.
            if let bots { settingsConnection = (toolkit, Set(known.map(\.id)), bots) }
            // P48: another account of an app that has one: a multi-account link session, so Composio adds it.
            let id = try await service.createSession(userID: configuration.userID, toolkits: [toolkit], addingAccount: known.contains { $0.toolkit == toolkit })
            do {
                let link = try await service.connect(sessionID: id, toolkit: toolkit)
                if let authSession { await authSession.client.deleteSession(authSession.id) }
                authSession = (service, id, toolkit); pendingLink = link; return link
            } catch { await service.deleteSession(id); throw error }
        } catch { self.error = describe(error); return nil }
    }

    /// Key creation is deferred to an explicit first Connect action. Browsing never creates a project.
    private func ensureKeyForFirstConnection(_ toolkit: String) async throws {
        guard !hasKey else { return }
        guard let provisioner else { throw ComposioProvisioningError.unavailable }
        guard persist() else { throw ComposioError.accessChanged }
        let credential = try await provisioner.credentialForFirstConnection(toolkit: toolkit)
        try Task.checkCancellation()
        keyStore.setKey(credential.apiKey, for: Self.keyAccount)
        guard savedKey() == credential.apiKey else { throw BackendError.unavailable("Your app connection key could not be saved to Keychain.") }
        configuration.userID = credential.userID; configuration.projectID = credential.projectID
        configuration.grants = [:]; configuration.appToolkits = nil; revision = UUID()
        guard persist() else { keyStore.setKey("", for: Self.keyAccount); throw ComposioError.accessChanged }
    }

    func disconnect(_ account: ComposioAccount) async {
        guard !busy, persistenceEnabled else { return }; busy = true; error = nil; defer { busy = false }
        // Revoke local access before the network call, including in-flight actions waiting for review.
        for bot in Array(configuration.grants.keys) { configuration.grants[bot]?.removeAll { $0 == account.id } }
        revision = UUID(); persist()
        do { try await client.deleteAccount(account.id); accounts.removeAll { $0.id == account.id } }
        catch { self.error = describe(error) }
    }

    /// P48: Rename… in Connected accounts. An empty name puts back the automatic one: the profile name where the app has
    /// one, else no alias (the fallback name).
    func rename(_ account: ComposioAccount, to name: String) async {
        guard !busy, persistenceEnabled else { return }; busy = true; error = nil; defer { busy = false }
        let service = client
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        do {
            if !wanted.isEmpty { _ = try await saveAlias(wanted, for: account, using: service) }
            else if AccountProfileName.table[account.toolkit] != nil, account.isActive {
                namingAccounts.insert(account.id); defer { namingAccounts.remove(account.id) }
                _ = try await saveAlias(try await profileName(of: account, using: service), for: account, using: service)
            } else { try await service.setAlias("", account: account.id) }
            accounts = try await service.accounts(userID: configuration.userID)
        } catch { self.error = describe(error) }
    }

    /// P47: the first new active account of the app a Settings connection asked for goes to every bot it named. P48: also
    /// to a bot that already has another account of that app (several accounts per app), up to 10 per app.
    private func grantSettingsConnection() {
        guard let pending = settingsConnection,
              let account = accounts.first(where: { $0.toolkit == pending.toolkit && $0.isActive && !pending.known.contains($0.id) }) else { return }
        settingsConnection = nil
        for bot in pending.bots {
            let ids = grants(for: bot)
            guard !ids.contains(account.id), grantedCount(of: account.toolkit, in: ids) < Self.accountsPerApp else { continue }
            configuration.grants[bot.uuidString] = (ids + [account.id]).sorted()
        }
        var names = configuration.appToolkits ?? [:]
        names[account.id] = account.toolkit; configuration.appToolkits = names
        revision = UUID(); persist(); grantedToAllToolkit = account.toolkit; grantedToAllAccountID = account.id
    }

    func grants(for botID: UUID) -> [String] { configuration.grants[botID.uuidString] ?? [] }
    func enabledToolkits(for botID: UUID) -> [String] {
        guard hasKey else { return [] }
        return Set(grants(for: botID).compactMap { id -> String? in
            if let account = accounts.first(where: { $0.id == id }) { return account.isActive ? account.toolkit : nil }
            guard let toolkit = configuration.appToolkits?[id], ComposioClient.validIdentifier(toolkit) else { return nil }
            return toolkit
        }).sorted()
    }
    func allows(_ account: ComposioAccount, botID: UUID) -> Bool { grants(for: botID).contains(account.id) }
    /// P48: what the bot sees: each enabled app with its granted accounts by name (an account not loaded yet by its id).
    func enabledAccounts(for botID: UUID) -> [String: [String]] {
        guard hasKey else { return [:] }
        var apps: [String: [String]] = [:]
        for id in grants(for: botID) {
            if let account = accounts.first(where: { $0.id == id }) { if account.isActive { apps[account.toolkit, default: []].append(account.label) } }
            else if let toolkit = configuration.appToolkits?[id], ComposioClient.validIdentifier(toolkit) { apps[toolkit, default: []].append(id) }
        }
        return apps.mapValues { $0.sorted() }
    }
    /// An app's name for people: the catalog's, the popular list's, else the identifier in words.
    func appName(_ slug: String) -> String { ComposioToolkit.displayName(slug, catalog: catalog) }
    /// A connection card may grant only an active account for the app shown to the user.
    @discardableResult func allowConnection(toolkit: String, accountID: String, botID: UUID) -> Bool {
        guard hasKey, persistenceEnabled, !busy,
              let account = accounts.first(where: { $0.id == accountID && $0.toolkit == toolkit && $0.isActive }) else { return false }
        setAllowed(true, account: account, botID: botID)
        return persistenceEnabled && allows(account, botID: botID)
    }
    /// P48: Composio's limit for one app's accounts in a session (`max_accounts_per_toolkit` 2–10).
    nonisolated static let accountsPerApp = 10
    func grantedCount(of toolkit: String, in ids: [String]) -> Int {
        ids.filter { id in (accounts.first { $0.id == id }?.toolkit ?? configuration.appToolkits?[id]) == toolkit }.count
    }
    /// P48: a bot may have several accounts of one app switched on, at most `accountsPerApp`.
    func setAllowed(_ allowed: Bool, account: ComposioAccount, botID: UUID) {
        guard persistenceEnabled, !busy, !allowed || account.isActive else { return }
        var ids = grants(for: botID).filter { $0 != account.id }
        if allowed {
            guard grantedCount(of: account.toolkit, in: ids) < Self.accountsPerApp else {
                error = ConnectedAppsCopy.accountsPerAppCap; return
            }
            ids.append(account.id)
            var names = configuration.appToolkits ?? [:]
            names[account.id] = account.toolkit; configuration.appToolkits = names
        }
        configuration.grants[botID.uuidString] = ids.isEmpty ? nil : ids.sorted()
        revision = UUID(); persist()
    }

    func removeBot(_ id: UUID) { configuration.grants[id.uuidString] = nil; revision = UUID(); persist() }

    func scope(for botID: UUID) async throws -> ComposioRunScope {
        let selected = grants(for: botID); let capturedRevision = revision; let service = client
        guard persistenceEnabled, !selected.isEmpty else { throw ComposioError.accessChanged }
        let live = try await service.accounts(userID: configuration.userID)
        guard revision == capturedRevision else { throw ComposioError.accessChanged }
        accounts = live
        let chosen = live.filter { selected.contains($0.id) && $0.isActive }
        let byApp = Dictionary(grouping: chosen, by: \.toolkit).mapValues { $0.map(\.id).sorted() }
        guard chosen.count == selected.count, byApp.values.allSatisfy({ $0.count <= Self.accountsPerApp }) else { throw ComposioError.accessChanged }
        return .init(client: service, userID: configuration.userID, accounts: byApp,
                     labels: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.label) }), revision: capturedRevision)
    }

    func check(_ scope: ComposioRunScope, botID: UUID, account: String) throws {
        guard persistenceEnabled, revision == scope.revision, grants(for: botID).contains(account), hasKey else { throw ComposioError.accessChanged }
    }

    @discardableResult private func persist() -> Bool {
        guard persistenceEnabled else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: fileURL, options: .atomic)
            return true
        } catch { persistenceEnabled = false; self.error = "Connected app settings could not be saved. App execution is disabled until the file can be saved."; return false }
    }
    func describe(_ error: Error) -> String {
        error.localizedDescription.replacingOccurrences(of: savedKey().isEmpty ? "\u{0}" : savedKey(), with: "[key]")
    }
}

/// An app action's approval belongs to SwarmHub. Stop cancels the waiter; no provider call is retried.
actor AppToolApprovalBroker {
    private var waiting: [UUID: CheckedContinuation<Bool, any Error>] = [:]
    func wait(_ request: ApprovalRequest, emit: @Sendable (AgentEvent) -> Void) async throws -> Bool {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting[request.id] = continuation; emit(.approval(request))
            }
        } onCancel: { Task { await self.cancel(request.id) } }
    }
    func decide(_ id: UUID, approved: Bool) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        continuation.resume(returning: approved); return true
    }
    private func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
