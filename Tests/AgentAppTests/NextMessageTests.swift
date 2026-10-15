import Foundation
import Testing
@testable import AgentApp

// P32 item 9: a failed steer offers "Send as next message"; the text goes out as a normal message once the running
// turn (or group round) ends, at once when nothing runs. Scripted backend; no network.

@MainActor @Test func aFailedSteerIsSentAsTheNextMessageOnceTheTurnEnds() async throws {
    let backend = ScriptedTurnBackend(steerFails: true)
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "fix it"))
    try await waitUntil { bot.messages.contains { $0.metadata[SteerKey.steer] == "failed" } }
    let bubble = try #require(bot.messages.first { $0.metadata[SteerKey.steer] == "failed" })
    #expect(SteerCopy.caption(bubble) == "Steer not delivered")
    #expect(store.canSendAsNextMessage(bubble))

    // Still streaming: queued, nothing sent yet, the button is gone.
    #expect(store.sendAsNextMessage(bubble))
    #expect(bubble.metadata[SteerKey.steer] == "next" && !store.canSendAsNextMessage(bubble))
    #expect(SteerCopy.caption(bubble) == "Sends as the next message when the answer ends")
    #expect(await backend.calls.all.filter { $0.hasPrefix("send:") } == ["send:go"])

    await backend.emit(step(.completed), .token("Done."), .completed); await backend.end(stream: 1)
    try await backend.calls.wait { $0.contains("send:fix it") }
    #expect(bubble.metadata[SteerKey.steer] == "sentNext")
    #expect(SteerCopy.caption(bubble) == "Not delivered as a steer; sent as the next message")
    let users = bot.messages.filter { $0.role == .user }
    #expect(users.map(\.content) == ["go", "fix it", "fix it"])
    #expect(users.last?.isSteer == false, "the resend is a normal message")
    #expect(bot.messages.last?.role == .assistant && bot.messages.last?.isStreaming == true)
    await backend.emit(.token("Fixed."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.turns.nextMessages.isEmpty)
}

@MainActor @Test func pressedWhileIdleItSendsAtOnce() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    let bubble = ChatMessage(role: .user, content: "later", metadata: [SteerKey.steer: "failed"])
    bot.messages = [ChatMessage(role: .user, content: "go"), ChatMessage(role: .assistant, content: "ok"), bubble]
    #expect(store.sendAsNextMessage(bubble))
    try await backend.calls.wait { $0.contains("send:later") }
    #expect(bubble.metadata[SteerKey.steer] == "sentNext")
    await backend.end(); try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func onlyFailedSteersOfferIt() {
    let (store, bot) = steerStore(ScriptedTurnBackend())
    let delivered = ChatMessage(role: .user, content: "a", metadata: [SteerKey.steer: "delivered"])
    let plain = ChatMessage(role: .user, content: "b")
    let leftOver = ChatMessage(role: .user, content: "c", metadata: [SteerKey.steer: "next"])
    let stray = ChatMessage(role: .user, content: "d", metadata: [SteerKey.steer: "failed"])
    bot.messages = [delivered, plain, leftOver]
    #expect(!store.canSendAsNextMessage(delivered) && !store.canSendAsNextMessage(plain))
    #expect(store.canSendAsNextMessage(leftOver), "a queued text lost to a quit offers the button again")
    #expect(!store.canSendAsNextMessage(stray) && !store.sendAsNextMessage(stray), "not in any chat")
}

@MainActor @Test func aFailedGroupSteerIsSentToTheGroupAfterTheRound() async throws {
    let backend = ScriptedTurnBackend(steerFails: true)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let dmt = Bot(name: "DMT", backend: .hermes, hermesProfile: "default"), achilles = Bot(name: "Achilles", backend: .hermes, hermesProfile: "default")
    store.bots = [dmt, achilles]
    let group = try #require(store.createGroup(name: "Pair", memberIDs: [dmt.id, achilles.id]))
    #expect(store.send(text: "@DMT hello", to: group))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") } }
    await backend.emit(.token("Before. "))
    try await waitUntil { (store.soleTurn?.steerAvailable == true) && store.soleTurn?.assistant?.content == "Before. " }
    #expect(store.send(text: "@DMT shorter", to: group))
    try await waitUntil { group.messages.contains { $0.metadata[SteerKey.steer] == "failed" } }
    let bubble = try #require(group.messages.first { $0.metadata[SteerKey.steer] == "failed" })
    #expect(store.sendAsNextMessage(bubble) && bubble.metadata[SteerKey.steer] == "next")

    await backend.emit(.token("After."), .completed); await backend.end(stream: 1)
    try await waitUntil { await backend.streamCount == 2 }
    #expect(bubble.metadata[SteerKey.steer] == "sentNext")
    #expect(group.messages.filter { $0.role == .user && !$0.isSteer }.map(\.content) == ["@DMT hello", "@DMT shorter"])
    await backend.emit(.token("Shorter."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(group.messages.last { $0.role == .assistant }?.authorID == dmt.id)
}
