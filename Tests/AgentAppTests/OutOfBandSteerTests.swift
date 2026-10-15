import Foundation
import Testing
@testable import AgentApp

// P44 1: Hermes's run_steer wrapper on a history row. The live text is Reactor's row 417 (2026-10-15).

private let steerText = "Jak bedzie trzeba to utworzmy dostep mcp do ksiegowania wplat"
private let liveRow = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history] \(steerText) [/OUT-OF-BAND USER MESSAGE]"

@Test func theLiveRowParsesToTheInnerTextMarkedOutOfBand() throws {
    let row = try #require(HermesBackend.parseMessage(["id": 417, "role": "user", "content": liveRow, "timestamp": 1_792_095_786.0]))
    #expect(row.content == steerText && row.outOfBand)
    let multiline = BackendMessage(role: "user", content: "[OUT-OF-BAND USER MESSAGE]\nline one\nline two\n[/OUT-OF-BAND USER MESSAGE]\n")
    #expect(multiline.content == "line one\nline two" && multiline.outOfBand)
    let plain = BackendMessage(role: "user", content: "a normal question")
    #expect(plain.content == "a normal question" && !plain.outOfBand)
}

@Test func aWrapperQuotedInAnAssistantReplyIsLeftAlone() throws {
    let quoted = "Hermes wraps steers like this:\n```\n\(liveRow)\n```"
    let assistant = try #require(HermesBackend.parseMessage(["role": "assistant", "content": quoted]))
    #expect(assistant.content == quoted && !assistant.outOfBand)
    let bare = try #require(HermesBackend.parseMessage(["role": "assistant", "content": liveRow]))
    #expect(bare.content == liveRow, "only user rows are steers")
    // A user row that merely mentions the wrapper inside other text is not one whole wrapper.
    let mention = "What does `\(liveRow)` mean?"
    #expect(BackendMessage(role: "user", content: mention).content == mention)
}

@MainActor @Test func reconcileAddsTheSteerAsTheUsersMessageWithItsLabel() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Reactor"])
    let bot = bots[0]; bot.hermesSessionID = "s-reactor"
    let start = Date().addingTimeInterval(-60)
    states[0].add("s-reactor", "user", "Zaksieguj wplaty z wrzesnia", time: start.timeIntervalSince1970)
    states[0].add("s-reactor", "assistant", "Ksieguje, to chwile potrwa.", finish: "stop", time: start.addingTimeInterval(5).timeIntervalSince1970)
    states[0].add("s-reactor", "user", liveRow, time: start.addingTimeInterval(20).timeIntervalSince1970)
    states[0].add("s-reactor", "assistant", "Dobrze, w razie potrzeby utworze dostep.", finish: "stop", time: start.addingTimeInterval(30).timeIntervalSince1970)
    bot.messages = [ChatMessage(role: .user, content: "Zaksieguj wplaty z wrzesnia", createdAt: start),
                    ChatMessage(role: .assistant, content: "Ksieguje, to chwile potrwa.", createdAt: start.addingTimeInterval(5), turnState: .finished)]
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages.map(\.content) == ["Zaksieguj wplaty z wrzesnia", "Ksieguje, to chwile potrwa.", steerText, "Dobrze, w razie potrzeby utworze dostep."])
    let steer = bot.messages[2]
    #expect(steer.role == .user && SteerCopy.caption(steer, botName: bot.name) == "Sent while Reactor was working")
    #expect(!bot.messages.contains { $0.content.contains("OUT-OF-BAND") })
    // A second pass changes nothing (the steer row pairs as the user's own text).
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages.count == 4)
}

@MainActor @Test func aLocalSteerBubbleForTheSameTextIsKeptAlone() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Reactor"])
    let bot = bots[0]; bot.hermesSessionID = "s-reactor"
    let start = Date().addingTimeInterval(-60)
    states[0].add("s-reactor", "user", "Zaksieguj wplaty", time: start.timeIntervalSince1970)
    states[0].add("s-reactor", "assistant", "Pierwsza czesc.", finish: "tool_calls", time: start.addingTimeInterval(5).timeIntervalSince1970)
    states[0].add("s-reactor", "user", liveRow, time: start.addingTimeInterval(20).timeIntervalSince1970)
    states[0].add("s-reactor", "assistant", "Druga czesc.", finish: "stop", time: start.addingTimeInterval(30).timeIntervalSince1970)
    bot.messages = [ChatMessage(role: .user, content: "Zaksieguj wplaty", createdAt: start),
                    ChatMessage(role: .assistant, content: "Pierwsza czesc.", createdAt: start.addingTimeInterval(5), metadata: [TurnKey.part: "1"], turnState: .finished),
                    ChatMessage(role: .user, content: steerText, createdAt: start.addingTimeInterval(19), metadata: [SteerKey.steer: "delivered"]),
                    ChatMessage(role: .assistant, content: "Druga czesc.", createdAt: start.addingTimeInterval(30), metadata: [TurnKey.part: "2"], turnState: .finished)]
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages.filter { $0.content == steerText }.count == 1)
    #expect(bot.messages.count == 4 && bot.unreadCount == 0)

    // Without the part split (the reply went on in one bubble) the box's steer turn is still not added.
    bot.messages = [bot.messages[0], ChatMessage(role: .assistant, content: "Pierwsza czesc.\n\nDruga czesc.", createdAt: start.addingTimeInterval(5), turnState: .finished),
                    ChatMessage(role: .user, content: steerText, createdAt: start.addingTimeInterval(19), metadata: [SteerKey.steer: "delivered"])]
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages.filter { $0.content == steerText }.count == 1 && bot.messages.count == 3)
}

@MainActor @Test func aStoredWrappedRowIsCleanInPreviewAndCopy() throws {
    let stored = ChatMessage(role: .user, content: liveRow, metadata: [TurnKey.restored: "added"])
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(stored))
    #expect(decoded.content == steerText && decoded.metadata[SteerKey.outOfBand] == "1")
    #expect(SteerCopy.caption(decoded, botName: "Reactor") == "Sent while Reactor was working")
    let preview = SidebarFragment.text(messages: [decoded], draft: nil, isWorking: false, archiveNewest: nil)
    #expect(preview == "You: " + steerText)
    // Merged history (the older path) is clean too.
    let merged = AppStore.mergeHermesHistory(local: [], server: [BackendMessage(role: "user", content: liveRow)])
    #expect(merged?.first?.content == steerText && merged?.first?.metadata[SteerKey.outOfBand] == "1")
    // An assistant row that quotes the wrapper keeps it (it is the bot's own text).
    let quoted = ChatMessage(role: .assistant, content: "```\n\(liveRow)\n```")
    #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(quoted)).content == quoted.content)
}
