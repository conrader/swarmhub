import Foundation
import Testing
@testable import AgentApp

/// P47: an app connected from Settings → Connected apps is on for every bot that can use connected apps, once, at
/// connection. Composio is `MockHermesProtocol` (the accounts list grows when the browser step "finishes"); nothing
/// reaches the network, the Keychain or a browser.
private final class ComposioAccounts: @unchecked Sendable {
    private let lock = NSLock(); private var items: [[String: Any]]
    init(_ items: [[String: Any]]) { self.items = items }
    func add(_ item: [String: Any]) { lock.lock(); items.append(item); lock.unlock() }
    func handler(_ request: URLRequest) -> (Int, Any) {
        guard request.url!.path.hasSuffix("connected_accounts") else { return composioHandler(request) }
        lock.lock(); defer { lock.unlock() }; return (200, ["items": items, "next_cursor": NSNull()])
    }
}

@MainActor private func fixture(_ existing: [[String: Any]] = [composioAccount()]) async -> (ConnectedAppsStore, ComposioAccounts) {
    let accounts = ComposioAccounts(existing)
    let (apps, _, _) = composioFixture(handler: { accounts.handler($0) })
    await apps.refresh()
    return (apps, accounts)
}

@MainActor @Test func settingsConnectTurnsTheNewAccountOnForEveryEligibleBotOnce() async throws {
    let (apps, accounts) = await fixture()
    let jarvis = UUID(), cfo = UUID(), keeper = UUID()
    apps.setAllowed(true, account: try #require(apps.accounts.first), botID: keeper)
    #expect(await apps.connect("slack", grantingTo: [jarvis, cfo]) != nil)
    #expect(apps.grantedToAllToolkit == nil, "nothing is granted before the account appears")
    accounts.add(composioAccount("ca_slack", toolkit: "slack"))
    await apps.refresh()
    #expect(apps.grants(for: jarvis) == ["ca_slack"] && apps.grants(for: cfo) == ["ca_slack"])
    #expect(apps.grants(for: keeper) == ["ca_work"], "a bot not named by the pane is untouched")
    #expect(apps.grantedToAllToolkit == "slack" && apps.enabledToolkits(for: jarvis) == ["slack"])
    #expect(ConnectedAppsCopy.onForAllBots("Slack") == "Slack is on for all your bots. Turn it off for any bot below.")

    // Switched off for one bot, it stays off through later refreshes.
    apps.setAllowed(false, account: try #require(apps.accounts.first { $0.id == "ca_slack" }), botID: cfo)
    await apps.refresh(); await apps.refresh()
    #expect(apps.grants(for: cfo).isEmpty && apps.grants(for: jarvis) == ["ca_slack"])
}

@MainActor @Test func settingsConnectAddsASecondAccountOfTheSameApp() async throws {
    let (apps, accounts) = await fixture()
    let jarvis = UUID(), cfo = UUID()
    apps.setAllowed(true, account: try #require(apps.accounts.first { $0.id == "ca_work" }), botID: cfo)
    _ = await apps.connect("gmail", grantingTo: [jarvis, cfo])
    accounts.add(composioAccount("ca_personal"))
    await apps.refresh()
    #expect(apps.grants(for: jarvis) == ["ca_personal"])
    #expect(apps.grants(for: cfo) == ["ca_personal", "ca_work"], "P48: the new account is added beside Cfo's first Gmail")
}

@MainActor @Test func settingsConnectNeverGrantsAnAccountThatExistedBeforeIt() async throws {
    // The pane had loaded nothing; the work Gmail already existed at Composio when Connect was pressed.
    let accounts = ComposioAccounts([composioAccount()])
    let (apps, _, _) = composioFixture(handler: { accounts.handler($0) })
    let jarvis = UUID()
    _ = await apps.connect("gmail", grantingTo: [jarvis])
    await apps.refresh()
    #expect(apps.grants(for: jarvis).isEmpty && apps.grantedToAllToolkit == nil)
    accounts.add(composioAccount("ca_personal"))
    await apps.refresh()
    #expect(apps.grants(for: jarvis) == ["ca_personal"])
}

@MainActor @Test func chatConnectCardStillGrantsOnlyItsBot() async throws {
    let (apps, accounts) = await fixture([])
    let chatBot = UUID(), other = UUID()
    _ = await apps.connect("gmail")
    accounts.add(composioAccount())
    await apps.refresh()
    #expect(apps.grants(for: chatBot).isEmpty && apps.grants(for: other).isEmpty && apps.grantedToAllToolkit == nil)
    #expect(apps.allowConnection(toolkit: "gmail", accountID: "ca_work", botID: chatBot))
    #expect(apps.grants(for: chatBot) == ["ca_work"] && apps.grants(for: other).isEmpty)
}

@MainActor @Test func settingsPaneBotsAreTheBotsThatCanUseConnectedApps() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes), local = Bot(name: "Local", backend: .openClaw)
    store.bots = [jarvis, local]
    #expect(store.connectedAppsBots.map(\.id) == [jarvis.id])
}

@Test func sidebarControlAndBotPromptUseTheSameWords() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let chat = try String(contentsOf: root.appending(path: "Sources/AgentApp/ConnectedApps/ConnectedAppsChat.swift"), encoding: .utf8)
    #expect(ConnectedAppsCopy.connectAppsLabel == "Connect apps")
    #expect(chat.contains("\\(ConnectedAppsCopy.connectAppsLabel) at the bottom left"))
}
