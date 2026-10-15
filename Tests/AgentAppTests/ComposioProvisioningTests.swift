import Foundation
import Testing
@testable import AgentApp


@MainActor @Test func composioFirstConnectCreatesKeyAndLaterAppsReuseIt() async throws {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let keys = InMemoryKeyStore(); let provisioner = FakeComposioProvisioner()
    let directory = temporaryStore().deletingLastPathComponent()
    let apps = ConnectedAppsStore(directory: directory, keyStore: keys, session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!, provisioner: provisioner)
    #expect(!apps.hasKey)
    await apps.search("Gmail")
    #expect(apps.catalog.map(\.id) == ["gmail"])
    #expect(provisioner.calls.isEmpty && MockHermesProtocol.recorded(host).isEmpty)
    #expect(await apps.connect("gmail")?.host == "connect.composio.dev")
    #expect(apps.hasKey && provisioner.calls == ["gmail"])
    #expect(apps.configuration.userID == "swarmhub_signed_in_user" && apps.configuration.projectID == "pr_synthetic_user")
    #expect(await apps.connect("slack")?.host == "connect.composio.dev")
    #expect(provisioner.calls == ["gmail"])
    let saved = try String(contentsOf: directory.appending(path: "connected-apps.json"), encoding: .utf8)
    #expect(!saved.contains("ak_synthetic") && !saved.contains("session"))
    let reloaded = ConnectedAppsStore(directory: directory, keyStore: keys, session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!, provisioner: provisioner)
    #expect(await reloaded.connect("gmail") != nil)
    #expect(provisioner.calls == ["gmail"], "Restarting must reuse the stored key")
}

@MainActor @Test func composioFailedProvisioningDoesNotStartOAuthOrSaveKey() async {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let keys = InMemoryKeyStore(); let provisioner = FakeComposioProvisioner(); provisioner.fails = true
    let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: keys, session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!, provisioner: provisioner)
    #expect(await apps.connect("gmail") == nil)
    #expect(!apps.hasKey && apps.error != nil)
    #expect(MockHermesProtocol.recorded(host).isEmpty)
    provisioner.fails = false
    #expect(await apps.connect("gmail") != nil && apps.hasKey)
}

@MainActor @Test func composioExistingKeySkipsAutomaticProvisioning() async {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let provisioner = FakeComposioProvisioner()
    let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: InMemoryKeyStore([ConnectedAppsStore.keyAccount: syntheticComposioKey]), session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!, provisioner: provisioner)
    #expect(await apps.connect("gmail") != nil)
    #expect(provisioner.calls.isEmpty)
}

@MainActor @Test func composioProvisioningUsesTheInstallAndNeverSendsLocalOwner() async throws {
    let (host, session) = MockHermesProtocol.serve { _ in
        (200, ["api_key": "ak_synthetic_user", "user_id": "swarmhub_user", "project_id": "pr_user"])
    }
    let identity = FakeSwarmHubInstall()
    let provisioner = ComposioProvisioningClient(baseURL: URL(string: "https://\(host)/swarmhub/")!, session: session, credential: identity)
    let key = try await provisioner.credentialForFirstConnection(toolkit: "gmail")
    #expect(key.apiKey == "ak_synthetic_user" && identity.calls == 1)
    let request = MockHermesProtocol.recorded(host)[0]
    #expect(request.url!.path == "/swarmhub/v1/composio/provision")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Install ins_synthetic.synthetic-install-key")
    #expect(Set(composioBody(request).keys) == ["toolkit"])
    #expect(request.value(forHTTPHeaderField: "x-org-api-key") == nil)
}

@Test func composioProvisioningRejectsUnsafeServerAddresses() {
    #expect(!ComposioProvisioningClient.validServiceURL(URL(string: "http://example.com/")!))
    #expect(!ComposioProvisioningClient.validServiceURL(URL(string: "https://user:password@example.com/")!))
    #expect(!ComposioProvisioningClient.validServiceURL(URL(string: "https://example.com/?key=secret")!))
    #expect(ComposioProvisioningClient.validServiceURL(URL(string: "https://agenthut.net/swarmhub/")!))
}
