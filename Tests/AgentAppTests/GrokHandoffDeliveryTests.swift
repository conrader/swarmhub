import Foundation
import Testing
@testable import AgentApp

// How an imported bot's agent gets its earlier conversation (`HerdrHandoff`): as a turn of its own before the
// person's message, once per agent session, read from the session's saved rows on the server.

private let persona = "You are Ada. Keep answers short."
private let appNote = "A note of the app for this bot."

/// A handoff of a conversation too long to go whole, for a bot with this id.
private func fixture(summary: String? = nil) -> (handoff: HerdrHandoff, id: UUID) {
    let id = UUID()
    let transcript = GrokHandoff.Transcript(handoffConversation(exchanges: 120, bytes: 400))
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    let saved = summary.map { handoffSummary($0, of: plan) }
    return (GrokHandoff.package(GrokHandoff.render(transcript, plan: plan, summary: saved, botName: "Ada"), archiveID: id), id)
}

/// The bot's backend on `bridge`, with instructions and one note of the app; `handoff` nil is a bot without one.
private func backend(_ bridge: HandoffBridge, id: UUID, handoff: HerdrHandoff?) -> HerdrBackend {
    var made = HerdrBackend(client: bridge.client(), botName: "Ada", botID: id, template: nil, instructions: persona)
    made.helperNote = appNote
    if let handoff { made.handoff = HerdrHandoffSource(lead: handoff.lead, prepare: { _ in handoff }) }
    return made
}

/// Sends one message of the person and returns the reply the chat ends up with.
private func say(_ text: String, to backend: HerdrBackend, session: String) async throws -> String {
    var reply = ""
    let stream = try await backend.send(AgentRequest(sessionID: session, systemPrompt: "", messages: [(role: "user", content: text)]))
    for try await event in stream {
        if case .replace(let now) = event { reply = now }
    }
    return reply
}

private let answering: @Sendable (String) -> String? = { task in task.contains("[SwarmHub handoff") ? "It stood at question 120." : "the answer" }

@Test func aNewAgentReadsTheConversationBeforeThePersonsMessage() async throws {
    let bridge = HandoffBridge(); bridge.answers = answering
    let (handoff, id) = fixture()
    let reply = try await say("What did we decide last?", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch-with-files", "message"])
    let first = sent[0], second = sent[1]
    #expect(first.text.contains(persona) && first.text.contains(handoff.marker) && first.text.contains("grok-handoff.md"), "the first task: the bot's instructions and the note with its marker")
    #expect(!first.text.contains("What did we decide last?") && !first.text.contains(appNote), "neither the person's message nor the app's notes")
    #expect(first.files.keys.sorted() == ["grok-handoff.md", "grok-history-full.md"])
    #expect(first.files["grok-handoff.md"] == String(decoding: handoff.files[0].data, as: UTF8.self) && first.files["grok-history-full.md"]?.contains("question 1 end") == true)
    #expect(first.workspaceID == id.uuidString.lowercased(), "launched into the bot's own workspace folder")
    #expect(first.text.utf8.count <= 12 * 1024 && first.text.contains("The last messages, in case you cannot open the files:") && first.text.contains("answer 120 end"))
    #expect(second.agent == first.agent && second.text.hasSuffix("What did we decide last?") && second.text.contains(appNote) && !second.text.contains(handoff.lead))
    #expect(reply == "the answer")
}

@Test func aSessionThatHasReadItIsSentNothingMore() async throws {
    let (handoff, id) = fixture()
    let name = HerdrBackend.agentName(botName: "Ada", botID: id)
    // The same revision, and an older one: either way the session has had the conversation.
    #expect(GrokHandoff.marker(for: id, revision: "1-1", origin: .ownChat).hasPrefix(GrokHandoff.lead(for: id, origin: .ownChat)))
    for marker in [handoff.marker, GrokHandoff.marker(for: id, revision: "1-1")] {
        let bridge = HandoffBridge(); bridge.answers = answering
        bridge.seed(agent: name, rows: [("task", marker + " You are continuing an existing conversation."), ("reply", "It stood at question 120."),
                                        ("task", "an earlier question"), ("reply", "an earlier answer")])
        let reply = try await say("And now?", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
        let sent = bridge.sent
        try #require(sent.map(\.route) == ["message"], "no request beside the person's message")
        #expect(sent[0].text.hasSuffix("And now?") && !sent[0].text.contains(handoff.lead) && sent[0].files.isEmpty && reply == "the answer")
    }
}

@Test func aHandoffThatGotNoReplyIsSentAgain() async throws {
    let (handoff, id) = fixture()
    let name = HerdrBackend.agentName(botName: "Ada", botID: id)
    let bridge = HandoffBridge(); bridge.answers = answering
    // It was stopped or lost: the agent is not working on it.
    bridge.seed(agent: name, rows: [("task", "an earlier question"), ("reply", "an earlier answer"), ("task", handoff.note(bytes: 8_000, withFiles: true))])
    let reply = try await say("And now?", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["message-with-files", "message"])
    #expect(sent[0].agent == name && sent[0].text.hasPrefix(handoff.marker) && sent[0].files.keys.sorted() == ["grok-handoff.md", "grok-history-full.md"], "to the running agent, with the files")
    #expect(!sent[0].text.contains(persona), "an agent that holds a conversation has its instructions")
    #expect(sent[1].text.hasSuffix("And now?") && reply == "the answer")
}

@Test func aHandoffTheAgentIsStillReadingIsWaitedForNotSentTwice() async throws {
    let (handoff, id) = fixture()
    let name = HerdrBackend.agentName(botName: "Ada", botID: id)
    let bridge = HandoffBridge(); bridge.answers = answering
    bridge.agentState = "working"; bridge.lateReply = "It stood at question 120."
    bridge.seed(agent: name, rows: [("task", handoff.note(bytes: 8_000, withFiles: true))])
    let reply = try await say("And now?", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["message"], "the handoff on its way is followed")
    #expect(sent[0].text.hasSuffix("And now?") && !sent[0].text.contains(handoff.lead) && reply == "the answer")
    // What the saved rows say, by themselves.
    let task = HerdrClient.Item(id: 4, kind: "task", text: handoff.marker + " …"), answer = HerdrClient.Item(id: 5, kind: "reply", text: "ok")
    let other = HerdrClient.Item(id: 3, kind: "task", text: "a question")
    let unsent = HerdrClient.Item(id: 4, kind: "task", text: handoff.marker + " …", state: "not_sent")
    #expect(HerdrClient.handoffState(lead: handoff.lead, rows: [other]) == .missing && HerdrClient.handoffState(lead: handoff.lead, rows: []) == .missing)
    #expect(HerdrClient.handoffState(lead: handoff.lead, rows: [answer, task, other]) == .delivered, "in whatever order the rows come")
    #expect(HerdrClient.handoffState(lead: handoff.lead, rows: [other, task]) == .unanswered(task: 4))
    #expect(HerdrClient.handoffState(lead: handoff.lead, rows: [HerdrClient.Item(id: 2, kind: "reply", text: "earlier"), other, task]) == .unanswered(task: 4), "a reply before it does not count")
    #expect(HerdrClient.handoffState(lead: handoff.lead, rows: [other, unsent, answer]) == .missing, "a task that was never typed taught the agent nothing")
}

@Test func anAgentStartedAheadOfTimeIsStartedAgainWithTheFiles() async throws {
    let (handoff, id) = fixture()
    let name = HerdrBackend.agentName(botName: "Ada", botID: id)
    let bridge = HandoffBridge(); bridge.answers = answering
    bridge.seed(agent: name, warm: true)
    let reply = try await say("Hello again", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["end", "launch-with-files", "message"], "the unused agent is ended and launched with the files, so they land in its folder")
    #expect(sent.allSatisfy { $0.agent == name } && sent[1].text.contains(persona) && sent[1].text.contains(handoff.marker) && sent[1].files.count == 2)
    #expect(sent[1].workspaceID == id.uuidString.lowercased() && sent[2].text.hasSuffix("Hello again") && reply == "the answer" && bridge.liveNames == [name])
    // A server that cannot launch with files keeps the agent and sends them to it, as its first task.
    let older = HandoffBridge(); older.answers = answering; older.launchAttachments = false
    older.seed(agent: name, warm: true)
    _ = try await say("Hello again", to: backend(older, id: id, handoff: handoff), session: id.uuidString)
    try #require(older.sent.map(\.route) == ["message-with-files", "message"])
    #expect(older.sent[0].text.contains(persona) && older.sent[0].text.contains(handoff.marker) && older.sent[0].text.utf8.count <= 12 * 1024)
}

@Test func aServerThatTakesNoFilesGetsTheNoteWithItsExcerpt() async throws {
    let (handoff, id) = fixture(summary: "They planned the launch for Friday.")
    let bridge = HandoffBridge(); bridge.answers = answering; bridge.attachments = false
    _ = try await say("Hello again", to: backend(bridge, id: id, handoff: handoff), session: id.uuidString)
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch", "message"])
    #expect(sent[0].files.isEmpty && sent[0].text.contains(handoff.marker) && sent[0].text.contains("could not take the files") && sent[0].text.contains("They planned the launch for Friday."))
    #expect(sent[0].text.utf8.count <= HerdrClient.taskBytes && sent[1].text.hasSuffix("Hello again"))
}

@Test @MainActor func theTurnTakesNoSteerUntilTheHandoffHasEnded() async throws {
    let (handoff, id) = fixture()
    let bridge = HandoffBridge(); bridge.holds = { $0.contains("[SwarmHub handoff") }
    let made = backend(bridge, id: id, handoff: handoff)
    let stream = try await made.send(AgentRequest(sessionID: id.uuidString, systemPrompt: "", messages: [(role: "user", content: "Hello")]))
    #expect(try await made.features().isEmpty, "from the moment the turn starts")
    let reading = Task { for try await _ in stream {} }
    try await waitUntil { bridge.sent.count == 1 }
    #expect(try await made.features().isEmpty, "while the agent reads the conversation")
    bridge.release("It stood at question 120.")
    try await reading.value
    #expect(try await made.features() == ["run_steer"] && bridge.sent.map(\.route) == ["launch-with-files", "message"])
    // A bot without a handoff takes steers from the start, as it always did.
    let plain = backend(HandoffBridge(), id: id, handoff: nil)
    _ = try await plain.send(AgentRequest(sessionID: id.uuidString, systemPrompt: "", messages: [(role: "user", content: "Hello")]))
    #expect(try await plain.features() == ["run_steer"])
}

@Test func withoutAHandoffAndInAGroupTheMessageGoesAsItAlwaysDid() async throws {
    let (handoff, id) = fixture()
    // A bot that has none.
    let plain = HandoffBridge()
    _ = try await say("Hello", to: backend(plain, id: id, handoff: nil), session: id.uuidString)
    try #require(plain.sent.map(\.route) == ["launch"])
    #expect(plain.sent[0].text.contains(persona) && plain.sent[0].text.contains(appNote) && plain.sent[0].text.hasSuffix("Hello") && plain.sent[0].files.isEmpty)
    // The agent the bot has in a group gets nothing of it.
    let group = HandoffBridge()
    let session = GroupRouting.sessionID(group: UUID(), bot: id)
    _ = try await say("Hello", to: backend(group, id: id, handoff: handoff), session: session)
    try #require(group.sent.map(\.route) == ["launch"])
    #expect(group.sent[0].agent == HerdrBackend.groupRuntimeName(sessionID: session, botID: id) && !group.sent[0].text.contains(handoff.lead) && group.sent[0].text == plain.sent[0].text)
}

@Test @MainActor func aBotThatWasNotImportedOrHasItsSwitchOffSendsWhatItAlwaysDid() async throws {
    let id = UUID()
    let plainBridge = HandoffBridge(), offBridge = HandoffBridge()
    let (plainStore, plainBot) = try handoffStore(plainBridge, botID: id)
    let (offStore, offBot) = try handoffStore(offBridge, lines: handoffConversation(exchanges: 5), botID: id)
    #expect(try offStore.herdrBackend(for: offBot).handoff != nil, "an imported bot hands over unless the person turned that off")
    #expect(offStore.grokHandoffLine(for: offBot) == GrokHandoffCopy.pending("Ada"))
    offStore.setGrokHandsOver(false, for: offBot)
    #expect(try offStore.herdrBackend(for: offBot).handoff == nil)
    #expect(try plainStore.herdrBackend(for: plainBot).handoff == nil)
    #expect(offStore.grokHandoffLine(for: offBot) == GrokHandoffCopy.off("Ada") && !plainStore.grokHandoffApplies(to: plainBot))
    #expect(plainStore.send(text: "Hello there") && offStore.send(text: "Hello there"))
    try await waitUntil { plainStore.runningTurns.isEmpty && offStore.runningTurns.isEmpty }
    #expect(plainBridge.sent.map(\.route) == ["launch"] && offBridge.sent == plainBridge.sent, "the same requests, text for text")
    #expect(offBot.messages.last?.content == "ok" && offStore.grokHandoffRecord(for: offBot) == nil)
    // Forgetting a bot's handoff puts the switch back where it starts.
    offStore.forgetGrokHandoff(offBot.id)
    #expect(offStore.grokHandsOver(offBot))
}

@Test @MainActor func anImportedBotReadsItsHistoryBeforeItsFirstReplyAndTheChatSaysSoOnce() async throws {
    let bridge = HandoffBridge(); bridge.answers = answering
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 5))
    #expect(store.send(text: "Where were we?"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffRecord(for: bot) != nil }
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch-with-files", "message"])
    #expect(sent[0].text.contains(GrokHandoff.lead(for: bot.id)) && !sent[0].text.contains("Where were we?") && sent[0].files["grok-handoff.md"]?.contains("question 5 end") == true)
    #expect(sent[1].text.hasSuffix("Where were we?"))
    #expect(bot.messages.filter { $0.role != .system }.map(\.role) == [.user, .assistant] && bot.messages.last(where: { $0.role == .assistant })?.content == "the answer")
    let lines = bot.messages.filter { $0.role == .system }
    #expect(lines.map(\.content) == [GrokHandoffCopy.read("Ada")] && lines.allSatisfy { AppOnlyLine.isAppOnly($0) }, "one line for the person, never sent to the agent")
    let record = try #require(store.grokHandoffRecord(for: bot))
    #expect(record.older == 0 && record.recent == 10 && !record.summarised && record.marker.hasPrefix(GrokHandoff.lead(for: bot.id)))
    #expect(store.grokHandoffLine(for: bot).hasPrefix("Handed over to Ada · all 10 messages · "))
    // The next message finds the conversation read: nothing but the message, and no second line in the chat.
    #expect(store.send(text: "And then?"))
    try await waitUntil { store.runningTurns.isEmpty }
    #expect(bridge.sent.map(\.route) == ["launch-with-files", "message", "message"] && bot.messages.filter { $0.role == .system }.count == 1)
}
