import Foundation
import Testing
@testable import AgentApp

// P51: technical rows fold into one line, whatever wrote them. All rows are synthetic (shaped like a real store's).

private let marker = "[[SWARMHUB_APP_REQUEST_C687FDE6-BD8F-4E9E-B3B1-098F2863562C]]"
private var context: TechnicalContext { TechnicalContext(botName: "Jarvis", displayName: { ["grok-infra": "Infra", "grok-jarvis": "Jarvis"][$0] ?? $0 }) }
/// Metadata of a row the P16 reconcile adopted from the box, and of one this app wrote while streaming.
private let adopted = ["box": "3761", "restored": "added"], written = ["run": "run_0c0f0739e0aa41eaad0553b07184a1d7", "status": "terminal"]

private func search(_ metadata: [String: String]) -> ChatMessage {
    ChatMessage(role: .assistant, content: marker + "\n{\"action\":\"search\",\"query\":\"Read the authenticated GitHub user\"}", metadata: metadata)
}
private func execute(_ metadata: [String: String], account: String? = nil) -> ChatMessage {
    let account = account.map { ",\"account\":\"\($0)\"" } ?? ""
    return ChatMessage(role: .assistant, content: marker + "\n{\"action\":\"execute\",\"tool\":\"GITHUB_GET_THE_AUTHENTICATED_USER\",\"arguments\":{}\(account)}", metadata: metadata)
}
private func result(_ json: String, _ metadata: [String: String]) -> ChatMessage {
    ChatMessage(role: .user, content: ConnectedAppsChat.resultPrefix + json + "\nContinue the original task. Use the app request format only if another app call is needed.", metadata: metadata)
}
private let toolsJSON = #"{"tools":[{"app":"github","slug":"GITHUB_GET_THE_AUTHENTICATED_USER","description":"Get the user"},{"app":"github","slug":"GITHUB_LIST_REPOS"}],"accounts":{"github":["konrad"]}}"#
private let skillText = """
[IMPORTANT: The user has invoked the "agent-background-operations" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]

---
name: agent-background-operations
description: Synthetic skill body for tests.
---
# Background operations
Check the queue, then report.
"""

@Test(arguments: [adopted, written]) func anAppLookupAndItsResultFoldIntoOneLine(metadata: [String: String]) throws {
    let request = search(metadata), answer = result(toolsJSON, metadata), before = (request.content, answer.content)
    let layout = TechnicalRow.layout([request, answer], context: { _ in context })
    let fold = try #require(layout.folds[request.id])
    #expect(fold.kind == .appRequest && fold.summary == "Jarvis looked up GitHub tools · 2 found")
    #expect(fold.partnerID == answer.id && layout.absorbed == [answer.id], "the result row is part of the line")
    #expect(layout.visible([request, answer]).map(\.id) == [request.id])
    #expect(fold.original.contains(request.content) && fold.original.contains(answer.content), "unfold shows both")
    #expect((request.content, answer.content) == before, "content is never rewritten")
}

@Test(arguments: [adopted, written]) func anAppExecuteFoldsOkFailedOrWaiting(metadata: [String: String]) throws {
    let ok = [execute(metadata), result(#"{"data":{"login":"octo"},"successful":true}"#, metadata)]
    #expect(TechnicalRow.layout(ok, context: { _ in context }).folds[ok[0].id]?.summary == "Jarvis used GitHub · Get the authenticated user · ok")
    let failure = AppRequestFailure(error: ComposioError.http(400), tool: "Get the authenticated user", text: "Composio request failed (HTTP 400).")
    let failed = [execute(metadata, account: "konrad@work"), result(failure.botResult, metadata)]
    #expect(TechnicalRow.layout(failed, context: { _ in context }).folds[failed[0].id]?.summary == "Jarvis used GitHub (konrad@work) · Get the authenticated user · failed")
    let waiting = execute(metadata)
    #expect(TechnicalRow.layout([waiting], context: { _ in context }).folds[waiting.id]?.summary == "Jarvis used GitHub · Get the authenticated user · waiting for approval")
    let later = [execute(metadata), ChatMessage(role: .assistant, content: "I could not reach GitHub.")]
    #expect(TechnicalRow.layout(later, context: { _ in context }).folds[later[0].id]?.summary.hasSuffix("· no result") == true)
}

@Test func anAccountIDReadsAsItsP48Name() throws {
    var named = context; named.accountName = { $0 == "ca_123" ? "Gmail · konrad@example.com" : nil }
    let row = ChatMessage(role: .assistant, content: marker + #"{"action":"execute","tool":"GMAIL_SEND_EMAIL","account":"ca_123","arguments":{}}"#)
    #expect(TechnicalRow.classify(row, isLast: true, context: named)?.summary == "Jarvis used Gmail (Gmail · konrad@example.com) · Send email · waiting for approval")
}

@Test func aResultAloneFoldsAndUnfoldPrettyPrints() throws {
    let row = result(toolsJSON, adopted)
    #expect(TechnicalRow.classify(row, context: context)?.summary == "Jarvis got an app result · ok")
    let parts = TechnicalApps.parts(request: search([:]).content, result: row.content)
    #expect(parts.map(\.title) == ["Request", "Result"])
    #expect(parts[1].text.hasPrefix("{\n  \"accounts\""), "pretty-printed, keys sorted")
    #expect(parts[1].text.hasSuffix("Continue the original task. Use the app request format only if another app call is needed."))
    let long = String(repeating: "x", count: 9_000)
    #expect(TechnicalApps.capped(long, all: false).cut && TechnicalApps.capped(long, all: false).text.count < 4_200)
    #expect(TechnicalApps.capped(long, all: true) == (long, false))
}

@Test(arguments: [adopted, written]) func skillLoadingTextFoldsWithItsWakeLabel(metadata: [String: String]) throws {
    let plain = ChatMessage(role: .user, content: skillText, metadata: metadata)
    #expect(TechnicalRow.classify(plain, context: context)?.summary == "Uses skill agent-background-operations")
    let heartbeat = ChatMessage(role: .user, content: skillText, metadata: metadata.merging([AutomationKey.woken: "heartbeat"]) { $1 })
    let fold = try #require(TechnicalRow.classify(heartbeat, context: context))
    #expect(fold.kind == .skill && fold.summary == "Heartbeat · uses skill agent-background-operations" && fold.original == skillText)
    let routine = ChatMessage(role: .user, content: skillText, metadata: [AutomationKey.woken: "routine Payment check"])
    #expect(TechnicalRow.classify(routine, context: context)?.summary == "Routine Payment check · uses skill agent-background-operations")
}

@Test(arguments: [adopted, written]) func botToBotMessagesFoldToTheirFirstLine(metadata: [String: String]) throws {
    let asked = ChatMessage(role: .user, content: "[Message from grok-infra via SwarmHub]\n\n  Can you check   the disk?\nIt is at 91%.", metadata: metadata)
    let fold = try #require(TechnicalRow.classify(asked, context: context))
    #expect(fold.kind == .botMessage && fold.summary == "Infra → Jarvis: Can you check the disk?" && fold.profile == "grok-infra")
    let replied = ChatMessage(role: .user, content: "[Reply from grok-infra via SwarmHub]\nDone, 40% free now.", metadata: metadata)
    #expect(TechnicalRow.classify(replied, context: context)?.summary == "Infra replied: Done, 40% free now.")
}

@Test func p42ExchangeCardsFoldAndRoutineCardsStay() throws {
    let card = ChatMessage(role: .assistant, content: "Jarvis wrote to Infra", presentation: .botMessage,
                           metadata: [BotWorkKey.origin: "bot:grok-jarvis", BotMessageKey.from: "grok-jarvis", BotMessageKey.to: "grok-infra",
                                      BotWorkKey.request: "Please rotate the logs.\nThen tell me.", BotWorkKey.reply: "Rotated."])
    let fold = try #require(TechnicalRow.classify(card, context: TechnicalContext(botName: "Infra", displayName: context.displayName)))
    #expect(fold.summary == "Jarvis → Infra: Please rotate the logs." && fold.original == "Please rotate the logs.\nThen tell me.\n\nRotated.")
    let routine = ChatMessage(role: .assistant, content: "", presentation: .botMessage, metadata: [BotWorkKey.origin: "routine:Morning report"])
    #expect(TechnicalRow.classify(routine, context: context) == nil)
}

@Test func otherWrappersShowTheirLabel() throws {
    let cron = ChatMessage(role: .user, content: "[Cronjob \"jarvis-hourly-heartbeat-cet\" output — scheduled job, not the user. Review it.]\n\nAll quiet.", metadata: adopted)
    #expect(TechnicalRow.classify(cron, context: context)?.summary == "Heartbeat")
    cron.metadata[AutomationKey.display] = "Routine: nightly"
    #expect(TechnicalRow.classify(cron, context: context)?.summary == "Routine: nightly", "the P46 label wins")
    let ack = ChatMessage(role: .assistant, content: "SB_CONTEXT_RECEIVED\n", metadata: adopted)
    #expect(TechnicalRow.classify(ack, context: context)?.kind == .ack && TechnicalRow.classify(ack, context: context)?.summary == "Context received")
    let wrapped = ChatMessage(role: .user, content: "[OUT-OF-BAND USER MESSAGE from Konrad]\nStop after this file\n[/OUT-OF-BAND USER MESSAGE]")
    #expect(TechnicalRow.classify(wrapped, context: context)?.summary == "Sent while Jarvis was working: Stop after this file")
}

@Test func normalMessagesNeverFold() throws {
    let normal = [
        "SwarmHub app results look fine to me; the SwarmHub bot agrees.",
        "Here is the code:\n```swift\nlet x = 1\n```",
        "```json\n{\"action\":\"search\",\"query\":\"x\"}\n```",
        "Use [[SWARMHUB_APP_REQUEST_<uuid>]] only at the start.",
        "[Message from the past] hello",
        "OK", "NASA", "I said SB_CONTEXT_RECEIVED earlier.",
        "[IMPORTANT] read this first",
        "I mentioned [Message from grok-infra via SwarmHub] in my notes."
    ]
    for text in normal {
        for role in [MessageRole.user, .assistant] {
            #expect(TechnicalRow.classify(ChatMessage(role: role, content: text), context: context) == nil, "\(role): \(text)")
        }
    }
    #expect(TechnicalRow.classify(ChatMessage(role: .assistant, content: skillText), context: context) == nil, "an assistant quoting the skill text")
}

@Test func swarmhubBlocksReadAsOneLineFromTheirOps() throws {
    let one = "Installed the manager’s skills.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"1.0.0\"}]}\n```"
    #expect(SwarmhubSummary.lines(in: one) == [.init(summary: "Installed swarmhub-manager 1.0.0 on grok-jarvis",
                                                      block: "{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"1.0.0\"}]}")])
    #expect(SwarmhubBlock.visibleText(one) == "Installed the manager’s skills.", "the prose stays, the block is gone")
    let many = "Done.\n```swarmhub\n[{\"op\":\"skills_installed\",\"bot\":\"grok-boppy\",\"skills\":[{\"name\":\"swarmhub-feedback\",\"version\":\"1.0.0\"},{\"name\":\"swarmhub-messages\",\"version\":\"1.1.0\"}]},{\"op\":\"models_changed\",\"model\":\"gpt-6.1-sol\",\"count\":23},{\"op\":\"avatar\",\"name\":\"cfo\"}]\n```"
    #expect(SwarmhubSummary.lines(in: many).map(\.summary) == ["Skills installed on grok-boppy: swarmhub-feedback 1.0.0, swarmhub-messages 1.1.0 · Switched 23 bots to gpt-6.1-sol · 1 more"])
    #expect(SwarmhubSummary.lines(in: "```swarmhub\n{not json\n```").map(\.summary) == ["SwarmHub update"])
    #expect(SwarmhubSummary.lines(in: "```swift\nlet op = 1\n```").isEmpty, "other fences are code")
    let bare = ChatMessage(role: .assistant, content: "```swarmhub\n{\"op\":\"bot_created\",\"name\":\"scout\"}\n```")
    #expect(TechnicalRow.displayLine(bare, context: context) == "Created bot scout", "a reply that is only a block reads as its line")
}

@MainActor @Test func anExistingStoreWithSuchRowsLoadsFolded() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bot = Bot(name: "Jarvis", backend: .hermes)
    bot.messages = [search(adopted), result(toolsJSON, adopted), ChatMessage(role: .user, content: skillText, metadata: [AutomationKey.woken: "heartbeat"]),
                    ChatMessage(role: .assistant, content: "Queue is empty.")]
    try JSONEncoder().encode(StoreFile(bots: [bot], groups: [])).write(to: url)
    let loaded = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let rows = try #require(loaded.bots.first?.messages)
    #expect(rows.map(\.content) == bot.messages.map(\.content), "loaded as written")
    let layout = TechnicalRow.layout(rows, context: { _ in TechnicalContext(botName: "Jarvis") })
    #expect(layout.visible(rows).map { layout.folds[$0.id]?.summary ?? $0.content } == [
        "Jarvis looked up GitHub tools · 2 found", "Heartbeat · uses skill agent-background-operations", "Queue is empty."])
}
