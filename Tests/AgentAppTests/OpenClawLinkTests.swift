import Foundation
import Testing
@testable import AgentApp

// P12 Part A: pairing, reconnects, liveness and requests on a manual clock.

/// The connect params without what must differ per attempt (nonce, signature, signedAt).
private func stable(_ params: GatewayJSON) -> GatewayJSON {
    guard var object = params.object, var device = object["device"]?.object else { return params }
    device["nonce"] = nil; device["signature"] = nil; device["signedAt"] = nil
    object["device"] = .object(device)
    return .object(object)
}

@Test func thePairingWaitRepeatsIdenticallyShowsTheLatestRequestAndResumesOnApproval() async throws {
    let fake = FakeGateway(); fake.requiresApproval = true
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup(url: "wss://gw-test.example")
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock)
    await link.connect()
    try await waitFor { if case .pairingRequired(let id, _, _) = await link.state { return id == "req-1" }; return false }
    guard case .pairingRequired(_, let reason, let deviceId) = await link.state else { return }
    #expect(reason == "not-paired" && deviceId.count == 64)
    #expect(GatewayState.pairingRequired(requestId: "req-1", reason: nil, deviceId: deviceId).line() == "Waiting for approval on the Gateway host: openclaw devices approve req-1")
    try await clock.waitForSleeper(GatewayLink.pairingRetry)
    clock.advance(by: GatewayLink.pairingRetry)
    try await waitFor { await link.state == .pairingRequired(requestId: "req-2", reason: "not-paired", deviceId: deviceId) }
    fake.approve()
    try await clock.waitForSleeper(GatewayLink.pairingRetry)
    clock.advance(by: GatewayLink.pairingRetry)
    try await waitFor { await link.state.isConnected }
    let params = fake.connectParams
    #expect(params.count == 3 && Set(params.map(stable)).count == 1, "same key, role, scopes and auth every time")
    #expect(Set(params.compactMap { $0["device"]?["nonce"]?.string }).count == 3, "a fresh nonce per attempt")
    await link.disconnect()
}

@Test func anUntrustedRequestIDNeverReachesTheCopyableCommand() {
    #expect(GatewayState.approveCommand("req-1.a_b:C") == "openclaw devices approve req-1.a_b:C")
    for hostile in ["x; rm -rf ~", "$(id)", "a b", "`x`", "", String(repeating: "a", count: 129), "ré"] {
        #expect(GatewayState.approveCommand(hostile) == "openclaw devices approve <requestId>", "\(hostile)")
    }
}

@Test func thePairingWaitEndsAfterTenMinutes() async throws {
    let fake = FakeGateway(); fake.requiresApproval = true
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock)
    await link.connect()
    for _ in 0..<120 {
        try await clock.waitForSleeper(GatewayLink.pairingRetry)
        clock.advance(by: GatewayLink.pairingRetry)
    }
    try await waitFor { await link.state == .failed(.pairingTimedOut) }
    #expect(fake.pairingRequests == 121)
}

@Test func reconnectsBackOffFromOneToThirtySecondsWithJitterAndResetAfterAStableLink() async throws {
    let fake = FakeGateway(); fake.tickIntervalMs = 3_600_000 // the watchdog stays out of the way
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let states = AwaitableLog<GatewayState>()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock, jitter: 1, states: states)
    _ = try await link.ready()
    var delays: [Duration] = []
    for expected in [1.2, 2.4, 4.8, 9.6, 19.2, 36.0, 36.0] {
        let before = fake.connectParams.count
        fake.lastSocket?.drop()
        try await waitFor { if case .reconnecting = await link.state { return true }; return false }
        guard case .reconnecting(let delay) = await link.state else { return }
        delays.append(delay)
        #expect(delay == .milliseconds(Int(expected * 1000)), "+20% jitter on \(expected / 1.2) s")
        try await clock.waitForSleeper(delay) // the state is published just before the pause begins
        clock.advance(by: delay)
        try await waitFor { await link.state.isConnected && fake.connectParams.count == before + 1 }
    }
    // Up for 30 s or more: the next drop starts from 1 s again.
    clock.advance(by: GatewayLink.stableAfter)
    fake.lastSocket?.drop()
    try await waitFor { await link.state == .reconnecting(in: .milliseconds(1_200)) }
    #expect(states.all.contains(.connecting) && delays.count == 7)
    await link.disconnect()
}

@Test func theTickWatchdogClosesASilentLinkWith4000() async throws {
    let fake = FakeGateway(); fake.tickIntervalMs = 1_000
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock)
    let connection = try await link.ready()
    let socket = try #require(fake.lastSocket)
    let (_, ticks) = await connection.subscribe { $0.event == "tick" }
    try await clock.waitForSleeper(.seconds(2))
    clock.advance(by: .milliseconds(1_500))
    fake.emit("tick", ["ts": 1])
    var iterator = ticks.makeAsyncIterator(); _ = await iterator.next()
    clock.advance(by: .milliseconds(500)) // t = 2 s: a frame arrived in this window
    try await clock.waitForSleeper(.seconds(2))
    clock.advance(by: .milliseconds(1_900)) // t = 3.9 s
    #expect(await connection.isClosed == false)
    clock.advance(by: .milliseconds(100)) // t = 4 s: silent since 1.5 s
    try await waitFor { await connection.isClosed }
    #expect(await connection.closeReason == .tickTimeout && socket.closedWith == 4000)
    try await waitFor { if case .reconnecting = await link.state { return true }; return false }
    await link.disconnect()
}

@Test func pendingRequestsFailOnCloseAndAreNeverReplayed() async throws {
    let fake = FakeGateway(); fake.silentMethods = ["chat.history"]
    let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    let connection = try await link.ready()
    let call = Task { try await connection.request("chat.history", params: ["sessionKey": "agent:agent-alpha:x"]) }
    try await fake.requestLog.wait { $0.contains("chat.history") }
    fake.lastSocket?.drop()
    await #expect(throws: GatewayConnectionError.closed) { try await call.value }
    _ = try await link.ready()
    #expect(fake.requestsFor("chat.history").count == 1, "never replayed after the reconnect")
    await link.disconnect()
}

@Test func requestsTimeOutOnTheClock() async throws {
    let fake = FakeGateway(); fake.silentMethods = ["chat.abort"]
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock)
    let connection = try await link.ready()
    let call = Task { try await connection.request("chat.abort", params: ["sessionKey": "s"], timeout: .seconds(10)) }
    try await clock.waitForSleeper(.seconds(10))
    clock.advance(by: .seconds(10))
    await #expect(throws: GatewayConnectionError.timeout("chat.abort")) { try await call.value }
    await link.disconnect()
}

@Test func repliesResolveOutOfOrderByID() async throws {
    let fake = FakeGateway(); fake.silentMethods = ["sessions.list", "chat.history"]
    let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    let connection = try await link.ready()
    let first = Task { try await connection.request("sessions.list", params: [:]) }
    let second = Task { try await connection.request("chat.history", params: ["sessionKey": "s"]) }
    try await fake.requestLog.wait { $0.contains("sessions.list") && $0.contains("chat.history") }
    let socket = try #require(fake.lastSocket)
    let ids = socket.sentFrames.compactMap { text -> (String, String)? in
        guard case .request(let id, let method, _)? = GatewayFrame.decode(text) else { return nil }; return (method, id)
    }
    let byMethod = Dictionary(ids, uniquingKeysWith: { $1 })
    fake.respond(to: try #require(byMethod["chat.history"]), on: socket, payload: ["which": "second"])
    fake.respond(to: try #require(byMethod["sessions.list"]), on: socket, payload: ["which": "first"])
    let (one, two) = (try await first.value, try await second.value)
    #expect(one == ["which": "first"] && two == ["which": "second"])
    await link.disconnect()
}

@Test func eventsFanOutByPredicateBufferedFromSubscriptionTime() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    let connection = try await link.ready()
    let (_, chat) = await connection.subscribe { $0.event == "chat" }
    let (_, other) = await connection.subscribe { $0.event == "agent" }
    fake.emit("unknown.event", ["x": 1])
    for seq in 1...3 { fake.emit("chat", ["seq": .int(seq)], seq: seq) }
    fake.emit("agent", ["runId": "r"])
    var iterator = chat.makeAsyncIterator(), agents = other.makeAsyncIterator()
    var seen: [Int] = []
    for _ in 0..<3 { if let event = await iterator.next() { seen.append(event.payload["seq"]?.int ?? -1) } }
    let agent = await agents.next()
    #expect(seen == [1, 2, 3] && agent?.event == "agent")
    await link.disconnect()
    let after = await iterator.next()
    #expect(after == nil, "streams finish on close")
}

@Test func wakeRetriesAtOnceInsteadOfWaitingOutTheBackoff() async throws {
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let fake = FakeGateway(); let fails = LockedFlag(true)
    let link = GatewayLink(gateway: gateway, credentials: GatewayCredentials(gateway: gateway, keyStore: keys), makeTransport: {
        let transport = ScriptedGatewayTransport(server: fake); if fails.value { transport.openError = URLError(.cannotConnectToHost) }; return transport
    }, clock: clock, jitter: { 0 }, publish: { _ in })
    await link.connect()
    try await waitFor { if case .failed(.unreachable) = await link.state { return true }; return false }
    try await clock.waitForSleeper(.seconds(1))
    fails.value = false
    await link.retryNow()
    try await waitFor { await link.state.isConnected }
    #expect(clock.now == .zero, "no time passed")
    await link.disconnect()
}
