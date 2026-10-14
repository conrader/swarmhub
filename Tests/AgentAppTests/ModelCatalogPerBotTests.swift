import Foundation
import Testing
@testable import AgentApp

// P17: the Hermes mapper, per-bot validity, keep-last-good and joining an in-flight load. Synthetic gateways
// (`PickerServer`, `E2EServer` with a catalog per profile); made-up names only.

private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!

@Test(arguments: CatalogShape.allCases) func theHermesMapperKeepsP11sGroupsTagsAndReasons(shape: CatalogShape) {
    let options = HermesModelOptions.parse(catalogPayload(shape))
    let catalog = options.catalog(profile: "grok-jarvis")
    let picker = ModelPickerModel(info: { var info = BotServerInfo(); info.modelOptions = .loaded(options); return info }(), current: nil, sessionID: "s1", profile: "grok-jarvis")
    #expect(catalog.suppliers.map(\.slug) == picker.groups.map(\.slug) && catalog.suppliers.first?.slug == "lab-one", "default first")
    #expect(catalog.suppliers.map(\.name) == picker.groups.map(\.name))
    #expect(catalog.suppliers.first { $0.slug == "preset-box" }?.tags == ["preset"])
    #expect(catalog.suppliers.first { $0.slug == "lab-paid" }?.reason(for: "paid-a") == (shape == .v0217 ? "checking the plan" : "needs a paid plan"))
    #expect(catalog.hiddenCount == picker.hiddenCount && catalog.hiddenCount == 2)
    #expect(catalog.defaultSupplier == "lab-one" && catalog.agentDefault == .init(model: "model-alpha", supplier: "lab-one"))
    #expect(catalog.pinning == .permanent && catalog.place == "your Hermes box" && catalog.detail == "Profile grok-jarvis")
    #expect(catalog.supplier(answering: "lab-1")?.slug == "lab-one", "aliases answer")
    #expect(catalog.offers(beta) && !catalog.offers(ModelChoice(provider: "lab-1", model: "model-beta")!) && !catalog.offers(ModelChoice(provider: "router", model: "model-beta")!),
            "slug and id, never the id alone")
    let reflected = String(reflecting: catalog) + String(reflecting: picker)
    for sentinel in catalogSentinels { #expect(!reflected.contains(sentinel)) }
    #expect(!((catalog as Any) is any Encodable), "not Codable")
}

@Test func effectiveSaysOfferedNotOfferedOrNotChecked() throws {
    let catalog = HermesModelOptions.parse(soloCatalogPayload()).catalog(profile: "grok-rapper")
    let solo = try #require(ModelChoice(provider: "lab-solo", model: "solo-mini"))
    #expect(ModelPolicy.effective(role: .conversation, settings: nil, defaults: .init(conversation: solo), catalog: catalog).check == .offered)
    let skipped = ModelPolicy.effective(role: .conversation, settings: nil, defaults: .init(conversation: beta), catalog: catalog)
    #expect(skipped.check == .notOffered && skipped.choice == nil && skipped.source == .boxDefault)
    #expect(skipped.note == "model-beta isn't offered by this agent. Chats here run on the agent default.")
    let stopped = ModelPolicy.effective(role: .conversation, settings: .init(conversation: .choice(beta)), defaults: nil, catalog: catalog)
    #expect(stopped.choice == beta && stopped.note == "model-beta isn't offered by this agent. A new chat stops until you change it.")
    #expect(ModelPolicy.effective(role: .conversation, settings: nil, defaults: .init(conversation: beta), catalog: nil).check == .notChecked)
    #expect(ModelPolicy.effective(role: .conversation, settings: nil, defaults: nil, catalog: catalog).check == nil)
}

@Test @MainActor func twoProfilesAndAnotherHostEachReadTheirOwnList() async {
    let (store, jarvis, rapper, host, _) = rolesStore(pickerServer())
    let other = PickerServer(catalogs: ["grok-far": soloCatalogPayload()], keys: ["grok-far": "far-key-11"])
    let (farHost, _) = MockHermesProtocol.serve(other.handler)
    let far = Bot(name: "Far", backend: .hermes, hermesProfile: "grok-far"); far.hermesBaseURL = "https://\(farHost)/v1"
    store.keyStore.setKey("far-key-11", for: "hermes.grok-far"); store.bots.append(far)
    store.modelDefaults.conversation = beta
    await store.loadModelRoles()
    #expect(store.modelCatalog(for: jarvis).value?.agentDefault?.model == "model-alpha" && store.modelCatalog(for: rapper).value?.agentDefault?.model == "solo-model")
    #expect(store.modelCatalog(for: far).value?.detail == "Profile grok-far")
    #expect(!rolePaths(host).contains { $0.contains("grok-far") } && rolePaths(farHost).allSatisfy { $0.contains("/p/grok-far/") })
    let roles = store.modelRoles()
    #expect(roles.servers.map(\.server) == [host, farHost])
    #expect(roles.offerSummary(beta) == "Offered by 1 of 3 agents; not by Rapper, Far")
    #expect(store.modelRolesRow(for: rapper).conversation?.text == "Conversation: solo-model · Lab Solo · agent default")
    #expect(store.modelRolesRow(for: rapper).conversation?.note == "model-beta isn't offered by this agent. Chats here run on the agent default.")
    #expect(store.editorModelsSummary(for: jarvis) == "Jarvis: editor models your Hermes box, Profile grok-jarvis; agent default model-alpha; \(AppConstants.name) default offered; 4 suppliers")
    #expect(store.editorModelsSummary(for: rapper).hasSuffix("\(AppConstants.name) default not offered; 1 suppliers"))
    let keyless = Bot(name: "Keyless", backend: .hermes, hermesProfile: "grok-keyless"); store.bots.append(keyless)
    #expect(store.modelRoles().offerSummary(beta) == "Offered by 1 of 4 agents; not by Rapper, Far; 1 not loaded")
}

@MainActor private func perProfileStore() -> (AppStore, Bot, Bot, Bot, E2EServer.State) {
    let (store, jarvis, dmt, achilles, state, _) = applyStore(.v0205)
    state.with { $0.catalogs["grok-achilles"] = soloCatalogPayload() }
    return (store, jarvis, dmt, achilles, state)
}

@Test @MainActor func aDefaultOfferedByTwoOfThreeIsSkippedOnTheThirdWithANote() async throws {
    let (store, jarvis, dmt, achilles, state) = perProfileStore()
    store.modelDefaults.conversation = beta
    for bot in [jarvis, dmt, achilles] { try await sendAndWait(store, bot, "hi E2E-PERBOT") }
    #expect(lockPosts(state).map(\.path).allSatisfy { !$0.contains("grok-achilles") } && lockPosts(state).count == 2)
    #expect(achilles.hermesModelLock == nil && lines(state).last == "POST /p/grok-achilles/api/sessions/agentapp_\(achilles.id.uuidString.lowercased())/chat/stream")
    let note = "\(AppConstants.name)'s default model model-beta was not applied: model-beta isn't offered by this agent. This chat runs on the agent default."
    #expect(achilles.messages.filter { $0.role == .system }.map(\.content) == [note])
    await store.loadModelRoles()
    #expect(store.modelRoles().offerSummary(beta) == "Offered by 2 of 3 agents; not by Achilles")
}

@Test @MainActor func aNotOfferedOverrideStopsItsSend() async throws {
    let (store, _, _, achilles, state) = perProfileStore()
    achilles.modelSettings = .init(conversation: .choice(beta))
    try await sendAndWait(store, achilles, "hi E2E-STOP")
    #expect(!lines(state).contains { $0.hasSuffix("/chat/stream") } && lockPosts(state).isEmpty)
    #expect(store.errorMessage == "model-beta, this bot's model, was not applied: model-beta isn't offered by this agent. Nothing was sent.")
    #expect(store.modelRolesRow(for: achilles).canSwitch == false)
}

@Test @MainActor func keepLastGoodHoldsInTheSameScopeAndDropsOnAScopeChange() async {
    let server = pickerServer()
    let (store, jarvis, _, _, _) = pickerStore(server)
    await store.loadServerInfo(for: jarvis)
    server.set(status: 500, for: "/api/model/options")
    await store.loadServerInfo(for: jarvis, force: true)
    let info = store.botInfo.info(for: jarvis.id)
    #expect(store.modelCatalog(for: jarvis).value?.detail == "Profile grok-jarvis", "the last good list stays")
    #expect(info?.refreshError?.contains("[key]") == true && info?.refreshError?.contains("jarvis-key-77") == false && info?.modelsAsOf != nil)
    let picker = store.modelPicker(for: jarvis)
    #expect(picker.showsMenu && !picker.canSwitch && picker.notes.contains { $0.offersRetry && $0.text.contains("Showing the list from") })
    #expect(store.botInfo.isStale(botID: jarvis.id, sessionID: "s1", scope: info?.scope ?? ""), "the next open retries")

    jarvis.hermesProfile = "grok-rapper"
    await store.loadServerInfo(for: jarvis, force: true)
    #expect(store.modelCatalog(for: jarvis).value == nil, "nothing crosses profiles")
    if case .failed = store.modelCatalog(for: jarvis) {} else { Issue.record("a failed read with no good list in this scope is failed") }
}

@Test @MainActor func aFirstSendRacingTheOverviewFetchesOnce() async throws {
    let (store, jarvis, _, _, state) = perProfileStore()
    store.modelDefaults.conversation = beta
    let overview = Task { await store.loadServerInfo(for: jarvis) }
    try await sendAndWait(store, jarvis, "hi E2E-RACE")
    await overview.value
    #expect(lines(state).filter { $0 == "GET /p/grok-jarvis/api/model/options" }.count == 1)
    #expect(jarvis.hermesModelLock?.model == "model-beta", "the send did not skip its default for a .loading list")
}

@Test @MainActor func aSkillsLessJoinDoesNotStrandTheOverviewsSkills() async {
    let (store, jarvis, _, host, _) = pickerStore(pickerServer())
    let editorLoad = Task { await store.loadServerInfo(for: jarvis, includeSkills: false) }
    let overview = Task { await store.loadServerInfo(for: jarvis) }
    await editorLoad.value; await overview.value
    #expect(store.botInfo.info(for: jarvis.id)?.skills.value?.count == 1)
    #expect(rolePaths(host).filter { $0.hasSuffix("/v1/skills") }.count == 1)
}
