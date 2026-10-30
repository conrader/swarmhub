import Foundation
import Testing
@testable import AgentApp

// uxfix1: transient network trouble (-1005 lost, -1001 timed out, -1004 cannot connect, -1009 offline, a dropped stream)
// never opens the modal "Backend Error" alert; a turn that never left the Mac is sent again by itself.

@Test func transientNetworkErrorsAreRecognisedWhateverWrapsThem() {
    for code: URLError.Code in [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet] {
        #expect(TransientNetwork.isTransient(URLError(code)), "\(code.rawValue)")
        #expect(TransientNetwork.isTransient(StreamBreak(delivered: true, underlying: URLError(code))), "\(code.rawValue) after the headers")
        #expect(TransientNetwork.isTransient(NSError(domain: NSURLErrorDomain, code: code.rawValue)), "\(code.rawValue) as NSError")
    }
    #expect(TransientNetwork.isTransient(StreamBreak(delivered: true, underlying: StreamBreak.EndOfStream())), "a stream cut without a terminal event")
    #expect(TransientNetwork.isTransient(NSError(domain: NSPOSIXErrorDomain, code: 54)), "ECONNRESET")
    #expect(TransientNetwork.isTransient(NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])))
    #expect(TransientNetwork.isTransient(BackendError.http(502, "bad gateway")))
    #expect(!TransientNetwork.isTransient(BackendError.http(401, "no")))
    #expect(!TransientNetwork.isTransient(BackendError.unavailable("The network connection was lost.")), "a box's own words are not the network")
    #expect(!TransientNetwork.isTransient(URLError(.badServerResponse)))
    #expect(!TransientNetwork.isTransient(URLError(.cancelled)))
    #expect(!TransientNetwork.isTransient(CancellationError()))
}

@Test func theNetworkConnectionWasLostIsNeverAlertText() {
    for text in ["The network connection was lost.", "Stop failed: The request timed out.", "Could not connect to the server.",
                 "The Internet connection appears to be offline.",
                 "SwarmHub’s instructions were not installed (x for Y): The install turn failed: The network connection was lost.",
                 "The operation couldn’t be completed. (NSURLErrorDomain error -1005.)",
                 URLError(.networkConnectionLost).localizedDescription, URLError(.timedOut).localizedDescription] {
        #expect(TransientNetwork.isTransient(text: text), "\(text)")
    }
    #expect(!TransientNetwork.isTransient(text: "HTTP 401: the server rejected this key."))
    #expect(!TransientNetwork.isTransient(text: "box failed"))
    #expect(!TransientNetwork.isTransient(text: URLError(.badServerResponse).localizedDescription))
}

@MainActor @Test func transientTextIsTheSmallLineAndGoesWhenTheBoxAnswers() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.errorMessage = "The network connection was lost."
    #expect(store.modalErrorMessage == nil, "never the alert")
    #expect(store.connectionNotice == "The network connection was lost.")
    store.noteBoxSuccess()
    #expect(store.errorMessage == nil && store.connectionNotice == nil, "the box answered: the line goes")
    store.errorMessage = "HTTP 401: the server rejected this key."
    #expect(store.modalErrorMessage == "HTTP 401: the server rejected this key." && store.connectionNotice == nil)
    store.clearConnectionNotice()
    #expect(store.errorMessage != nil, "other errors stay for the alert")
}

@MainActor @Test func aDroppedTurnNeverRaisesTheAlert() async throws {
    for ending: EndingBackend.Ending in [.cutAfterToken, .throwBeforeHeaders(.networkConnectionLost), .throwBeforeHeaders(.timedOut)] {
        let backend = EndingBackend(ending)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
        var timing = ReconcileTiming.fast; timing.schedule = []; store.reconcileTiming = timing
        let bot = Bot(name: "Echo", backend: .hermes, hermesProfile: "default", hermesSessionID: "s-echo"); store.bots = [bot]; store.selectedBot = bot
        #expect(store.send(text: "question"))
        try await waitUntil { !store.anyTurnRunning }
        #expect(store.errorMessage == nil && store.modalErrorMessage == nil, "\(ending)")
        #expect(bot.messages.contains { $0.role == .system && $0.metadata[TurnKey.tone] == "warning" }, "the chat still says it (\(ending))")
    }
}

/// Fails `failures` sends with an error proving the request never left the Mac, then answers.
private actor FlakyBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    private var failures: Int
    private(set) var sends = 0
    init(failures: Int) { self.failures = failures }
    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sends += 1
        if failures > 0 { failures -= 1; throw StreamBreak(delivered: false, underlying: URLError(.cannotConnectToHost), requestStarted: false) }
        return AsyncThrowingStream { continuation in continuation.yield(.token("answer")); continuation.yield(.completed); continuation.finish() }
    }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { id ?? "s" }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "ok" }
}

@MainActor @Test func aTurnThatNeverLeftTheMacIsSentAgainByItself() async throws {
    let backend = FlakyBackend(failures: 2)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let pauses = LockedValue<[Duration]>([])
    store.sendRetryDelays = [.seconds(1), .seconds(3), .seconds(8)]
    store.setupRetrySleep = { delay in _ = pauses.swap(pauses.current + [delay]) }
    let bot = Bot(name: "Echo", backend: .hermes, hermesProfile: "default", hermesSessionID: "s-echo"); store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "question"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(await backend.sends == 3 && pauses.current == [.seconds(1), .seconds(3)], "two backed-off resends")
    let reply = try #require(bot.messages.first { $0.role == .assistant })
    #expect(reply.content == "answer" && reply.turnState == .finished && store.errorMessage == nil)
    #expect(reply.metadata[TurnKey.reconnecting] == nil, "the Reconnecting… state ended with the turn")
    #expect(!bot.messages.contains { $0.role == .system }, "no warning line for a send that went through")
    #expect(bot.messages.filter { $0.role == .user }.count == 1, "one message, sent once it could be")
}

@MainActor @Test func aTurnThatStillCannotLeaveTheMacEndsUnsentWithoutAnAlert() async throws {
    let backend = FlakyBackend(failures: 10)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    store.sendRetryDelays = [.seconds(1), .seconds(3)]
    store.setupRetrySleep = { _ in }
    let bot = Bot(name: "Echo", backend: .hermes, hermesProfile: "default", hermesSessionID: "s-echo"); store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "question"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(await backend.sends == 3, "the first send and two retries")
    let reply = try #require(bot.messages.first { $0.role == .assistant })
    #expect(reply.turnState == .notSent && reply.metadata[TurnKey.why] == "offline")
    #expect(store.modalErrorMessage == nil, "after the retries it is the row's footer and a warning line, never the alert")
}

@MainActor @Test func aReconnectIsTheRowsLiveStateUntilTheBoxSendsAgain() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    try await startSteerableTurn(store, backend, running: false)
    let row = bot.messages[1]
    await backend.emit(.status(TurnErrorCopy.reconnecting))
    try await waitUntil { row.metadata[TurnKey.reconnecting] == "1" }
    #expect(row.content == "Before. " && row.isStreaming, "the reply so far stays; no warning line, no alert")
    #expect(!bot.messages.contains { $0.role == .system } && store.errorMessage == nil)
    await backend.emit(.token("after."))
    try await waitUntil { row.metadata[TurnKey.reconnecting] == nil }
    await backend.emit(.completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(row.content == "Before. after." && row.turnState == .finished)
}
