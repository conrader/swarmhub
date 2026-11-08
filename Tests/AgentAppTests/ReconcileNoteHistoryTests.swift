import Foundation
import Testing
@testable import AgentApp

// backlog7: the reconcile's "Hermes history was not merged…" note (and the restart's uncertain-queue warning) is an
// app-only `system` row. The legacy v1/chat/completions path sends every history row, so it must never be history.

@MainActor private func noteFixture() -> (AppStore, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Fixture-\(UUID().uuidString.prefix(8))", backend: .hermes, hermesProfile: "fixture-backlog7")
    store.bots = [bot]
    bot.messages = [ChatMessage(role: .user, content: "earlier"),
                    ChatMessage(role: .assistant, content: "ok", turnState: .finished),
                    ReconcileNote.line(ReconcileNote.diverged),
                    // Saved before the tag existed: matched by its text.
                    ChatMessage(role: .system, content: ReconcileNote.diverged),
                    ReconcileNote.line(ReconcileNote.uncertainQueuePrefix + "queued text"),
                    ChatMessage(role: .system, content: ReconcileNote.uncertainQueuePrefix + "older queued text"),
                    // backlog10: the other app-only rows, tagged and as saved before the tag.
                    AppOnlyLine.line(AppOnlyLine.created.render("Fixture Mgr", "Fixture Scout")),
                    ChatMessage(role: .system, content: OrientationCopy.gaveUp("Fixture Scout")),
                    ChatMessage(role: .system, content: AppOnlyLine.reviewing.render("Fixture Rev"), presentation: .review),
                    ChatMessage(role: .system, content: BotMessageCopy.arrival(from: "Fixture Sender", to: "Fixture Scout"), presentation: .botMessage),
                    ChatMessage(role: .user, content: "now")]
    return (store, bot)
}

@Test @MainActor func reconcileNotesAreNeverChatHistory() {
    let (store, bot) = noteFixture()
    let history = store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: ""))
    #expect(history.map(\.content) == ["earlier", "ok", "now"])
    #expect(!history.contains { $0.role == "system" })
    #expect(bot.messages.filter(ReconcileNote.isNote).count == 4, "still shown in the chat")
}

@Test @MainActor func reconcileNotesNeverReachTheLegacyCompletionsPayload() async throws {
    let (store, bot) = noteFixture()
    let history = store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: ""))
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8)) }
    for try await _ in try await backend.send(.init(sessionID: "backlog7-\(UUID().uuidString)", systemPrompt: "p", messages: history)) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/chat/completions" }?.body)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let wire = String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
    #expect(!wire.contains("not merged") && !wire.contains("Queued message delivery"))
    #expect(!wire.contains("Fixture"), "backlog10: no notice, orientation, review or bot card text")
    #expect(messages.filter { $0["role"] as? String == "system" }.count == 1, "only the persona")
    #expect(messages.count == 4)
}
