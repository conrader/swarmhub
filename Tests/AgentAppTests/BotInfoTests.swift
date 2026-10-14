import Foundation
import Testing
@testable import AgentApp

// Payload shapes copied from Hermes `gateway/platforms/api_server.py` (v2026.8.19 / v0.21.7) handlers:
// `_handle_capabilities`, `_handle_skills` (`_find_all_skills`), `_handle_toolsets`, `_handle_model_options`
// (`build_models_payload` + picker hints) and `_handle_session_model_lock`. All values are synthetic.

private func capabilitiesPayload(skills: Bool = true, modelOptions: Bool = true, modelLock: Bool = true) -> [String: Any] {
    ["object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "grok-test",
     "auth": ["type": "bearer", "required": true],
     "features": ["chat_completions": true, "session_resources": true, "model_options": modelOptions, "session_chat_streaming": true,
                  "session_model_lock": modelLock, "admin_config_rw": false, "memory_write_api": false, "skills_api": skills,
                  "session_continuity_header": "X-Hermes-Session-Id"],
     "endpoints": ["models": ["method": "GET", "path": "/v1/models"], "model_options": ["method": "GET", "path": "/api/model/options"],
                   "skills": ["method": "GET", "path": "/v1/skills"], "toolsets": ["method": "GET", "path": "/v1/toolsets"],
                   "session": ["method": "GET", "path": "/api/sessions/{session_id}"],
                   "session_model_lock": ["method": "POST", "path": "/api/sessions/{session_id}/model"]]]
}

private func skillsPayload() -> [String: Any] { ["object": "list", "data": [
    ["name": "weekly-report", "description": "Writes the weekly status report.\nSecond line is dropped.", "category": "productivity"],
    ["name": "tide-check", "description": "Looks up tide tables.", "category": NSNull()],
    ["name": "ledger", "description": "", "category": "finance"],
    ["name": "", "description": "nameless rows are skipped"]]] }

private func toolsetsPayload() -> [String: Any] { ["object": "list", "platform": "api_server", "data": [
    ["name": "web", "label": "Web search", "description": "Search and fetch pages", "enabled": true, "configured": true, "tools": ["web_extract", "web_search"]],
    ["name": "image_gen", "label": "Images", "description": "Generate images", "enabled": true, "configured": false, "tools": ["image_generate"]],
    ["name": "browser", "label": "", "description": "Drive a browser", "enabled": false, "configured": true, "tools": []]]] }

private func modelOptionsPayload() -> [String: Any] { ["model": "model-alpha", "provider": "lab-one", "providers": [
    ["slug": "lab-one", "name": "Lab One", "is_current": true, "is_user_defined": false, "models": ["model-alpha", "model-beta"], "total_models": 2,
     "source": "built-in", "authenticated": true, "auth_type": "api_key", "key_env": "LAB_ONE_API_KEY", "capabilities": ["model-alpha": ["fast": false, "reasoning": true]]],
    ["slug": "router", "name": "Router", "is_current": false, "models": [["id": "vendor/model-gamma"], ["name": "vendor/model-delta"]], "total_models": 40, "source": "hermes", "authenticated": true],
    ["slug": "lab-two", "name": "Lab Two", "is_current": false, "models": ["model-z"], "total_models": 1, "source": "canonical", "authenticated": false]]] }

private func requestBody(_ request: URLRequest) -> [String: Any]? {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private struct SendableBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

/// Serves `/p/grok-jarvis/...` like a multiplexed gateway. `lockStatus` controls the model-lock answer.
private func botInfoHandler(capabilities: [String: Any]?, modelOptionsStatus: Int = 200, lockStatus: Int = 200, sessionModel: Any = "grok-jarvis") -> MockHermesProtocol.Handler {
    let capabilities = capabilities.map { SendableBox($0) }, sessionModel = SendableBox(sessionModel)
    return { (request: URLRequest) -> (Int, Any) in
        let path = request.url!.path
        guard path.hasPrefix("/p/grok-jarvis/") else { return (404, ["error": "no route"]) }
        switch (request.httpMethod ?? "GET", String(path.dropFirst("/p/grok-jarvis".count))) {
        case ("GET", "/v1/capabilities"):
            if let capabilities { return (200, capabilities.value) }
            return (404, ["error": "no route"])
        case ("GET", "/v1/skills"): return (200, skillsPayload())
        case ("GET", "/v1/toolsets"): return (200, toolsetsPayload())
        case ("GET", "/api/model/options"): return modelOptionsStatus == 200 ? (200, modelOptionsPayload()) : (modelOptionsStatus, ["error": ["message": "nope"]] as [String: Any])
        case ("GET", "/api/sessions/s1"): return (200, ["object": "hermes.session", "session": ["id": "s1", "model": sessionModel.value, "has_model_config": false] as [String: Any]] as [String: Any])
        case ("POST", "/api/sessions/s1/model"):
            guard lockStatus == 200 else { return (lockStatus, ["error": ["message": "Requested Browser model lock cannot be routed; refusing silent global fallback", "code": "model_lock_unavailable"]] as [String: Any]) }
            let body = requestBody(request) ?? [:]
            let provider = body["provider"] as? String ?? "", model = body["model"] as? String ?? ""
            let runtime: [String: Any] = ["provider": provider, "model": model, "route_source": "raw_request", "requested": ["provider": provider, "model": model], "model_lock": "accepted"]
            return (200, ["object": "hermes.session.model_lock", "session_id": "s1", "runtime": runtime] as [String: Any])
        default: return (404, ["error": "no route"])
        }
    }
}

@MainActor private func botInfoStore(_ handler: @escaping MockHermesProtocol.Handler, sessionID: String? = "s1") -> (AppStore, Bot, String) {
    let (host, session) = MockHermesProtocol.serve(handler)
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": "jarvis-key"]), defaults: defaults, hermesSession: session)
    let bot = Bot(name: "Jarvis", backend: .hermes, skills: ["local-note"], hermesProfile: "grok-jarvis", hermesSessionID: sessionID)
    bot.importedSkills = [.init(name: "Weekly-Report", markdown: "# synthetic"), .init(name: "travel-planner", markdown: "# synthetic")]
    store.bots = [bot]
    return (store, bot, host)
}

@Test func botInfoPayloadsParseFromHandlerShapes() {
    let capabilities = HermesCapabilities.parse(capabilitiesPayload())
    #expect(capabilities.skills && capabilities.toolsets && capabilities.modelOptions && capabilities.sessionModelLock)
    #expect(capabilities.model == "grok-test")

    let skills = HermesSkill.parseList(skillsPayload())
    #expect(skills.map(\.name) == ["weekly-report", "tide-check", "ledger"])
    #expect(skills[0].description == "Writes the weekly status report.")
    #expect(skills.map(\.category) == ["productivity", nil, "finance"])

    let toolsets = HermesToolset.parseList(toolsetsPayload())
    #expect(toolsets.map(\.label) == ["Web search", "Images", "browser"])
    #expect(toolsets.map(\.enabled) == [true, true, false]); #expect(toolsets[1].configured == false)
    #expect(toolsets[0].tools == ["web_extract", "web_search"])

    let options = HermesModelOptions.parse(modelOptionsPayload())
    #expect(options.model == "model-alpha"); #expect(options.provider == "lab-one")
    #expect(options.providers.map(\.slug) == ["lab-one", "router", "lab-two"])
    #expect(options.providers[1].models == ["vendor/model-gamma", "vendor/model-delta"])
    #expect(options.selectable.map(\.slug) == ["lab-one", "router"])
}

@Test func skillsGroupByCategoryAndFilter() {
    let skills = HermesSkill.parseList(skillsPayload())
    let groups = BotCapabilitiesView.grouped(skills)
    #expect(groups.map(\.category) == ["productivity", "finance", nil])
    #expect(BotCapabilitiesView.filtered(skills, query: "tide").map(\.name) == ["tide-check"])
    #expect(BotCapabilitiesView.filtered(skills, query: "FINANCE").map(\.name) == ["ledger"])
    #expect(BotCapabilitiesView.filtered(skills, query: "  ").count == 3)
    let retired = skills + [HermesSkill(name: "old-tool", description: "Superseded", category: ".collision-retired")]
    #expect(BotCapabilitiesView.grouped(retired).map(\.category) == ["productivity", "finance", nil], "dot-categories are hidden")
}

@Test @MainActor func botInfoUsesProfilePrefixAndProfileKey() async {
    let (store, bot, host) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload()))
    await store.loadServerInfo(for: bot)
    let info = store.botInfo.info(for: bot.id)
    #expect(info?.skills.value?.count == 3); #expect(info?.toolsets.value?.count == 3)
    #expect(info?.showsModelPicker == true); #expect(info?.canLockSessionModel == true)
    let requests = MockHermesProtocol.recorded(host)
    #expect(Set(requests.compactMap { $0.url?.path }) == ["/p/grok-jarvis/v1/capabilities", "/p/grok-jarvis/v1/skills", "/p/grok-jarvis/v1/toolsets", "/p/grok-jarvis/api/model/options", "/p/grok-jarvis/api/sessions/s1",
                                                                "/p/grok-jarvis/health", "/p/grok-jarvis/health/detailed"], "P24: the version is read too (this fake has no /health)")
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer jarvis-key" })
    // The session row holds the profile's virtual alias, so the server default is shown.
    #expect(store.currentModel(for: bot) == .init(model: "model-alpha", provider: "lab-one", source: "server default"))
    #expect(HeadlessSnapshot.overviewSummary(store: store, bot: bot) == "Jarvis: Overview skills 3, toolsets 3, model model-alpha (server default), picker on")
    // Imported template skills already installed on the server are not repeated (case-insensitive).
    #expect(BotCapabilitiesView.importedOnly(bot.importedSkills.map(\.name) + bot.skills, server: info?.skills.value ?? []) == ["travel-planner", "local-note"])
    await store.loadServerInfo(for: bot)
    #expect(MockHermesProtocol.recorded(host).count == requests.count, "cached for the session")
    await store.loadServerInfo(for: bot, force: true)
    #expect(MockHermesProtocol.recorded(host).count == requests.count * 2, "refresh refetches")
}

@Test @MainActor func capabilityFlagsOffHideSkillsAndPicker() async {
    let (store, bot, host) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload(skills: false, modelOptions: false, modelLock: false)))
    await store.loadServerInfo(for: bot)
    let info = store.botInfo.info(for: bot.id)
    #expect(info?.skills == .unavailable("This server does not list its skills."))
    #expect(info?.showsModelPicker == false); #expect(info?.canLockSessionModel == false)
    let paths = MockHermesProtocol.recorded(host).compactMap { $0.url?.path }
    #expect(!paths.contains("/p/grok-jarvis/v1/skills")); #expect(!paths.contains("/p/grok-jarvis/api/model/options"))
    // Toolsets have no flag of their own: the advertised endpoint still lists them.
    #expect(info?.toolsets.value?.count == 3)
    await store.switchModel(for: bot, provider: "lab-one", model: "model-beta")
    #expect(!MockHermesProtocol.recorded(host).contains { $0.httpMethod == "POST" }); #expect(bot.hermesModelLock == nil)
}

@Test @MainActor func missingRoutesAndOldServersHideFeatures() async {
    var unflagged = capabilitiesPayload(); unflagged["features"] = ["session_chat_streaming": true]; unflagged["endpoints"] = nil
    let (store, bot, _) = botInfoStore(botInfoHandler(capabilities: unflagged, modelOptionsStatus: 404))
    await store.loadServerInfo(for: bot)
    #expect(store.botInfo.info(for: bot.id)?.showsModelPicker == false)
    #expect(store.botInfo.info(for: bot.id)?.skills.value?.count == 3)

    let (old, oldBot, oldHost) = botInfoStore(botInfoHandler(capabilities: nil))
    await old.loadServerInfo(for: oldBot)
    let info = old.botInfo.info(for: oldBot.id)
    #expect(info?.skills == .unavailable("This Hermes server does not report its capabilities."))
    #expect(info?.showsModelPicker == false)
    #expect(Set(MockHermesProtocol.recorded(oldHost).compactMap { $0.url?.path }) == ["/p/grok-jarvis/v1/capabilities", "/p/grok-jarvis/health", "/p/grok-jarvis/health/detailed"])

    let (failing, failingBot, _) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload(), modelOptionsStatus: 500))
    await failing.loadServerInfo(for: failingBot)
    if case .failed = failing.botInfo.info(for: failingBot.id)?.modelOptions {} else { Issue.record("5xx is an error, not a hidden feature") }
}

@Test @MainActor func modelSwitchPostsIdsOnlyToSessionModelRoute() async throws {
    let (store, bot, host) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload()))
    await store.loadServerInfo(for: bot)
    await store.switchModel(for: bot, provider: "router", model: "vendor/model-gamma")
    let post = try #require(MockHermesProtocol.recorded(host).first { $0.httpMethod == "POST" })
    #expect(post.url?.path == "/p/grok-jarvis/api/sessions/s1/model")
    #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer jarvis-key")
    let body = try #require(requestBody(post))
    #expect(Set(body.keys) == ["model", "provider"])
    #expect(body["model"] as? String == "vendor/model-gamma"); #expect(body["provider"] as? String == "router")
    #expect(bot.hermesModelLock == .init(sessionID: "s1", provider: "router", model: "vendor/model-gamma"))
    #expect(store.currentModel(for: bot)?.source == "chosen for this chat")
    #expect(BotInfoCache.isCurrent("vendor/model-gamma", provider: "router", current: store.currentModel(for: bot)))
    #expect(!BotInfoCache.isCurrent("vendor/model-gamma", provider: "lab-one", current: store.currentModel(for: bot)))
    #expect(store.botInfo.info(for: bot.id)?.modelError == nil)
    // A lock recorded for an older session does not describe the new one.
    bot.hermesSessionID = "s2"
    #expect(store.currentModel(for: bot)?.source == "server default")
}

@Test @MainActor func unroutableModelLockIsReportedAndNotStored() async {
    let (store, bot, _) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload(), lockStatus: 409))
    await store.loadServerInfo(for: bot)
    await store.switchModel(for: bot, provider: "lab-one", model: "model-beta")
    #expect(bot.hermesModelLock == nil)
    #expect(store.botInfo.info(for: bot.id)?.modelError?.contains("will not fall back") == true)
    #expect(store.botInfo.info(for: bot.id)?.isSwitchingModel == false)

    let (fresh, freshBot, freshHost) = botInfoStore(botInfoHandler(capabilities: capabilitiesPayload()), sessionID: nil)
    await fresh.loadServerInfo(for: freshBot)
    await fresh.switchModel(for: freshBot, provider: "lab-one", model: "model-beta")
    #expect(!MockHermesProtocol.recorded(freshHost).contains { $0.httpMethod == "POST" })
    #expect(fresh.botInfo.info(for: freshBot.id)?.modelError?.contains("Send a message first") == true)
}

@Test func currentModelPrefersSessionLockThenSessionThenDefault() {
    let options = HermesModelOptions.parse(modelOptionsPayload())
    let lock = HermesModelLock(sessionID: "s1", provider: "router", model: "m-lock")
    // P11: the session row beats a local lock when it reports a different concrete model (changed from another client).
    #expect(BotInfoCache.currentModel(lock: lock, sessionID: "s1", sessionModel: "m-row", aliases: [], options: options) == .init(model: "m-row", provider: nil, source: "this chat"))
    #expect(BotInfoCache.currentModel(lock: lock, sessionID: "s1", sessionModel: "vendor/m-lock", aliases: [], options: options)?.model == "m-lock")
    #expect(BotInfoCache.currentModel(lock: lock, sessionID: "s1", sessionModel: nil, aliases: [], options: options)?.model == "m-lock")
    #expect(BotInfoCache.currentModel(lock: lock, sessionID: "s9", sessionModel: "m-row", aliases: [], options: options) == .init(model: "m-row", provider: nil, source: "this chat"))
    #expect(BotInfoCache.currentModel(lock: nil, sessionID: "s1", sessionModel: "hermes-agent", aliases: ["hermes-agent"], options: options)?.source == "server default")
    #expect(BotInfoCache.currentModel(lock: nil, sessionID: nil, sessionModel: nil, aliases: [], options: nil) == nil)
    #expect(HermesBackend.modelLockBody(provider: "", model: "m") as NSDictionary == ["model": "m"] as NSDictionary)
}

@Test func modelLockSurvivesStoreRoundTrip() throws {
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis", hermesSessionID: "s1")
    bot.hermesModelLock = .init(sessionID: "s1", provider: "lab-one", model: "model-beta")
    let decoded = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
    #expect(decoded.hermesModelLock == bot.hermesModelLock)
}
