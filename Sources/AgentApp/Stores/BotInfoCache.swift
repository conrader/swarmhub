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
    var isRefreshing = true
    var isSwitchingModel = false
    var modelError: String?

    /// The picker shows only when the server offers model options; switching also needs the session lock route.
    var showsModelPicker: Bool { modelOptions.value != nil }
    var canLockSessionModel: Bool { capabilities?.sessionModelLock == true }
}

/// Per-bot cache for the app session (memory only). Views read `entries`; loads go through `AppStore`.
@MainActor final class BotInfoCache: ObservableObject {
    @Published private(set) var entries: [UUID: BotServerInfo] = [:]
    /// Off for headless and test stores: views then never fetch on appear; callers load explicitly.
    var autoLoad = true
    private var inFlight: Set<UUID> = []

    func info(for botID: UUID) -> BotServerInfo? { entries[botID] }

    func load(botID: UUID, sessionID: String?, using backend: HermesBackend, force: Bool = false) async {
        if !force, entries[botID] != nil { return }
        guard inFlight.insert(botID).inserted else { return }
        defer { inFlight.remove(botID) }
        var info = entries[botID] ?? BotServerInfo()
        info.isRefreshing = true; info.modelError = nil; entries[botID] = info
        entries[botID] = await Self.fetch(sessionID: sessionID, using: backend, previous: info)
    }

    nonisolated static func fetch(sessionID: String?, using backend: HermesBackend, previous: BotServerInfo = .init()) async -> BotServerInfo {
        var info = previous
        info.isRefreshing = false
        let capabilities: HermesCapabilities?
        do { capabilities = try await backend.capabilities() }
        catch {
            let reason = describe(error, key: backend.apiKey)
            info.skills = .failed(reason); info.toolsets = .failed(reason); info.modelOptions = .unavailable(reason)
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
        if let sessionID, capabilities.features["session_resources"] != false {
            info.sessionModel = try? await backend.sessionModel(sessionID: sessionID)
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

    /// Model shown for the chat: a lock confirmed for this session, else the session row's model (unless it is the
    /// gateway's virtual alias, which means "server default"), else the server's configured default.
    nonisolated static func currentModel(lock: HermesModelLock?, sessionID: String?, sessionModel: String?, aliases: Set<String>, options: HermesModelOptions?) -> CurrentModel? {
        if let lock, lock.sessionID == sessionID { return .init(model: lock.model, provider: lock.provider.isEmpty ? nil : lock.provider, source: "chosen for this chat") }
        if let sessionModel, !aliases.contains(sessionModel) { return .init(model: sessionModel, provider: nil, source: "this chat") }
        if let model = options?.model { return .init(model: model, provider: options?.provider, source: "server default") }
        return nil
    }

    nonisolated static func isCurrent(_ model: String, provider: String, current: CurrentModel?) -> Bool {
        guard let current, current.model == model else { return false }
        return current.provider == nil || current.provider == provider
    }

    func replace(botID: UUID, with info: BotServerInfo) { entries[botID] = info }
    func beginSwitch(botID: UUID) { entries[botID]?.isSwitchingModel = true; entries[botID]?.modelError = nil }
    func finishSwitch(botID: UUID, error: String?) { entries[botID]?.isSwitchingModel = false; entries[botID]?.modelError = error }
}
