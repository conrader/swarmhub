import Foundation
import Testing
@testable import AgentApp

@Test func connectorDefaultsShipInBothManagerTemplatesAndTheInstalledSkill() throws {
    for kind in [BackendKind.hermes, .openClaw] {
        let template = try #require(BotManagerText.template(for: kind))
        let filled = kind == .hermes ? BotManagerText.filled(template, managerProfile: "manager") : BotManagerText.filled(template, managerAgent: "manager")
        #expect(!filled.contains("{{"))
        #expect(filled.contains("default-connectors.py"))
        #expect(filled.contains(kind == .hermes ? "provision hermes" : "provision openclaw"))
        #expect(!filled.contains("def provision(home, backend, bot):"), "ordinary manager text stays small")
    }
    let skill = try #require(SkillLibrary.bundled().first { $0.name == SkillLibrary.managerSkill })
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "manager", managerTemplate: BotManagerText.template()))
    #expect(skill.files.contains { $0.path == "scripts/default-connectors.py" && $0.content.contains("def provision(home, backend, bot):") })
    #expect(rendered.contains("provision hermes"))
    let custom = try #require(SkillLibrary.render(skill, forProfile: "manager", managerTemplate: BotManagerText.withConnectorDefaults("Custom instructions for {{MANAGER}}", backend: .hermes)))
    #expect(custom.contains("Custom instructions for manager") && custom.contains("provision hermes"), "older prompt overrides retain the app's defaults")
    let stock = try #require(BotManagerText.template())
    #expect(BotManagerText.withConnectorDefaults(stock, backend: .hermes) == stock)
}

@Test func connectorReportsValidateStatesCountsAndNames() throws {
    let text = """
    ```swarmhub
    {"op":"connectors","name":"new-bot","list":[
      {"name":"sb","state":"loaded","tool_count":5,"detail":"Last bot catalog (including deferred tools).","observed_at":1792000000},
      {"name":"docs","state":"failed","detail":"Connector connection timed out."},
      {"name":"other","state":"never_attempted","detail":"Awaiting first load."}]}
    ```
    """
    guard case .connectors(let name, let rows) = try #require(SwarmhubBlock.ops(in: text)?.first) else { Issue.record("Missing report"); return }
    #expect(name == "new-bot")
    #expect(rows.map(\.status) == ["Loaded 5 tools", "Failed", "Never attempted"])
    #expect(rows[0].observedAt == Date(timeIntervalSince1970: 1792000000))
    for row: [String: Any] in [
        ["name": "sb", "state": "loaded", "detail": "No count"],
        ["name": "sb", "state": "loaded", "tool_count": -1, "detail": "Bad count"],
        ["name": "../other", "state": "failed", "detail": "Bad name"],
        ["name": "sb", "state": "healthy", "detail": "Unknown state"]
    ] { #expect(SwarmhubOp(["op": "connectors", "name": "new-bot", "list": [row]]) == nil) }
}

@Test @MainActor func onlyCreationWithoutTheCurrentSkillCarriesTheConnectorBootstrap() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Manager", backend: .hermes, hermesProfile: "manager"); bot.canManageBots = true
    store.bots = [bot]
    let ordinary = try #require(store.managementText(for: bot, text: "list bots", conversation: bot))
    #expect(!ordinary.contains("def provision(home, backend, bot):"))
    let creation = try #require(store.managementText(for: bot, text: "create a bot for reports", conversation: bot))
    #expect(creation.contains("def provision(home, backend, bot):"))
    #expect(creation.contains("~/.config/swarmhub/default-connectors.py"))
    #expect(store.managementText(for: bot, text: "yes", conversation: bot)?.contains("def provision(home, backend, bot):") == true)
    // An outdated skill keeps the cheap pointer; only its creation turns add the connector step and helper it predates.
    bot.installedSkills = [SkillLibrary.managerSkill: "1.3.0"]
    store.managementExchanges = [:]
    #expect(store.managementText(for: bot, text: "list bots", conversation: bot) == AppStore.skillPointer)
    store.managementExchanges = [:]
    let outdated = try #require(store.managementText(for: bot, text: "create a bot for reports", conversation: bot))
    #expect(outdated.hasPrefix(AppStore.skillPointer + "\n\nEvery new bot gets"))
    #expect(outdated.contains("provision hermes") && outdated.contains("def provision(home, backend, bot):") && !outdated.contains("{{"))
    #expect(!outdated.contains("hermes profile create"), "not the full manager text")
    bot.installedSkills = [SkillLibrary.managerSkill: try #require(store.skillLibrary.first { $0.name == SkillLibrary.managerSkill }).version.description]
    #expect(store.managementText(for: bot, text: "create a bot for reports", conversation: bot) == AppStore.skillPointer)
}

@Test @MainActor func connectorFailuresPersistAndDoNotCrossBotBindings() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "One", backend: .hermes, hermesProfile: "one")
    store.bots = [bot]
    store.recordConnectors([.init(name: "sb", state: .failed, detail: "SSH authentication was rejected.")], for: bot)
    let decoded = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
    #expect(decoded.connectorReport == bot.connectorReport)
    #expect(store.connectorReport(for: decoded)?.connectors.first?.status == "Failed")
    decoded.hermesProfile = "two"
    #expect(store.connectorReport(for: decoded) == nil)
    decoded.hermesProfile = "one"; decoded.hermesBaseURL = "https://other.invalid/v1"
    #expect(store.connectorReport(for: decoded) == nil)
    let legacy = Bot(name: "Legacy", backend: .hermes)
    #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(legacy)).connectorReport == nil)
}

@Test @MainActor func connectorCheckReadsTheBotsOwnBackendAndSurfacesAnUnreportedFailure() async throws {
    let reply = "```swarmhub\n{\"op\":\"connectors\",\"name\":\"own-profile\",\"list\":[{\"name\":\"sb\",\"state\":\"loaded\",\"tool_count\":5,\"detail\":\"Last bot catalog (including deferred tools).\"}]}\n```"
    let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        if request.url?.path.hasSuffix("/chat/stream") == true { return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])]) }
        if request.url?.path == "/api/sessions" { return .json(200, ["session": ["id": "synthetic-check"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Own", backend: .hermes, hermesProfile: "own-profile")
    store.bots = [bot]
    await store.checkConnectors(for: bot)
    #expect(store.connectorReport(for: bot)?.connectors.first?.status == "Loaded 5 tools")
    #expect(store.connectorChecks.isEmpty)
    let sent = try #require(ChatParityServer.requests(host).first { $0.path.hasSuffix("/chat/stream") })
    let instructions = sent.body?["instructions"] as? String ?? ""
    #expect(instructions.contains("inspect hermes 'own-profile'"))
    #expect(instructions.contains("Do not edit files"))
    bot.hermesProfile = "different-profile"
    await store.checkConnectors(for: bot)
    #expect(store.connectorReport(for: bot)?.connectors.first?.state == .failed, "a report for another profile is rejected")
}

@Test @MainActor func managerRecordsConnectorFailuresOnlyForItsOwnBots() async {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let manager = Bot(name: "Manager", backend: .hermes, hermesProfile: "manager")
    let bot = Bot(name: "New", backend: .hermes, hermesProfile: "new")
    let other = Bot(name: "Elsewhere", backend: .hermes, hermesProfile: "new"); other.hermesBaseURL = "https://elsewhere.invalid/v1"
    store.bots = [manager, bot, other]
    let rows = [BotConnectorReport.Connector(name: "sb", state: .failed, detail: "Existing read-only SB SSH identity is missing on this computer.")]
    store.recordConnectors([.creationUnreported], for: bot)
    #expect(store.connectorReport(for: bot)?.connectors.first?.status == "Failed")
    #expect(BotConnectorReport.Connector.creationUnreported.detail.contains("Retry"), "names the button a failed report shows")
    await store.apply(.connectors(name: "new", rows: rows), manager: manager)
    #expect(bot.connectorReport?.connectors == rows, "the manager's own report replaces the creation placeholder")
    #expect(other.connectorReport == nil)
}
