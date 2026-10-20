import Foundation
import Testing
@testable import AgentApp

/// A notification fence for `deviceTask`; card content still comes only from the runtime read.
private let deviceFence = "Submitted.\n```swarmhub\n{\"op\":\"approval\",\"task\":\"\(deviceTask)\",\"kind\":\"outbound\",\"gate\":\"owner\",\"decider\":\"owner\",\"bot\":\"worker\",\"intent\":\"TEST\",\"summary\":\"TEST never sent\",\"risks\":[\"money\"]}\n```"

private func testSeed() throws -> Data {
    let seeds = try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("release-bundles/TEST-device-keys.json")))
    return approvalHex(try #require(seeds["keys"]?.arrayValue?.first?["seed"]?.stringValue))
}

/// The store derives its key ID from the TEST seed, so the endpoint must use the same derived identity.
private func testSeedEndpoint() throws -> DeviceEndpoint { DeviceEndpoint(identity: try DeviceApprovalIdentity(seed: testSeed())) }

/// A device-required store with one card whose approve is saved behind an uncertain (503) dispatch.
@MainActor private func lockedApproveCard(_ endpoint: DeviceEndpoint, session: URLSession, origin: String)
    async throws -> (AppStore, Bot, DeviceApprovalSettings) {
    let defaults = isolatedDefaults(), keys = MemoryApprovalKeys()
    try keys.insert(testSeed(), account: DeviceApprovalIdentity.account(box: origin))
    let settings = DeviceApprovalSettings(defaults: defaults); settings.confirmOperatorCutover(origin)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(),
        defaults: defaults, hermesSession: session, approvalKeys: keys)
    let bot = Bot(name: "TEST owner", backend: .hermes, hermesProfile: "owner")
    bot.hermesBaseURL = origin + "/v1"; store.bots = [bot]
    let reviewed = try await store.managedRuntime(bot, verb: "get", task: deviceTask)
    store.approvals = [try reviewed.request(botID: bot.id)]
    store.decideManagedAction(try #require(store.approvals.first), approved: true)
    try await waitUntil { store.approvals.first?.decisionPending == false }
    #expect(store.approvals.first?.managedDecision == true && settings.hasAttempt(origin: origin, task: deviceTask))
    return (store, bot, settings)
}

extension ManagedRemoteControlTests {
    @Test @MainActor func repeatedNotificationClearingExpiredAttemptAlsoClearsCardChoice() async throws {
        let endpoint = try testSeedEndpoint()
        endpoint.issued -= 120 // Expired box time stand-in; no waiting or sockets.
        endpoint.decisionFailure = 503
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host
        let (store, bot, settings) = try await lockedApproveCard(endpoint, session: session, origin: origin)
        // The repeated fence's read clears the expired attempt; the card's saved approve must go with it.
        store.errorMessage = nil
        store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: deviceFence), bot: bot)
        try await waitUntil { store.approvals.first?.managedDecision == nil && store.errorMessage != nil }
        #expect(!settings.hasAttempt(origin: origin, task: deviceTask))
        #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
        #expect(store.errorMessage == ManagedControlError.attemptExpired.localizedDescription)
        let saved = try StoreFile.decode(JSONEncoder().encode(store.storeFile))
        #expect(saved.managedApprovals?.first?.managedDecision == nil)
        #expect(endpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt"])
        // Deny is accepted now (no "earlier decision is still awaiting a receipt"), and nothing resent the approve.
        endpoint.issued = Int64(Date().timeIntervalSince1970); endpoint.decisionFailure = nil
        store.decideManagedAction(try #require(store.approvals.first), approved: false)
        try await waitUntil { store.approvals.isEmpty }
        #expect(bot.approvalAudit.last?.outcome == .denied)
        #expect(endpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt", "receipt", "challenge", "decide"])
    }

    @Test(arguments: [false, true]) @MainActor
    func goneOperationClearsAttemptAndCardChoice(notification: Bool) async throws {
        let endpoint = try testSeedEndpoint()
        endpoint.decisionFailure = 503 // Live nonce: before this fix the attempt stayed locked indefinitely.
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host
        let (store, bot, settings) = try await lockedApproveCard(endpoint, session: session, origin: origin)
        endpoint.gone = true; store.errorMessage = nil
        if notification {
            store.routeManagedApprovals(in: ChatMessage(role: .assistant, content: deviceFence), bot: bot)
        } else {
            store.decideManagedAction(try #require(store.approvals.first), approved: true)
        }
        try await waitUntil { store.approvals.first?.decisionPending == false && store.errorMessage != nil }
        #expect(store.approvals.first?.managedDecision == nil && store.approvals.count == 1)
        #expect(!settings.hasAttempt(origin: origin, task: deviceTask))
        #expect(store.errorMessage == ManagedControlError.operationGone.localizedDescription)
        #expect(bot.approvalAudit.isEmpty)
        #expect(endpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt"])
        // Not locked: deny is taken, reads "gone" again, and no challenge or decision is generated.
        store.errorMessage = nil
        store.decideManagedAction(try #require(store.approvals.first), approved: false)
        try await waitUntil { store.approvals.first?.decisionPending == false && store.errorMessage != nil }
        #expect(store.errorMessage == ManagedControlError.operationGone.localizedDescription)
        #expect(store.approvals.first?.managedDecision == nil)
        #expect(endpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt", "receipt"])
    }

    @Test func goneReplyWithExtraFieldsKeepsTheAttempt() async throws {
        let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
        endpoint.decisionFailure = 503
        let (host, session) = MockHermesProtocol.serve { request in
            guard request.url?.lastPathComponent == "receipt" else { return endpoint.handle(request) }
            let response: [String: Any] = ["request": DeviceApprovalWire.digest(pickerRequestBody(request)),
                "receipt": NSNull(), "status": "gone", "record": [:]]
            return (200, response)
        }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, settings = DeviceApprovalSettings(defaults: isolatedDefaults())
        let reviewed = endpoint.operation(origin: origin)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: deviceDecisionInput(reviewed, approved: true), identity: identity, settings: settings,
                reviewed: reviewed, session: session)
        }
        let previous = try settings.attempt(origin: origin, task: deviceTask)
        do {
            _ = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: settings, session: session)
            Issue.record("A malformed gone reply must not clear anything")
        } catch ManagedControlError.invalidRecord {}
        let retained = try settings.attempt(origin: origin, task: deviceTask)
        #expect(previous != nil && retained == previous)
    }
}
