import Foundation
import Testing
@testable import AgentApp

@MainActor @Test func composioBotSeesOnlyItsEnabledAppsAfterRestartWithoutNetworkDiscovery() async throws {
    let (apps, host, directory) = composioFixture { request in
        if request.url!.path.hasSuffix("connected_accounts") {
            return (200, ["items": [composioAccount(), composioAccount("ca_other_bot", toolkit: "slack")]])
        }
        return composioHandler(request)
    }
    await apps.refresh()
    let botID = UUID(); let otherBotID = UUID()
    apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    apps.setAllowed(true, account: apps.accounts[1], botID: otherBotID)
    let (restoredHost, session) = MockHermesProtocol.serve(composioHandler)
    let restored = ConnectedAppsStore(directory: directory,
                                     keyStore: InMemoryKeyStore([ConnectedAppsStore.keyAccount: syntheticComposioKey]), session: session,
                                     apiURL: URL(string: "https://\(restoredHost)/api/v3.1/")!)
    #expect(restored.accounts.isEmpty)
    #expect(restored.enabledToolkits(for: botID) == ["gmail"])
    #expect(restored.enabledToolkits(for: otherBotID) == ["slack"])
    let backend = AppRequestBackend(.normal)
    let before = MockHermesProtocol.recorded(host).count
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "What apps can you use?")]),
                                                   botID: botID, backend: backend, apps: restored)
    for try await _ in stream {}
    let request = try #require(await backend.recorded().first)
    // P48: each app with its accounts; before the first refresh after a restart an account shows by its id.
    #expect(request.systemPrompt.contains("Enabled apps for this bot, each with the accounts you may use by name: {\"gmail\":[\"ca_work\"]}"))
    #expect(!request.systemPrompt.contains("ca_other_bot") && !request.systemPrompt.contains(syntheticComposioKey))
    #expect(request.systemPrompt.contains("Connect apps at the bottom left"))
    #expect(MockHermesProtocol.recorded(host).count == before)
    #expect(MockHermesProtocol.recorded(restoredHost).isEmpty)
    restored.setAllowed(false, account: apps.accounts[0], botID: botID)
    #expect(restored.enabledToolkits(for: botID).isEmpty)
    #expect(restored.enabledToolkits(for: otherBotID) == ["slack"])
}

@MainActor @Test func composioRememberedAppNamesNeverGrantAccessAndAreClearedOnKeyRotation() async throws {
    let (apps, _, directory) = composioFixture(); await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    #expect(apps.enabledToolkits(for: UUID()).isEmpty)
    let withoutKey = ConnectedAppsStore(directory: directory, keyStore: InMemoryKeyStore(), provisioner: FakeComposioProvisioner())
    #expect(withoutKey.enabledToolkits(for: botID).isEmpty)
    let backend = AppRequestBackend(.normal)
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Hello")]),
                                                   botID: botID, backend: backend, apps: withoutKey)
    for try await _ in stream {}
    let prompt = try #require(await backend.recorded().first?.systemPrompt)
    #expect(prompt.hasPrefix("persona\n\n") && prompt.contains("```connect-app"))
    #expect(!prompt.contains("Enabled apps for this bot") && !prompt.contains("SWARMHUB_APP_REQUEST_"))
    // P38 B: with no key and no SwarmHub service there is nothing to connect through: the request goes out unchanged.
    let nothing = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: InMemoryKeyStore())
    let plain = AppRequestBackend(.normal)
    for try await _ in try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Hello")]),
                                                         botID: botID, backend: plain, apps: nothing) {}
    #expect(await plain.recorded().first?.systemPrompt == "persona")
    #expect(apps.saveKey("synthetic-replacement-key"))
    #expect(apps.configuration.appToolkits == nil && apps.enabledToolkits(for: botID).isEmpty)
}
