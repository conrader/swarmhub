import Foundation
import Testing
@testable import AgentApp

// One confirmation, one bounded turn per legacy profile; failures never erase another bot's result. Synthetic only.

@MainActor private func allBotsStore(failingProfile: String? = nil, payloadRejectedProfile: String? = nil) -> (AppStore, Bot, [Bot], String) {
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, body in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            let instructions = body?["instructions"] as? String ?? ""
            let profile = String((instructions.components(separatedBy: #""op":"skills_installed","bot":""#).last ?? "").prefix { $0 != "\"" })
            if profile == payloadRejectedProfile { return .json(400, ["error": ["message": "Invalid 'instructions': string too long. Expected max 1048576, got 2802969."]]) }
            let reply = profile == failingProfile ? "The filesystem refused the skill writes." : """
            Installed.
            ```swarmhub
            {"op":"skills_installed","bot":"\(profile)","skills":[{"name":"swarmhub-messages","version":"9.9.9"},{"name":"swarmhub-feedback","version":"9.9.9"}]}
            ```
            """
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
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

@Test @MainActor func sixteenBotsKeepTheirBundledSkillBytesInSeparateBudgetedTurns() async throws {
    let (store, manager, others, host) = allBotsStore()
    let extra = (0..<14).map { Bot(name: "Worker \($0)", backend: .hermes, hermesProfile: "worker-\($0)") }
    store.bots.append(contentsOf: extra)
    let targets = Array(others.prefix(2)) + extra
    #expect(store.installSkillsOnAllBots(manager: manager))
    // Sixteen sequential turns of up to 512 KiB each: the shared ceiling, not a 30 s cap (a loaded full-suite Mac hit 32.6 s).
    // A timeout says whether the batch stalled (turns sent, profiles still queued, a slot held) or only ran slowly.
    do {
        try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && targets.allSatisfy { store.skillInstallResults[$0.id] != nil } }
    } catch {
        let sent = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count
        Issue.record("\(sent) turns sent, \(store.allBotsSkillQueue[manager.id]?.count ?? 0) queued, manager idle: \(store.isIdle(manager))")
        throw error
    }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 16)
    for turn in turns {
        let instructions = try #require(turn.body?["instructions"] as? String)
        #expect(try JSONSerialization.data(withJSONObject: ["instructions": instructions]).count <= SkillInstallPayloadError.instructionsByteBudget)
    }
    #expect(targets.allSatisfy { !$0.installedSkills.isEmpty && $0.skillInstallFailures.isEmpty })
    #expect(manager.messages.filter { $0.metadata["skill-install-result"] != nil }.count == 16)
}

@Test @MainActor func separateManagerTurnsInstallMessagingSkillsOnEveryBotWithoutThem() async throws {
    let (store, jarvis, others, host) = allBotsStore()
    let (infra, reactor, elsewhere) = (others[0], others[1], others[2])
    let gaps = store.messagingSkillGaps(manager: jarvis)
    #expect(gaps.map(\.bot.name) == ["Infra", "Reactor"], "the manager has them; another connection's bot is not this manager's")
    #expect(gaps.allSatisfy { Set($0.skills.map(\.name)) == AppStore.messagingSkills }, "an older version counts as missing")
    #expect(AllBotsSkillCopy.missing(gaps[0].skills).hasPrefix("Missing: swarmhub-"))
    #expect(store.managersWithSkillGaps.map(\.name) == ["Jarvis"])
    #expect(store.installSkillsOnAllBots(manager: jarvis))
    try await waitUntil { !store.anyTurnRunning && infra.installedSkills["swarmhub-feedback"] != nil && reactor.installedSkills["swarmhub-feedback"] != nil }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 2, "one manager request per bot")
    for (turn, profile) in zip(turns, ["grok-infra", "grok-reactor"]) {
        let sent = try #require(turn.body?["instructions"] as? String)
        #expect(try JSONSerialization.data(withJSONObject: ["instructions": sent]).count <= SkillInstallPayloadError.instructionsByteBudget)
        #expect(sent.contains("mkdir -p ~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-messages"))
        #expect(sent.contains("cat > ~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-messages/scripts/bot-msg <<'SWARMHUB_EOF'"))
        #expect(sent.contains("~/.hermes/profiles/\(profile)/skills/swarmhub/swarmhub-feedback/SKILL.md"))
        #expect(sent.contains(#"{"op":"skills_installed","bot":"\#(profile)","skills":["#))
        let other = profile == "grok-infra" ? "grok-reactor" : "grok-infra"
        #expect(!sent.contains("\(other)/skills"), "no other bot's skill bytes in this turn")
        #expect(!sent.contains("grok-jarvis/skills") && !sent.contains("grok-other"))
    }
    #expect(jarvis.messages.filter { $0.role == .user }.map(\.content) == [AllBotsSkillCopy.request(1), AllBotsSkillCopy.request(1)])
    #expect(store.messagingSkillGaps(manager: jarvis).isEmpty && elsewhere.installedSkills.isEmpty, "recorded per bot, capped at this build's versions")
    #expect(!store.installSkillsOnAllBots(manager: jarvis), "nothing left to install")
}

@Test @MainActor func allBotsRecordsFailureAndContinuesToTheNextBot() async throws {
    let (store, manager, others, host) = allBotsStore(failingProfile: "grok-infra")
    #expect(store.installSkillsOnAllBots(manager: manager))
    // Moving to another chat during the batch must not change the next turn's destination.
    store.selectedBot = others[2]
    try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && store.skillInstallResults[others[1].id] != nil }
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 2)
    #expect(store.skillInstallResults[others[0].id]?.status == .failed)
    #expect(store.skillInstallResults[others[1].id]?.status == .peerEnableUnverified)
    #expect(others[0].installedSkills.isEmpty && !others[0].skillInstallFailures.isEmpty)
    #expect(!others[1].installedSkills.isEmpty && others[1].skillInstallFailures.isEmpty)
    #expect(others[2].messages.isEmpty)
    #expect(manager.messages.filter { $0.metadata["skill-install-result"] != nil }.count == 2)
}

@Test @MainActor func oversizedBotIsNotSentAndDoesNotPreventASmallerBotInstalling() async throws {
    let (store, manager, others, host) = allBotsStore()
    // Rendering a profile can change the size: the first profile exceeds the budget through {{BOT}} expansion.
    let large = BundledSkill(name: "swarmhub-feedback", version: SkillVersion("1.0.0")!,
        template: String(repeating: "{{BOT}}", count: 40_000))
    store.skillLibraryOverride = [large]
    others[0].hermesProfile = "grok-infra-very-long-profile"
    manager.installedSkills[large.name] = "1.0.0"
    #expect(store.installSkillsOnAllBots(manager: manager))
    try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && store.skillInstallResults[others[1].id] != nil }
    let turns = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }
    #expect(turns.count == 1)
    #expect(store.skillInstallResults[others[0].id]?.status == .clientPayloadError)
    #expect(store.skillInstallResults[others[0].id]?.detail.contains("nothing was sent") == true)
    #expect(others[0].skillInstallFailures.isEmpty)
    #expect(store.skillInstallResults[others[1].id]?.status == .installed)
}

@Test @MainActor func provider400ForOneBotDoesNotBackOffOrStopTheOtherBots() async throws {
    let (store, manager, others, host) = allBotsStore(payloadRejectedProfile: "grok-infra")
    #expect(store.installSkillsOnAllBots(manager: manager))
    try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && store.skillInstallResults[others[1].id] != nil }
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 2)
    #expect(store.skillInstallResults[others[0].id]?.status == .clientPayloadError)
    #expect(others[0].installedSkills.isEmpty && others[0].skillInstallFailures.isEmpty)
    #expect(!others[1].installedSkills.isEmpty && others[1].skillInstallFailures.isEmpty)
}

@Test @MainActor func stoppingAllBotsCancelsTheRemainingProfiles() throws {
    let (store, manager, others, host) = allBotsStore()
    store.allBotsSkillQueue[manager.id] = store.messagingSkillGaps(manager: manager)
    store.continueAllBotsSkillInstall(manager: manager, end: .stoppedByUser)
    #expect(store.allBotsSkillQueue.isEmpty && ChatParityServer.requests(host).isEmpty)
    #expect(others.prefix(2).allSatisfy { store.skillInstallResults[$0.id]?.status == .notSent && $0.skillInstallFailures.isEmpty })
}

@Test @MainActor func stoppingAQueuedManagerMessageLetsTheBatchContinue() async throws {
    let (store, manager, others, host) = allBotsStore()
    store.allBotsSkillQueue[manager.id] = store.messagingSkillGaps(manager: manager)
    // The user's queued message took the slot between installs and was stopped: it is not the batch's install turn.
    store.continueAllBotsSkillInstall(manager: manager, end: .stoppedByUser, token: UUID())
    try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && others.prefix(2).allSatisfy { store.skillInstallResults[$0.id] != nil } }
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 2)
    #expect(others.prefix(2).allSatisfy { store.skillInstallResults[$0.id]?.status != .notSent && !$0.installedSkills.isEmpty })
    #expect(store.allBotsSkillTurn.isEmpty)
}

@Test @MainActor func aRetryThatSendsNothingResumesTheBatch() async throws {
    let (store, manager, others, host) = allBotsStore()
    store.allBotsSkillQueue[manager.id] = store.messagingSkillGaps(manager: manager)
    // A Retry holds the manager's chat and ends before runChatTurn (nothing sent); only its slot release can resume.
    let token = store.beginTurn(in: manager, bot: manager, assistant: nil).token
    #expect(!store.sendNextAllBotsSkillInstall(manager: manager), "waits while the chat is busy")
    #expect(store.allBotsSkillQueue[manager.id]?.count == 2 && ChatParityServer.requests(host).isEmpty)
    store.releaseSlot(token)
    try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty && others.prefix(2).allSatisfy { store.skillInstallResults[$0.id] != nil } }
    #expect(ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.count == 2)
}
