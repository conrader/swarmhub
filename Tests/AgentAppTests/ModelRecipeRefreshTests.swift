import Foundation
import Testing
@testable import AgentApp

// P32 item 12: once the manager's model recipe finishes (a step of the turn read swarmhub-model.log, or the reply has
// a swarmhub block), the bots on its connection are read again without skills. Synthetic server only.

@MainActor private func recipeStore(reply: String) -> (AppStore, Bot, Bot, String) {
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") { return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])]) }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        if path.hasSuffix("/v1/capabilities") { return .json(200, ["object": "hermes.capabilities"]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes },
                         keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k", "hermes.mira": "k"]), defaults: isolatedDefaults())
    store.skillLibraryOverride = []
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    let mira = Bot(name: "Mira", backend: .hermes, hermesProfile: "mira")
    store.bots = [jarvis, mira]; store.selectedBot = jarvis
    return (store, jarvis, mira, host)
}

private func reads(_ host: String) -> [String] {
    ChatParityServer.requests(host).map(\.path).filter { !$0.hasSuffix("/chat/stream") && $0 != "/api/sessions" && !$0.hasSuffix("/features") && !$0.contains("/health") }
}

private func capabilityReads(_ host: String) -> Int { reads(host).filter { $0.hasSuffix("/v1/capabilities") }.count }

private func steps(_ previews: String?...) -> [ToolStep] { previews.map { ToolStep(name: "terminal", preview: $0, startedAt: .now) } }

@Test func recipeIsFinishedWhenAStepReadTheLogOrTheReplyHasABlock() {
    #expect(AppStore.modelRecipeFinished(reply: "All set.", steps: steps("hermes profile list", "cat ~/.hermes/swarmhub-model.log")))
    #expect(AppStore.modelRecipeFinished(reply: "Done.\n```swarmhub\n{\"op\":\"model_set\"}\n```", steps: []))
    #expect(!AppStore.modelRecipeFinished(reply: "The model is grok-4.", steps: steps("hermes profile list", nil)))
}

@Test @MainActor func aReplyWithABlockRefreshesEveryBotOnTheConnection() async throws {
    let (store, jarvis, mira, host) = recipeStore(reply: "Changed.\n```swarmhub\n{\"op\":\"description\",\"bot\":\"mira\",\"description\":\"x\"}\n```")
    #expect(store.send(text: "set everyone to grok-4"))
    // The turn's own feature check reads capabilities once; the refresh adds one read per bot.
    try await waitUntil { !store.anyTurnRunning && capabilityReads(host) >= 3 }
    #expect(!reads(host).contains { $0.hasSuffix("/v1/skills") }, "skills are not read")
    let reply = try #require(jarvis.messages.last)
    #expect(store.refreshModelsAfterRecipe(reply, from: jarvis, in: jarvis).map(\.id) == [jarvis.id, mira.id])
}

@Test @MainActor func anOrdinaryReplyRefreshesNothing() async throws {
    let (store, _, _, host) = recipeStore(reply: "Hello.")
    #expect(store.send(text: "hi"))
    try await waitUntil { !store.anyTurnRunning }
    try await Task.sleep(for: .milliseconds(100))
    #expect(capabilityReads(host) == 1, "only the turn's own feature check: \(reads(host))")
}

@Test @MainActor func onlyTheManagersOwnChatAndItsConnectionCount() throws {
    let (store, jarvis, mira, _) = recipeStore(reply: "")
    let other = Bot(name: "Elsewhere", backend: .hermes, hermesProfile: "x"); other.hermesBaseURL = "https://other.example/v1"
    store.bots.append(other)
    let reply = ChatMessage(role: .assistant, content: "ok")
    var activity = ToolActivity(); activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "cat ~/.hermes/swarmhub-model.log"), at: .now); reply.activity = activity
    // A steer split the turn: the step is on the first part, the text on the second.
    let first = ChatMessage(role: .user, content: "set models"), steer = ChatMessage(role: .user, content: "and Mira", metadata: [SteerKey.steer: "delivered"])
    let tail = ChatMessage(role: .assistant, content: "Done.")
    jarvis.messages = [first, reply, steer, tail]
    #expect(store.refreshModelsAfterRecipe(tail, from: jarvis, in: jarvis).map(\.name) == ["Jarvis", "Mira"])
    mira.messages = [first, reply]
    #expect(store.refreshModelsAfterRecipe(reply, from: mira, in: mira).isEmpty, "not a manager")
    let thread = ChatThread(parentMessageID: reply.id, parentSessionID: nil, hermesSessionID: nil, messages: [first, reply]); jarvis.threads = [thread]
    #expect(store.refreshModelsAfterRecipe(reply, from: jarvis, in: thread).isEmpty, "a thread is not the manager's chat")
}
