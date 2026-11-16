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

/// Fails `failures` sends with an error proving the request never left the Mac, then answers.
private actor FlakyBackend: AgentBackend {
    nonisolated let kind = BackendKind.herdr
    private var failures: Int
    private(set) var sends = 0
    init(failures: Int) { self.failures = failures }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sends += 1
        if failures > 0 { failures -= 1; throw StreamBreak(delivered: false, underlying: URLError(.cannotConnectToHost), requestStarted: false) }
        return AsyncThrowingStream { continuation in continuation.yield(.token("answer")); continuation.yield(.completed); continuation.finish() }
    }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func testConnection() async throws -> String { "ok" }
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
