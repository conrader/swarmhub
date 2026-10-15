import Foundation
import Testing
@testable import AgentApp

// P22 store level: the manager text rides only on management turns (checked in the HTTP bodies a real HermesBackend
// sends), swarmhub ops change the store, and no key reaches store.json. Synthetic servers only; no live writes.

private let managerKey = "0123456789abcdef0123456789abcdef"
private let marker = "P22-MANAGER-TEXT-MARKER"

/// A manager store whose bot talks to a synthetic Hermes (`ChatParityServer`) that answers every chat turn with
/// `replies` in order (the last one repeats) and serves `/p/<profile>/v1/models` for `served` derived keys.
@MainActor private func managerStore(replies: [String] = ["ok"], served: Set<String> = [], url: URL = temporaryStore(), legacy: Bool = false) -> (AppStore, Bot, String) {
    let counter = LockedTrace()
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { request, _ in
        let path = request.url!.path
        if path == "/v1/chat/completions" {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("message", ["choices": [["delta": ["content": reply]]]])])
        }
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        return .json(404, ["error": "no route"])
    }
    let probe = MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "p", parts[2...] == ["v1", "models"], served.contains(parts[1]) else { return (404, ["error": "no route"]) }
        let expected = "Bearer " + BotManagerText.derivedKey(managerKey: managerKey, botName: parts[1])
        return request.value(forHTTPHeaderField: "Authorization") == expected ? (200, ["data": [["id": parts[1]]]]) : (401, ["error": "bad key"])
    }
    let defaults = isolatedDefaults(); defaults.set("https://\(probe.host)", forKey: "hermesBaseURL")
    let keys = InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": managerKey])
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: keys, defaults: defaults, hermesSession: probe.session)
    store.managerTemplateOverride = "\(marker) you are {{MANAGER}} ({{MANAGER_ENV}})"
    store.botProbeAttempts = 2; store.botProbeDelay = .milliseconds(5)
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, host)
}

@MainActor private func turn(_ store: AppStore, _ text: String) async throws {
    #expect(store.send(text: text))
    try await waitUntil { !store.anyTurnRunning }
}

/// The `instructions` of every chat turn the server received, in order.
private func sentInstructions(_ host: String) -> [String] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["instructions"] as? String ?? "" }
}

@Test @MainActor func managerTextRidesOnlyOnManagementTurns() async throws {
    let (store, _, host) = managerStore()
    try await turn(store, "Good morning Jarvis")                      // ordinary → not attached
    try await turn(store, "Create a bot called rapper that raps")     // intent → attached
    try await turn(store, "yes")                                      // follow-up → attached
    try await turn(store, "yes")
    try await turn(store, "yes")                                      // third follow-up, still open
    try await turn(store, "thanks, what's the weather?")              // window closed after 3 follow-ups → not attached
    let sent = sentInstructions(host)
    #expect(sent.map { $0.contains(marker) } == [false, true, true, true, true, false])
    #expect(sent[0] == "You are Jarvis." && sent[5] == "You are Jarvis.")
    #expect(sent[1].hasPrefix("You are Jarvis.\n\n") && sent[1].contains("you are grok-jarvis (~/.hermes/profiles/grok-jarvis/.env)"))
    // The session is created with the bot's own instructions only, and history never carries the text either.
    let created = try #require(ChatParityServer.requests(host).first { $0.path == "/api/sessions" })
    let sessionPrompt = created.body?["system_prompt"] as? String
    #expect(sessionPrompt == "You are Jarvis.")
    #expect(!ChatParityServer.requests(host).contains { ($0.body?["input"] as? String ?? "").contains(marker) })
}

/// Legacy servers get the whole history each turn: the text is only ever the turn's system message, never a stored message.
@Test @MainActor func legacyHistoryNeverCarriesTheManagerText() async throws {
    let (store, _, host) = managerStore(legacy: true)
    try await turn(store, "list bots")
    store.managementExchanges = [:]
    try await turn(store, "good night")
    let turns = ChatParityServer.requests(host).filter { $0.path == "/v1/chat/completions" }.compactMap { $0.body?["messages"] as? [[String: Any]] }
    #expect(turns.count == 2)
    #expect((turns[0].first?["content"] as? String)?.contains(marker) == true)
    let ordinary = turns[1].compactMap { $0["content"] as? String }
    #expect(ordinary.count == 4 && ordinary.allSatisfy { !$0.contains(marker) })
}

@Test @MainActor func aSwarmhubBlockClosesTheExchange() async throws {
    let block = "Done.\n```swarmhub\n{\"op\":\"instructions_changed\",\"name\":\"grok-jarvis\"}\n```"
    let (store, _, host) = managerStore(replies: ["Shall I?", block, "ok"])
    try await turn(store, "change the instructions of grok-jarvis")
    try await turn(store, "yes")
    try await turn(store, "yes")
    #expect(sentInstructions(host).map { $0.contains(marker) } == [true, true, false])
}

@Test @MainActor func tenMinutesCloseTheExchange() async throws {
    let (store, _, host) = managerStore()
    var clock = Date(timeIntervalSince1970: 2_000_000); store.now = { clock }
    try await turn(store, "list bots")
    clock = clock.addingTimeInterval(601)
    try await turn(store, "yes")
    #expect(sentInstructions(host).map { $0.contains(marker) } == [true, false])
}

@Test @MainActor func menuFillsTheComposerAndAttachesTheNextTurn() async throws {
    let (store, jarvis, host) = managerStore()
    store.startManagement(.newBot, manager: jarvis)
    #expect(store.composerFill?.botID == jarvis.id && store.composerFill?.text == ManageBotsAction.newBot.request())
    try await turn(store, "a bot that says PONG")
    #expect(sentInstructions(host).map { $0.contains(marker) } == [true])
}

@Test @MainActor func nonManagersAndThreadsNeverGetTheText() async throws {
    let (store, jarvis, host) = managerStore()
    jarvis.canManageBots = false
    try await turn(store, "create a bot called x")
    #expect(!sentInstructions(host)[0].contains(marker))
    #expect(store.managementExchanges.isEmpty)
}

// MARK: Ops

@Test @MainActor func botCreatedDerivesTheKeyProbesAndAddsTheBot() async throws {
    let url = temporaryStore()
    let block = "Created.\n```swarmhub\n{\"op\":\"bot_created\",\"name\":\"p22-vanilla-test\",\"description\":\"Says PONG\",\"avatar\":{\"shape\":\"heart\",\"colour\":\"cyan\"}}\n```"
    let (store, jarvis, _) = managerStore(replies: [block], served: ["p22-vanilla-test"], url: url)
    try await turn(store, "yes create a bot called p22-vanilla-test")
    try await waitUntil { store.bots.count == 2 }
    let created = try #require(store.bots.first { $0.hermesProfile == "p22-vanilla-test" })
    #expect(created.name == "P22 Vanilla Test" && created.botDescription == "Says PONG" && created.backend == .hermes)
    #expect(created.avatarMark == AvatarMark(shape: "heart", colour: "cyan"))
    let derived = BotManagerText.derivedKey(managerKey: managerKey, botName: "p22-vanilla-test")
    #expect(store.keyStore.key(for: "hermes.p22-vanilla-test") == derived)
    #expect(jarvis.messages.last?.role == .system && jarvis.messages.last?.content == "Jarvis created P22 Vanilla Test")
    // No key in store.json: neither the derived key nor the manager's.
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains(derived) && !saved.contains(managerKey))
}

@Test @MainActor func botCreatedKeepsNothingWhenTheProbeFails() async throws {
    let block = "```swarmhub\n{\"op\":\"bot_created\",\"name\":\"not-there\"}\n```"
    let (store, jarvis, _) = managerStore(replies: [block], served: [])
    try await turn(store, "create a bot called not-there")
    try await waitUntil { jarvis.messages.last?.role == .system }
    #expect(jarvis.messages.last?.content == "Couldn’t reach not-there yet")
    #expect(store.bots.count == 1 && store.keyStore.key(for: "hermes.not-there").isEmpty)
}

@Test @MainActor func avatarDescriptionInstructionsAndRetireOpsChangeTheirBots() async throws {
    let rapper = Bot(name: "Rapper", backend: .hermes, messages: [ChatMessage(role: .user, content: "hi")], hermesProfile: "grok-rapper")
    let ops = "```swarmhub\n[{\"op\":\"avatar\",\"name\":\"grok-rapper\",\"shape\":\"star\",\"colour\":\"red\"},{\"op\":\"avatar\",\"name\":\"grok-jarvis\",\"shape\":\"gem\",\"colour\":\"blue\"},"
        + "{\"op\":\"description\",\"name\":\"grok-rapper\",\"description\":\"Writes verses\"},{\"op\":\"instructions\",\"name\":\"grok-rapper\",\"text\":\"You rap.\"}]\n```"
    let (store, jarvis, _) = managerStore(replies: [ops, "```swarmhub\n{\"op\":\"instructions_changed\",\"name\":\"grok-rapper\"}\n```", "```swarmhub\n{\"op\":\"bot_retired\",\"name\":\"grok-rapper\"}\n```"])
    store.bots.append(rapper)
    let t0 = Date(timeIntervalSince1970: 3_000_000); store.now = { t0 }
    try await turn(store, "change the avatar of grok-rapper")
    try await waitUntil { rapper.boxInstructions != nil }
    #expect(rapper.avatarMark == AvatarMark(shape: "star", colour: "red") && jarvis.avatarMark == AvatarMark(shape: "gem", colour: "blue"))
    #expect(rapper.botDescription == "Writes verses" && rapper.boxInstructions == BoxInstructions(text: "You rap.", fetchedAt: t0))
    try await turn(store, "change the instructions of grok-rapper")
    try await waitUntil { rapper.boxInstructions?.stale == true }
    #expect(rapper.boxInstructions?.text == "You rap.")
    try await turn(store, "retire the bot grok-rapper")
    try await waitUntil { rapper.isHidden }
    // Retired = hidden with a label; the bot and its history stay.
    #expect(rapper.retiredOnBox && store.bots.contains(rapper) && rapper.messages.map(\.content) == ["hi"])
}

@Test @MainActor func botsListOffersMissingProfilesAndAddUsesTheDerivedKey() async throws {
    let list = "```swarmhub\n{\"op\":\"bots\",\"list\":[{\"name\":\"grok-jarvis\"},{\"name\":\"default\"},{\"name\":\"new-one\",\"description\":\"New\"},{\"name\":\"pasted\"}]}\n```"
    let (store, jarvis, _) = managerStore(replies: [list], served: ["new-one"])
    try await turn(store, "list bots")
    try await waitUntil { store.botOffers[jarvis.id] != nil }
    #expect(store.botOffers[jarvis.id]?.map(\.name) == ["new-one", "pasted"])
    await store.addOffered(try #require(store.botOffers[jarvis.id]?.first), manager: jarvis)
    #expect(store.bots.contains { $0.hermesProfile == "new-one" && $0.botDescription == "New" })
    await store.addOffered(try #require(store.botOffers[jarvis.id]?.first { $0.name == "pasted" }), manager: jarvis)
    #expect(store.botOffers[jarvis.id]?.map(\.state) == [.unreachable])
}

// MARK: Role

@Test @MainActor func jarvisBecomesManagerOnceAndOnlyOnePerConnection() throws {
    let url = temporaryStore(); let defaults = isolatedDefaults()
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), other = Bot(name: "Other", backend: .hermes, hermesProfile: "grok-other")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(StoreFile(bots: [jarvis, other], groups: [])).write(to: url)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let loaded = try #require(store.bots.first { $0.hermesProfile == "grok-jarvis" })
    #expect(loaded.canManageBots && store.isManager(loaded))
    let second = try #require(store.bots.first { $0.hermesProfile == "grok-other" })
    store.setCanManageBots(second, true)
    #expect(second.canManageBots && !loaded.canManageBots && store.manager(for: loaded)?.id == second.id)
    store.setCanManageBots(second, false)
    // The migration ran once: reopening does not turn Jarvis back on.
    let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(!reopened.bots.contains { $0.canManageBots })
    // Non-Hermes bots cannot hold the role.
    let mock = Bot(name: "Mock", backend: .mock); reopened.bots.append(mock); reopened.setCanManageBots(mock, true)
    #expect(!mock.canManageBots)
}
