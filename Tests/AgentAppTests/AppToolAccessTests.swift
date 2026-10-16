import Foundation
import Testing
@testable import AgentApp

/// P52 item 1: read-only app actions run without a card and show as one folded line; anything that may change something
/// still asks. Composio is `MockHermesProtocol`; nothing reaches the network.

@Test func theBriefsExamplesClassifyBothWays() {
    for slug in ["GMAIL_FETCH_EMAILS", "GMAIL_GET_PROFILE", "GITHUB_GET_THE_AUTHENTICATED_USER", "GITHUB_LIST_REPOSITORIES_FOR_THE_AUTHENTICATED_USER",
                 "GITHUB_WHO_AM_I", "GOOGLEDRIVE_DOWNLOAD_FILE", "SLACK_SEARCH_MESSAGES"] {
        let app = String(slug.prefix { $0 != "_" }).lowercased()
        #expect(AppToolAccess.classify(slug: slug, toolkit: app, tags: []) == .read, "\(slug) runs")
    }
    for slug in ["GMAIL_SEND_EMAIL", "GITHUB_RUN_GRAPH_QL_QUERY", "GITHUB_UPDATE_THE_AUTHENTICATED_USER", "GITHUB_STAR_A_REPOSITORY_FOR_THE_AUTHENTICATED_USER",
                 "GITHUB_FOLLOW_A_USER", "GMAIL_GET_AND_TRASH_MESSAGE", "GITHUB_LIST_AND_MERGE_PULLS", "GOOGLEDRIVE_GET_AND_SHARE_FILE"] {
        let app = String(slug.prefix { $0 != "_" }).lowercased()
        #expect(AppToolAccess.classify(slug: slug, toolkit: app, tags: []) == .write, "\(slug) asks")
    }
}

@Test func anUnknownActionAsks() {
    #expect(AppToolAccess.classify(slug: "NOTION_ARCHIVE_PAGE", toolkit: "notion", tags: []) == .write)
    #expect(AppToolAccess.classify(slug: "SLACK_CONVERSATIONS_HISTORY", toolkit: "slack", tags: []) == .write, "no read word: asks")
    #expect(AppToolAccess.classify(slug: "GITHUB", toolkit: "github", tags: []) == .write, "no action part: asks")
    #expect(AppToolAccess.classify(slug: "GCAL_GET_EVENT", toolkit: "googlecalendar", tags: ["readOnlyHint"]) == .write, "a slug without its app prefix asks")
}

@Test func tagsWinOverNamesWhenPresent() {
    #expect(AppToolAccess.classify(slug: "GITHUB_GET_THE_AUTHENTICATED_USER", toolkit: "github", tags: ["destructiveHint"]) == .write)
    #expect(AppToolAccess.classify(slug: "SLACK_CONVERSATIONS_HISTORY", toolkit: "slack", tags: ["readOnlyHint"]) == .read)
    #expect(AppToolAccess.classify(slug: "GITHUB_RUN_GRAPH_QL_QUERY", toolkit: "github", tags: ["readOnlyHint"]) == .write, "a deny word still asks")
    #expect(AppToolAccess.classify(slug: "X_GET_ITEM", toolkit: "x", tags: ["readOnlyHint", "destructive_hint"]) == .write, "write tags beat read tags")
    let tool = try! #require(ComposioTool(.object(["slug": .string("SLACK_CONVERSATIONS_HISTORY"), "toolkit": .object(["slug": .string("slack")]),
                                                   "input_parameters": .object([:]), "tags": .array([.string("readOnlyHint"), .number(1)])])))
    #expect(tool.tags == ["readOnlyHint"])
}

@MainActor @Test func eachToolIsClassifiedOncePerSlug() async throws {
    let (apps, _, _) = composioFixture()
    let tool = try #require(ComposioTool(.object(["slug": .string("GMAIL_FETCH_EMAILS"), "toolkit": .object(["slug": .string("gmail")]), "input_parameters": .object([:])])))
    #expect(apps.access(of: tool) == .read && apps.toolAccess == ["GMAIL_FETCH_EMAILS": .read])
    apps.toolAccess["GMAIL_FETCH_EMAILS"] = .write
    #expect(apps.access(of: tool) == .write, "the cached answer is used")
}

@MainActor @Test func aReadRunsWithoutACardAndShowsAFoldedLine() async throws {
    let (apps, host, _) = composioFixture(handler: composioReadHandler); await apps.refresh()
    let backend = AppRequestBackend(.read)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat")
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.send(text: "Read my inbox"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.approvals.isEmpty && !bot.messages.contains { $0.content.hasPrefix("Approved") }, "no approval card")
    #expect(MockHermesProtocol.recorded(host).filter { $0.url!.path.hasSuffix("/execute") }.count == 1)
    #expect(bot.messages.last { $0.role == .assistant }?.content == "Your inbox contains one message.")
    let line = try #require(bot.messages.first { $0.metadata[TechnicalKey.appRequest] != nil })
    let fold = try #require(store.technicalLayout(bot.messages, botName: bot.name).folds[line.id])
    #expect(fold.kind == .appRequest && fold.summary == "Plainsay used Gmail · Fetch emails · ok")
    #expect(fold.original.contains("GMAIL_FETCH_EMAILS") && fold.original.contains("synthetic inbox") && !fold.original.contains("never-copy"))
    #expect(store.technicalLine(line, botName: bot.name) == fold.summary, "previews use the line, never the raw request")
    let history = store.chatHistory(bot, excluding: ChatMessage(role: .assistant, content: ""))
    #expect(!history.contains { $0.content.contains("GMAIL_FETCH_EMAILS") }, "the line is display only, never sent to the bot as history")
    let receipt = try #require(apps.receipts.last)
    #expect(receipt.state == .succeeded && receipt.tool == "GMAIL_FETCH_EMAILS")
}

@MainActor @Test func aWriteStillShowsTheCardWithTheNewNote() async throws {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    let backend = AppRequestBackend()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat")
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.send(text: "Send the reply"))
    try await waitUntil { !store.approvals.isEmpty }
    let card = store.approvals[0]
    #expect(card.routeNote == "Changes in your apps ask you; reading runs on its own." && card.summary == "Gmail · ca_work")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") })
    #expect(!bot.messages.contains { $0.metadata[TechnicalKey.appRequest] != nil }, "a write is never a free-run line")
    store.decide(card, approved: false)
    try await waitUntil { !store.anyTurnRunning }
}

@Test func theRuleIsStatedInOneLine() {
    #expect(ConnectedAppsCopy.approvalRule == "Changes in your apps ask you; reading runs on its own.")
    #expect(ConnectedAppsCopy.composioExplanation.contains("Reading, such as checking your email, runs on its own"))
}
