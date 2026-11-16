import Foundation
import Testing
@testable import AgentApp

// Lines the app writes into a chat for the person only are never sent to an agent as history; the Stop lines carry
// the person's intent and stay.

@MainActor private func lineStore() -> (AppStore, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in TestBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .herdr); store.bots = [bot]
    return (store, bot)
}

@MainActor private func history(_ store: AppStore, _ bot: Bot) -> [String] {
    store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: "")).map(\.content)
}

@Test func aTemplateRendersAndMatchesItsOwnLines() {
    let line = AppOnlyLine.botAskPassedOn.render("Boppy", "Research", "Jarvis")
    #expect(line == "Boppy asked for a bot named “Research”. The request was passed on to Jarvis, the main bot.")
    #expect(AppOnlyLine.botAskPassedOn.matches(line) && !AppOnlyLine.created.matches("no such line") && AppOnlyLine.created.matches("Jarvis created Research"))
    #expect(!AppOnlyLine.botRemoved.matches("You removed , which  had created."), "a gap holds at least one character")
}

@MainActor @Test func appOnlyLinesAreShownButNeverSentAsHistory() {
    let (store, bot) = lineStore()
    let waiting = ChatMessage(role: .system, content: TurnWaitCopy.behind, metadata: [TurnWaitCopy.key: "line"])
    let warning = ChatMessage(role: .system, content: "Jarvis: offline", metadata: [TurnKey.tone: "warning"])
    bot.messages = [ChatMessage(role: .user, content: "earlier"), AppOnlyLine.line(AppOnlyLine.created.render("Jarvis", "Research")),
                    ReconcileNote.line(ReconcileNote.uncertainQueuePrefix + "hello"), waiting, warning, ChatMessage(role: .user, content: "now")]
    #expect(history(store, bot) == ["earlier", "now"])
    #expect(bot.messages.count == 6, "the lines stay in the chat")
    for row in bot.messages.dropFirst().dropLast(2) { #expect(AppOnlyLine.isAppOnly(row)) }
    #expect(!AppOnlyLine.isAppOnly(bot.messages[0]) && !AppOnlyLine.isAppOnly(warning), "a warning is left out by its tone, not as an app-only line")
}

@MainActor @Test func stopLinesStayInHistory() {
    let (store, bot) = lineStore()
    let stops = [IntentLine.stopRequested.render("Herdr"), IntentLine.stoppedBeforeRunID.render("Herdr"), IntentLine.stoppedNoRunControl.render(),
                 IntentLine.stopFailed.render("Herdr", "the agent did not answer")]
    bot.messages = [ChatMessage(role: .user, content: "go")] + stops.map { ChatMessage(role: .system, content: $0) } + [ChatMessage(role: .user, content: "again")]
    #expect(history(store, bot) == ["go"] + stops + ["again"])
    for stop in stops { #expect(IntentLine.matches(stop), "\(stop)") }
    #expect(!IntentLine.matches("Jarvis created Research"))
}
