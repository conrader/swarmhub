import Foundation
import Testing
@testable import AgentApp

// P17 item 3: the agent editor's Models section. Pure decisions (`RoleModelEditorModel`) plus its load against the
// synthetic multiplexed box (`PickerServer`); GETs only, made-up names.

private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private let madeUp = ModelChoice(provider: "lab-one", model: "made-up")!
private let loaded = Loadable<ModelCatalog>.loaded(HermesModelOptions.parse(catalogPayload(.v0205)).catalog(profile: "grok-jarvis"))

private func model(new: Bool = false, saved: BackendKind? = .hermes, pending: BackendKind = .hermes, _ catalog: Loadable<ModelCatalog> = loaded,
                   entry: Bool = true, autoLoad: Bool = true, appDefault: ModelChoice? = nil, setting: ModelSetting = .inherit) -> RoleModelEditorModel {
    RoleModelEditorModel(isNew: new, savedBackend: saved, pendingBackend: pending, catalog: catalog, hasEntry: entry, autoLoad: autoLoad, appDefault: appDefault, setting: setting)
}

@Test func everyEditorStateHasItsReason() {
    #expect(model(new: true, saved: nil).reason == "Models come from the agent's own backend once it exists.")
    #expect(model(pending: .openClaw).reason == "Models come from the OpenClaw gateway once connected.")
    #expect(model(saved: .mock, pending: .hermes).reason == "Models come from the Hermes profile once the agent is saved.")
    #expect(model(.loading, entry: false, autoLoad: false).reason == "Not loaded yet." && !model(.loading, entry: false, autoLoad: false).offersRetry)
    #expect(model(.loading).reason == "Loading this agent's models…")
    #expect(model(.unavailable("Add this bot's key to see its models.")).reason == "Add this bot's key to see its models." && !model(.unavailable("x")).offersRetry)
    #expect(model(.failed("HTTP 500: boom")).reason == "HTTP 500: boom" && model(.failed("x")).offersRetry)
    for state in [model(new: true, saved: nil), model(pending: .openClaw), model(.loading), model(.unavailable("x")), model(.failed("x"))] {
        #expect(!state.showsMenu && !state.canChoose && state.leading.isEmpty)
    }
    let ready = model()
    #expect(ready.showsMenu && ready.canChoose && ready.showsUnpinCopy && ready.reason == "Models from Profile grok-jarvis on your Hermes box.")
    #expect(ready.leading == [.init(title: "Agent default (model-alpha)", setting: .box)] && ready.label == "Agent default (model-alpha)")
}

@Test func theAppDefaultRowIsMarkedPerAgent() {
    let offered = model(appDefault: beta)
    #expect(offered.leading.map(\.title) == ["\(AppConstants.name) default (model-beta)", "Agent default (model-alpha)"] && offered.warning == nil)
    #expect(offered.label == "\(AppConstants.name) default (model-beta)")
    let missing = model(appDefault: madeUp)
    #expect(missing.leading.first == .init(title: "\(AppConstants.name) default (made-up) — not offered by this agent", setting: .inherit), "still selectable")
    #expect(missing.warning == "made-up isn't offered by this agent. Chats here run on the agent default.")
    #expect(model(appDefault: madeUp, setting: .box).warning == nil)
    #expect(model(setting: .choice(madeUp)).warning == "made-up isn't offered by this agent. A new chat stops until you change it.")
    #expect(model(setting: .choice(beta)).label == "model-beta" && model(setting: .choice(beta)).warning == nil)
}

@Test @MainActor func openingTheEditorLoadsOnceWithoutSkillsAndAgainOnlyWhenDue() async {
    let server = pickerServer()
    let (store, jarvis, _, host, _) = pickerStore(server)
    await store.loadEditorModels(for: jarvis, pendingBackend: .openClaw)
    await store.loadEditorModels(for: nil, pendingBackend: .hermes)
    #expect(MockHermesProtocol.recorded(host).isEmpty, "a pending other backend and a new agent load nothing")

    await store.loadEditorModels(for: jarvis, pendingBackend: .hermes)
    #expect(Set(rolePaths(host)) == ["GET /p/grok-jarvis/v1/capabilities", "GET /p/grok-jarvis/v1/toolsets", "GET /p/grok-jarvis/api/model/options",
                                     "GET /p/grok-jarvis/api/sessions/s1", "GET /p/grok-jarvis/health", "GET /p/grok-jarvis/health/detailed"])
    let first = rolePaths(host).count
    await store.loadEditorModels(for: jarvis, pendingBackend: .hermes)
    #expect(rolePaths(host).count == first, "fresh: no second read")

    let start = Date(); store.botInfo.now = { start.addingTimeInterval(BotInfoCache.maxAge + 1) }
    await store.loadEditorModels(for: jarvis, pendingBackend: .hermes)
    #expect(rolePaths(host).filter { $0.hasSuffix("/api/model/options") }.count == 2, "stale: read again")
    await store.loadEditorModels(for: jarvis, pendingBackend: .hermes, force: true)
    #expect(rolePaths(host).filter { $0.hasSuffix("/api/model/options") }.count == 3, "Retry")
    jarvis.hermesProfile = "grok-rapper"
    await store.loadEditorModels(for: jarvis, pendingBackend: .hermes)
    #expect(rolePaths(host).last { $0.hasSuffix("/api/model/options") } == "GET /p/grok-rapper/api/model/options", "scope change")
    #expect(!rolePaths(host).contains { $0.contains("/v1/skills") || $0.hasPrefix("POST") })
}

@Test @MainActor func aBotWithNoProfileListsTheDefaultProfileAndKeylessBotsSendNothing() async {
    let server = PickerServer(catalogs: ["default": soloCatalogPayload(), "grok-jarvis": catalogPayload(.v0205)], keys: ["default": "default-key", "grok-jarvis": "jarvis-key-77"])
    let (host, session) = MockHermesProtocol.serve { request in
        guard let url = request.url, !url.path.hasPrefix("/p/") else { return server.handler(request) }
        var routed = request; routed.url = URL(string: "https://\(url.host!)/p/default\(url.path)"); return server.handler(routed)
    }
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes": "default-key"]), defaults: defaults, hermesSession: session)
    let fresh = Bot(name: "Fresh", backend: .hermes), keyless = Bot(name: "Keyless", backend: .hermes, hermesProfile: "grok-keyless")
    store.bots = [fresh, keyless]

    await store.loadEditorModels(for: fresh, pendingBackend: .hermes)
    let model = editor(store, fresh)
    #expect(model.reason == "Models from Profile default on your Hermes box." && model.leading.last?.title == "Agent default (solo-model)")
    #expect(store.modelPicker(for: fresh).groups.map(\.slug) == ["lab-solo"])

    let before = MockHermesProtocol.recorded(host).count
    await store.loadEditorModels(for: keyless, pendingBackend: .hermes)
    await store.loadServerInfo(for: keyless)
    #expect(MockHermesProtocol.recorded(host).count == before, "no key, no request")
    #expect(editor(store, keyless).reason == "Add this bot's key to see its models.")
    #expect(store.botInfo.info(for: keyless.id)?.skills == .unavailable("Add this bot's key to see its models."), "the Overview reads unavailable, not a 401")
}

@MainActor private func editor(_ store: AppStore, _ bot: Bot) -> RoleModelEditorModel {
    RoleModelEditorModel(isNew: false, savedBackend: bot.backend, pendingBackend: bot.backend, catalog: store.modelCatalog(for: bot),
                         hasEntry: store.botInfo.info(for: bot.id) != nil, autoLoad: false, appDefault: store.modelDefaults.conversation, setting: .inherit)
}

@Test @MainActor func aBackendChangeClearsTheStoredPair() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); bot.modelSettings = .init(conversation: .choice(beta))
    store.bots = [bot]
    var same = BotEditorFields(bot: bot)
    same.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.modelSettings?.conversation == .choice(beta), "same backend keeps the pair")
    var changed = BotEditorFields(bot: bot); changed.backend = .openClaw
    changed.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.backend == .openClaw && bot.modelSettings == nil, "no stale Hermes pair on an OpenClaw bot")
}
