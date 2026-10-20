import CryptoKit
import Foundation
import Testing
@testable import AgentApp

private let deviceTask = "task." + String(repeating: "a", count: 32)
private let deviceRuntime = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

/// A TLS endpoint stand-in. CryptoKit verifies both domains; no sockets or shared-key verifier.
private final class DeviceEndpoint: @unchecked Sendable {
    let identity: DeviceApprovalIdentity
    private let lock = NSLock()
    private var committed: ManagedRecord?
    private var events: [String] = []
    var loseAcknowledgement = false
    var corruptChallenge = false
    var decisionFailure: Int?
    var refusalReason = "signature_invalid"
    init(identity: DeviceApprovalIdentity) { self.identity = identity }
    var calls: [String] { lock.withLock { events } }

    func operation(origin: String) -> ManagedRecord {
        ManagedRecord(id: deviceTask, fingerprint: String(repeating: "b", count: 64), gate: "owner",
            status: "awaiting-owner", decider: "owner",
            spec: .init(kind: "outbound", bot: "worker", intent: "TEST full operation", risks: ["money"],
                        argv: ["/bin/true", "café"], to: "nobody@example.invalid", text: "TEST never sent ☃", fake: true),
            remoteBinding: .init(origin: origin, runtime: deviceRuntime, profile: "owner"))
    }

    func handle(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        do {
            let raw = pickerRequestBody(request)
            let envelope = try DeviceApprovalJSON.parse(raw)
            let signed = try #require(envelope["signed"]?.objectValue)
            let verb = request.url!.lastPathComponent
            let origin = "https://" + request.url!.host!
            events.append(verb)
            #expect(request.url!.path == "/swarmhub/control/v2/owner/" + verb)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-SwarmHub-Signature") == nil)
            #expect(request.httpShouldHandleCookies == false)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: approvalHex(identity.publicKey))
            let signature = approvalHex(try #require(envelope["signature"]?.stringValue))
            #expect(publicKey.isValidSignature(signature, for: try DeviceApprovalWire.message(signed, read: verb != "decide")))
            #expect(signed["key_id"] == .string(identity.keyID) && signed["origin"] == .string(origin))
            var response: [String: JSONValue] = ["request": .string(DeviceApprovalWire.digest(raw))]
            switch verb {
            case "receipt":
                response["receipt"] = try committed.map { try DeviceApprovalJSON.parse(JSONEncoder().encode($0)) } ?? .null
                if committed == nil {
                    response["status"] = .string("awaiting-owner")
                    response["record"] = try DeviceApprovalJSON.parse(JSONEncoder().encode(operation(origin: origin)))
                }
            case "challenge":
                var record = operation(origin: origin)
                record.remoteBinding = nil // P5b's challenge record is not a receipt.
                response["record"] = try DeviceApprovalJSON.parse(JSONEncoder().encode(record))
                let fingerprint = try DeviceApprovalWire.digest(DeviceApprovalWire.canonical(.object(record.spec.fields)))
                response["challenge"] = .object([
                    "version": .int(2), "domain": .string(DeviceApprovalWire.domain), "key_id": .string(identity.keyID),
                    "origin": .string(origin), "runtime": .string(deviceRuntime), "profile": .string("owner"),
                    "task": .string(deviceTask), "gate": .string("owner"), "nonce": .string(String(repeating: "1", count: 64)),
                    "issued": .int(1000), "expires": .int(1060),
                    "fingerprint": .string(corruptChallenge ? String(repeating: "0", count: 64) : fingerprint)])
            case "decide":
                #expect(committed == nil)
                if let decisionFailure {
                    return (decisionFailure, ["error": "control request refused", "reason": refusalReason])
                }
                let approved = try #require(signed["approved"]?.boolValue)
                var record = operation(origin: origin)
                record = ManagedRecord(id: record.id, fingerprint: record.fingerprint, gate: record.gate,
                    status: approved ? "queued" : "denied", decider: "owner", spec: record.spec,
                    decided_by: "owner", decided_at: 1020, remoteBinding: record.remoteBinding,
                    remoteReceipt: .init(id: "11111111-2222-3333-4444-555555555555", approved: approved, `protocol`: 2,
                        device: identity.keyID, nonce: signed["nonce"]?.stringValue, fingerprint: signed["fingerprint"]?.stringValue,
                        message: try DeviceApprovalWire.digest(DeviceApprovalWire.message(signed))))
                committed = record
                if loseAcknowledgement { return (503, ["error": "TEST lost acknowledgement"]) }
                response["receipt"] = try DeviceApprovalJSON.parse(JSONEncoder().encode(record))
            default: Issue.record("unexpected route"); return (403, [:])
            }
            return (200, try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(response))))
        } catch { Issue.record(error); return (403, [:]) }
    }
}

extension ManagedRemoteControlTests {
    @Test func legacyBoxDispatchDoesNotTouchApprovalVaultOrV2() async throws {
        let keys = MemoryApprovalKeys(); keys.refuseWrite = true
        let (host, session) = MockHermesProtocol.serve { request in
            #expect(request.url?.path == "/swarmhub/control/v1/owner")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-legacy")
            let raw = pickerRequestBody(request)
            #expect(request.value(forHTTPHeaderField: "X-SwarmHub-Signature") == ManagedRemoteControl.signature(raw, key: "TEST-legacy", purpose: "request"))
            return (403, [:])
        }
        defer { session.invalidateAndCancel() }
        let settings = DeviceApprovalSettings(defaults: isolatedDefaults())
        await #expect(throws: (any Error).self) {
            try await ManagedRemoteControl.requestForBox(address: "https://\(host)/v1", profile: "owner", key: "TEST-legacy",
                verb: "get", task: deviceTask, input: nil, settings: settings, approvalKeys: keys, session: session)
        }
        #expect(MockHermesProtocol.recorded(host).count == 1)
    }

    @Test func requiredBoxNeverFallsBackOnRejectionRedirectOrKeyFailure() async throws {
        for status in [403, 500, 301, 302, 303, 307, 308] {
            let (host, session) = MockHermesProtocol.serve { request in
                #expect(request.url?.path == "/swarmhub/control/v2/owner/receipt")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (status, ["location": "/swarmhub/control/v1/owner"])
            }
            defer { session.invalidateAndCancel() }
            let defaults = isolatedDefaults(), origin = "https://" + host
            DeviceApprovalSettings(defaults: defaults).confirmOperatorCutover(origin)
            let settings = DeviceApprovalSettings(defaults: defaults) // Routing survives a restart.
            #expect(settings.isRequired(origin))
            let start = ContinuousClock.now
            await #expect(throws: (any Error).self) {
                try await ManagedRemoteControl.requestForBox(address: origin, profile: "owner", key: "TEST-unused",
                    verb: "get", task: deviceTask, input: nil, settings: settings, approvalKeys: MemoryApprovalKeys(), session: session, timeout: 2)
            }
            #expect(ContinuousClock.now - start < .seconds(3))
            #expect(MockHermesProtocol.recorded(host).count == 1)
            let broken = MemoryApprovalKeys(); broken.refuseWrite = true
            await #expect(throws: (any Error).self) {
                try await ManagedRemoteControl.requestForBox(address: origin, profile: "owner", key: "TEST-unused",
                    verb: "decide", task: deviceTask, input: nil, settings: settings, approvalKeys: broken, session: session)
            }
            #expect(MockHermesProtocol.recorded(host).count == 1)
        }
    }

    @Test(arguments: [true, false])
    func deviceChallengeSignsReviewedFullOperationAndReconcilesLostACK(approved: Bool) async throws {
        let identity = try testApprovalIdentity()
        let endpoint = DeviceEndpoint(identity: identity); endpoint.loseAcknowledgement = true
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let defaults = isolatedDefaults(), origin = "https://" + host
        let settings = DeviceApprovalSettings(defaults: defaults)
        let reviewed = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
            input: nil, identity: identity, settings: settings, session: session)
        #expect(reviewed.sameOperation(as: endpoint.operation(origin: origin)))
        let input = try JSONSerialization.data(withJSONObject: ["approved": approved, "fingerprint": reviewed.fingerprint,
            "gate": reviewed.gate, "binding": ["origin": origin, "runtime": deviceRuntime, "profile": "owner"]])
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: input, identity: identity, settings: settings, reviewed: reviewed, session: session)
        }
        let receipt = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
            input: nil, identity: identity, settings: DeviceApprovalSettings(defaults: defaults), session: session)
        #expect(receipt.confirms(approved, original: reviewed))
        #expect(endpoint.calls == ["receipt", "challenge", "decide", "receipt"])
        let expected = try #require(try settings.attempt(origin: origin, task: deviceTask))
        for field in ["message", "nonce", "device", "fingerprint", "runtime", "approved"] {
            var wrong = receipt
            switch field {
            case "message": wrong.remoteReceipt?.message = String(repeating: "0", count: 64)
            case "nonce": wrong.remoteReceipt?.nonce = String(repeating: "0", count: 64)
            case "device": wrong.remoteReceipt?.device = "TEST-other"
            case "fingerprint": wrong.remoteReceipt?.fingerprint = String(repeating: "0", count: 64)
            case "runtime": wrong.remoteBinding = .init(origin: origin, runtime: UUID().uuidString.lowercased(), profile: "owner")
            default: var changed = expected; changed["approved"] = .bool(!approved)
                #expect(throws: ManagedControlError.self) { try DeviceApprovalClient.validateReceipt(wrong, origin: origin, profile: "owner", task: deviceTask, identity: identity, expected: changed) }
                continue
            }
            #expect(throws: ManagedControlError.self) { try DeviceApprovalClient.validateReceipt(wrong, origin: origin, profile: "owner", task: deviceTask, identity: identity, expected: expected) }
        }
    }

    @Test func invalidChallengeSendsNoDecision() async throws {
        let identity = try testApprovalIdentity()
        let endpoint = DeviceEndpoint(identity: identity); endpoint.corruptChallenge = true
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, reviewed = endpoint.operation(origin: "https://" + host)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: deviceDecisionInput(reviewed, approved: true), identity: identity,
                settings: DeviceApprovalSettings(defaults: isolatedDefaults()), reviewed: reviewed, session: session)
        }
        #expect(endpoint.calls == ["challenge"])
    }

    @Test func updateHostUnavailableDoesNotChangeDeviceRouting() async throws {
        let identity = try testApprovalIdentity(), origin = "https://box.example.invalid"
        let defaults = isolatedDefaults(); defaults.set("https://unreachable.invalid", forKey: "updateHost")
        let settings = DeviceApprovalSettings(defaults: defaults); settings.confirmOperatorCutover(origin)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: settings, session: UnreachableProtocol.session, timeout: 1)
        }
        #expect(settings.isRequired(origin))
        #expect(try settings.attempt(origin: origin, task: deviceTask) == nil)
    }
}

extension ManagedRemoteControlTests {
    @Test(arguments: [true, false])
    func v2SuccessfulDecisionsRequireMatchingReviewedSpec(approved: Bool) async throws {
        let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, settings = DeviceApprovalSettings(defaults: isolatedDefaults())
        let reviewed = endpoint.operation(origin: origin)
        let input = try JSONSerialization.data(withJSONObject: ["approved": approved, "fingerprint": reviewed.fingerprint,
            "gate": reviewed.gate, "binding": ["origin": origin, "runtime": deviceRuntime, "profile": "owner"]])
        let stale = ManagedRecord(id: reviewed.id, fingerprint: reviewed.fingerprint, gate: reviewed.gate,
            status: reviewed.status, decider: reviewed.decider, spec: .init(kind: "outbound", bot: "worker", intent: "TEST altered"),
            remoteBinding: reviewed.remoteBinding)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: input, identity: identity, settings: settings, reviewed: stale, session: session)
        }
        #expect(endpoint.calls == ["challenge"])
        #expect(try settings.attempt(origin: origin, task: deviceTask) == nil)
        let receipt = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
            input: input, identity: identity, settings: settings, reviewed: reviewed, session: session)
        #expect(receipt.confirms(approved, original: reviewed))
        #expect(endpoint.calls == ["challenge", "challenge", "decide"])
    }

    @Test func uncertainDispatchWithNoReceiptNeverChallengesOrReapplies() async throws {
        let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, defaults = isolatedDefaults()
        let settings = DeviceApprovalSettings(defaults: defaults)
        try settings.remember(["approved": .bool(true)], origin: origin, task: deviceTask)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: DeviceApprovalSettings(defaults: defaults), session: session)
        }
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: nil, identity: identity, settings: settings, session: session)
        }
        #expect(endpoint.calls == ["receipt"])
    }

    @Test func v2DeadlineRejectsWithoutFallingBack() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceHangingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = try testApprovalIdentity(), start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: "https://box.example.invalid", profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: DeviceApprovalSettings(defaults: isolatedDefaults()), session: session, timeout: 0.05)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}

private final class DeviceHangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

extension ManagedRemoteControlTests {
    @Test @MainActor func appRoutesRequiredBoxWithoutReadingSharedKey() async throws {
        let keys = MemoryApprovalKeys()
        let seedDocument = try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("release-bundles/TEST-device-keys.json")))
        let seed = approvalHex(try #require(seedDocument["keys"]?.arrayValue?.first?["seed"]?.stringValue))
        let identity = try DeviceApprovalIdentity(seed: seed)
        let endpoint = DeviceEndpoint(identity: identity)
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, defaults = isolatedDefaults()
        try keys.insert(seed, account: DeviceApprovalIdentity.account(box: origin))
        DeviceApprovalSettings(defaults: defaults).confirmOperatorCutover(origin)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(),
            defaults: defaults, hermesSession: session, approvalKeys: keys)
        let bot = Bot(name: "TEST owner", backend: .hermes, hermesProfile: "owner")
        bot.hermesBaseURL = origin + "/v1"; store.bots = [bot]
        let reviewed = try await store.managedRuntime(bot, verb: "get", task: deviceTask)
        let input = try JSONSerialization.data(withJSONObject: ["approved": false, "fingerprint": reviewed.fingerprint,
            "gate": reviewed.gate, "binding": ["origin": origin, "runtime": deviceRuntime, "profile": "owner"]])
        let receipt = try await store.managedRuntime(bot, verb: "decide", task: deviceTask, input: input, reviewed: reviewed)
        #expect(receipt.confirms(false, original: reviewed))
        #expect(endpoint.calls == ["receipt", "challenge", "decide"])
    }

    @Test func v2ReplyForDifferentRequestFailsClosed() async throws {
        let (host, session) = MockHermesProtocol.serve { request in
            #expect(request.url?.path == "/swarmhub/control/v2/owner/receipt")
            return (200, ["request": String(repeating: "0", count: 64), "receipt": NSNull(), "status": "awaiting-owner"])
        }
        defer { session.invalidateAndCancel() }
        let identity = try testApprovalIdentity()
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: "https://" + host, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: DeviceApprovalSettings(defaults: isolatedDefaults()), session: session)
        }
        #expect(MockHermesProtocol.recorded(host).count == 1)
    }
}

private func deviceDecisionInput(_ record: ManagedRecord, approved: Bool) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["approved": approved, "fingerprint": record.fingerprint,
        "gate": record.gate, "binding": ["origin": record.remoteBinding!.origin,
        "runtime": deviceRuntime, "profile": "owner"]])
}

extension ManagedRemoteControlTests {
    @Test func repeatedPendingReadsNeverRequestANonce() async throws {
        let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
        let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
        defer { session.invalidateAndCancel() }
        let origin = "https://" + host, settings = DeviceApprovalSettings(defaults: isolatedDefaults())
        for _ in 0..<12 {
            let record = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: settings, session: session)
            #expect(record.sameOperation(as: endpoint.operation(origin: origin)))
        }
        #expect(endpoint.calls == Array(repeating: "receipt", count: 12))
        #expect(!settings.hasAttempt(origin: origin, task: deviceTask))
    }

    @Test(arguments: ["signature_invalid", "device_revoked", "nonce_expired", "nonce_replayed"])
    func explicitRefusalAllowsRetryOrDeny(reason: String) async throws {
        for retryApproval in [true, false] {
            let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
            endpoint.decisionFailure = 403; endpoint.refusalReason = reason
            let (host, session) = MockHermesProtocol.serve { endpoint.handle($0) }
            defer { session.invalidateAndCancel() }
            let origin = "https://" + host, defaults = isolatedDefaults()
            let settings = DeviceApprovalSettings(defaults: defaults), reviewed = endpoint.operation(origin: origin)
            do {
                _ = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                    input: deviceDecisionInput(reviewed, approved: true), identity: identity, settings: settings,
                    reviewed: reviewed, session: session)
                Issue.record("Expected a definitive refusal")
            } catch ManagedControlError.refused(let code) { #expect(code == reason) }
            #expect(!DeviceApprovalSettings(defaults: defaults).hasAttempt(origin: origin, task: deviceTask))
            endpoint.decisionFailure = nil
            let current = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: settings, session: session)
            let result = try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: deviceDecisionInput(current, approved: retryApproval), identity: identity, settings: settings,
                reviewed: current, session: session)
            #expect(result.confirms(retryApproval, original: reviewed))
            #expect(endpoint.calls == ["challenge", "decide", "receipt", "challenge", "decide"])
        }
    }

    @Test(arguments: [403, 503, 302, 408])
    func ambiguousDispatchKeepsAttemptAndBlocksEitherDecision(status: Int) async throws {
        let identity = try testApprovalIdentity(), endpoint = DeviceEndpoint(identity: identity)
        endpoint.decisionFailure = status; endpoint.refusalReason = "TEST-unknown-result"
        let (host, stubSession) = MockHermesProtocol.serve { endpoint.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceDecisionTimeoutProtocol.self, MockHermesProtocol.self]
        let session = status == 408 ? URLSession(configuration: configuration) : stubSession
        defer { session.invalidateAndCancel(); stubSession.invalidateAndCancel() }
        let origin = "https://" + host, defaults = isolatedDefaults()
        let settings = DeviceApprovalSettings(defaults: defaults), reviewed = endpoint.operation(origin: origin)
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                input: deviceDecisionInput(reviewed, approved: true), identity: identity, settings: settings,
                reviewed: reviewed, session: session)
        }
        let restarted = DeviceApprovalSettings(defaults: defaults)
        #expect(try restarted.attempt(origin: origin, task: deviceTask)?["approved"] == .bool(true))
        await #expect(throws: (any Error).self) {
            try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "get", task: deviceTask,
                input: nil, identity: identity, settings: restarted, session: session)
        }
        for approved in [true, false] {
            await #expect(throws: (any Error).self) {
                try await DeviceApprovalClient.request(address: origin, profile: "owner", verb: "decide", task: deviceTask,
                    input: deviceDecisionInput(reviewed, approved: approved), identity: identity, settings: restarted,
                    reviewed: reviewed, session: session)
            }
        }
        // The timeout protocol intercepts decide; all later calls only read the receipt.
        #expect(MockHermesProtocol.recorded(host).count == (status == 408 ? 2 : 3))
        #expect(restarted.hasAttempt(origin: origin, task: deviceTask))
    }
}

extension ManagedRemoteControlTests {
    @Test(arguments: [false, true]) @MainActor
    func refusedCardCanSwitchToDenyButAmbiguousCardStaysLocked(ambiguous: Bool) async throws {
        let keys = MemoryApprovalKeys(), defaults = isolatedDefaults()
        let seedDocument = try DeviceApprovalJSON.parse(Data(contentsOf: deviceFixture("release-bundles/TEST-device-keys.json")))
        let seed = approvalHex(try #require(seedDocument["keys"]?.arrayValue?.first?["seed"]?.stringValue))
        // loadOrCreate derives the app's key ID from the same TEST public key.
        let appIdentity = try DeviceApprovalIdentity(seed: seed)
        let appEndpoint = DeviceEndpoint(identity: appIdentity)
        appEndpoint.decisionFailure = ambiguous ? 503 : 403
        let (appHost, appSession) = MockHermesProtocol.serve { appEndpoint.handle($0) }
        defer { appSession.invalidateAndCancel() }
        let appOrigin = "https://" + appHost
        try keys.insert(seed, account: DeviceApprovalIdentity.account(box: appOrigin))
        let settings = DeviceApprovalSettings(defaults: defaults); settings.confirmOperatorCutover(appOrigin)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(),
            defaults: defaults, hermesSession: appSession, approvalKeys: keys)
        let bot = Bot(name: "TEST owner", backend: .hermes, hermesProfile: "owner")
        bot.hermesBaseURL = appOrigin + "/v1"; store.bots = [bot]
        let original = try await store.managedRuntime(bot, verb: "get", task: deviceTask)
        store.approvals = [try original.request(botID: bot.id)]
        store.decideManagedAction(try #require(store.approvals.first), approved: true)
        try await waitUntil { store.approvals.first?.decisionPending == false }
        let saved = try StoreFile.decode(JSONEncoder().encode(store.storeFile))
        store.approvals = try #require(saved.managedApprovals)
        #expect(store.approvals.first?.managedDecision == (ambiguous ? true : nil))
        #expect(settings.hasAttempt(origin: appOrigin, task: deviceTask) == ambiguous)
        appEndpoint.decisionFailure = nil
        store.decideManagedAction(try #require(store.approvals.first), approved: false)
        if ambiguous {
            #expect(store.approvals.first?.managedDecision == true)
            store.decideManagedAction(try #require(store.approvals.first), approved: true)
            try await waitUntil { store.approvals.first?.decisionPending == false }
            #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
            #expect(appEndpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt"])
        } else {
            try await waitUntil { store.approvals.isEmpty }
            #expect(bot.approvalAudit.last?.outcome == .denied)
            #expect(appEndpoint.calls == ["receipt", "receipt", "challenge", "decide", "receipt", "challenge", "decide"])
        }
    }
}

private final class DeviceDecisionTimeoutProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.lastPathComponent == "decide" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    override func stopLoading() {}
}
