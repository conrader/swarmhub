import Foundation
import Testing
@testable import AgentApp

// P16 Part 3: Retry reads the box first and sends at most once. SessionServer only, synthetic text.

/// A bot chat holding one unsent turn: a user row and its empty `notSent` reply row.
@MainActor private func unsentChat(_ text: String = "please answer", boxSession: Bool = true) -> (AppStore, Bot, SessionServer.State, ChatMessage) {
    let (store, bots, states) = reconcileStore(bots: ["Alpha"])
    let bot = bots[0]; store.selectedBot = bot
    if boxSession { bot.hermesSessionID = "s-alpha"; states[0].with { $0.sessions["s-alpha"] = [] } }
    let row = ChatMessage(role: .assistant, content: "", metadata: ["why": "offline"], turnState: .notSent)
    bot.messages = [ChatMessage(role: .user, content: text), row]
    return (store, bot, states[0], row)
}

@MainActor @Test func theBoxHasTheTurnSoNothingIsSent() async throws {
    let (store, bot, box, row) = unsentChat()
    box.add("s-alpha", "user", "please answer"); box.add("s-alpha", "assistant", "the box answered", finish: "stop")
    store.retry(row)
    #expect(store.isStreaming && row.metadata["check"] == "checking", "the slot is claimed before the first await")
    try await waitUntil { store.isIdle }
    #expect(box.chatPosts.isEmpty && row.content == "the box answered" && row.turnState == .finished)
    #expect(bot.messages.filter { $0.role == .user }.count == 1)
}

@MainActor @Test func theBoxHasTheUserTurnStillRunningSoNothingIsSent() async throws {
    let (store, _, box, row) = unsentChat()
    box.add("s-alpha", "user", "please answer")
    store.retry(row)
    try await waitUntil { store.isIdle }
    #expect(box.chatPosts.isEmpty && row.turnState == .incomplete)
}

@MainActor @Test func aFailedOrShortReadSendsNothingAndSaysSo() async throws {
    let (store, bot, box, row) = unsentChat()
    box.with { $0.networkDown = true }
    store.retry(row)
    try await waitUntil { store.isIdle }
    #expect(box.chatPosts.isEmpty && row.turnState == .notSent && bot.messages.last?.content == "Alpha: Can't reach the box; nothing was sent.")
    // The read does not reach back past the row.
    let (short, shortBot, shortBox, old) = unsentChat()
    short.reconcileTiming.window = 2; short.reconcileTiming.maxWindows = 1
    old.metadata = [:]; shortBot.messages[0] = ChatMessage(role: .user, content: "please answer", createdAt: Date().addingTimeInterval(-3_600))
    let oldRow = ChatMessage(role: .assistant, content: "", createdAt: Date().addingTimeInterval(-3_600), turnState: .notSent); shortBot.messages[1] = oldRow
    for index in 0..<4 { shortBox.add("s-alpha", "user", "later \(index)"); shortBox.add("s-alpha", "assistant", "reply \(index)", finish: "stop") }
    shortBot.messages += (0..<4).flatMap { [ChatMessage(role: .user, content: "later \($0)"), ChatMessage(role: .assistant, content: "reply \($0)", turnState: .finished)] }
    short.retry(oldRow)
    try await waitUntil { short.isIdle }
    #expect(shortBox.chatPosts.isEmpty && oldRow.turnState == .notSent && shortBot.messages.contains { $0.content.hasSuffix("Can't reach the box; nothing was sent.") })
}

@MainActor @Test func whenTheBoxLacksTheTurnExactlyOnePostGoesIntoTheSameRow() async throws {
    let (store, bot, box, row) = unsentChat()
    box.with { $0.scripts = [.reply(chunks: ["sent ", "now"])] }
    store.retry(row); store.retry(row)
    #expect(store.send(text: "typed meanwhile") == false, "a Send during the read sees a turn in progress")
    try await waitUntil { store.isIdle && row.turnState == .finished }
    #expect(box.chatPosts.count == 1 && row.content == "sent now")
    #expect(SessionServer.inputText(box.chatPosts[0].body?["input"]) == "please answer", "the original row's text")
    #expect(bot.messages.filter { $0.role == .user }.count == 1 && bot.messages.filter { $0.role == .assistant }.count == 1)
}

@MainActor @Test func aChatWithoutASessionCountsAsTheBoxLackingTheTurn() async throws {
    let (store, bot, box, row) = unsentChat(boxSession: false)
    store.retry(row)
    try await waitUntil { store.isIdle && row.turnState == .finished }
    #expect(box.chatPosts.count == 1 && bot.hermesSessionID != nil)
}

@MainActor @Test func aStopDuringTheReadSendsNothing() async throws {
    let (store, _, box, row) = unsentChat()
    store.retry(row); store.stop()
    try await waitUntil { store.isIdle && !store.isStreaming }
    #expect(box.chatPosts.isEmpty && row.turnState == .notSent)
}

@MainActor @Test func retrySendsTheOriginalImages() async throws {
    let (store, bot, box, row) = unsentChat()
    let image = try #require(store.prepareAttachment(imageData: syntheticImage(width: 8, height: 8, alpha: false), name: "dot.png"))
    bot.messages[0] = ChatMessage(role: .user, content: "see", attachments: [image])
    store.retry(row)
    try await waitUntil { store.isIdle }
    let parts = try #require(box.chatPosts.first?.body?["input"] as? [[String: Any]])
    #expect(parts.contains { $0["type"] as? String == "image_url" } && parts.contains { $0["text"] as? String == "see" })
}

@MainActor @Test func aNewerUnmatchedBoxTurnBlocksTheOneTapSend() async throws {
    let (store, bot, box, row) = unsentChat()
    box.add("s-alpha", "user", "typed on another device"); box.add("s-alpha", "assistant", "answered there", finish: "stop")
    store.retry(row)
    try await waitUntil { store.isIdle }
    #expect(box.chatPosts.isEmpty && row.metadata["retry"] == "blocked")
    #expect(bot.messages.contains { $0.content == "Alpha: Can't match the box's newest message; nothing was sent." })
    store.retry(row, sendAnyway: true)
    try await waitUntil { store.isIdle && box.chatPosts.count == 1 }
}

@MainActor @Test func anAmbiguousRowNeedsASecondTap() async throws {
    let (store, _, box, row) = unsentChat()
    row.metadata["ambiguous"] = "1"
    store.retry(row)
    #expect(!store.isStreaming && row.metadata["retry"] == "confirm" && box.log.all.isEmpty, "the first tap only asks")
    store.retry(row)
    try await waitUntil { store.isIdle && box.chatPosts.count == 1 }
}

@MainActor @Test func retryIsOfferedOnlyWhereItCanWork() async throws {
    let (store, bots, _) = reconcileStore(bots: ["Alpha", "Beta"])
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    let older = ChatMessage(role: .assistant, content: "", authorID: bots[0].id, turnState: .notSent)
    let later = ChatMessage(role: .assistant, content: "answered later", authorID: bots[0].id, turnState: .finished)
    let beta = ChatMessage(role: .assistant, content: "", authorID: bots[1].id, turnState: .notSent)
    group.messages = [ChatMessage(role: .user, content: "a"), older, beta, ChatMessage(role: .user, content: "b"), later]
    #expect(!store.canRetry(older), "the member answered a later turn")
    #expect(store.canRetry(beta))
    store.removeMember(bots[1].id, from: group)
    #expect(!store.canRetry(beta), "not a current member")
    // A legacy-transport bot gets no one-tap Retry.
    let legacy = Bot(name: "Old", backend: .hermes); store.bots.append(legacy)
    let row = ChatMessage(role: .assistant, content: "", turnState: .notSent)
    legacy.messages = [ChatMessage(role: .user, content: "x"), row]
    store.botFeatures[legacy.id] = ["jobs"]
    #expect(!store.canRetry(row))
}

@MainActor @Test func aCutStreamAndARelaunchOnlyRead() async throws {
    let url = temporaryStore()
    let (store, bots, states) = reconcileStore(bots: ["Alpha"], url: url)
    let bot = bots[0]; bot.hermesSessionID = "s-alpha"; states[0].with { $0.sessions["s-alpha"] = [] }
    states[0].with { $0.scripts = [.eof(chunks: ["half"])] }
    store.selectedBot = bot
    #expect(store.send(text: "go"))
    try await waitUntil { store.isIdle }
    #expect(bot.messages.first { $0.role == .assistant }?.turnState != nil)
    store.save()
    let posts = states[0].posts.count
    let relaunched = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: store.keyStore, defaults: isolatedDefaults(), hermesSession: store.hermesSession)
    relaunched.reconcileTiming = .fast; relaunched.routines.autoLoad = true
    relaunched.startLaunchWork(makeConnectivity: { ManualConnectivity() })
    try await waitUntil { states[0].log.all.filter { $0.method == "GET" && $0.path.hasSuffix("/messages") }.count >= 2 }
    #expect(states[0].posts.count == posts, "only GETs after a cut stream and a relaunch")
}
