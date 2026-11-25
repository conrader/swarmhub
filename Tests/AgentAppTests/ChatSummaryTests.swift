import Foundation
import Testing
@testable import AgentApp

@Test @MainActor func explicitChatSummaryIsSavedBeforeEndingAndDeliveredOnlyToTheNewSession() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    bridge.answers = { task in task.contains("preparing a handover") ? "Release on Friday." : "ok" }
    let (store, bot) = try handoffStore(bridge)
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    bridge.seed(agent: name)
    bot.messages = [ChatMessage(role: .user, content: "Use the Friday release slot."),
                    ChatMessage(role: .assistant, content: "Recorded the date.")]
    let ids = bot.messages.map(\.id)
    try await store.summarizeAndStartFresh(bot)
    #expect(bot.messages.map(\.id) == ids && !bridge.liveNames.contains(name))
    let cache = try #require(GrokHandoffCache.load(store.chatSummaryURL(bot.id)))
    #expect(cache.summary == "Release on Friday." && cache.messages == 2)
    #expect(bridge.sent.first?.files.values.first?.contains("Recorded the date.") == true)
    #expect(store.send(text: "What day?"))
    try await waitUntil { store.runningTurns.isEmpty && store.herdrCarryOver(for: bot) == nil }
    let fresh = try #require(bridge.sent.last(where: { $0.agent == name && $0.route == "launch-with-files" }))
    #expect(fresh.text.contains(cache.summary) && fresh.text.hasSuffix("What day?"))
    #expect(fresh.files["conversation-full.md"]?.contains("Use the Friday release slot.") == true)
    #expect(fresh.files["conversation-so-far.md"]?.contains("Use the Friday release slot.") == false)
    #expect(!FileManager.default.fileExists(atPath: store.chatSummaryURL(bot.id).path))
}

@Test @MainActor func newMessageWhileSummarizingKeepsOriginalSession() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    bridge.holds = { $0.contains("preparing a handover") }
    let (store, bot) = try handoffStore(bridge)
    bot.messages = [ChatMessage(role: .user, content: "Status?"), ChatMessage(role: .assistant, content: "Working.")]
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    bridge.seed(agent: name)
    let pending = Task { try await store.summarizeAndStartFresh(bot) }
    try await waitUntil { bridge.sent.contains { $0.agent.hasPrefix("handoff-") } }
    #expect(store.send(text: "A new question"))
    try await waitUntil { store.runningTurns.isEmpty && bot.messages.contains { $0.content == "ok" } }
    bridge.release("Summary of the previous exchange.")
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(bridge.liveNames.contains(name) && store.herdrCarryOver(for: bot) == nil)
    #expect(!bridge.sent.contains { $0.agent == name && $0.route == "end" })
}

@Test @MainActor func remoteTurnDuringSummaryKeepsOriginalSession() async throws {
    let bridge = HandoffBridge()
    bridge.agentState = "idle"
    bridge.holds = { $0.contains("preparing a handover") }
    let (store, bot) = try handoffStore(bridge)
    bot.messages = [ChatMessage(role: .assistant, content: "The first build passed.")]
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    bridge.seed(agent: name)
    let pending = Task { try await store.summarizeAndStartFresh(bot) }
    try await waitUntil { bridge.sent.contains { $0.agent.hasPrefix("handoff-") } }
    _ = try await bridge.client().deliver("Work from another client", name: name, template: nil, model: nil)
    bridge.release("First build passed.")
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(bridge.liveNames.contains(name) && !bridge.sent.contains { $0.agent == name && $0.route == "end" })
}
