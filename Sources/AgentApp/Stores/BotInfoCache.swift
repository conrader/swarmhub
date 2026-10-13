import Foundation

enum Loadable<Value: Equatable & Sendable>: Equatable, Sendable {
    case loading, loaded(Value), unavailable(String), failed(String)
    var value: Value? { if case .loaded(let value) = self { value } else { nil } }
}

struct CurrentModel: Equatable, Sendable { let model: String; let provider: String?; let source: String }

/// What the bot's Hermes profile reports about itself: skills, toolsets and model choice.
struct BotServerInfo: Equatable, Sendable {
    var capabilities: HermesCapabilities?
    var skills: Loadable<[HermesSkill]> = .loading
    var toolsets: Loadable<[HermesToolset]> = .loading
    var modelOptions: Loadable<HermesModelOptions> = .loading
    var sessionModel: String?
    /// The session `sessionModel` was read (or acknowledged) for; a value for another session is ignored.
    var sessionModelSessionID: String?
    var isRefreshing = true
    var isSwitchingModel = false
    var modelError: String?
    /// When, for which `baseURL|profile` and which session id this entry was last fetched.
    var fetchedAt: Date?
    var scope: String?
    var sessionID: String?
    var lastLoadFailed = false
    /// Bumped when a switch starts or is acknowledged, so a reload that overlaps it does not overwrite the session model.
    var switchGeneration = 0

    var failedAnything: Bool {
        if case .failed = skills { return true }
        if case .failed = toolsets { return true }
        if case .failed = modelOptions { return true }
        return false
    }

    /// The picker shows only when the server offers model options; switching also needs the session lock route.
    var showsModelPicker: Bool { modelOptions.value != nil }
    var canLockSessionModel: Bool { capabilities?.sessionModelLock == true }
}

/// Per-bot cache for the app session (memory only). Views read `entries`; loads go through `AppStore`.
@MainActor final class BotInfoCache: ObservableObject {
    @Published private(set) var entries: [UUID: BotServerInfo] = [:]
    /// Off for headless and test stores: views then never fetch on appear; callers load explicitly.
    var autoLoad = true
    /// Entries older than this are fetched again when the Overview appears; never polled.
    static let maxAge: TimeInterval = 300
    var now: () -> Date = { Date() }
    private var inFlight: Set<UUID> = []

    func info(for botID: UUID) -> BotServerInfo? { entries[botID] }

    nonisolated static func scope(of backend: HermesBackend) -> String { "\(backend.baseURL.absoluteString)|\(backend.profile)" }

    /// A load is due when there is no entry, it failed last time, it was read for another scope or session id, or it
    /// is older than `maxAge`.
    func isStale(botID: UUID, sessionID: String?, scope: String) -> Bool {
        guard let info = entries[botID], let fetchedAt = info.fetchedAt else { return true }
        return info.lastLoadFailed || info.scope != scope || info.sessionID != sessionID || now().timeIntervalSince(fetchedAt) >= Self.maxAge
    }

    func load(botID: UUID, sessionID: String?, using backend: HermesBackend, force: Bool = false) async {
        let scope = Self.scope(of: backend)
        if !force, !isStale(botID: botID, sessionID: sessionID, scope: scope) { return }
        guard inFlight.insert(botID).inserted else { return }
        defer { inFlight.remove(botID) }
        var info = entries[botID] ?? BotServerInfo()
        info.isRefreshing = true
        if !info.isSwitchingModel { info.modelError = nil }
        entries[botID] = info
        let generation = info.switchGeneration
        let fetched = await Self.fetch(sessionID: sessionID, using: backend, previous: info)
        merge(fetched, botID: botID, generation: generation, scope: scope, sessionID: sessionID)
    }

    /// Writes a finished fetch into the entry as it is now, so a switch that ran meanwhile keeps its state.
    private func merge(_ fetched: BotServerInfo, botID: UUID, generation: Int, scope: String, sessionID: String?) {
        var info = entries[botID] ?? fetched
        info.capabilities = fetched.capabilities
        (info.skills, info.toolsets, info.modelOptions) = (fetched.skills, fetched.toolsets, fetched.modelOptions)
        if info.switchGeneration == generation, !info.isSwitchingModel { (info.sessionModel, info.sessionModelSessionID) = (fetched.sessionModel, fetched.sessionModelSessionID) }
        info.isRefreshing = false
        info.fetchedAt = now(); info.scope = scope; info.sessionID = sessionID
        info.lastLoadFailed = fetched.lastLoadFailed || fetched.failedAnything
        entries[botID] = info
    }

    nonisolated static func fetch(sessionID: String?, using backend: HermesBackend, previous: BotServerInfo = .init()) async -> BotServerInfo {
        var info = previous
        info.isRefreshing = false; info.lastLoadFailed = false
        let capabilities: HermesCapabilities?
        do { capabilities = try await backend.capabilities() }
        catch {
            let reason = describe(error, key: backend.apiKey)
            info.skills = .failed(reason); info.toolsets = .failed(reason); info.modelOptions = .failed(reason)
            info.lastLoadFailed = true
            return info
        }
        info.capabilities = capabilities
        guard let capabilities else {
            let reason = "This Hermes server does not report its capabilities."
            info.skills = .unavailable(reason); info.toolsets = .unavailable(reason); info.modelOptions = .unavailable(reason)
            return info
        }
        async let skills = optional(capabilities.skills, "This server does not list its skills.", key: backend.apiKey) { try await backend.skills() }
        async let toolsets = optional(capabilities.toolsets, "This server does not list its toolsets.", key: backend.apiKey) { try await backend.toolsets() }
        async let options = optional(capabilities.modelOptions, "This server does not offer model options.", key: backend.apiKey) { try await backend.modelOptions() }
        (info.skills, info.toolsets, info.modelOptions) = await (skills, toolsets, options)
        // A failed read keeps the last good value; `sessionModelSessionID` says which session it describes.
        if let sessionID, capabilities.features["session_resources"] != false {
            do { (info.sessionModel, info.sessionModelSessionID) = (try await backend.sessionModel(sessionID: sessionID), sessionID) } catch {}
        }
        return info
    }

    /// Runs `fetch` only when the server advertises the feature; a 404 or 405 means the route is absent.
    private nonisolated static func optional<T: Equatable & Sendable>(_ supported: Bool, _ offReason: String, key: String, _ fetch: @Sendable () async throws -> T) async -> Loadable<T> {
        guard supported else { return .unavailable(offReason) }
        do { return .loaded(try await fetch()) }
        catch BackendError.http(let code, _) where code == 404 || code == 405 { return .unavailable(offReason) }
        catch { return .failed(describe(error, key: key)) }
    }

    nonisolated static func describe(_ error: Error, key: String) -> String {
        let text: String
        if case BackendError.http(let code, _) = error, code == 401 || code == 403 { text = "HTTP \(code): the server rejected this bot's key." }
        else { text = error.localizedDescription }
        return key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[key]")
    }

    /// Model shown for the chat: a lock confirmed for this session (unless the session row reports a different
    /// concrete model, i.e. another client changed it), else the session row's model (unless it is the gateway's
    /// virtual alias, which means "server default"), else the server's configured default.
    nonisolated static func currentModel(lock: HermesModelLock?, sessionID: String?, sessionModel: String?, aliases: Set<String>, options: HermesModelOptions?) -> CurrentModel? {
        let rowModel = sessionModel.flatMap { aliases.contains($0) ? nil : $0 }
        if let lock, lock.sessionID == sessionID, rowModel.map({ HermesModelOptions.sameModel($0, lock.model) }) ?? true {
            return .init(model: lock.model, provider: lock.provider.isEmpty ? nil : lock.provider, source: "chosen for this chat")
        }
        if let rowModel { return .init(model: rowModel, provider: nil, source: "this chat") }
        if let model = options?.model { return .init(model: model, provider: options?.provider, source: "server default") }
        return nil
    }

    nonisolated static func isCurrent(_ model: String, provider: String, current: CurrentModel?) -> Bool {
        guard let current, current.model == model else { return false }
        return current.provider == nil || current.provider == provider
    }

    func replace(botID: UUID, with info: BotServerInfo) { entries[botID] = info }
    func beginSwitch(botID: UUID) { entries[botID]?.isSwitchingModel = true; entries[botID]?.modelError = nil; entries[botID]?.switchGeneration += 1 }
    /// Records the model the box acknowledged (or read back) for `sessionID` at once.
    func setSessionModel(botID: UUID, sessionID: String, model: String) {
        entries[botID]?.sessionModel = model; entries[botID]?.sessionModelSessionID = sessionID; entries[botID]?.switchGeneration += 1
    }
    func finishSwitch(botID: UUID, error: String?) { entries[botID]?.isSwitchingModel = false; entries[botID]?.modelError = error }
}
