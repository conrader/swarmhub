import Foundation
import Testing
@testable import AgentApp

// What keeps the handoff from getting in the person's way: a long session is not handed the conversation twice, a
// handoff that fails lets the message through and stops trying, a summary that failed waits a day, and a message
// sent while the conversation is handed over waits its turn.

@MainActor private func systemLines(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }

@Test @MainActor func aLongSessionIsNotHandedTheConversationAgain() async throws {
    // Like the real server, this one shows only a session's newest 30 rows, so the marker soon leaves them.
    let bridge = HandoffBridge(); bridge.pageSize = 30
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 5))
    let lead = GrokHandoff.lead(for: bot.id), url = store.grokHistory.handoffStateURL(for: bot.id)
    #expect(store.send(text: "Message 0"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffState(for: bot.id).read != nil }
    let launch = try #require(store.grokHandoffState(for: bot.id).read)
    #expect(launch.address == "t1" && launch.createdMs == 1 && launch.core == "c" && launch.server == HerdrServer.defaultID)
    #expect(GrokHandoffState.load(url).read == launch, "kept beside the archive")
    let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o600)
    // Without what the Mac remembers, the session's rows still say that it was read, and it is remembered again.
    try FileManager.default.removeItem(at: url)
    store.grokHandoffs.states[bot.id] = nil
    #expect(store.send(text: "Message 1"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffState(for: bot.id).read == launch }
    #expect(bridge.sent.map(\.route) == ["launch-with-files", "message"])
    for index in 2...40 {
        #expect(store.send(text: "Message \(index)"))
        try await waitUntil { store.runningTurns.isEmpty }
    }
    let sent = bridge.sent
    #expect(sent.filter { $0.route == "launch-with-files" }.count == 1 && !sent.contains(where: { $0.route == "message-with-files" }), "one handoff in 41 exchanges")
    #expect(sent.filter { $0.route == "message" }.count == 40 && sent.filter { $0.text.contains(lead) }.count == 1)
    #expect(systemLines(bot) == [GrokHandoffCopy.read("Ada")] && bot.messages.last(where: { $0.role == .assistant })?.content == "ok")
    // What the Mac remembers goes with the archive.
    store.grokHistory.remove(bot.id)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func aHandoffThatFailsLetsTheMessageThroughAndIsTriedOnlyOnceMore() async throws {
    let bridge = HandoffBridge(); bridge.refusesFiles = true
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 5))
    let lead = GrokHandoff.lead(for: bot.id)
    let why = "The server said: This bot needs a workspace folder for attachments."
    func failures() -> Int { store.grokHandoffState(for: bot.id).failures?.count ?? 0 }
    // The first message: the handoff is refused, the message goes as it always did, and the chat says so once.
    #expect(store.send(text: "First"))
    try await waitUntil { store.runningTurns.isEmpty && failures() == 1 }
    #expect(bridge.refused == ["launch-with-files"] && bridge.sent.map(\.route) == ["launch"])
    #expect(bridge.sent[0].text.hasSuffix("First") && !bridge.sent[0].text.contains(lead) && bridge.sent[0].files.isEmpty)
    #expect(bot.messages.last(where: { $0.role == .assistant })?.content == "ok", "the reply arrives")
    #expect(systemLines(bot) == [GrokHandoffCopy.failed("Ada", why: why, again: true)])
    #expect(store.grokHandoffLine(for: bot) == GrokHandoffCopy.notHandedOver("Ada", why: why, again: true) && store.grokHandoffLine(for: bot).hasPrefix("Not handed over"))
    #expect(store.grokOffersRetry(for: bot) && store.grokHandoffRecord(for: bot) == nil && store.grokHandoffState(for: bot.id).read == nil)
    // The second: tried once more, for the agent that is running now.
    #expect(store.send(text: "Second"))
    try await waitUntil { store.runningTurns.isEmpty && failures() == 2 }
    #expect(bridge.refused == ["launch-with-files", "message-with-files"] && bridge.sent.map(\.route) == ["launch", "message"])
    #expect(systemLines(bot) == [GrokHandoffCopy.failed("Ada", why: why, again: true), GrokHandoffCopy.failed("Ada", why: why, again: false)])
    #expect(store.grokHandoffLine(for: bot) == GrokHandoffCopy.notHandedOver("Ada", why: why, again: false))
    // The third: no handoff request at all.
    #expect(store.send(text: "Third"))
    try await waitUntil { store.runningTurns.isEmpty && bridge.sent.count == 3 }
    #expect(bridge.refused.count == 2 && bridge.sent.map(\.route) == ["launch", "message", "message"] && systemLines(bot).count == 2)
    #expect(bridge.sent[2].text.hasSuffix("Third") && bot.messages.last(where: { $0.role == .assistant })?.content == "ok")
    // The person asks again from the header, and the server now takes files.
    bridge.refusesFiles = false
    store.retryGrokHandoff(for: bot)
    #expect(!store.grokOffersRetry(for: bot) && store.grokHandoffLine(for: bot) == GrokHandoffCopy.pending("Ada"))
    #expect(store.send(text: "Fourth"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffRecord(for: bot) != nil }
    #expect(bridge.sent.map(\.route) == ["launch", "message", "message", "message-with-files"] && bridge.sent[3].text.contains(lead))
    #expect(store.grokHandoffState(for: bot.id).failures == nil && store.grokHandoffLine(for: bot).hasPrefix("Handed over to Ada"))
    #expect(systemLines(bot).count == 3 && systemLines(bot).contains(GrokHandoffCopy.read("Ada")))
}

@Test func onlyWhatWouldStopTheMessageTooIsLeftToIt() {
    #expect(HerdrHandoff.reason(CancellationError()) == nil && HerdrHandoff.reason(URLError(.cancelled)) == nil)
    #expect(HerdrHandoff.reason(URLError(.notConnectedToInternet)) == nil && HerdrHandoff.reason(HerdrClient.Failure.unauthorized) == nil)
    #expect(HerdrHandoff.reason(HerdrClient.Failure.silent) == "Its agent finished without a reply.")
    #expect(HerdrHandoff.reason(HerdrClient.Failure.ended) == "Its agent stopped while reading it.")
    #expect(HerdrHandoff.reason(HerdrClient.Failure.waitingAtPrompt) == HerdrHandoff.reason(HerdrClient.Failure.notDelivered(nil)))
    #expect(HerdrHandoff.reason(HerdrClient.SummaryTimeout()) == "Reading it took too long." && HerdrHandoff.reason(URLError(.timedOut)) != nil)
    #expect(HerdrHandoff.reason(HerdrClient.Failure.http(413, "Too large.")) == "The server said: Too large.")
    #expect(HerdrHandoff.reason(BackendError.unavailable("This server cannot receive attachments.")) == "This server cannot receive attachments.")
    // "New conversation" does not promise an empty start to a bot that is handed its history again.
    #expect(GrokHandoffCopy.newConversation("Ada", readsHistory: true).contains("includes its Grok history") && !GrokHandoffCopy.newConversation("Ada", readsHistory: true).contains("empty context"))
    #expect(GrokHandoffCopy.newConversation("Ada", readsHistory: false) == "Start Ada with empty context. Earlier messages stay visible here.")
}

@Test @MainActor func aSummaryThatFailedIsNotTriedAgainForADayUnlessAsked() async throws {
    let bridge = HandoffBridge()
    bridge.refusesLaunch = { $0.hasPrefix("handoff-") }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 120, bytes: 400))
    let compactor = HerdrClient.compactorName(for: bot.id)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    store.now = { start }
    func talk(_ text: String) async throws {
        #expect(store.send(text: text))
        try await waitUntil { store.runningTurns.isEmpty }
    }
    func handoffs() -> Int { bridge.sent.filter { $0.route == "launch-with-files" }.count }
    try await talk("One")
    #expect(bridge.refused == [compactor] && handoffs() == 1)
    #expect(store.grokHandoffState(for: bot.id).summaryHold == GrokHandoffState.SummaryHold(revision: "240-240", at: start, tooLong: false))
    // An hour later the bot starts a new agent: the handoff goes at once, and no summary is started.
    store.now = { start.addingTimeInterval(3_600) }
    #expect(try await store.restartHerdrAgent(for: bot))
    try await talk("Two")
    #expect(bridge.refused == [compactor] && handoffs() == 2, "handed over again, without a second try at the summary")
    let second = bridge.sent.last(where: { $0.route == "launch-with-files" })
    #expect(second?.files["grok-handoff.md"]?.contains("The older part is not summarised here") == true)
    // More than a day later it is tried once more.
    store.now = { start.addingTimeInterval(25 * 3_600) }
    #expect(try await store.restartHerdrAgent(for: bot))
    try await talk("Three")
    #expect(bridge.refused == [compactor, compactor] && handoffs() == 3)
    #expect(store.grokHandoffState(for: bot.id).summaryHold?.at == start.addingTimeInterval(25 * 3_600))
    // New lines lift the hold, and so does the person's request.
    #expect(!store.grokHandoffState(for: bot.id).holdsSummary(of: "242-242", now: start.addingTimeInterval(25 * 3_600)))
    #expect(store.grokHandoffState(for: bot.id).holdsSummary(of: "240-240", now: start.addingTimeInterval(26 * 3_600)) && store.grokOffersSummary(for: bot))
    bridge.refusesLaunch = { _ in false }
    let asked = await store.retryGrokSummary(for: bot)
    let made = await asked?.value
    #expect(made?.summary == "ok" && store.grokHandoffState(for: bot.id).summaryHold == nil && !store.grokOffersSummary(for: bot))
    #expect(GrokHandoffCache.load(store.grokHistory.handoffURL(for: bot.id)) == made)
}

@Test @MainActor func aVeryLongOlderPartIsOnlySummarisedWhenThePersonAsks() async throws {
    let bridge = HandoffBridge()
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 300, bytes: 2_000))
    let agent = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let found = await store.grokHandoffDraft(for: bot)
    let draft = try #require(found)
    #expect(draft.plan.needsSummary && draft.parts > GrokHandoff.unaskedParts && draft.parts <= GrokHandoff.mostParts, "\(draft.parts) files")
    #expect(store.send(text: "Hello"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffRecord(for: bot) != nil }
    #expect(bridge.sent.map(\.route) == ["launch-with-files"] && bridge.sent.allSatisfy { $0.agent == agent }, "no summary agent was started")
    #expect(store.grokHandoffState(for: bot.id).summaryHold?.tooLong == true && store.grokOffersSummary(for: bot))
    #expect(store.grokHandoffLine(for: bot).contains("without a summary") && store.grokHandoffLine(for: bot).contains(GrokHandoffCopy.tooLong))
    // Asked for, it is made in messages of four files.
    let asked = await store.retryGrokSummary(for: bot)
    let made = await asked?.value
    let rounds = bridge.sent.filter { $0.agent != agent && $0.route != "end" }
    #expect(made?.summary == "ok" && rounds.count == (draft.parts + 3) / 4 && rounds.allSatisfy { $0.files.count <= 4 && $0.text.utf8.count <= 12 * 1024 })
    #expect(rounds.map(\.files.count).reduce(0, +) == draft.parts && bridge.sent.last?.route == "end" && bridge.liveNames == [agent])
    #expect(store.grokHandoffState(for: bot.id).summaryHold == nil)
}

@Test @MainActor func turningTheSwitchOffStopsASummaryThatIsBeingMade() async throws {
    let bridge = HandoffBridge()
    bridge.holds = { $0.contains("You are preparing a handover") }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 120, bytes: 400))
    let started = await store.prepareGrokSummary(for: bot.id)
    let making = try #require(started)
    try await waitUntil { bridge.sent.count == 1 }
    #expect(store.grokHandoffLine(for: bot) == GrokHandoffCopy.preparing(152))
    store.setGrokHandsOver(false, for: bot)
    let made = await making.value
    #expect(made == nil)
    try await waitUntil { store.grokHandoffs.summaries.isEmpty }
    #expect(bridge.sent.map(\.route) == ["launch-with-files", "end"] && bridge.liveNames.isEmpty, "its agent is ended")
    #expect(store.grokHandoffState(for: bot.id).summaryHold == nil, "a summary that was stopped is not one that failed")
    // And none is started while the switch is off.
    let again = await store.prepareGrokSummary(for: bot.id)
    #expect(again == nil && bridge.sent.count == 2)
}

@Test @MainActor func aMessageDuringHandoffRemainsRecoverable() async throws {
    let bridge = HandoffBridge()
    bridge.holds = { $0.contains("[SwarmHub handoff") }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 5))
    #expect(store.herdrSteers(bot), "this bot takes steers")
    #expect(store.send(text: "First"))
    try await waitUntil { bridge.sent.count == 1 }
    #expect(bridge.sent[0].route == "launch-with-files" && !store.canSteer(in: bot), "the turn the chat does not show takes no steer")
    #expect(store.send(text: "Second"))
    let row = try #require(bot.messages.first { $0.content == "Second" })
    #expect(row.metadata[TurnWaitCopy.key] == "waiting" && store.hasWaitingTurn(in: bot))
    #expect(bridge.sent.count == 1)
    bridge.release("It stood at question 5.")
    try await waitUntil { store.runningTurns.isEmpty }
    #expect(bridge.sent.map(\.route) == ["launch-with-files", "message"])
    #expect(bridge.sent[0].text.hasSuffix("First") && bridge.sent[1].text.hasSuffix("Second") && store.turns.nextMessages.isEmpty)
}

@Test @MainActor func importedHistoryDoesNotOccupyTheCodexTurnOrQueueItsSteers() async throws {
    let bridge = HandoffBridge()
    bridge.codexSteer = true
    bridge.holds = { $0.hasSuffix("First question") }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 5))
    #expect(store.send(text: "First question"))
    try await waitUntil { store.canSteer(in: bot) }
    #expect(bridge.sent.map(\.route) == ["launch-with-files"])
    #expect(store.send(text: "One more detail"))
    try await waitUntil { bot.messages.contains { $0.content == "One more detail" && $0.metadata[SteerKey.steer] == "delivered" } }
    #expect(bridge.sent.map(\.route) == ["launch-with-files", "steer"])
    #expect(!store.hasWaitingTurn(in: bot))
    bridge.release("Answer with the detail.")
    try await waitUntil { store.runningTurns.isEmpty }
}
