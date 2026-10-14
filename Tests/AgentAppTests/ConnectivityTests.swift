import Foundation
import Testing
@testable import AgentApp

// P16 Part 4: sleep, wake, path and timeouts. ManualConnectivity drives the events; SystemConnectivity is never created.

@MainActor private func connectedGroup(_ names: [String]) throws -> (AppStore, [Bot], [SessionServer.State], GroupChat, ManualConnectivity) {
    let (store, bots, states) = reconcileStore(bots: names)
    let source = ManualConnectivity(); store.connectivity = source; store.listenForConnectivity()
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    return (store, bots, states, group, source)
}

@MainActor @Test func aDeadPathSkipsTheWholeRoundAtOnce() async throws {
    let (store, bots, states, group, source) = try connectedGroup(["Alpha", "Beta"])
    source.send(.pathDown)
    try await waitUntil { store.turns.pathDown }
    store.send(text: "anyone there", to: group)
    try await waitUntil { store.isIdle && group.round == nil }
    #expect(states.allSatisfy { $0.posts.isEmpty })
    for bot in bots { #expect(group.messages.first { $0.authorID == bot.id }?.metadata["why"] == "offline") }
    #expect(group.messages.last?.content == "Not sent to Alpha, Beta (offline).")
}

@MainActor @Test func theIncidentInMiniatureAnOfflineMemberStopsTheRestAndRetrySendsOnce() async throws {
    let (store, bots, states, group, source) = try connectedGroup(["Alpha", "Beta"])
    states[0].with { $0.scripts = [.fail(.notConnectedToInternet)] }
    store.send(text: "status", to: group)
    try await waitUntil { store.isIdle && group.round == nil }
    let alpha = try #require(group.messages.first { $0.authorID == bots[0].id }), beta = try #require(group.messages.first { $0.authorID == bots[1].id })
    #expect(alpha.turnState == .notSent && alpha.metadata["why"] == "offline" && beta.turnState == .notSent && states[1].posts.isEmpty)
    #expect(group.messages.contains { $0.content.hasPrefix("Alpha: ") && $0.metadata["tone"] == "warning" })
    // The path comes back: a pass reads every member; nothing is resent by itself.
    source.send(.pathUp)
    try await waitUntil { !states[1].log.all.filter { $0.method == "GET" }.isEmpty || !store.turns.pathDown }
    #expect(states[0].chatPosts.count == 1 && states[1].chatPosts.isEmpty, "only the original failed attempt; nothing resent")
    // Retry on Beta's newest row sends exactly once, with a context built now.
    store.retry(beta)
    try await waitUntil { store.isIdle && beta.turnState == .finished }
    #expect(states[1].chatPosts.count == 1 && SessionServer.inputText(states[1].chatPosts[0].body?["input"]).hasSuffix("Konrad: status"))
    #expect(group.messages.filter { $0.authorID == bots[1].id }.count == 1, "into the same row")
}

@MainActor @Test func wakeAndPathUpReconcileWhatNeedsIt() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Alpha"])
    let source = ManualConnectivity(); store.connectivity = source; store.listenForConnectivity()
    let bot = bots[0]; bot.hermesSessionID = "s-alpha"
    states[0].add("s-alpha", "user", "q"); states[0].add("s-alpha", "assistant", "the full reply", finish: "stop")
    bot.messages = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "the", turnState: .incomplete)]
    source.send(.didWake)
    try await waitUntil { bot.messages[1].content == "the full reply" }
    bot.messages[1].content = "the"; bot.messages[1].turnState = .incomplete
    source.send(.pathUp)
    try await waitUntil { bot.messages[1].content == "the full reply" }
    #expect(states[0].posts.isEmpty)
}

@MainActor @Test func noEventCancelsAStreamAndSleepSaves() async throws {
    let url = temporaryStore()
    let (store, bots, states) = reconcileStore(bots: ["Alpha"], url: url)
    let source = ManualConnectivity(); store.connectivity = source; store.listenForConnectivity()
    let bot = bots[0]; bot.hermesSessionID = "s-alpha"; states[0].with { $0.sessions["s-alpha"] = []; $0.scripts = [.hang] }
    store.selectedBot = bot
    #expect(store.send(text: "long job"))
    try await waitUntil { states[0].chatPosts.count == 1 }
    for event in [ConnectivityEvent.pathDown, .willSleep, .didWake, .pathUp] { source.send(event) }
    try await waitUntil { !store.turns.pathDown }
    #expect(store.isStreaming && store.streamTask != nil, "pathDown, sleep and wake cancel nothing")
    bot.name = "Renamed before sleep"
    source.send(.willSleep)
    try await waitUntil { (try? String(contentsOf: url, encoding: .utf8))?.contains("Renamed before sleep") == true }
    store.stop()
    try await waitUntil { store.isIdle }
}

@MainActor @Test func launchWorkRunsOnceAndNeverMidRound() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Alpha", "Beta"])
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    states[0].with { $0.scripts = [.hang] }
    store.send(text: "go", to: group)
    try await waitUntil { states[0].chatPosts.count == 1 }
    store.turns.roundsAtLaunch = [group.id]
    store.recoverInterruptedRounds()
    #expect(group.round != nil && !group.messages.contains { $0.metadata["why"] == "quit" }, "a no-op while a turn runs")
    store.routines.autoLoad = false
    store.startLaunchWork(makeConnectivity: { ManualConnectivity() })
    #expect(!store.turns.didLaunchRecovery, "gated on routines.autoLoad: snapshot renders and tests never run it")
    store.routines.autoLoad = true
    store.startLaunchWork(makeConnectivity: { ManualConnectivity() }); store.startLaunchWork(makeConnectivity: { Issue.record("a second .task must not run it"); return nil })
    #expect(store.turns.didLaunchRecovery)
    store.stop()
    try await waitUntil { store.isIdle }
}
