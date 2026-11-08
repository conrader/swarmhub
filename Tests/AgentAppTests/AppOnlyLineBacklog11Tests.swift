import Foundation
import Testing
@testable import AgentApp

// backlog11: the plain `system` rows backlog10 left unchecked. `insertNote` lines (a skipped default model, a compacted
// resend) reached the legacy v1/chat/completions payload and are now app-only. Skill-install result lines, the
// context-recovery new-session line, a group's "was skipped" lines and P39's "Waiting" line already stayed out; these
// tests pin that. Approved/Declined (manual and automatic) and stop lines stay. Fixture names are synthetic.

/// Texts builds before backlog11 saved with no tag. Frozen on purpose: a reworded producer must keep its old template
/// in `AppOnlyLine.legacy`, or saved rows leak again.
private let preBacklog11Lines = [
    "\(AppConstants.name)'s default model fixture-model was not applied: fixture-model isn't offered by this agent. This chat runs on the agent default.",
    // P17 (2026-10-14) reworded "box default" to "agent default"; the app was still Torvli the day before.
    "Torvli's default model fixture-model was not applied: Hermes cannot route fixture-model for this chat. This chat runs on the box default.",
    "Conversation was compacted to fit the model; your message was sent again.",
]

/// Kept: intent lines, including an automatic decision and ones that quote a note's words.
private let keptSystemLines = [
    "Approved: \(AppConstants.name)'s default model fixture-model was not applied: x. This chat runs on the agent default.",
    "Declined: Conversation was compacted to fit the model; your message was sent again.",
    "Stop requested from Hermes.",
]

private func untagged(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }

@MainActor private func noteStore() -> (AppStore, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let bot = Bot(name: "Fixture-\(UUID().uuidString.prefix(8))", backend: .hermes, hermesProfile: "fixture-backlog11")
    store.bots = [bot]
    return (store, bot)
}

@MainActor private func history(_ store: AppStore, _ bot: Bot) -> [(role: String, content: String)] {
    store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: ""))
}

// MARK: drift: producer ⇄ filter

@Test func notesStillRenderThePreBacklog11TextTheFilterMatches() {
    // The model note's real producer (`skipModel`) is pinned end to end in ModelCatalogPerBotTests; here its template is.
    let produced = [AppOnlyLine.modelNotApplied.render(AppConstants.name, "fixture-model", "fixture-model isn't offered by this agent."),
                    AppOnlyLine.modelNotAppliedBoxDefault.render("Torvli", "fixture-model", "Hermes cannot route fixture-model for this chat."),
                    TurnErrorCopy.compacted]
    #expect(produced == preBacklog11Lines)
    for text in preBacklog11Lines { #expect(AppOnlyLine.isAppOnly(untagged(text)), "untagged saved row leaks: \(text)") }
    for text in keptSystemLines { #expect(!AppOnlyLine.isAppOnly(untagged(text)), "intent line dropped: \(text)") }
    #expect(!AppOnlyLine.modelNotApplied.matches("'s default model  was not applied:  This chat runs on the agent default."))
}

/// The notes' wording lives in `AppOnlyLine` only; a producer that spells it out again would drift from the filter.
@Test func noProducerWritesANoteAsALiteral() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentApp")
    let fragments = ["This chat runs on the agent default", "This chat runs on the box default", "compacted to fit the model"]
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
    #expect(files.count > 100)
    for file in files where file.lastPathComponent != "AppOnlyLine.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for fragment in fragments { #expect(!text.contains(fragment), "\"\(fragment)\" written as a literal in \(file.lastPathComponent)") }
        // `insertNote` writes through `AppOnlyLine.line`, never a bare system row.
        if file.lastPathComponent == "AppStore+ModelPolicy.swift" { #expect(!text.contains("ChatMessage(role: .system, content: text)")) }
    }
}

// MARK: per row type

@Test @MainActor func insertNoteWritesATaggedLineThatIsNeverHistory() {
    let (store, bot) = noteStore()
    let user = ChatMessage(role: .user, content: "hi"), assistant = ChatMessage(role: .assistant, content: "")
    bot.messages = [user, assistant]
    store.insertNote(preBacklog11Lines[0], in: bot, before: assistant)
    store.insertNote(TurnErrorCopy.compacted, in: bot, before: assistant)
    #expect(bot.messages.map(\.content) == ["hi", preBacklog11Lines[0], TurnErrorCopy.compacted, ""])
    #expect(bot.messages.filter { $0.role == .system }.allSatisfy { $0.metadata[AppOnlyLine.key] == "1" })
    #expect(store.chatHistory(bot, excluding: assistant).map(\.content) == ["hi"])
}

@Test @MainActor func untaggedNotesSavedBeforeBacklog11AreNeverHistory() {
    let (store, bot) = noteStore()
    bot.messages = [ChatMessage(role: .user, content: "earlier")] + preBacklog11Lines.map(untagged) + keptSystemLines.map(untagged) + [ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot).map(\.content) == ["earlier"] + keptSystemLines + ["now"])
}

@Test @MainActor func skillInstallResultLinesAlreadyStayOut() {
    let (store, manager) = noteStore()
    let scout = Bot(name: "Fixture Scout", backend: .hermes, hermesProfile: "fixture-scout-b11"); store.bots.append(scout)
    manager.messages = [ChatMessage(role: .user, content: "install skills")]
    store.recordSkillInstallResult(.init(status: .installed, detail: "Installed fixture-skill."), bot: scout, manager: manager)
    store.recordSkillInstallResult(.init(status: .failed, detail: "fixture-skill failed."), bot: scout, manager: manager)
    // The shape the first build (957233d, 2026-10-21) saved: the key was there from the start, as a literal.
    manager.messages.append(ChatMessage(role: .system, content: "Fixture Scout (fixture-scout-b11): old", metadata: [TurnKey.tone: "warning", "skill-install-result": scout.id.uuidString]))
    #expect(manager.messages.filter { $0.role == .system }.count == 3)
    #expect(history(store, manager).map(\.content) == ["install skills"])
}

@Test @MainActor func theNewSessionLineAlreadyStaysOutAndIsTheBoundary() {
    let (store, bot) = noteStore()
    for text in [TurnErrorCopy.newSession, TurnErrorCopy.newSessionNotSent] {
        bot.messages = [ChatMessage(role: .user, content: "before"), ChatMessage(role: .assistant, content: "old", turnState: .finished),
                        ChatMessage(role: .system, content: text, metadata: [ContextKey.boundary: "1"]), ChatMessage(role: .user, content: "after")]
        #expect(history(store, bot).map(\.content) == ["after"])
    }
}

@Test func aGroupsSkippedLinesNeverReachAMembersContext() {
    // `groupTurn` sends `GroupRouting.context` as its one message; group chats never go through `chatHistory`.
    let me = GroupRouting.Member(id: UUID(), name: "Fixture Ada"), other = GroupRouting.Member(id: UUID(), name: "Fixture Scout")
    let skipped = ["Fixture Scout was skipped: no key for fixture-scout.", "Fixture Scout was skipped: fixture refusal",
                   "Not sent to Fixture Scout (offline).", "Stopped. Skipped: Fixture Scout."]
    let messages = [ChatMessage(role: .user, content: "@all hi")] + skipped.map(untagged) + [ChatMessage(role: .user, content: "@ada now")]
    let context = GroupRouting.context(for: me, groupName: "Fixture Team", members: [me, other], messages: messages)
    let user = GroupRouting.defaultUserName
    #expect(context.hasSuffix("\(user): @all hi\n\(user): @ada now"))
    for line in skipped { #expect(!context.contains(line), "in a member's context: \(line)") }
}

@Test @MainActor func aWaitLineACrashLeftBehindIsNeverHistoryButItsMessageIs() {
    let (store, bot) = noteStore()
    let waiting = ChatMessage(role: .user, content: "queued", metadata: [TurnWaitCopy.key: "waiting"])
    bot.messages = [waiting, ChatMessage(role: .system, content: TurnWaitCopy.behind, metadata: [TurnWaitCopy.key: "line"]),
                    ChatMessage(role: .system, content: "Waiting: 6 replies are already running.", metadata: [TurnWaitCopy.key: "line"]),
                    ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot).map(\.content) == ["queued", "now"])
}

@Test @MainActor func automaticApprovalDecisionsStayInHistory() {
    let (store, bot) = noteStore()
    let auto = ChatMessage(role: .system, content: "Approved automatically: Run git log", presentation: .approvalDecision, metadata: ["approvalOutcome": "approved"])
    bot.messages = [ChatMessage(role: .user, content: "earlier"), auto, ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot).map(\.content) == ["earlier", "Approved automatically: Run git log", "now"])
}

// MARK: the wire

@Test @MainActor func noNoteReachesTheLegacyCompletionsPayload() async throws {
    let (store, bot) = noteStore()
    let scout = Bot(name: "Fixture Scout", backend: .hermes, hermesProfile: "fixture-scout-b11w"); store.bots.append(scout)
    let assistant = ChatMessage(role: .assistant, content: "")
    bot.messages = [ChatMessage(role: .user, content: "before the boundary"),
                    ChatMessage(role: .system, content: TurnErrorCopy.newSession, metadata: [ContextKey.boundary: "1"]),
                    ChatMessage(role: .user, content: "earlier"), ChatMessage(role: .assistant, content: "ok", turnState: .finished)]
        + preBacklog11Lines.map(untagged) + keptSystemLines.map(untagged)
        + [ChatMessage(role: .system, content: "Approved automatically: Run git log", presentation: .approvalDecision),
           ChatMessage(role: .system, content: TurnWaitCopy.behind, metadata: [TurnWaitCopy.key: "line"]),
           ChatMessage(role: .user, content: "now"), assistant]
    store.insertNote(preBacklog11Lines[0], in: bot, before: assistant)
    store.insertNote(TurnErrorCopy.compacted, in: bot, before: assistant)
    store.recordSkillInstallResult(.init(status: .installed, detail: "Installed fixture-skill."), bot: scout, manager: bot)
    let (host, backend) = ChatParityServer.serve(features: [:]) { _, _ in ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8)) }
    let rows = store.chatHistory(bot, excluding: assistant)
    for try await _ in try await backend.send(.init(sessionID: "backlog11-\(UUID().uuidString)", systemPrompt: "p", messages: rows)) {}
    let body = try #require(ChatParityServer.requests(host).first { $0.path == "/v1/chat/completions" }?.body)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let contents = messages.compactMap { $0["content"] as? String }
    for text in preBacklog11Lines + [TurnErrorCopy.newSession, TurnWaitCopy.behind] { #expect(!contents.contains(text), "on the wire: \(text)") }
    #expect(!contents.contains { $0.contains("Installed fixture-skill") || $0 == "before the boundary" })
    let systems = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }
    #expect(systems == ["p"] + keptSystemLines + ["Approved automatically: Run git log"], "the persona, then only the intent lines")
    #expect(messages.filter { $0["role"] as? String != "system" }.compactMap { $0["content"] as? String } == ["earlier", "ok", "now"])
}
