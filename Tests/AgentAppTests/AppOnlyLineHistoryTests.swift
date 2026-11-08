import Foundation
import Testing
@testable import AgentApp

// backlog10: manager notices, the orientation "gave up" line, review cards and bot-work/bot-message cards are app-only
// `system` rows: shown in the chat, never model-bound history (the legacy v1/chat/completions path sends every history
// row). Approved/Declined lines and stop lines carry the user's intent and stay. Fixture names are synthetic.

/// The exact text builds before backlog10 saved, with no tag. Frozen on purpose: if a producer's wording changes, these
/// rows still exist in saved chats, so the old form must stay in `AppOnlyLine.legacy` (or the leak reopens).
private let preBacklog10Lines = [
    "Fixture Mgr created Fixture Scout",
    "Couldn’t reach fixture-scout yet",
    "Couldn’t see fixture-scout yet",
    "Connected Fixture Scout, Fixture Ada.",
    "Couldn’t connect Fixture Ada; they are listed under “not connected”.",
    "Connected Fixture Scout. Couldn’t connect Fixture Ada; they are listed under “not connected”.",
    "Nothing was connected.",
    "Fixture Ada’s old key is back on the box; Fixture Ada is no longer connected here.",
    "Couldn’t restore Fixture Ada’s old key; nothing changed here.",
    "Fixture Scout could not be reached for 24 h, so it was not given an orientation.",
    "Fixture Rev is reviewing this reply…",
    // backlog7's notes, matched by `ReconcileNote`.
    "Hermes history was not merged because it diverges from this local conversation.",
    "Queued message delivery is uncertain after restart. Refresh server history before sending again: fixture queued text",
]

/// Intent lines, including ones whose title or error text contains an app-only line's words: always kept.
private let intentLines = [
    "Approved: Fixture Mgr created Fixture Scout", "Declined: Couldn’t reach fixture-scout yet",
    "Stop requested from Hermes.", "Stopped locally before Hermes supplied a run ID.",
    "Stopped locally; this OpenClaw Gateway does not offer chat.abort.", "Stopped locally; this Hermes version has no run-control endpoint.",
    "Hermes Stop failed: the run was created by another device.",
]

private func untagged(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }

@MainActor private func lineStore() -> (AppStore, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Fixture-\(UUID().uuidString.prefix(8))", backend: .hermes, hermesProfile: "fixture-backlog10")
    store.bots = [bot]
    return (store, bot)
}

@MainActor private func history(_ store: AppStore, _ bot: Bot) -> [(role: String, content: String)] {
    store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: ""))
}

// MARK: drift: producer ⇄ filter

@Test @MainActor func everyProducerStillWritesThePreBacklog10TextTheFilterMatches() {
    // Each producer, given the fixture's values, must write exactly the frozen text. A reworded producer fails here:
    // keep its old template in `AppOnlyLine.legacy` and update this list deliberately.
    let produced = [
        AppOnlyLine.created.render("Fixture Mgr", "Fixture Scout"), AppOnlyLine.couldNotReach.render("fixture-scout"),
        AppOnlyLine.couldNotSee.render("fixture-scout"), BoxCopy.adopted(added: ["fixture-scout", "fixture-ada"], failed: []),
        BoxCopy.adopted(added: [], failed: ["fixture-ada"]), BoxCopy.adopted(added: ["fixture-scout"], failed: ["fixture-ada"]),
        BoxCopy.adopted(added: [], failed: []), BoxCopy.restored("Fixture Ada"), BoxCopy.restoreFailed("Fixture Ada"),
        OrientationCopy.gaveUp("Fixture Scout"), AppOnlyLine.reviewing.render("Fixture Rev"),
        ReconcileNote.diverged, ReconcileNote.uncertainQueuePrefix + "fixture queued text",
    ]
    #expect(produced == preBacklog10Lines)
    for text in preBacklog10Lines { #expect(AppOnlyLine.isAppOnly(untagged(text)), "untagged saved row leaks: \(text)") }
    let kept = [IntentLine.approved.render("Fixture Mgr created Fixture Scout"), IntentLine.declined.render("Couldn’t reach fixture-scout yet"),
                IntentLine.stopRequested.render("Hermes"), IntentLine.stoppedBeforeRunID.render("Hermes"), IntentLine.stoppedNoAbort.render(),
                IntentLine.stoppedNoRunControl.render(), IntentLine.stopFailed.render("Hermes", "the run was created by another device.")]
    #expect(kept == intentLines)
    for text in intentLines { #expect(!AppOnlyLine.isAppOnly(untagged(text)), "intent line dropped: \(text)") }
}

/// No row producer may write an app-only line's text as a literal: it must go through the shared constant.
@Test func noProducerWritesAnAppOnlyLineAsALiteral() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentApp")
    let owners: Set<String> = ["AppOnlyLine.swift", "TurnState.swift"]
    let fragments = [" could not be reached for 24 h", "’s old key is back on the box", "is reviewing this reply", "Couldn’t see ",
                     "Couldn’t connect ", "Nothing was connected", "Couldn’t restore ", "history was not merged",
                     "Queued message delivery is uncertain", "Approved: ", "Declined: ", "Stop requested from", "Stopped locally", "Stop failed: "]
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
    #expect(files.count > 100)
    for file in files where !owners.contains(file.lastPathComponent) {
        let text = try String(contentsOf: file, encoding: .utf8)
        // `notice("…")` with a literal (a logger's `.notice(` is not a row).
        #expect(text.range(of: #"(?<![.\w])notice\(""#, options: .regularExpression) == nil, "a literal manager notice in \(file.lastPathComponent)")
        for fragment in fragments { #expect(!text.contains(fragment), "\"\(fragment)\" written as a literal in \(file.lastPathComponent)") }
    }
}

@Test func lineTemplateMatchesOnlyItsShape() {
    let restored = AppOnlyLine.keyRestored
    #expect(restored.matches(restored.render("A", "A")) && !restored.matches("’s old key is back on the box;  is no longer connected here."))
    #expect(!AppOnlyLine.created.matches(" created ") && !AppOnlyLine.created.matches("x created ") && AppOnlyLine.created.matches("x created y"))
    #expect(AppOnlyLine.nothingConnected.matches("Nothing was connected.") && !AppOnlyLine.nothingConnected.matches("Nothing was connected. "))
    #expect(!AppOnlyLine.couldNotReach.matches("Couldn’t reach yet") && AppOnlyLine.couldNotReach.matches("Couldn’t reach x yet"))
}

// MARK: per row type: filtered vs kept

@Test @MainActor func managerNoticesAreTaggedAndNeverHistory() {
    let (store, manager) = lineStore()
    manager.messages = [ChatMessage(role: .user, content: "make a scout")]
    store.notice(AppOnlyLine.created.render(manager.name, "Fixture Scout"), in: manager)
    store.notice(AppOnlyLine.couldNotReach.render("fixture-scout"), in: manager)
    store.notice(AppOnlyLine.couldNotSee.render("fixture-scout"), in: manager)
    store.notice(BoxCopy.adopted(added: ["fixture-scout"], failed: ["fixture-ada"]), in: manager)
    store.notice(BoxCopy.restored("Fixture Ada"), in: manager)
    store.notice(BoxCopy.restoreFailed("Fixture Ada"), in: manager)
    #expect(manager.messages.dropFirst().allSatisfy { $0.role == .system && $0.metadata[AppOnlyLine.key] == "1" })
    #expect(history(store, manager).map(\.content) == ["make a scout"])
}

@Test @MainActor func untaggedLinesSavedBeforeBacklog10AreNeverHistory() {
    let (store, bot) = lineStore()
    bot.messages = [ChatMessage(role: .user, content: "earlier")] + preBacklog10Lines.map(untagged) + [ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot).map(\.content) == ["earlier", "now"])
}

@Test @MainActor func approvedDeclinedAndStopLinesStayInHistory() {
    let (store, bot) = lineStore()
    bot.messages = [ChatMessage(role: .user, content: "earlier")] + intentLines.map(untagged) + [ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot).map(\.content) == ["earlier"] + intentLines + ["now"])
    #expect(history(store, bot).filter { $0.role == "system" }.count == intentLines.count)
}

@Test @MainActor func reviewCardsAreNeverHistoryWhileWaitingOrDone() async throws {
    let coder = Bot(name: "Fixture Coder", backend: .hermes, hermesProfile: "fixture-coder-b10"), rev = Bot(name: "Fixture Rev", backend: .hermes, hermesProfile: "fixture-rev-b10")
    let owner = TestBackend(transport: .nativeSessions), reviewer = TestBackend(transport: .nativeSessions, streamMode: .response("VERDICT: ok"))
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == rev.id ? reviewer : owner },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = [coder, rev]
    coder.reviewAfter = [ReviewAfterRule(trigger: .codingJob, reviewerID: rev.id)]
    let reply = ChatMessage(role: .assistant, content: "Fixed.\ncode-job: claude done · ran 4s", turnState: .finished)
    var activity = ToolActivity(), t = Date.now
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "code-job --bot fixture-coder-b10 --order claude", callID: "1"), at: t)
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "1"), at: t.addingTimeInterval(4)); activity.finish(at: t.addingTimeInterval(5))
    reply.activity = activity
    coder.messages = [ChatMessage(role: .user, content: "fix it"), reply]
    let card = try #require(store.startReviewIfNeeded(reply, from: coder, in: coder))
    #expect(card.content == AppOnlyLine.reviewing.render("Fixture Rev") && card.presentation == .review)
    #expect(history(store, coder).map(\.content) == ["fix it", reply.content])
    try await waitUntil { card.metadata[ReviewKey.state] != "pending" }
    #expect(card.content == "Fixture Rev: looks good")
    #expect(history(store, coder).map(\.content) == ["fix it", reply.content])
}

@Test @MainActor func botMessageAndBotWorkCardsAreNeverHistory() {
    let (store, bot) = lineStore()
    bot.messages = [ChatMessage(role: .user, content: "earlier")]
    store.postArrival(from: "fixture-sender-b10", recipient: bot, session: "b10-arrival-\(UUID().uuidString)")
    let turn = BotWorkTurn(requestID: "b10-req", request: "check the disk", origin: nil, activity: nil, reply: "disk ok", finished: true, startedAt: .now)
    let session = "b10-work-\(UUID().uuidString)"
    store.applyBotWork(turn, bot: bot, session: session, origin: .routine("fixture-nightly"), key: .init(bot: bot.id, target: session), start: .now)
    #expect(bot.messages.filter { $0.presentation == .botMessage && $0.role == .system }.count == 2)
    #expect(history(store, bot).map(\.content) == ["earlier"])
}

@Test @MainActor func anOrientationGivenUpIsATaggedLineNeverHistory() async {
    let (store, bot) = lineStore()
    var clock = Date(timeIntervalSince1970: 7_000_000); store.now = { clock }
    store.queueOrientation(bot)
    clock += 25 * 3600; await store.orient(bot)
    #expect(bot.messages.map(\.content) == [OrientationCopy.gaveUp(bot.name)] && bot.messages[0].metadata[AppOnlyLine.key] == "1")
    #expect(history(store, bot).isEmpty)
}

// MARK: the wire

@Test @MainActor func onlyIntentSystemRowsReachTheLegacyCompletionsPayload() async throws {
    let (store, bot) = lineStore()
    bot.messages = [ChatMessage(role: .user, content: "earlier"), ChatMessage(role: .assistant, content: "ok", turnState: .finished)]
        + preBacklog10Lines.map(untagged) + preBacklog10Lines.map(AppOnlyLine.line) + intentLines.map(untagged)
        + [ChatMessage(role: .user, content: "now")]
    store.postArrival(from: "fixture-sender-b10", recipient: bot, session: "b10-wire-\(UUID().uuidString)")
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8)) }
    for try await _ in try await backend.send(.init(sessionID: "backlog10-\(UUID().uuidString)", systemPrompt: "p", messages: history(store, bot))) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/chat/completions" }?.body)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let contents = messages.compactMap { $0["content"] as? String }
    for text in preBacklog10Lines { #expect(!contents.contains { $0.contains(text) }, "on the wire: \(text)") }
    #expect(!contents.contains { $0.contains("fixture-sender-b10") || $0.contains("wrote to") })
    let systems = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }
    #expect(systems.count == 1 + intentLines.count && Array(systems.dropFirst()) == intentLines, "the persona, then only the intent lines")
    #expect(messages.count == 1 + 3 + intentLines.count)
}
