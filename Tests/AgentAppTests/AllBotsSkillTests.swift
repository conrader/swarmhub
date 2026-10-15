import Foundation
import Testing
@testable import AgentApp

// P42 7: "Install SwarmHub skills on all bots": one confirmation, one manager turn covering every profile on the
// connection without the messaging skills, each recorded from the reply's block. Synthetic server only.

@MainActor private func allBotsStore(reply: String) -> (AppStore, Bot, [Bot], String) {
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") { return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])]) }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text"
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    let infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")
    let reactor = Bot(name: "Reactor", backend: .hermes, hermesProfile: "grok-reactor")
    let library = store.skillLibrary
    for skill in library where AppStore.messagingSkills.contains(skill.name) { jarvis.installedSkills[skill.name] = skill.version.description }
    // Reactor has an older messaging skill and no feedback skill.
    reactor.installedSkills["swarmhub-messages"] = "0.9.0"
    let elsewhere = Bot(name: "Elsewhere", backend: .hermes, hermesProfile: "grok-other"); elsewhere.hermesBaseURL = "https://other.example.com/v1"
    store.bots = [jarvis, infra, reactor, elsewhere]; store.selectedBot = jarvis
    return (store, jarvis, [infra, reactor, elsewhere], host)
}

@Test @MainActor func oneManagerTurnInstallsTheMessagingSkillsOnEveryBotWithoutThem() async throws {
    let block = """
    Installed on both.
    ```swarmhub
    [{"op":"skills_installed","bot":"grok-infra","skills":[{"name":"swarmhub-messages","version":"9.9.9"},{"name":"swarmhub-feedback","version":"9.9.9"}]},
     {"op":"skills_installed","bot":"grok-reactor","skills":[{"name":"swarmhub-messages","version":"9.9.9"},{"name":"swarmhub-feedback","version":"9.9.9"}]}]
    ```
    """
    let (store, jarvis, others, host) = allBotsStore(reply: block)
    let (infra, reactor, elsewhere) = (others[0], others[1], others[2])
    let gaps = store.messagingSkillGaps(manager: jarvis)
    #expect(gaps.map(\.bot.name) == ["Infra", "Reactor"], "the manager has them; another connection's bot is not this manager's")
    #expect(gaps.allSatisfy { Set($0.skills.map(\.name)) == AppStore.messagingSkills }, "an older version counts as missing")
    #expect(AllBotsSkillCopy.missing(gaps[0].skills).hasPrefix("Missing: swarmhub-"))
    #expect(store.managersWithSkillGaps.map(\.name) == ["Jarvis"])
    #expect(store.installSkillsOnAllBots(manager: jarvis))
    try await waitUntil { !store.anyTurnRunning && infra.installedSkills["swarmhub-feedback"] != nil && reactor.installedSkills["swarmhub-feedback"] != nil }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 1, "one manager request for every bot")
    let sent = try #require(turns.first?.body?["instructions"] as? String)
    #expect(sent.contains("confirmed it once for all of these profiles: grok-infra (Infra), grok-reactor (Reactor)"))
    for profile in ["grok-infra", "grok-reactor"] {
        #expect(sent.contains("mkdir -p ~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-messages"))
        #expect(sent.contains("cat > ~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-messages/scripts/bot-msg <<'SWARMHUB_EOF'"))
        #expect(sent.contains("~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-feedback/SKILL.md"))
        #expect(sent.contains(#"{"op":"skills_installed","bot":"\#(profile)","skills":["#))
    }
    #expect(!sent.contains("grok-jarvis/skills") && !sent.contains("grok-other"))
    #expect(jarvis.messages.first { $0.role == .user }?.content == "Install SwarmHub skills on all 2 bots.")
    #expect(store.messagingSkillGaps(manager: jarvis).isEmpty && elsewhere.installedSkills.isEmpty, "recorded per bot, capped at this build's versions")
    #expect(!store.installSkillsOnAllBots(manager: jarvis), "nothing left to install")
}
