import Foundation
import Testing
@testable import AgentApp

// P45 1: the composer's `/` menu and the basic commands. Scripted backend; no network.

@Test func theMenuFiltersAsYouTypeAndClosesAtTheFirstSpace() {
    #expect(SlashMenu.matches(for: "/") == SlashCommand.menu)
    #expect(SlashMenu.matches(for: "/st") == [.stop, .status])
    #expect(SlashMenu.matches(for: "/RE") == [.retry])
    #expect(SlashMenu.matches(for: "/tus") == [.status], "contains, after the prefix matches")
    #expect(SlashMenu.matches(for: "/zz") == [])
    #expect(SlashMenu.matches(for: "/model gpt") == nil && SlashMenu.matches(for: "hello /st") == nil)
    #expect(SlashMenu.completion(for: .model) == "/model " && SlashMenu.completion(for: .help) == "/help")
}

@Test func arrowKeysWrapAndEscClosesUntilTheTextChanges() {
    var state = SlashMenuState()
    let matches = state.matches(for: "/", commands: SlashCommand.menu)
    state.move(-1, count: matches.count)
    #expect(state.current(in: matches) == SlashCommand.menu.last)
    state.move(1, count: matches.count); state.move(1, count: matches.count)
    #expect(state.current(in: matches) == .new)
    #expect(state.current(in: [.stop]) == .stop, "clamped when the list shrinks")
    state.dismissedAt = "/s"
    #expect(!state.isOpen(for: "/s", commands: SlashCommand.menu) && state.matches(for: "/s", commands: SlashCommand.menu).isEmpty)
    #expect(state.isOpen(for: "/st", commands: SlashCommand.menu))
    #expect(!SlashMenuState().isOpen(for: "/", commands: []), "no commands (groups): no menu")
}

@Test func inputIsACommandAnUnknownCommandOrAMessage() {
    #expect(SlashInput("/help") == .command(.help, arguments: ""))
    #expect(SlashInput("  /Model  gpt-5.5 ") == .command(.model, arguments: "gpt-5.5"))
    #expect(SlashInput("/frobnicate now") == .unknown("frobnicate"))
    #expect(SlashInput("/usr/bin/env is missing") == .message, "a path is not a command")
    #expect(SlashInput("/") == .message && SlashInput("hello") == .message)
}

@MainActor @Test func anUnknownCommandIsSentAsTextAfterAWarning() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    #expect(store.submitComposer(text: "/frobnicate now"))
    try await backend.calls.wait { $0.contains("send:/frobnicate now") }
    let rows = bot.messages.map { "\($0.role.rawValue):\($0.content)" }
    #expect(Array(rows.prefix(2)) == ["system:\(SlashInput.unknownWarning)", "user:/frobnicate now"])
    await backend.emit(.token("ok"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func helpAndStatusAreLocalLinesTheBotNeverSees() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    bot.messages = [ChatMessage(role: .user, content: "hi there"), ChatMessage(role: .assistant, content: "hello", turnState: .finished)]
    #expect(store.submitComposer(text: "/help"))
    let help = try #require(bot.messages.last)
    #expect(help.role == .system && help.metadata[SlashKey.line] == "1" && help.content.contains("/retry — Retry the last reply"))
    #expect(store.submitComposer(text: "/status"))
    let status = try #require(bot.messages.last?.content)
    #expect(status.contains("Model: not known yet") && status.contains("Context: 2 messages") && status.contains("Reply: idle"))
    #expect(backend.calls.all.isEmpty)
    // The next real turn's history leaves both lines out.
    let reply = ChatMessage(role: .assistant, content: "")
    #expect(store.chatHistory(bot, excluding: reply).map(\.content) == ["hi there", "hello"])
}

@MainActor @Test func newWithoutAForkableSessionSaysWhatItNeeds() {
    let (store, bot) = steerStore(ScriptedTurnBackend())
    #expect(store.submitComposer(text: "/new"))
    #expect(bot.messages.last?.content.hasPrefix("A new thread needs a reply") == true && store.openThreadID == nil)
}

@MainActor @Test func modelWithoutANameShowsTheCurrentOneAndAnUnknownNameSendsNothing() {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    #expect(store.submitComposer(text: "/model"))
    #expect(bot.messages.last?.content == "Model: not known yet. Type /model <name> to switch.")
    #expect(store.submitComposer(text: "/model nonexistent-9"))
    #expect(bot.messages.last?.content.hasPrefix("No model named nonexistent-9") == true)
    #expect(backend.calls.all.isEmpty)
}

@MainActor @Test func retrySendsTheLastMessageAgainAndStopStopsTheReply() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
    #expect(store.submitComposer(text: "count to three"))
    try await backend.calls.wait { $0.contains("send:count to three") }
    await backend.emit(.token("1 2 3"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.submitComposer(text: "/retry"))
    try await waitUntil { await backend.streamCount == 2 }
    #expect(bot.messages.filter { $0.role == .user }.map(\.content) == ["count to three", "count to three"])
    #expect(store.submitComposer(text: "/stop"))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("stop:") } }
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.submitComposer(text: "/stop"))
    #expect(bot.messages.last?.content == "Nothing is running in this chat.")
}
