import Foundation
import Testing
@testable import AgentApp

@Test func connectAppCardParsesAmongOrdinaryAssistantText() {
    let text = "I can help with your inbox.\n\n```connect-app\n{\"app\":\"GMAIL\",\"reason\":\"To find your unread emails.\"}\n```\n\nContinue after connecting."
    #expect(ChatCardParser.parse(text) == [
        .markdown("I can help with your inbox."), .connectApp(.init(toolkit: "gmail", reason: "To find your unread emails.")),
        .markdown("Continue after connecting.")
    ])
    #expect(ChatCardParser.parse("```connect-app\n{\"app\":\"slack\"}\n```") == [.connectApp(.init(toolkit: "slack", reason: ""))])
}

@Test func connectAppCardRefusesUrlsIdentityFieldsMalformedAndUnfinishedRequests() {
    let bodies = [
        "{\"app\":\"gmail\",\"url\":\"https://attacker.example/sign-in\"}",
        "{\"app\":\"gmail\",\"bot_id\":\"another-bot\"}", "{\"app\":\"gmail\",\"user_id\":\"other-user\"}",
        "{\"app\":\"https://attacker.example\"}", "{\"app\":\"../gmail\"}", "{\"app\":\"\"}",
        "{\"app\":\"gmail\",\"reason\":true}", "{\"app\":\"gmail\",\"reason\":\"" + String(repeating: "x", count: 241) + "\"}",
        "{\"reason\":\"Connect an app\"}", "{\"app\":\"gmail\"} trailing"
    ]
    for body in bodies {
        #expect(ChatCardParser.parse("```connect-app\n" + body + "\n```") == [.code(language: "connect-app", body: body)])
    }
    let unfinished = ChatCardParser.parse("```connect-app\n{\"app\":\"gmail\"}")
    #expect(unfinished == [.code(language: "connect-app", body: "{\"app\":\"gmail\"}")])
    #expect(ChatCardParser.parse("````markdown\n```connect-app\n{\"app\":\"gmail\"}\n```\n````").allSatisfy {
        if case .connectApp = $0 { return false }; return true
    })
}

@MainActor @Test func connectAppCardIsAvailableBeforeFirstConnectionWithoutCreatingKeysOrCallingComposio() async throws {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let keys = InMemoryKeyStore()
    let provisioner = FakeComposioProvisioner()
    let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: keys, session: session,
                                  apiURL: URL(string: "https://\(host)/api/v3.1/")!, provisioner: provisioner)
    let backend = AppRequestBackend(.connectionCard)
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "existing-chat", systemPrompt: "Original persona", messages: [(role: "user", content: "Read my inbox")]),
                                                   botID: UUID(), backend: backend, apps: apps)
    var text = ""
    for try await event in stream { if case .token(let token) = event { text += token } }
    #expect(ChatCardParser.parse(text).contains(.connectApp(.init(toolkit: "gmail", reason: "To find your unread emails."))))
    let request = try #require(await backend.recorded().first)
    #expect(request.sessionID == "existing-chat" && request.systemPrompt.hasPrefix("Original persona\n\n"))
    #expect(request.systemPrompt.contains("```connect-app") && request.messages.last?.content == "Read my inbox")
    #expect(!apps.hasKey && MockHermesProtocol.recorded(host).isEmpty && provisioner.calls.isEmpty)
}

@MainActor @Test func connectAppCardGrantsOnlyTheChosenAppAccountToTheRequestingBot() async throws {
    let (apps, _, _) = composioFixture { request in
        if request.url!.path.hasSuffix("connected_accounts") {
            return (200, ["items": [composioAccount(), composioAccount("ca_personal"),
                                     composioAccount("ca_slack", toolkit: "slack"), composioAccount("ca_expired", status: "EXPIRED")]])
        }
        return composioHandler(request)
    }
    await apps.refresh()
    let bot = UUID(); let otherBot = UUID()
    #expect(apps.allowConnection(toolkit: "gmail", accountID: "ca_work", botID: otherBot))
    for (toolkit, id) in [("gmail", "ca_slack"), ("gmail", "ca_expired"), ("gmail", "ca_foreign"), ("slack", "ca_work")] {
        #expect(!apps.allowConnection(toolkit: toolkit, accountID: id, botID: bot))
    }
    #expect(apps.grants(for: bot).isEmpty)
    #expect(apps.allowConnection(toolkit: "gmail", accountID: "ca_personal", botID: bot))
    #expect(apps.grants(for: bot) == ["ca_personal"] && apps.grants(for: otherBot) == ["ca_work"])
    #expect(apps.allowConnection(toolkit: "gmail", accountID: "ca_work", botID: bot))
    #expect(apps.grants(for: bot) == ["ca_work"], "Changing the selected account replaces the previous account for this app")
}

@MainActor @Test func connectAppCardTargetsItsChatAuthorAndNeverFallsBackToTheSelectedBot() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let author = Bot(name: "Requesting bot", backend: .hermes); let selected = Bot(name: "Other bot", backend: .hermes)
    store.bots = [author, selected]; store.selectedBot = selected
    #expect(store.connectionBot(id: author.id) === author)
    #expect(store.connectionBot(id: nil) == nil && store.connectionBot(id: UUID()) == nil)
    let demo = Bot(name: "Demo", backend: .hermes, isDemo: true), mock = Bot(name: "Mock")
    store.bots = [author, selected, demo, mock]
    #expect(store.connectionBot(id: demo.id) == nil && store.connectionBot(id: mock.id) == nil, "demo and non-Hermes bots get no app connections")
    store.bots = [selected]
    #expect(store.connectionBot(id: author.id) == nil)
}
