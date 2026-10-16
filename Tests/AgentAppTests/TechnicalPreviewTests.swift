import Foundation
import Testing
@testable import AgentApp

// P51: sidebar previews, notifications, unread counts, reply quotes and Copy use the folded line, never raw protocol.
// Synthetic boxes and rows only.

private let marker = "[[SWARMHUB_APP_REQUEST_0D5A3C1E-7B2F-4C1A-9E8D-2F6B1A4C9E70]]"
private let lookup = marker + "\n{\"action\":\"search\",\"query\":\"Read the authenticated GitHub user\"}"
private let found = ConnectedAppsChat.resultPrefix + #"{"tools":[{"app":"github","slug":"GITHUB_GET_THE_AUTHENTICATED_USER"}]}"# + "\nContinue the original task. Use the app request format only if another app call is needed."
private let run = marker + "\n{\"action\":\"execute\",\"tool\":\"GITHUB_GET_THE_AUTHENTICATED_USER\",\"arguments\":{}}"

@Test func previewsUseTheFoldedLine() {
    let context = TechnicalContext(botName: "Jarvis")
    func preview(_ rows: [ChatMessage]) -> String { SidebarFragment.text(messages: rows, draft: nil, isWorking: false, archiveNewest: nil, technical: context) }
    #expect(preview([ChatMessage(role: .assistant, content: lookup), ChatMessage(role: .user, content: found)]) == "Jarvis looked up GitHub tools · 1 found",
            "the result row is its request's line, not \"You: SwarmHub app result…\"")
    #expect(preview([ChatMessage(role: .assistant, content: run)]) == "Jarvis used GitHub · Get the authenticated user · waiting for approval")
    let skill = ChatMessage(role: .user, content: "[IMPORTANT: The user has invoked the \"agent-background-operations\" skill, indicating they want you to follow its instructions.]\n# Body",
                            metadata: [AutomationKey.woken: "heartbeat"])
    #expect(preview([skill]) == "Heartbeat · uses skill agent-background-operations")
    #expect(preview([ChatMessage(role: .assistant, content: "Done.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"scout\",\"skills\":[{\"name\":\"swarmhub-messages\",\"version\":\"1.1.0\"}]}\n```")]) == "Done.")
    #expect(preview([ChatMessage(role: .assistant, content: "```swarmhub\n{\"op\":\"bot_retired\",\"name\":\"scout\"}\n```")]) == "Retired scout")
    #expect(preview([ChatMessage(role: .user, content: "[Message from infra via SwarmHub]\nDisk is at 91%")]) == "infra → Jarvis: Disk is at 91%")
    #expect(preview([ChatMessage(role: .user, content: "plain question")]) == "You: plain question", "normal rows as before")
    // A group names the author of each row.
    let author = UUID()
    let group = SidebarFragment.text(messages: [ChatMessage(role: .assistant, content: run, authorID: author)], draft: nil, isWorking: false, archiveNewest: nil,
                                     author: { $0 == author ? "Infra" : nil })
    #expect(group == "Infra used GitHub · Get the authenticated user · waiting for approval")
}

@MainActor @Test func copyAndQuotesNeverShowTheRawRow() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .hermes); store.bots = [bot]; store.selectedBot = bot
    let request = ChatMessage(role: .assistant, content: run)
    #expect(store.technicalLine(request) == "Jarvis used GitHub · Get the authenticated user · no result", "the composer quote and the reply line")
    let fold = try #require(TechnicalRow.classify(request, context: store.technicalContext(botName: bot.name)))
    #expect(fold.summary != request.content && fold.original == request.content, "Copy copies the line, Copy original the raw")
    let reply = ChatMessage(role: .assistant, content: "Your login is octo.\n```swarmhub\n{\"op\":\"report\",\"id\":\"r1\",\"kind\":\"bug\",\"title\":\"x\"}\n```")
    #expect(store.technicalLine(reply) == "Your login is octo.", "a normal reply's quote drops the block, as Copy reply does")
    #expect(request.content == run && reply.content.contains("```swarmhub"), "content unchanged")
}

@MainActor @Test func anAppPairCountsAsNoUnreadByItself() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], box = states[0], start = Date()
    await store.pollLiveRowsOnce(now: start)
    box.add("s-jarvis", "user", "Who am I on GitHub?")
    box.add("s-jarvis", "assistant", lookup, finish: "stop")
    box.add("s-jarvis", "user", found)
    box.add("s-jarvis", "assistant", run, finish: "stop")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(15))
    #expect(bot.messages.count == 6 && bot.messages.last?.content == run, "adopted from the box as they are")
    #expect(bot.unreadCount == 0, "the request rows count nothing")
    let rows = bot.messages.filter { !$0.isSilent }, layout = store.technicalLayout(rows, botName: bot.name)
    #expect(layout.visible(rows).compactMap { layout.folds[$0.id]?.summary } == ["Jarvis looked up GitHub tools · 1 found", "Jarvis used GitHub · Get the authenticated user · waiting for approval"])
    box.add("s-jarvis", "user", ConnectedAppsChat.resultPrefix + #"{"data":{"login":"octo"}}"# + "\nContinue the original task.")
    box.add("s-jarvis", "assistant", "You are octo on GitHub.", finish: "stop")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(30))
    #expect(bot.unreadCount == 1, "the answer counts once")
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil, technical: store.technicalContext(botName: bot.name)) == "You are octo on GitHub.")
    let after = store.technicalLayout(bot.messages, botName: bot.name)
    #expect(after.folds.values.map(\.summary).sorted() == ["Jarvis looked up GitHub tools · 1 found", "Jarvis used GitHub · Get the authenticated user · ok"])
}
