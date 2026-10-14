import Foundation
import Testing
@testable import AgentApp

// P13 Part A: Settings → Models, the Overview role lines and the headless roles line are read-only. Synthetic
// gateways (`ModelRolesSupport.swift`, `ModelPickerTestSupport.swift`) over URLProtocol mocks.

@Test(arguments: CatalogShape.allCases) @MainActor func loadIsGetOnlyAndLeavesTheStoreByteIdentical(shape: CatalogShape) async throws {
    let (store, jarvis, rapper, host, url) = rolesStore(pickerServer(shape), delegation: ["grok-jarvis": true, "grok-rapper": false])
    let archive = Bot(name: "Old group", backend: .hermes, hermesProfile: "grok-old"); archive.archivedMembers = ["A"]
    store.bots.append(archive)
    store.save()
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try Data(contentsOf: url), encodedBefore = try encoder.encode(StoreFile(bots: store.bots, groups: store.groups))
    _ = store.modelRoles(); _ = store.modelRolesSummary(for: jarvis)
    #expect(MockHermesProtocol.recorded(host).isEmpty, "opening the pane fetches nothing")

    await store.loadModelRoles()
    let requests = MockHermesProtocol.recorded(host)
    #expect(!requests.isEmpty && requests.allSatisfy { $0.httpMethod == "GET" }, "\(rolePaths(host))")
    #expect(!rolePaths(host).contains { $0.contains("/v1/skills") }, "Load skips skills")
    #expect(!rolePaths(host).contains { $0.contains("grok-old") }, "archives are not loaded")
    #expect(Set(rolePaths(host)) == ["GET /p/grok-jarvis/v1/capabilities", "GET /p/grok-jarvis/v1/toolsets", "GET /p/grok-jarvis/api/model/options", "GET /p/grok-jarvis/api/sessions/s1",
                                     "GET /p/grok-rapper/v1/capabilities", "GET /p/grok-rapper/v1/toolsets", "GET /p/grok-rapper/api/model/options", "GET /p/grok-rapper/api/sessions/r1",
                                     // P24's version read; these fakes have no /health, so /health/detailed is tried too.
                                     "GET /p/grok-jarvis/health", "GET /p/grok-jarvis/health/detailed", "GET /p/grok-rapper/health", "GET /p/grok-rapper/health/detailed"])
    #expect(try Data(contentsOf: url) == before, "Load saves nothing")
    #expect(try encoder.encode(StoreFile(bots: store.bots, groups: store.groups)) == encodedBefore, "and changes nothing it would save")
    #expect(jarvis.hermesModelLock == nil && rapper.hermesModelLock == nil)

    // The Overview, opened later, still fetches the skills the pane skipped.
    await store.loadServerInfo(for: jarvis)
    #expect(rolePaths(host).filter { $0 == "GET /p/grok-jarvis/v1/skills" }.count == 1)
}

@Test(arguments: CatalogShape.allCases) @MainActor func rowsReadTheBoxDefaultPerBot(shape: CatalogShape) async {
    let (store, jarvis, rapper, _, _) = rolesStore(pickerServer(shape), delegation: ["grok-jarvis": true, "grok-rapper": false])
    let before = store.modelRoles()
    #expect(before.rows.map(\.conversation?.text) == ["Conversation: not loaded · agent default", "Conversation: not loaded · agent default"])
    #expect(before.fleetSummary == "agent default: not loaded (press Load)")

    await store.loadModelRoles()
    let roles = store.modelRoles()
    let jarvisRow = try! #require(roles.rows.first { $0.id == jarvis.id }), rapperRow = try! #require(roles.rows.first { $0.id == rapper.id })
    #expect(jarvisRow.conversation?.text == "Conversation: model-alpha · Lab One · agent default")
    #expect(jarvisRow.conversation?.accessibilityLabel == "Conversation, model-alpha, Lab One, agent default")
    #expect(jarvisRow.coding?.text == "Coding threads: same as conversation")
    #expect(rapperRow.conversation?.text == "Conversation: solo-model · Lab Solo · agent default")
    #expect(jarvisRow.subAgents == "on" && rapperRow.subAgents == "off")
    #expect(jarvisRow.blocked == nil && jarvisRow.mismatch == nil)
    #expect(roles.fleetSummary == "differs: model-alpha on 1, solo-model on 1")
    #expect(roles.subAgentSummary == "delegation toolset on for 1 of 2 bots")
    #expect(roles.servers.count == 1 && roles.servers[0].rows.map(\.name) == ["Jarvis", "Rapper"])
    #expect(store.modelRolesSummary(for: jarvis) == "Jarvis: roles conversation model-alpha (agent default) | coding threads same as conversation | sub-agents on, set on the box")
    #expect(store.modelRolesSummary(for: rapper) == "Rapper: roles conversation solo-model (agent default) | coding threads same as conversation | sub-agents off, set on the box")
    for text in roles.rows.flatMap({ [$0.conversation?.text, $0.coding?.text, ModelRolesModel.headlessLine($0)].compactMap { $0 } }) + [roles.fleetSummary] {
        for sentinel in catalogSentinels { #expect(!text.contains(sentinel)) }
    }
}

@Test @MainActor func fleetSummaryCountsMatchingDefaults() async {
    let server = PickerServer(catalogs: ["grok-jarvis": catalogPayload(.v0205), "grok-rapper": catalogPayload(.v0217)], keys: ["grok-jarvis": "j-key", "grok-rapper": "r-key"])
    let (store, _, _, _, _) = rolesStore(server)
    let third = Bot(name: "Keyless", backend: .hermes, hermesProfile: "grok-keyless"); store.bots.append(third)
    await store.loadModelRoles()
    #expect(store.modelRoles().fleetSummary == "agent default: model-alpha on 2 of 3 bots")
    #expect(store.modelRoles().subAgentSummary == "delegation toolset not loaded")
    #expect(store.modelRolesSummary(for: third).hasPrefix("Keyless: roles conversation not loaded (agent default)"))
}

@Test @MainActor func mismatchSentenceWithoutAButton() async {
    let server = pickerServer()
    server.set(sessionModel: "model-beta", profile: "grok-jarvis", session: "s1")
    let (store, jarvis, rapper, _, _) = rolesStore(server)
    await store.loadModelRoles()
    #expect(store.modelRolesRow(for: jarvis).mismatch == "This chat runs model-beta; this bot's default is model-alpha.")
    #expect(store.modelRolesRow(for: rapper).mismatch == nil, "the row's virtual alias means the box default")
}

@Test @MainActor func blockedBotsSayWhyAndOpenClawWaitsForItsGateway() async {
    let server = pickerServer()
    var capabilities = pickerCapabilities(modelLock: false)
    capabilities["features"] = (capabilities["features"] as! [String: Any]).merging(["session_model_lock": false]) { $1 }
    server.set(capabilities: capabilities)
    let (store, jarvis, _, _, _) = rolesStore(server)
    let claw = Bot(name: "Claw", backend: .openClaw); store.bots.append(claw)
    await store.loadModelRoles()
    #expect(store.modelRolesRow(for: jarvis).blocked == .noLock)
    #expect(store.modelRolesSummary(for: jarvis).hasSuffix("| This box can't switch a chat's model, so \(AppConstants.name) can't apply a model here."))
    // P17: the OpenClaw stub is not asked; its row is its reason, grouped under "OpenClaw", and Load sends it nothing.
    let clawRow = store.modelRolesRow(for: claw)
    #expect(clawRow.isOpenClaw && !clawRow.canAsk && clawRow.conversation == nil && clawRow.server == "OpenClaw")
    #expect(clawRow.catalogReason == "Models come from the OpenClaw gateway once connected.")
    #expect(store.modelRolesSummary(for: claw) == "Claw: roles Models come from the OpenClaw gateway once connected.")
    #expect(store.modelRoles().hermesRows.count == 2 && store.modelRoles().askableRows.count == 2)
    #expect(store.botInfo.info(for: claw.id) == nil)

    server.set(capabilities: nil)
    await store.loadModelRoles()
    #expect(store.modelRolesRow(for: jarvis).blocked == .legacy)
}

@Test func roleFixtureNamesNeverReachSources() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    // No provider or model names of any real box either: the app ships no model.
    let banned = roleFixtureNames + catalogProviderFixtureNames + ["gpt-", "openai-codex", "-sol", "-terra", "-luna", "claude-", "anthropic/"]
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for name in banned { #expect(!text.contains(name), "\(file.lastPathComponent) contains \(name)") }
    }
}
