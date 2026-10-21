import Foundation

enum Loadable<Value: Equatable & Sendable>: Equatable, Sendable {
    case loading, loaded(Value), unavailable(String), failed(String)
    var value: Value? { if case .loaded(let value) = self { value } else { nil } }
}

struct CurrentModel: Equatable, Sendable {
    let model: String; let provider: String?; let source: String
    /// An unpinned chat's session row names the model its last reply ran on; set only when that differs from `model`
    /// (the agent default its next reply uses).
    var lastReplyModel: String? = nil
    /// The source of a chat that runs on what the agent's backend reports as its default.
    static let agentDefault = "agent default"
}

/// What the bot's Hermes profile reports about itself: skills, toolsets and model choice.
struct BotServerInfo: Equatable, Sendable {
    var capabilities: HermesCapabilities?
    var skills: Loadable<[HermesSkill]> = .loading
    var toolsets: Loadable<[HermesToolset]> = .loading
    var modelOptions: Loadable<HermesModelOptions> = .loading
    /// P17: a non-Hermes backend's catalog (`ModelCatalogProviding`); nil for Hermes, whose catalog is mapped.
    var sourceCatalog: Loadable<ModelCatalog>?
    /// When the shown list was read, and why the last refresh failed while a good list is kept (memory only).
    var modelsAsOf: Date?
    var refreshError: String?
    /// What `/health` said on the last load (P24); nil before the first.
    var hermesVersion: HermesVersionReading?
    /// Known Hermes bugs this load ran into, shown as notes instead of errors (P24).
    var knownLimitations: [HermesKnownIssue] { HermesKnownIssue.allCases.filter { skills == .unavailable($0.note) } }
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
        if case .failed = sourceCatalog { return true }
        return refreshError != nil
    }

    /// The neutral catalog every surface reads: the source's own, else `modelOptions` mapped for `profile` (by
    /// default the profile this entry was read for).
    func catalog(profile: String? = nil) -> Loadable<ModelCatalog> {
        if let sourceCatalog { return sourceCatalog }
        let name = profile ?? scope.flatMap { $0.split(separator: "|").last.map(String.init) } ?? "default"
        switch modelOptions {
        case .loading: return .loading
        case .loaded(let options): return .loaded(options.catalog(profile: name))
        case .unavailable(let reason): return .unavailable(reason)
        case .failed(let reason): return .failed(reason)
        }
    }
    var catalog: Loadable<ModelCatalog> { catalog() }

    /// The picker shows only when the server offers model options; switching also needs the session lock route.
    var showsModelPicker: Bool { catalog.value != nil }
    var canLockSessionModel: Bool { capabilities?.sessionModelLock == true }
}

/// Per-bot cache for the app session (memory only). Views read `entries`; loads go through `AppStore`.
@MainActor final class BotInfoCache: ObservableObject {
    @Published private(set) var entries: [UUID: BotServerInfo] = [:]
    /// The Hermes version per connection (`scope`), from the last Overview load or Settings read; memory only.
    @Published private(set) var versions: [String: HermesVersionReading] = [:]
    /// Off for headless and test stores: views then never fetch on appear; callers load explicitly.
    var autoLoad = true
    /// Entries older than this are fetched again when the Overview appears; never polled.
    static let maxAge: TimeInterval = 300
    var now: () -> Date = { Date() }
    /// One load per bot; a second caller joins it instead of returning early (P17).
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    func info(for botID: UUID) -> BotServerInfo? { entries[botID] }

    nonisolated static func scope(of backend: HermesBackend) -> String { "\(backend.baseURL.absoluteString)|\(backend.profile)" }

    /// A load is due when there is no entry, it failed last time, it was read for another scope or session id, or it
    /// is older than `maxAge`.
    func isStale(botID: UUID, sessionID: String?, scope: String) -> Bool {
        guard let info = entries[botID], let fetchedAt = info.fetchedAt else { return true }
        return info.lastLoadFailed || info.scope != scope || info.sessionID != sessionID || now().timeIntervalSince(fetchedAt) >= Self.maxAge
    }

    /// `includeSkills: false` (Settings → Models) skips `/v1/skills`; an entry still without skills is then stale for
    /// a full load, so the Overview fetches them when it opens.
    /// A load already running for the bot is joined; afterwards "due" is checked again (skills included), so a
    /// skills-less join never leaves the Overview's skills unloaded and a first send never reads `.loading`.
    func load(botID: UUID, sessionID: String?, using backend: HermesBackend, force: Bool = false, includeSkills: Bool = true) async {
        let scope = Self.scope(of: backend)
        await run(botID: botID, sessionID: sessionID, scope: scope, force: force, due: { includeSkills && $0?.skills == .loading }) { previous in
            await Self.fetch(sessionID: sessionID, using: backend, previous: previous, includeSkills: includeSkills)
        }
    }

    /// P17: the same entry, staleness and join for a backend that supplies its own catalog (no skills or toolsets).
    func loadCatalog(botID: UUID, sessionID: String?, using provider: any ModelCatalogProviding, force: Bool = false) async {
        await run(botID: botID, sessionID: sessionID, scope: provider.catalogScope, force: force, due: { _ in false }) { previous in
            var info = previous
            info.isRefreshing = false; info.lastLoadFailed = false; info.capabilities = nil
            let reason = "This agent's backend reports no skills or tools here."
            (info.skills, info.toolsets) = (.unavailable(reason), .unavailable(reason))
            do { info.sourceCatalog = .loaded(try await provider.modelCatalog(sessionID: sessionID)) }
            catch BackendError.http(let code, _) where code == 404 || code == 405 { info.sourceCatalog = .unavailable("This agent's backend does not list its models.") }
            catch BackendError.unavailable(let text) { info.sourceCatalog = .unavailable(Self.describe(BackendError.unavailable(text), secrets: provider.secrets)) }
            catch { info.sourceCatalog = .failed(Self.describe(error, secrets: provider.secrets)) }
            return info
        }
    }

    private func run(botID: UUID, sessionID: String?, scope: String, force: Bool, due: (BotServerInfo?) -> Bool,
                     fetch: @escaping @Sendable (BotServerInfo) async -> BotServerInfo) async {
        var force = force
        while let running = inFlight[botID] { await running.value; force = false }
        guard force || isStale(botID: botID, sessionID: sessionID, scope: scope) || due(entries[botID]) else { return }
        var info = entries[botID] ?? BotServerInfo()
        info.isRefreshing = true
        if !info.isSwitchingModel { info.modelError = nil }
        entries[botID] = info
        let generation = info.switchGeneration, previous = info
        // The task clears its own slot before it completes, so a joiner never sees a finished load as running.
        let task = Task { @MainActor in
            let fetched = await fetch(previous)
            self.merge(fetched, botID: botID, generation: generation, scope: scope, sessionID: sessionID)
            self.inFlight[botID] = nil
        }
        inFlight[botID] = task
        await task.value
    }

    /// Writes a finished fetch into the entry as it is now, so a switch that ran meanwhile keeps its state.
    private func merge(_ fetched: BotServerInfo, botID: UUID, generation: Int, scope: String, sessionID: String?) {
        var info = entries[botID] ?? fetched
        let previous = info
        info.capabilities = fetched.capabilities
        info.hermesVersion = fetched.hermesVersion
        if let reading = fetched.hermesVersion { versions[scope] = reading }
        (info.skills, info.toolsets, info.modelOptions, info.sourceCatalog) = (fetched.skills, fetched.toolsets, fetched.modelOptions, fetched.sourceCatalog)
        // Keep-last-good: only a `.failed` refresh in the same scope keeps the list; nothing crosses profiles.
        info.refreshError = nil
        if case .failed(let reason) = fetched.catalog, previous.scope == scope, previous.catalog.value != nil {
            (info.modelOptions, info.sourceCatalog, info.refreshError) = (previous.modelOptions, previous.sourceCatalog, reason)
        } else { info.modelsAsOf = fetched.catalog.value == nil ? nil : now() }
        if info.switchGeneration == generation, !info.isSwitchingModel { (info.sessionModel, info.sessionModelSessionID) = (fetched.sessionModel, fetched.sessionModelSessionID) }
        info.isRefreshing = false
        info.fetchedAt = now(); info.scope = scope; info.sessionID = sessionID
        info.lastLoadFailed = fetched.lastLoadFailed || fetched.failedAnything
        entries[botID] = info
    }

    nonisolated static func fetch(sessionID: String?, using backend: HermesBackend, previous: BotServerInfo = .init(), includeSkills: Bool = true) async -> BotServerInfo {
        var info = previous
        info.isRefreshing = false; info.lastLoadFailed = false
        async let reading = backend.hermesVersion()
        let capabilities: HermesCapabilities?
        do { capabilities = try await backend.capabilities() }
        catch let deferred as HermesStatusDeferred {
            _ = await reading
            // Keep the last good snapshot; a later scheduled refresh retries after the host cooldown.
            if info.skills.value == nil { info.skills = .unavailable(deferred.localizedDescription) }
            if info.toolsets.value == nil { info.toolsets = .unavailable(deferred.localizedDescription) }
            if info.modelOptions.value == nil { info.modelOptions = .unavailable(deferred.localizedDescription) }
            return info
        }
        catch {
            info.hermesVersion = await reading
            let reason = describe(error, secrets: [backend.apiKey])
            info.skills = .failed(reason); info.toolsets = .failed(reason); info.modelOptions = .failed(reason)
            info.lastLoadFailed = true
            return info
        }
        info.capabilities = capabilities
        let version = await reading
        info.hermesVersion = version
        guard let capabilities else {
            let reason = "This Hermes server does not report its capabilities."
            info.skills = .unavailable(reason); info.toolsets = .unavailable(reason); info.modelOptions = .unavailable(reason)
            return info
        }
        let previousSkills = previous.skills
        let known = { @Sendable (error: Error) in HermesCompatibility.limitation(for: error, version: version.version)?.note }
        async let skills = includeSkills ? optional(capabilities.skills, "This server does not list its skills.", key: backend.apiKey, previous: previous.skills, known: known) { try await backend.skills() } : previousSkills
        async let toolsets = optional(capabilities.toolsets, "This server does not list its toolsets.", key: backend.apiKey, previous: previous.toolsets) { try await backend.toolsets() }
        async let options = optional(capabilities.modelOptions, "This server does not offer model options.", key: backend.apiKey, previous: previous.modelOptions) { try await backend.modelOptions() }
        (info.skills, info.toolsets, info.modelOptions) = await (skills, toolsets, options)
        // A failed read keeps the last good value; `sessionModelSessionID` says which session it describes.
        if let sessionID, capabilities.features["session_resources"] != false {
            do { (info.sessionModel, info.sessionModelSessionID) = (try await backend.sessionModel(sessionID: sessionID), sessionID) } catch {}
        }
        return info
    }

    /// Runs `fetch` only when the server advertises the feature; a 404 or 405 means the route is absent. `known` turns a
    /// known Hermes bug's exact symptom into its calm note (unavailable, not failed).
    private nonisolated static func optional<T: Equatable & Sendable>(_ supported: Bool, _ offReason: String, key: String, previous: Loadable<T> = .loading,
                                                                    known: @Sendable (Error) -> String? = { _ in nil },
                                                                    _ fetch: @Sendable () async throws -> T) async -> Loadable<T> {
        guard supported else { return .unavailable(offReason) }
        do { return .loaded(try await fetch()) }
        catch BackendError.http(let code, _) where code == 404 || code == 405 { return .unavailable(offReason) }
        catch let deferred as HermesStatusDeferred { return previous.value == nil ? .unavailable(deferred.localizedDescription) : previous }
        catch { return known(error).map { .unavailable($0) } ?? .failed(describe(error, key: key)) }
    }

    /// Reads the connection's version for Settings when no Overview load has (or `force`).
    func loadVersion(using backend: HermesBackend, force: Bool = false) async {
        let scope = Self.scope(of: backend)
        guard force || versions[scope] == nil else { return }
        versions[scope] = await backend.hermesVersion()
    }

    nonisolated static func describe(_ error: Error, key: String) -> String { describe(error, secrets: [key]) }
    nonisolated static func describe(_ error: Error, secrets: [String]) -> String {
        var text: String
        if case BackendError.http(let code, _) = error, code == 401 || code == 403 { text = "HTTP \(code): the server rejected this bot's key." }
        else { text = error.localizedDescription }
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[key]") }
        return text
    }

    /// Model shown for the chat: a lock confirmed for this session (unless the session row reports a different
    /// concrete model, i.e. another client changed it), else the agent default (an unpinned chat's next reply runs on
    /// it; Hermes' row only names the model the last reply ran on, carried as `lastReplyModel` when it differs), else
    /// the session row's model (unless it is the gateway's virtual alias, which means "server default").
    nonisolated static func currentModel(lock: HermesModelLock?, sessionID: String?, sessionModel: String?, aliases: Set<String>, options: HermesModelOptions?) -> CurrentModel? {
        currentModel(lock: lock, sessionID: sessionID, sessionModel: sessionModel, aliases: aliases, catalog: options?.catalog(profile: ""))
    }
    nonisolated static func currentModel(lock: HermesModelLock?, sessionID: String?, sessionModel: String?, aliases: Set<String>, catalog: ModelCatalog?) -> CurrentModel? {
        let rowModel = sessionModel.flatMap { aliases.contains($0) ? nil : $0 }
        if let lock, lock.sessionID == sessionID, rowModel.map({ ModelCatalog.sameModel($0, lock.model) }) ?? true {
            return .init(model: lock.model, provider: lock.provider.isEmpty ? nil : lock.provider, source: "chosen for this chat")
        }
        if let agentDefault = catalog?.agentDefault {
            let lastReply = rowModel.flatMap { ModelCatalog.sameModel($0, agentDefault.model) ? nil : $0 }
            return .init(model: agentDefault.model, provider: agentDefault.supplier, source: CurrentModel.agentDefault, lastReplyModel: lastReply)
        }
        if let rowModel { return .init(model: rowModel, provider: nil, source: "this chat") }
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
