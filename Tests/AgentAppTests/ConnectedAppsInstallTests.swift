import Foundation
import Testing
@testable import AgentApp

// P40: connected apps with no sign-in. The first Connect provisions the Composio project key with this Mac's install
// (`Authorization: Install <id>.<key>`, the P36 reports install) and keeps it in the key store; later connections reuse
// it. SwarmHub is `SwarmHubStub`, Composio is `MockHermesProtocol` (both URLProtocols on `.test` hosts): no network, no
// Keychain (InMemoryKeyStore), no browser.

private let installKey = "p40-install-key-0123456789abcdefghijklmnopqrstuv"
private let projectKey = "ak_p40_synthetic_project"
private let storedInstall = #"{"installID":"ins_p40","installKey":"\#(installKey)"}"#

/// The SwarmHub side: `/v1/installs` and `/v1/composio/provision` answering `provision`.
private func swarmHub(provision: @escaping @Sendable () -> (Int, Any) = { (200, ["project_id": "pr_p40", "api_key": projectKey, "user_id": "swarmhub_p40"]) }) -> (service: SwarmHubService, host: String, session: URLSession) {
    SwarmHubStub.serve { request, _ in
        switch request.url!.path {
        case "/swarmhub/v1/installs": (201, ["install_id": "ins_new", "install_key": installKey])
        case "/swarmhub/v1/composio/provision": provision()
        default: (404, ["error": "no route"])
        }
    }
}

@MainActor private func provisioned(_ hub: (service: SwarmHubService, host: String, session: URLSession), keys: InMemoryKeyStore) -> (ComposioProvisioningClient, ReportsCenter) {
    let center = ReportsCenter(fileURL: nil, keyStore: keys)
    center.session = hub.session; center.sleep = { _ in }; center.openURL = { _ in Issue.record("no browser: there is no sign-in") }
    let client = ComposioProvisioningClient(baseURL: URL(string: "https://\(hub.host)/swarmhub/")!, session: hub.session,
                                            credential: SwarmHubInstallIdentity(center: center, service: hub.service))
    return (client, center)
}

@MainActor @Test func p40ProvisionSendsTheInstallHeaderAndNeverSignsIn() async throws {
    let hub = swarmHub(), keys = InMemoryKeyStore([SwarmHubInstall.account: storedInstall])
    let (client, center) = provisioned(hub, keys: keys)
    let credential = try await client.credentialForFirstConnection(toolkit: "gmail")
    #expect(credential.apiKey == projectKey && credential.userID == "swarmhub_p40" && credential.projectID == "pr_p40")
    #expect(SwarmHubStub.paths(hub.host) == ["POST /swarmhub/v1/composio/provision"], "a stored install is reused; no auth route")
    #expect(SwarmHubStub.requests(hub.host)[0].request.value(forHTTPHeaderField: "Authorization") == "Install ins_p40.\(installKey)")
    #expect(center.account == .signedOut && center.signInTask == nil && center.storedToken == nil)
}

@MainActor @Test func p40NoInstallYetRegistersOnceThenProvisionsWithTheReportsInstall() async throws {
    let hub = swarmHub()
    let defaults = isolatedDefaults(); defaults.set("https://\(hub.host)/swarmhub", forKey: SwarmHubService.baseURLKey)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: defaults)
    store.reportsCenter.session = hub.session; store.reportsCenter.openURL = { _ in Issue.record("no browser: there is no sign-in") }
    #expect(store.reportsCenter.storedInstall == nil)
    let client = ComposioProvisioningClient(baseURL: URL(string: "https://\(hub.host)/swarmhub/")!, session: hub.session, credential: store.connectedAppsInstall())
    _ = try await client.credentialForFirstConnection(toolkit: "gmail")
    #expect(SwarmHubStub.paths(hub.host) == ["POST /swarmhub/v1/installs", "POST /swarmhub/v1/composio/provision"])
    #expect(store.reportsCenter.storedInstall == SwarmHubInstall(installID: "ins_new", installKey: installKey), "the same install reports use")
    #expect(SwarmHubStub.requests(hub.host)[1].request.value(forHTTPHeaderField: "Authorization") == "Install ins_new.\(installKey)")
}

@MainActor @Test func p40FirstConnectProvisionsOnceStoresTheKeyAndLaterConnectsReuseIt() async throws {
    let hub = swarmHub(), keys = InMemoryKeyStore()
    let (provisioner, center) = provisioned(hub, keys: keys)
    let (composio, session) = MockHermesProtocol.serve(composioHandler)
    let directory = temporaryStore().deletingLastPathComponent()
    let apps = ConnectedAppsStore(directory: directory, keyStore: keys, session: session, apiURL: URL(string: "https://\(composio)/api/v3.1/")!, provisioner: provisioner)
    #expect(await apps.connect("gmail")?.host == "connect.composio.dev")
    #expect(keys.key(for: ConnectedAppsStore.keyAccount) == projectKey && apps.configuration.projectID == "pr_p40" && apps.configuration.userID == "swarmhub_p40")
    #expect(MockHermesProtocol.recorded(composio).allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == projectKey })
    #expect(await apps.connect("slack")?.host == "connect.composio.dev")
    #expect(SwarmHubStub.paths(hub.host) == ["POST /swarmhub/v1/installs", "POST /swarmhub/v1/composio/provision"], "the second Connect does not provision")
    #expect(apps.error == nil && apps.retryToolkit == nil && center.account == .signedOut)
    // The keys are never written anywhere but the key store, nor shown.
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        #expect(!text.contains(projectKey) && !text.contains(installKey), "\(file.lastPathComponent)")
    }
}

@MainActor @Test func p40ServiceAnswersBecomePlainLinesWithRetryAndNoKey() async throws {
    let cases: [(answer: (Int, Any), line: String)] = [
        ((503, ["error": "not configured"]), "App connections aren't available yet."),
        ((429, ["error": "daily cap"]), "Too many new app connections right now. Try again in a while."),
        ((200, "garbage"), "SwarmHub could not verify the app connection response."),
        ((200, ["api_key": "not-a-composio-key", "user_id": "u", "project_id": "p"]), "SwarmHub could not verify the app connection response."),
        ((500, ["error": "boom"]), "SwarmHub could not prepare your app connection (HTTP 500). Try again shortly.")
    ]
    for (answer, line) in cases {
        nonisolated(unsafe) let reply = answer
        let hub = swarmHub(provision: { reply }), keys = InMemoryKeyStore([SwarmHubInstall.account: storedInstall])
        let (provisioner, _) = provisioned(hub, keys: keys)
        let (composio, session) = MockHermesProtocol.serve(composioHandler)
        let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: keys, session: session, apiURL: URL(string: "https://\(composio)/api/v3.1/")!, provisioner: provisioner)
        #expect(await apps.connect("gmail") == nil)
        #expect(apps.error == line && apps.retryToolkit == "gmail" && !apps.hasKey, "\(answer.0)")
        #expect(!(apps.error ?? "").localizedCaseInsensitiveContains("sign"), "no sign-in mention")
        #expect(MockHermesProtocol.recorded(composio).isEmpty, "no Composio request without a key")
    }
    // The install registration itself rate-limited: the same plain line.
    let limited = SwarmHubStub.serve { _, _ in (429, ["error": "too many installs"]) }
    let (client, _) = provisioned(limited, keys: InMemoryKeyStore())
    await #expect(throws: ComposioProvisioningError.rateLimited) { try await client.credentialForFirstConnection(toolkit: "gmail") }
    #expect(SwarmHubStub.paths(limited.host) == ["POST /swarmhub/v1/installs"])
}

@MainActor @Test func p40RetryAfterAFailedProvisionConnectsAndClearsTheRetry() async throws {
    let calls = LockedTrace()
    let hub = swarmHub(provision: {
        calls.add("p"); return calls.read().count == 1 ? (429, ["error": "busy"]) : (200, ["project_id": "pr_p40", "api_key": projectKey, "user_id": "swarmhub_p40"])
    })
    let keys = InMemoryKeyStore([SwarmHubInstall.account: storedInstall])
    let (provisioner, _) = provisioned(hub, keys: keys)
    let (composio, session) = MockHermesProtocol.serve(composioHandler)
    let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: keys, session: session, apiURL: URL(string: "https://\(composio)/api/v3.1/")!, provisioner: provisioner)
    #expect(await apps.connect("gmail") == nil && apps.retryToolkit == "gmail")
    #expect(await apps.connect(try #require(apps.retryToolkit)) != nil)
    #expect(apps.retryToolkit == nil && apps.error == nil && apps.hasKey)
}

@MainActor @Test func p40RefusedInstallRegistersAgainOnceAndRetriesOnce() async throws {
    let calls = LockedTrace()
    let hub = swarmHub(provision: {
        calls.add("p"); return calls.read().count == 1 ? (401, ["error": "unknown install"]) : (200, ["project_id": "pr_p40", "api_key": projectKey, "user_id": "swarmhub_p40"])
    })
    let (client, center) = provisioned(hub, keys: InMemoryKeyStore([SwarmHubInstall.account: storedInstall]))
    _ = try await client.credentialForFirstConnection(toolkit: "gmail")
    #expect(SwarmHubStub.paths(hub.host) == ["POST /swarmhub/v1/composio/provision", "POST /swarmhub/v1/installs", "POST /swarmhub/v1/composio/provision"])
    #expect(center.storedInstall?.installID == "ins_new" && center.account == .signedOut)
}

@MainActor @Test func p40HealthSaysNotAvailableWithoutMentioningSignIn() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    for (status, note) in [(503, Optional(ConnectedAppsCopy.notAvailable)), (200, nil)] {
        let hub = SwarmHubStub.serve { _, _ in (status, ["status": status == 200 ? "ready" : "unavailable", "sign_in": false]) }
        store.reportsCenter.session = hub.session
        await store.checkConnectedAppsService(url: URL(string: "https://\(hub.host)/swarmhub/")!)
        #expect(store.connectedApps.serviceNote == note && SwarmHubStub.paths(hub.host) == ["GET /swarmhub/health"])
    }
    for line in [ConnectedAppsCopy.notAvailable, ConnectedAppsCopy.tooManyConnections, ConnectedAppsCopy.backgroundNotAvailable, ConnectedAppsCopy.serviceNotConfigured] {
        #expect(!line.localizedCaseInsensitiveContains("sign"))
    }
}
