import Foundation
import Testing
@testable import AgentApp

// A bot whose agent program or model was changed carries on: its fresh agent reads the bot's chat so far, once.

@MainActor private func systemLines(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }
@MainActor private func replies(_ bot: Bot) -> Int { bot.messages.filter { $0.role == .assistant && !$0.isStreaming && $0.content == "ok" }.count }

@Test @MainActor func theChatSoFarIsWhatThePersonAndTheBotSaid() async throws {
    let (store, bot) = try handoffStore(HandoffBridge())
    #expect(store.herdrCarryLines(of: bot).isEmpty, "a bot nobody has talked to has nothing to carry over")
    store.armHerdrCarryOver(for: [bot], running: [:])
    #expect(await store.herdrCarryHandoff(for: bot.id, status: { _ in }) == nil && store.herdrCarryOver(for: bot) == nil, "noted for nothing: the first message goes as it always did")
    bot.messages = [
        ChatMessage(role: .user, content: "Plan the launch"),
        ChatMessage(role: .assistant, content: "Here is the plan.\n\n```swarmhub\n{\"op\":\"about_you\",\"add\":\"Likes plans.\"}\n```"),
        AppOnlyLine.line("Ada created Legal"),
        ChatMessage(role: .user, content: "[From SwarmHub]\nLegal exists now.", metadata: [HerdrBotRelay.Key.kind: HerdrBotRelay.outcome]),
        ChatMessage(role: .assistant, content: "Noted."),
        ChatMessage(role: .user, content: "And now?"),
    ]
    let lines = store.herdrCarryLines(of: bot)
    #expect(lines.map(\.text) == ["Plan the launch", "Here is the plan.", "[From SwarmHub]\nLegal exists now.", "Noted."], "no app line, no hidden block, and not the message that is still to be answered")
    #expect(lines.map(\.seq) == [1, 2, 3, 4] && lines.map(\.channel) == ["chat", "chat", "agent", "chat"] && lines[2].author == AppConstants.name && lines[2].to == "Ada")
    #expect(store.herdrCarryApplies(to: bot))

    // Noted when the bot's program or model is changed; the backend then hands the chat over before a message.
    #expect(try store.herdrBackend(for: bot).handoff == nil)
    let old = HerdrAgentLaunch(server: HerdrServer.defaultID, core: "c", address: "t9", createdMs: 9)
    store.armHerdrCarryOver(for: [bot], running: [bot.id: old])
    let source = try #require(try store.herdrBackend(for: bot).handoff)
    #expect(source.lead == GrokHandoff.lead(for: bot.id, origin: .ownChat) && source.read == old && source.failures == 0, "the agent that ran before holds the conversation itself")

    let handoff = try #require(await store.herdrCarryHandoff(for: bot.id, status: { _ in }))
    #expect(handoff.origin == .ownChat && handoff.files.map(\.name) == ["conversation-so-far.md", "conversation-full.md"] && handoff.summary == nil && handoff.recentMessages == 4)
    let note = handoff.note(bytes: 8_000, withFiles: true), file = String(decoding: handoff.files[0].data, as: UTF8.self)
    #expect(note.hasPrefix(handoff.marker + " You are continuing a conversation this bot already had with the person in this chat.") && note.contains("conversation-so-far.md") && !note.contains("another app"))
    #expect(file.contains("This is what the person and Ada have said in this chat so far.") && file.contains("conversation-full.md") && !file.contains("grok"))
    #expect(file.contains("### The person") && file.contains("### \(AppConstants.name) → Ada") && file.contains("Noted.") && !file.contains("And now?") && !file.contains("about_you"))

    // A failure is counted for that launch; the agent's reply ends it.
    let fresh = HerdrAgentLaunch(server: HerdrServer.defaultID, core: "c", address: "t10", createdMs: 10)
    store.herdrCarryFailed(HerdrHandoffFailure(launch: fresh, why: "Its agent finished without a reply."), botID: bot.id)
    #expect(store.herdrCarryOver(for: bot)?.failures == 1 && store.herdrCarryOver(for: bot)?.failedFor == fresh)
    #expect(systemLines(bot).last == "Ada could not read the earlier messages in this chat. Its agent finished without a reply. Your message was sent without it. It is tried once more with your next message.")
    store.herdrCarriedOver(HerdrHandoffReceipt(launch: fresh, handoff: handoff), botID: bot.id)
    #expect(store.herdrCarryOver(for: bot) == nil && systemLines(bot).last == "Ada read the earlier messages in this chat: all 4 messages")
    #expect(try store.herdrBackend(for: bot).handoff == nil, "nothing more is handed over until the next change")
}

@Test @MainActor func aFreshAgentReadsTheChatBeforeThePersonsMessageAndOnlyOnce() async throws {
    let bridge = HandoffBridge()
    let (store, bot) = try handoffStore(bridge)
    #expect(store.send(text: "Plan the launch for Friday"))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 1 }
    // The change: the agent that runs now is noted.
    let running = try #require(await store.herdrRunningLaunches(on: store.herdrServer(for: bot)))
    let old = try #require(running[bot.id])
    store.armHerdrCarryOver(for: [bot], running: running)
    #expect(store.herdrCarryOver(for: bot)?.old == old)
    // That agent holds the conversation: a message to it carries nothing more.
    #expect(store.send(text: "Still you?"))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 2 }
    #expect(bridge.sent.map(\.route) == ["launch", "message"] && store.herdrCarryOver(for: bot) != nil)
    // Started fresh: the next message is preceded by the chat so far.
    #expect(try await store.restartHerdrAgent(for: bot))
    #expect(store.send(text: "Where were we?"))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 3 && store.herdrCarryOver(for: bot) == nil }
    let sent = bridge.sent.filter { $0.route != "end" }
    try #require(sent.map(\.route) == ["launch", "message", "launch-with-files"])
    let handed = sent[2]
    #expect(handed.text.contains(GrokHandoff.lead(for: bot.id, origin: .ownChat)) && handed.text.hasSuffix("Where were we?"))
    #expect(handed.files.keys.sorted() == ["conversation-full.md", "conversation-so-far.md"])
    let file = try #require(handed.files["conversation-so-far.md"])
    #expect(file.contains("Plan the launch for Friday") && file.contains("Still you?") && !file.contains("Where were we?"))
    #expect(systemLines(bot).contains("Ada read the earlier messages in this chat: all 4 messages"))
    // Once: the next message is the person's alone, and so is the first one of an agent started after that.
    #expect(store.send(text: "Good."))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 4 }
    #expect(bridge.sent.filter { $0.route != "end" }.map(\.route).suffix(1) == ["message"] && bridge.sent.filter { $0.route.hasSuffix("with-files") }.count == 1)
}

@Test @MainActor func aChatThatCannotBeHandedOverLetsTheMessageThrough() async throws {
    let bridge = HandoffBridge(); bridge.refusesFiles = true
    let (store, bot) = try handoffStore(bridge)
    #expect(store.send(text: "First"))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 1 }
    store.armHerdrCarryOver(for: [bot], running: try #require(await store.herdrRunningLaunches(on: store.herdrServer(for: bot))))
    #expect(try await store.restartHerdrAgent(for: bot))
    #expect(store.send(text: "Second"))
    try await waitUntil { store.runningTurns.isEmpty && replies(bot) == 2 && store.herdrCarryOver(for: bot)?.failures == 1 }
    #expect(bridge.sent.last?.text.hasSuffix("Second") == true && bridge.sent.last?.files.isEmpty == true, "the message goes as it always did")
    #expect(systemLines(bot).contains { $0.hasPrefix("Ada could not read the earlier messages in this chat.") && $0.hasSuffix("It is tried once more with your next message.") })
}

@Test @MainActor func aPreviouslySavedProviderChoiceCarriesTheDirectChatOnItsNextSend() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 1))
    bot.messages = [ChatMessage(role: .user, content: "The ship date?"), ChatMessage(role: .assistant, content: "Friday.")]
    // A pre-upgrade bot: it has a saved choice and a live agent from another provider, with no pending-switch flag.
    store.defaults.set("tpl-one", forKey: HerdrBackend.botTemplateKey(bot.id))
    store.launchWorkEnabled = true
    var backend = try store.herdrBackend(for: bot)
    backend.coordinate = nil
    bridge.seed(agent: backend.agentName, template: "old-provider")
    for prompt in ["When was it?", "Thanks"] {
        let stream = try await backend.send(.init(sessionID: bot.id.uuidString, systemPrompt: "", messages: [(role: "user", content: prompt)], images: []))
        for try await _ in stream {}
    }
    let posts = bridge.sent
    #expect(posts.filter { $0.route == "end" }.count == 1)
    let handoffs = posts.filter { !$0.files.isEmpty }
    #expect(handoffs.count == 1, "both the imported archive and the current conversation travel once")
    #expect(handoffs.contains { $0.files["conversation-full.md"]?.contains("Friday.") == true })
    #expect(posts.filter { $0.text.hasSuffix("When was it?") }.count == 1)
    #expect(posts.last?.text.hasSuffix("Thanks") == true)
    #expect(bot.messages.contains { $0.content == "Friday." })
}

@Test @MainActor func pendingModelSwitchWaitsForIdleAfterTheReplyIsSaved() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    let (store, bot) = try handoffStore(bridge)
    bot.messages = [ChatMessage(role: .user, content: "Check the build"), ChatMessage(role: .assistant, content: "Build passed.")]
    store.setHerdrTemplate("tpl-one", for: bot)
    store.launchWorkEnabled = true
    var backend = try store.herdrBackend(for: bot)
    backend.coordinate = nil
    bridge.seed(agent: backend.agentName, template: "old-provider", rows: [("task", "Check the build"), ("reply", "Build passed.")])
    bridge.setState("working", for: backend.agentName)

    let session = bot.id.uuidString
    let stream = try await backend.send(.init(sessionID: session, systemPrompt: "", messages: [("user", "Run the tests")]))
    var waited = false
    for try await event in stream {
        if case .status(let code) = event, code == HerdrTurnStatus.waitingForIdle.code {
            waited = true
            #expect(store.modelSwitchPending(bot) && bridge.sent.isEmpty)
            #expect(try await backend.stopTarget(sessionID: session) == .noActiveRun)
            #expect(try await backend.features().isEmpty)
            bridge.setState("idle", for: backend.agentName)
        }
    }

    #expect(waited && !store.modelSwitchPending(bot))
    let posts = bridge.sent
    #expect(posts.map(\.route) == ["end", "launch-with-files"])
    #expect(posts.first { $0.route == "launch-with-files" }?.files["conversation-so-far.md"]?.contains("Build passed.") == true)
    #expect(posts.last?.text.hasSuffix("Run the tests") == true)
}

@Test @MainActor func startingFreshOrForgettingABotClearsPendingModelSwitchAndCarryOver() async throws {
    let bridge = HandoffBridge()
    let (store, bot) = try handoffStore(bridge)
    bot.messages = [ChatMessage(role: .user, content: "Secret draft"), ChatMessage(role: .assistant, content: "Ready.")]
    store.markModelSwitch(bot)
    store.armHerdrCarryOver(for: [bot], running: [:])
    #expect(store.modelSwitchPending(bot) && store.herdrCarryOver(for: bot) != nil)

    // Details → New conversation → Start fresh clears both the carry-over and the pending switch flag.
    store.setHerdrCarryOver(nil, for: bot)
    store.clearModelSwitch(bot.id)
    let server = store.herdrServer(for: bot)
    let workspace = try await store.herdrClient(for: server).workspace()
    let sources = try await store.prepareDirectModel(bot: bot, server: server, template: store.herdrTemplate(for: bot),
                                                     model: store.herdrModel(for: bot), in: workspace)
    #expect(sources.isEmpty && store.herdrCarryOver(for: bot) == nil && !store.modelSwitchPending(bot))

    // Deleting/forgetting a bot removes its model-switch and confirmation defaults too.
    store.markModelSwitch(bot)
    store.markAutoSwitch(bot)
    store.defaults.set("confirmed", forKey: "herdr.confirmed.\(bot.id)")
    store.forgetHerdrCarryOver(bot.id)
    #expect(!store.modelSwitchPending(bot) && !store.autoSwitchPending(bot) && store.defaults.object(forKey: "herdr.confirmed.\(bot.id)") == nil)
}

@Test @MainActor func togglingAutoModeReplacesWarmAgentsImmediatelyAndActiveSessionsOnNextSend() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    let (store, bot) = try handoffStore(bridge)
    let server = store.herdrServer(for: bot)
    store.launchWorkEnabled = true
    let agentName = HerdrBackend.agentName(botName: bot.name, botID: bot.id)

    // 1. An unused warm-started agent is ended immediately and replaced with a fresh warm agent.
    bridge.seed(agent: agentName, warm: true)
    let savedWarm = try await store.applyProjectAutoMode(true, for: bot, on: server)
    #expect(savedWarm.autoMode)
    #expect(!store.autoSwitchPending(bot), "fresh warm replacement already carries Auto mode")
    #expect(bridge.sent.map(\.route) == ["end", "launch"])

    // 2. An active conversation session stays until the next message, which restarts it with carry-over.
    bot.messages = [ChatMessage(role: .user, content: "Check the build"), ChatMessage(role: .assistant, content: "Ready to run.")]
    // Mark the running launch as used by seeding a conversation launch.
    _ = try await store.restartHerdrAgent(for: bot)
    bridge.seed(agent: agentName, warm: false, rows: [(kind: "task", text: "Check the build"), (kind: "reply", text: "Ready to run.")])
    let beforeCount = bridge.sent.count
    let savedUsed = try await store.applyProjectAutoMode(true, for: bot, on: server)
    #expect(savedUsed.autoMode && store.autoSwitchPending(bot))
    #expect(bridge.sent.count == beforeCount, "an active conversation is not killed before the next message")

    var backend = try store.herdrBackend(for: bot)
    backend.coordinate = nil
    let stream = try await backend.send(.init(sessionID: bot.id.uuidString, systemPrompt: "", messages: [(role: "user", content: "Run the tests")], images: []))
    for try await _ in stream {}

    let delta = Array(bridge.sent.dropFirst(beforeCount))
    #expect(delta.map(\.route) == ["end", "launch-with-files"])
    #expect(delta[1].files["conversation-so-far.md"]?.contains("Ready to run.") == true)
    #expect(delta[1].text.hasSuffix("Run the tests"))
    #expect(!store.autoSwitchPending(bot))
}
