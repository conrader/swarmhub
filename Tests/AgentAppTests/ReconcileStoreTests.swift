import Foundation
import Testing
@testable import AgentApp

// P16 Part 1 in the store: GET only, windows, sessions per member, triggers. Synthetic text, SessionServer only.

/// A bot chat whose box already holds `turns` (user, reply) pairs, ten seconds apart, ending now.
@MainActor private func chatWithBox(turns: Int, finish: String? = "stop") -> (AppStore, Bot, SessionServer.State, [String]) {
    let (store, bots, states) = reconcileStore(bots: ["Alpha"])
    let bot = bots[0]; bot.hermesSessionID = "s-alpha"
    var replies: [String] = []
    let start = Date().addingTimeInterval(-Double(turns) * 10)
    for index in 0..<turns {
        let reply = syntheticParagraph(40 + index % 7, seed: index + 1); replies.append(reply)
        states[0].add("s-alpha", "user", "question \(index)", time: start.addingTimeInterval(Double(index) * 10).timeIntervalSince1970)
        states[0].add("s-alpha", "assistant", reply, finish: finish, time: start.addingTimeInterval(Double(index) * 10 + 1).timeIntervalSince1970)
        bot.messages += [ChatMessage(role: .user, content: "question \(index)", createdAt: start.addingTimeInterval(Double(index) * 10)),
                         ChatMessage(role: .assistant, content: reply, createdAt: start.addingTimeInterval(Double(index) * 10 + 1), turnState: .finished)]
    }
    return (store, bot, states[0], replies)
}

@MainActor @Test func aPassReadsOnlyWithGETsAndWidensByWholeWindows() async throws {
    let (store, bot, box, replies) = chatWithBox(turns: 80)
    // An old reply the Mac cut: the read must reach back past it (row 10 of 160 → three windows).
    bot.messages[21].content = String(replies[10].prefix(12)); bot.messages[21].turnState = .incomplete
    let report = await store.reconcile(bot, reason: .refresh)
    #expect(box.methods == ["GET"], "a reconcile never POSTs")
    let windows = box.log.all.filter { $0.path.hasSuffix("/messages") }.map { "\($0.query["order"]!) \($0.query["limit"]!) \($0.query["offset"]!)" }
    #expect(windows == ["latest 61 0", "latest 61 60", "latest 61 120"])
    #expect(bot.messages[21].content == replies[10] && bot.messages[21].turnState == .finished && report.segments.first?.counts.extended == 1)
    #expect(bot.messages[21].metadata["restored"] == "extended" && bot.messages[21].metadata["box"] != nil)
}

@MainActor @Test func aMissingSessionIsQuietAndAFailedGETIsRepeatedOnceExceptATimeout() async throws {
    let (store, bot, box, _) = chatWithBox(turns: 1)
    bot.hermesSessionID = "s-gone"
    let quiet = await store.reconcile(bot, reason: .refresh)
    #expect(quiet.read == 1 && store.errorMessage == nil && !bot.messages.contains { $0.role == .system })
    bot.hermesSessionID = "s-alpha"
    box.with { $0.getFailures = [.networkConnectionLost] }
    let repeated = await store.reconcile(bot, reason: .refresh)
    #expect(repeated.read == 1 && box.log.all.filter { $0.path == "/api/sessions/s-alpha/messages" }.count == 2)
    box.with { $0.getFailures = [.timedOut] }
    let before = box.log.all.count
    let timedOut = await store.reconcile(bot, reason: .refresh)
    #expect(timedOut.unreachable && box.log.all.count - before == 1, "no repeat after .timedOut")
    #expect(store.errorMessage == nil)
}

@MainActor @Test func aBotChatIsExtendedAndAddedToAThreadOnlyExtended() async throws {
    let (store, bot, box, replies) = chatWithBox(turns: 2)
    bot.messages[3].content = String(replies[1].prefix(10)); bot.messages[3].turnState = .incomplete
    box.add("s-alpha", "user", "asked elsewhere"); box.add("s-alpha", "assistant", "answered elsewhere", finish: "stop")
    store.selectedBot = nil
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages[3].content == replies[1] && bot.messages.suffix(2).map(\.content) == ["asked elsewhere", "answered elsewhere"])
    #expect(bot.messages.last?.metadata["restored"] == "added" && bot.unreadCount == 1, "added rows alone bump unread")
    // A thread: extend and fill only.
    let thread = ChatThread(parentMessageID: bot.messages[1].id, parentSessionID: "s-alpha", hermesSessionID: "s-thread",
                            messages: [ChatMessage(role: .user, content: "thread ask"), ChatMessage(role: .assistant, content: "thr", turnState: .incomplete)])
    bot.threads = [thread]
    box.add("s-thread", "user", "thread ask"); box.add("s-thread", "assistant", "thread answer", finish: "stop")
    box.add("s-thread", "user", "other"); box.add("s-thread", "assistant", "other answer", finish: "stop")
    await store.reconcile(thread, reason: .refresh)
    #expect(thread.messages.map(\.content) == ["thread ask", "thread answer"])
}

@MainActor @Test func eachGroupMemberIsReadFromItsOwnBoxKeyAndPrefix() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Alpha", "Beta", "Gamma"])
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    let trigger = ChatMessage(role: .user, content: "status please"); group.messages.append(trigger)
    for (index, bot) in bots.enumerated() {
        let session = GroupRouting.sessionID(group: group.id, bot: bot.id)
        group.sessions[bot.id.uuidString.lowercased()] = session
        let blob = GroupRouting.context(for: .init(id: bot.id, name: bot.name), groupName: group.name, members: store.routingMembers(of: group), messages: group.messages, current: trigger.id)
        states[index].add(session, "user", blob); states[index].add(session, "assistant", "\(bot.name) full status report here", finish: "stop")
        group.messages.append(ChatMessage(role: .assistant, content: "\(bot.name) full", metadata: ["for": trigger.id.uuidString], authorID: bot.id, turnState: .incomplete))
    }
    (store.keyStore as! InMemoryKeyStore).setKey("", for: AppStore.keyAccount(forProfile: "grok-gamma"))
    let report = await store.reconcile(group, reason: .refresh)
    for (index, bot) in bots.prefix(2).enumerated() {
        let read = try #require(states[index].log.all.first { $0.path.hasSuffix("/messages") })
        #expect(read.headers["Authorization"] == "Bearer key-\(bot.name.lowercased())" && read.rawPath.hasPrefix("/p/grok-\(bot.name.lowercased())/"))
        #expect(group.messages.first { $0.authorID == bot.id }?.content == "\(bot.name) full status report here")
    }
    #expect(states[2].log.all.isEmpty && report.problems == ["Gamma: no readable key"], "a member without a key is skipped and counted")
    #expect(group.messages.first { $0.authorID == bots[2].id }?.turnState == .incomplete)
}

@MainActor @Test func streamingConversationsAndChangedRowsAreNeverTouched() async throws {
    let (store, bot, _, replies) = chatWithBox(turns: 1)
    bot.messages[1].content = "x"; bot.messages[1].turnState = .incomplete; bot.messages[1].isStreaming = true
    let skipped = await store.reconcile(bot, reason: .refresh)
    #expect(skipped.skipped && bot.messages[1].content == "x")
    bot.messages[1].isStreaming = false
    let snapshot = bot.messages.map(HistoryReconciler.LocalRow.init)
    let plan = HistoryReconciler.plan(.init(local: snapshot, server: [srow("user", "question 0"), srow("assistant", replies[0], finish: "stop")], mode: .chat(additions: true)))
    bot.messages[1].content = "xy" // changed between the read and the apply
    var report = ReconcileReport()
    store.apply(plan, snapshot: snapshot, to: .init(conversation: bot, bot: bot, sessionID: "s-alpha", mode: .chat(additions: true), name: "Alpha"), report: &report)
    #expect(bot.messages[1].content == "xy" && !report.changed)
}

@MainActor @Test func automaticPassesNeverRaiseTheAlertAndKeepAFloor() async throws {
    let (store, bot, box, _) = chatWithBox(turns: 1)
    store.reconcileTiming.floor = .seconds(60); store.reconcileTiming.openFloor = .seconds(60)
    box.with { $0.networkDown = true }
    let failed = await store.reconcile(bot, reason: .wake)
    #expect(failed.unreachable && store.errorMessage == nil)
    box.with { $0.networkDown = false }
    let before = box.log.all.count
    _ = await store.reconcile(bot, reason: .wake)
    #expect(box.log.all.count == before, "within the floor an automatic pass does nothing")
    _ = await store.reconcile(bot, reason: .refresh)
    #expect(box.log.all.count > before, "Refresh is exempt")
}

@MainActor @Test func openingAChatReconcilesItWithoutAnAlert() async throws {
    let (store, bot, box, replies) = chatWithBox(turns: 1)
    bot.messages[1].content = String(replies[0].prefix(5)); bot.messages[1].turnState = .incomplete
    store.open(bot)
    try await waitUntil { bot.messages[1].content == replies[0] }
    #expect(box.methods == ["GET"] && store.errorMessage == nil)
}

@MainActor @Test func aCutStreamIsFollowedByGETOnlyPassesThatCompleteTheRow() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Alpha"])
    let bot = bots[0]; bot.hermesSessionID = "s-alpha"; states[0].with { $0.sessions["s-alpha"] = [] }
    store.selectedBot = bot
    let full = syntheticParagraph(98, seed: 3) + "\n\n" + syntheticParagraph(193, seed: 4)
    states[0].with { $0.scripts = [.cut(chunks: [String(full.prefix(98)) + "\n\n"], persist: full)] }
    #expect(store.send(text: "tell me"))
    try await waitUntil { store.isIdle }
    try await waitUntil { bot.messages.first { $0.role == .assistant }?.content == full }
    let reply = try #require(bot.messages.first { $0.role == .assistant })
    #expect(reply.turnState == .finished && reply.metadata["restored"] == "extended")
    #expect(states[0].chatPosts.count == 1, "after a cut stream the app only reads")
    #expect(bot.messages.contains { $0.metadata["tone"] == "warning" })
}

@MainActor @Test func finishReasonAndRunStatusAbsentLeaveAnHonestIncomplete() async throws {
    let (store, bot, box, replies) = chatWithBox(turns: 1, finish: nil)
    box.with { $0.sessions["s-alpha"]![1].finish = nil; $0.features["run_status"] = true }
    bot.messages[1].content = String(replies[0].prefix(8)); bot.messages[1].turnState = .incomplete
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages[1].content == replies[0] && bot.messages[1].turnState == .incomplete && bot.messages[1].metadata["end"] == "none")
    #expect(TurnStateFooter.text(for: bot.messages[1]) == "The box has no more of this reply")
    // run_status reports a live run: no settle, no end mark.
    box.with { $0.runStatus["run-7"] = "running"; $0.sessions["s-alpha"]![1].finish = "stop" }
    bot.messages[1].metadata["end"] = nil; bot.messages[1].metadata["run"] = "run-7"
    let report = await store.reconcile(bot, reason: .refresh)
    #expect(report.activeRun && bot.messages[1].turnState == .incomplete)
}

@MainActor @Test func theLaunchSweepReadsAFewAtATimeAndNotOffline() async throws {
    let (store, bots, states) = reconcileStore(bots: ["A1", "A2", "A3", "A4", "A5"])
    for (bot, state) in zip(bots, states) { bot.hermesSessionID = "s-\(bot.name)"; state.add("s-\(bot.name)", "user", "hi"); state.add("s-\(bot.name)", "assistant", "yo", finish: "stop") }
    store.turns.pathDown = true
    await store.launchSweep()
    #expect(states.allSatisfy { $0.log.all.isEmpty }, "skipped offline")
    store.turns.pathDown = false
    await store.launchSweep()
    #expect(states.allSatisfy { !$0.log.all.isEmpty } && store.reconcileTiming.sweepWidth == 3)
}
