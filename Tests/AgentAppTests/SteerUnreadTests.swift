import Foundation
import Testing
@testable import AgentApp

// uxfix1-e2e: a steer is never lost. Hermes reads a steer only with a tool step's result, else hands it back; one the
// box accepted but never read (a text-only answer that ended first; live run 27 Oct) goes as the next message. And a
// proxy that cannot be reached (CFNetwork 310) is network trouble: retried, never the alert.

@MainActor @Test func aSteerTheBoxAcceptedButNeverReadIsSentAsTheNextMessage() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "use metric"))
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    // The answer ends with no tool step after the steer and no pending_steer: the model never saw it.
    await backend.emit(.steer(.accepted), .token("Done."), .completed); await backend.end()
    let followUp = "send:\(SteerCopy.lead)\nuse metric"
    try await backend.calls.wait { $0.contains(followUp) }
    await backend.emit(.token("Metric it is."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(await backend.calls.all == ["send:go", "steer:use metric", followUp], "sent once more, as the next message; never stopped")
    #expect(bot.messages[1].content == "Before. Done." && bot.messages[1].turnState == .finished)
    #expect(bot.messages.last?.content == "Metric it is.")
}

@MainActor @Test func aSteerReadWithAToolStepIsNotSentAgain() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: true)
    #expect(store.send(text: "use metric"))
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    await backend.emit(.steer(.accepted), step(.completed), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await backend.calls.all == ["send:go", "steer:use metric"], "it may have been read with the step's result: not sent twice")
}

@MainActor @Test func anUnreachableProxyIsNetworkTroubleThatNeverReachedTheBox() {
    let proxy = NSError(domain: "kCFErrorDomainCFNetwork", code: 310)
    #expect(TransientNetwork.isTransient(proxy) && AppStore.isTransient(proxy), "retried as unsent, never the alert")
    #expect(TransientNetwork.isTransient(text: "The install turn failed: The operation couldn’t be completed. (kCFErrorDomainCFNetwork error 310.)"))
    #expect(TransientNetwork.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: 302)) && !AppStore.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: 302)),
            "a lost connection may have reached the box: no blind resend")
    #expect(!TransientNetwork.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: 301)), "bad credentials are not network trouble")
}

@MainActor @Test func afterTheUsersStopAnUnreadSteerIsOfferedNotSent() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "use metric"))
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    store.stop(); try await waitUntil { !store.anyTurnRunning }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!(await backend.calls.all.contains { $0.hasPrefix("send:\(SteerCopy.lead)") }), "Stop means stop: nothing goes by itself")
    let bubble = try #require(bot.messages.first { $0.content == "use metric" })
    #expect(store.canSendAsNextMessage(bubble), "Send as next message is offered")
}

@MainActor @Test func aSteerAnsweredOnlyAfterItsTurnEndedIsSentAsTheNextMessage() async throws {
    let backend = ScriptedTurnBackend()
    await backend.holdSteers()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    #expect(store.send(text: "use metric"))
    try await backend.calls.wait { $0.contains("steer-held:use metric") }
    await backend.emit(.token("Done."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.first { $0.content == "use metric" }?.metadata["steer"] == "sent", "still on its way when the answer ended")
    await backend.releaseSteers()
    try await backend.calls.wait { $0.contains("send:use metric") }
    await backend.emit(.token("Metric."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(await backend.calls.all == ["send:go", "steer-held:use metric", "steer:use metric", "send:use metric"], "accepted too late to be read: sent once, as the next message")
    #expect(bot.messages.last?.content == "Metric.")
}

@MainActor @Test func everyCFNetworkDropIsNetworkTroubleNeverTheAlert() {
    for code in [1, 2, 302, 306, 308, 310, 311, -1005, -1009, -1001] {
        let error = NSError(domain: "kCFErrorDomainCFNetwork", code: code)
        #expect(TransientNetwork.isTransient(error), "CFNetwork \(code)")
        #expect(TransientNetwork.isTransient(text: "The operation couldn’t be completed. (kCFErrorDomainCFNetwork error \(code).)"), "text \(code)")
    }
    #expect(AppStore.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: -1009)) && AppStore.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: 1)),
            "never reached the box: resent by itself")
    #expect(!AppStore.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: -1005)), "a lost connection may have reached the box")
    #expect(!TransientNetwork.isTransient(NSError(domain: "kCFErrorDomainCFNetwork", code: 303)), "a parse failure is not network trouble")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    store.errorMessage = "The operation couldn’t be completed. (kCFErrorDomainCFNetwork error 310.)"
    #expect(store.modalErrorMessage == nil && store.connectionNotice != nil, "an inline reconnect line, no modal")
}
