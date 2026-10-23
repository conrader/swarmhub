import CryptoKit
import Foundation
import Testing
@testable import AgentApp

private let remoteTask = "task." + String(repeating: "a", count: 32)
private let remoteKey = "synthetic-owner-key"
private let runtimeID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

private func remoteRecord(origin: String, approved: Bool? = nil) -> ManagedRecord {
    ManagedRecord(id: remoteTask, fingerprint: String(repeating: "b", count: 64), gate: "owner",
                  status: approved.map { $0 ? "queued" : "denied" } ?? "awaiting-owner", decider: "owner",
                  spec: .init(kind: "outbound", bot: "worker", intent: "remote-fixture", risks: ["money"],
                              argv: ["/bin/true"], to: "nobody@example.invalid", text: "FAKE never sent", fake: true),
                  decided_by: approved == nil ? nil : "owner", decided_at: approved == nil ? nil : 1000,
                  remoteBinding: .init(origin: origin, runtime: runtimeID, profile: "owner"),
                  remoteReceipt: approved.map { .init(id: "11111111-2222-3333-4444-555555555555", approved: $0) })
}

private func signedResponse(raw: Data, record: ManagedRecord) throws -> [String: String] {
    let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    let payload = try JSONSerialization.data(withJSONObject: [
        "request": digest, "expires": body["expires"]!,
        "record": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
    ], options: [.sortedKeys])
    return ["payload": payload.base64EncodedString(), "signature": ManagedRemoteControl.signature(payload, key: remoteKey, purpose: "response")]
}

/// A redirect is refused at once, never by running into the request's own deadline. The deadline is long and the bound is
/// half of it: a loaded Mac took 3-4 s here (2026-10-23), while a call that waited for the body ends at the deadline.
private let redirectDeadline: TimeInterval = 60

/// In-process URLProtocol only. It models a committed decision whose acknowledgement was lost.
private final class RemoteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var decision: Bool?
    private var events: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return events }

    func handle(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        do {
            let raw = pickerRequestBody(request)
            let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let verb = try #require(body["verb"] as? String)
            let origin = "https://" + request.url!.host!
            #expect(request.url?.path == "/swarmhub/control/v1/owner")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + remoteKey)
            #expect(request.value(forHTTPHeaderField: "X-SwarmHub-Signature") == ManagedRemoteControl.signature(raw, key: remoteKey, purpose: "request"))
            #expect(body["origin"] as? String == origin && body["profile"] as? String == "owner")
            events.append(verb)
            if verb == "decide" {
                #expect(body["fingerprint"] as? String == String(repeating: "b", count: 64))
                #expect(body["gate"] as? String == "owner")
                #expect((body["binding"] as? [String: String]) == (["origin": origin, "runtime": runtimeID, "profile": "owner"] as [String: String]))
                decision = try #require(body["approved"] as? Bool)
                return (503, ["error": "synthetic lost acknowledgement"])
            }
            return (200, try signedResponse(raw: raw, record: remoteRecord(origin: origin, approved: decision)))
        } catch { Issue.record(error); return (403, ["error": "fixture refused"]) }
    }
}

struct ManagedRemoteControlTests {
    @Test func pythonSignatureFixtureRejectsTamperReplayWrongHostAndExpiry() throws {
        struct Fixture: Decodable { let key: String; let request: String; let requestSignature: String; let response: [String: String] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/remote_approval_protocol.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let raw = Data(fixture.request.utf8)
        let response = try JSONSerialization.data(withJSONObject: fixture.response)
        let origin = "https://box.example.invalid"
        #expect(ManagedRemoteControl.signature(raw, key: fixture.key, purpose: "request") == fixture.requestSignature)
        let valid = try ManagedRemoteControl.verify(response, request: raw, key: fixture.key, origin: origin, task: remoteTask, now: 1020)
        #expect(valid.awaiting && valid.spec.fake == true && valid.remoteBinding?.runtime == runtimeID)
        for (request, key, host, task, now) in [
            (raw + Data(" ".utf8), fixture.key, origin, remoteTask, 1020.0), // old response on a new request
            (raw, "wrong-key", origin, remoteTask, 1020.0),
            (raw, fixture.key, "https://wrong.example.invalid", remoteTask, 1020.0),
            (raw, fixture.key, origin, "task." + String(repeating: "c", count: 32), 1020.0),
            (raw, fixture.key, origin, remoteTask, 1060.0)
        ] {
            #expect(throws: ManagedControlError.self) {
                try ManagedRemoteControl.verify(response, request: request, key: key, origin: host, task: task, now: now)
            }
        }
        var tampered = fixture.response
        tampered["payload"] = Data("tampered".utf8).base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: ManagedControlError.self) {
            try ManagedRemoteControl.verify(damaged, request: raw, key: fixture.key, origin: origin, task: remoteTask, now: 1020)
        }
    }

    @Test func authenticatedTransportUsesHermesProfileKey() async throws {
        let fixture = RemoteFixture()
        let (host, session) = MockHermesProtocol.serve { fixture.handle($0) }
        defer { session.invalidateAndCancel() }
        let record = try await ManagedRemoteControl.request(address: "https://\(host)/v1", profile: "owner", key: remoteKey,
                                                            verb: "get", task: remoteTask, input: nil, session: session)
        #expect(record == remoteRecord(origin: "https://" + host))
        #expect(fixture.calls == (["get"] as [String]))
    }

    @Test func plaintextMissingKeyAndRedirectsFailClosed() async throws {
        let (target, targetSession) = MockHermesProtocol.serve { _ in Issue.record("redirect must not be followed"); return (200, [:]) }
        let (host, session) = MockHermesProtocol.serve { _ in (307, ["location": "https://\(target)/stolen"]) }
        defer { session.invalidateAndCancel(); targetSession.invalidateAndCancel() }
        for (address, key) in [("http://\(host)/v1", remoteKey), ("https://\(host)/v1", ""), ("https://\(host)/v1", remoteKey)] {
            let start = ContinuousClock.now
            await #expect(throws: ManagedControlError.self) {
                do {
                    return try await ManagedRemoteControl.request(address: address, profile: "owner", key: key,
                                                                  verb: "get", task: remoteTask, input: nil, session: session,
                                                                  timeout: redirectDeadline)
                } catch let error as ManagedControlError {
                    if address.hasPrefix("http:") || key.isEmpty {
                        guard case .unavailable = error else { Issue.record("expected unavailable"); throw error }
                    } else {
                        guard case .rejected = error else { Issue.record("expected rejected"); throw error }
                    }
                    throw error
                }
            }
            #expect(ContinuousClock.now - start < .seconds(redirectDeadline / 2))
            if address.hasPrefix("http:") || key.isEmpty { #expect(MockHermesProtocol.recorded(host).isEmpty) }
        }
        #expect(MockHermesProtocol.recorded(target).isEmpty)
        #expect(MockHermesProtocol.recorded(host).count == 1)
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectsRejectWithoutWaitingForBody(status: Int) async throws {
        // MockHermesProtocol reports the redirect but never finishes its original body.
        // Every destination is intercepted, including same-origin paths and HTTPS downgrades.
        let (target, targetSession) = MockHermesProtocol.serve { _ in Issue.record("redirect must not be followed"); return (200, [:]) }
        defer { targetSession.invalidateAndCancel() }
        for destination in ["/stolen", "https://\(target)/stolen", "http://\(target)/stolen"] {
            let (host, session) = MockHermesProtocol.serve { request in
                #expect(request.url?.path == "/swarmhub/control/v1/owner")
                return (status, ["location": destination])
            }
            defer { session.invalidateAndCancel() }
            for verb in ["get", "decide"] {
                let input = try JSONSerialization.data(withJSONObject: [
                    "approved": true, "fingerprint": String(repeating: "b", count: 64), "gate": "owner",
                    "binding": ["origin": "https://" + host, "runtime": runtimeID, "profile": "owner"]
                ])
                let start = ContinuousClock.now
                await #expect(throws: ManagedControlError.self) {
                    do {
                        return try await ManagedRemoteControl.request(address: "https://\(host)/v1", profile: "owner", key: remoteKey,
                                                                      verb: verb, task: remoteTask, input: input, session: session,
                                                                      timeout: redirectDeadline)
                    } catch let error as ManagedControlError {
                        guard case .rejected = error else { Issue.record("redirect must be rejected, not unsent"); throw error }
                        throw error
                    }
                }
                #expect(ContinuousClock.now - start < .seconds(redirectDeadline / 2))
            }
            #expect(MockHermesProtocol.recorded(host).count == 2)
        }
        #expect(MockHermesProtocol.recorded(target).isEmpty)
    }

    @Test func unreachableAndDeadlineFailClosed() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingApprovalProtocol.self]
        let hanging = URLSession(configuration: configuration)
        defer { hanging.invalidateAndCancel() }
        for session in [UnreachableProtocol.session, hanging] {
            await #expect(throws: URLError.self) {
                try await ManagedRemoteControl.request(address: "https://unreachable.test/v1", profile: "owner", key: remoteKey,
                                                        verb: "get", task: remoteTask, input: nil, session: session, timeout: 0.05)
            }
        }
    }

    @Test @MainActor func lostReceiptPersistsCardAndChoiceThenQueriesWithoutResending() async throws {
        for approved in [true, false] {
            let fixture = RemoteFixture()
            let (host, session) = MockHermesProtocol.serve { fixture.handle($0) }
            defer { session.invalidateAndCancel() }
            let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
            let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                                 keyStore: InMemoryKeyStore(["hermes.owner": remoteKey]), defaults: defaults, hermesSession: session)
            let bot = Bot(name: "Owner", backend: .hermes, hermesProfile: "owner")
            store.bots = [bot]
            let original = try await store.managedRuntime(bot, verb: "get", task: remoteTask)
            store.approvals = [try original.request(botID: bot.id)]
            store.decideManagedAction(try #require(store.approvals.first), approved: approved)
            try await waitUntil { store.approvals.first?.decisionPending == false }
            #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
            let saved = try StoreFile.decode(JSONEncoder().encode(store.storeFile))
            store.approvals = try #require(saved.managedApprovals) // Restart serialization boundary.
            #expect(store.approvals.first?.managedDecision == approved)
            #expect(store.approvals.first?.managedRecord?.remoteBinding == original.remoteBinding)
            // A new notification cannot overwrite the uncertain choice, and the opposite button cannot reverse it.
            store.decideManagedAction(try #require(store.approvals.first), approved: !approved)
            #expect(store.approvals.count == 1 && fixture.calls == (["get", "get", "decide"] as [String]))
            store.decideManagedAction(try #require(store.approvals.first), approved: approved)
            try await waitUntil { store.approvals.isEmpty }
            #expect(fixture.calls == (["get", "get", "decide", "get"] as [String]))
            #expect(bot.approvalAudit.last?.outcome == (approved ? .approved : .denied))
        }
    }

    @Test @MainActor func offlineLookupDoesNotLockChoiceAcrossRestart() async throws {
        let (store, bot) = steerStore(ScriptedTurnBackend())
        bot.hermesProfile = "owner"; bot.hermesBaseURL = "https://box.example.invalid/v1"
        let original = remoteRecord(origin: "https://box.example.invalid")
        store.approvals = [try original.request(botID: bot.id)]
        store.managedControl = { _, verb, _, _ in
            #expect(verb == "get")
            throw URLError(.notConnectedToInternet)
        }
        store.decideManagedAction(try #require(store.approvals.first), approved: true)
        try await waitUntil { store.approvals.first?.decisionPending == false }
        let saved = try StoreFile.decode(JSONEncoder().encode(store.storeFile))
        store.approvals = try #require(saved.managedApprovals)
        #expect(store.approvals.first?.managedDecision == nil)
        var calls: [String] = []
        store.managedControl = { _, verb, _, input in
            calls.append(verb)
            if verb == "get" { return original }
            let data = try #require(input)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["approved"] as? Bool == false)
            return remoteRecord(origin: "https://box.example.invalid", approved: false)
        }
        store.decideManagedAction(try #require(store.approvals.first), approved: false)
        try await waitUntil { store.approvals.isEmpty }
        #expect(calls == (["get", "decide"] as [String]) && bot.approvalAudit.last?.outcome == .denied)
    }

    @Test @MainActor func provenUnsentDecisionUnlocksOnlyANewChoice() async throws {
        for uncertain in [false, true] {
            let (store, bot) = steerStore(ScriptedTurnBackend())
            bot.hermesProfile = "owner"; bot.hermesBaseURL = "https://box.example.invalid/v1"
            let original = remoteRecord(origin: "https://box.example.invalid")
            var card = try original.request(botID: bot.id)
            if uncertain { card.managedDecision = true }
            store.approvals = [card]
            store.managedControl = { _, verb, _, _ in
                if verb == "get" { return original }
                throw ManagedControlError.unsent("Synthetic preflight failure")
            }
            store.decideManagedAction(card, approved: true)
            try await waitUntil { store.approvals.first?.decisionPending == false }
            #expect(store.approvals.first?.managedDecision == (uncertain ? true : nil))
            var decisions = 0
            store.managedControl = { _, verb, _, _ in
                if verb == "get" { return original }
                decisions += 1
                return remoteRecord(origin: "https://box.example.invalid", approved: false)
            }
            store.decideManagedAction(try #require(store.approvals.first), approved: false)
            if uncertain {
                #expect(store.approvals.count == 1 && decisions == 0)
            } else {
                try await waitUntil { store.approvals.isEmpty }
                #expect(decisions == 1)
            }
        }
    }

    @Test func decisionPreflightFailureIsExplicitlyUnsent() async throws {
        let (host, session) = MockHermesProtocol.serve { _ in
            Issue.record("preflight failure must not dispatch"); return (500, [:])
        }
        defer { session.invalidateAndCancel() }
        for (address, key) in [("http://\(host)", remoteKey), ("https://\(host)", "")] {
            let start = ContinuousClock.now
            do {
                _ = try await ManagedRemoteControl.request(address: address, profile: "owner", key: key,
                                                            verb: "decide", task: remoteTask, input: nil, session: session)
                Issue.record("plaintext or missing key should fail")
            } catch ManagedControlError.unsent { } catch { Issue.record(error) }
            #expect(ContinuousClock.now - start < .seconds(2))
            #expect(MockHermesProtocol.recorded(host).isEmpty)
        }
    }

    @Test @MainActor func signedRetirementRemovesOnlyTheBoundRuntimeCardAndAudits() async throws {
        for reason in ["gone", "superseded"] {
            for matchingRuntime in [true, false] {
                let runtime = matchingRuntime ? runtimeID : UUID().uuidString
                let (host, session) = MockHermesProtocol.serve { request in
                    do {
                        let raw = pickerRequestBody(request)
                        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
                        #expect(body["verb"] as? String == "get")
                        let payload = try JSONSerialization.data(withJSONObject: [
                            "request": SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
                            "expires": body["expires"]!,
                            "retired": ["task": remoteTask, "origin": "https://" + request.url!.host!,
                                        "runtime": runtime, "reason": reason]
                        ])
                        return (200, ["payload": payload.base64EncodedString(),
                                      "signature": ManagedRemoteControl.signature(payload, key: remoteKey, purpose: "response")])
                    } catch { Issue.record(error); return (500, [:]) }
                }
                defer { session.invalidateAndCancel() }
                let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
                let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                                     keyStore: InMemoryKeyStore(["hermes.owner": remoteKey]), defaults: defaults, hermesSession: session)
                let bot = Bot(name: "Owner", backend: .hermes, hermesProfile: "owner")
                store.bots = [bot]
                var card = try remoteRecord(origin: "https://" + host).request(botID: bot.id)
                card.managedDecision = true // Even an uncertain card can be retired by its bound runtime.
                store.approvals = [card]
                store.decideManagedAction(card, approved: true)
                try await waitUntil { !store.managedDecisionsInFlight.contains(card.id) }
                if matchingRuntime {
                    #expect(store.approvals.isEmpty)
                    #expect(bot.approvalAudit.last?.reason.contains("retired: runtime reports " + reason) == true)
                    #expect(bot.approvalAudit.last?.outcome == .asked)
                } else {
                    #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
                    #expect(store.approvals.first?.managedDecision == true)
                }
                #expect(MockHermesProtocol.recorded(host).count == 1)
            }
        }
    }

    @Test @MainActor func changedHostRuntimeOrDigestKeepsPendingCard() async throws {
        let backend = ScriptedTurnBackend(); let (store, bot) = steerStore(backend)
        bot.hermesProfile = "owner"; bot.hermesBaseURL = "https://box.example.invalid/v1"
        let original = remoteRecord(origin: "https://box.example.invalid")
        for alteration in ["host", "runtime", "digest", "spec", "receipt"] {
            store.approvals = [try original.request(botID: bot.id)]
            var fields = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(remoteRecord(origin: "https://box.example.invalid", approved: true))) as? [String: Any])
            if alteration == "host" { bot.hermesBaseURL = "https://wrong.example.invalid/v1" }
            if alteration == "runtime" { fields["remoteBinding"] = ["origin": "https://box.example.invalid", "profile": "owner", "runtime": UUID().uuidString] }
            if alteration == "digest" { fields["fingerprint"] = String(repeating: "c", count: 64) }
            if alteration == "spec" { fields["spec"] = ["kind": "outbound", "bot": "worker", "intent": "changed", "fake": true] }
            if alteration == "receipt" { fields.removeValue(forKey: "remoteReceipt") }
            let changed = try JSONDecoder().decode(ManagedRecord.self, from: JSONSerialization.data(withJSONObject: fields))
            store.managedControl = { _, verb, _, _ in #expect(verb == "get"); #expect(alteration != "host"); return changed }
            store.decideManagedAction(try #require(store.approvals.first), approved: true)
            try await waitUntil { store.approvals.first?.decisionPending == false }
            #expect(store.approvals.count == 1 && bot.approvalAudit.isEmpty)
            bot.hermesBaseURL = "https://box.example.invalid/v1"
        }
    }
}

private final class HangingApprovalProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // The client's wall-clock deadline must cancel this task.
    override func stopLoading() {}
}
