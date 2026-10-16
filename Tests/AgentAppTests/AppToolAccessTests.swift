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

@Test func toolsThatReachAnAddressAsk() {
    for slug in ["X_FETCH_URL", "X_GET_URL_CONTENT", "X_SEND_WEBHOOK", "X_GET_HTTP", "X_FETCH_HTTPS_PAGE", "X_GET_REQUEST", "X_LIST_CALLBACK",
                 "X_GET_REDIRECT", "X_GET_EMBED", "X_SCRAPE_PAGE", "X_CRAWL_SITE", "X_BROWSE", "X_NAVIGATE", "X_PING", "X_NOTIFY"] {
        #expect(AppToolAccess.classify(slug: slug, toolkit: "x", tags: ["readOnlyHint"]) == .write, "\(slug) asks")
    }
}

@Test func aReadWhoseArgumentsCouldCarryDataOutAsks() {
    let own: Set<String> = ["konrad@example.test"]
    func carries(_ arguments: ComposioValue) -> Bool { AppToolAccess.mayCarryDataOut(arguments, accountNames: own) }
    #expect(!carries(.object(["query": .string("is:unread newer_than:1d"), "max_results": .number(10), "include_spam": .bool(false)])))
    #expect(!carries(.object(["query": .string("to:Konrad@Example.test"), "path": .string("a/b")])), "the bot's own account is not an address out")
    for text in ["see http://collect.test/c", "HTTPS://collect.test", "ftp://collect.test/x", "//collect.test/c?d=1", "//[::1]/c"] {
        #expect(carries(.object(["query": .string(text)])), "\(text) asks")
    }
    #expect(carries(.object(["query": .string("from:someone@elsewhere.test")])), "another email asks")
    for text in ["\\\\collect.test", "%2F%2Fcollect.test", "\u{FF0F}\u{FF0F}collect.test", "someone\u{FF20}elsewhere.test", "/\t/collect.test", "%252F%252Fcollect.test", "//_collect.test", "x@żółw.pl", "evil.konrad@example.test", "żkonrad@example.test"] {
        #expect(carries(.object(["query": .string(text)])), "\(text) asks")
    }
    #expect(carries(.object(["query": .string(String(repeating: "e\u{301}", count: 1_001))])), "length counts Unicode scalars")
    #expect(carries(.object(["filters": .array([.object(["deep": .array([.string("https://collect.test")])])])])), "searched recursively")
    #expect(carries(.object(["https://collect.test/?d=1": .null])), "keys too")
    #expect(!carries(.object(["query": .string(String(repeating: "a", count: 2_000))])))
    #expect(carries(.object(["query": .string(String(repeating: "a", count: 2_001))])), "longer than 2,000 characters asks")
}

@MainActor @Test func fetchEmailsWithAURLInTheQueryAsks() async throws {
    let (apps, host, _) = composioFixture(handler: composioReadHandler); await apps.refresh()
    let backend = AppRequestBackend(.readWithURL)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat")
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.send(text: "Read my inbox"))
    try await waitUntil { !store.approvals.isEmpty }
    #expect(store.approvals[0].actionKind == "composio.GMAIL_FETCH_EMAILS")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") }, "nothing ran before the card")
    #expect(apps.toolAccess["GMAIL_FETCH_EMAILS"] == .read, "the tool is still a read; this call asks")
    store.decide(store.approvals[0], approved: false)
    try await waitUntil { !store.anyTurnRunning }
}
