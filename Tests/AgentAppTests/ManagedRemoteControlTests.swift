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
                #expect((body["binding"] as? [String: String]) == ["origin": origin, "runtime": runtimeID, "profile": "owner"])
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
        #expect(fixture.calls == ["get"])
    }

    @Test func plaintextMissingKeyAndRedirectsFailClosed() async throws {
        let (target, targetSession) = MockHermesProtocol.serve { _ in Issue.record("redirect must not be followed"); return (200, [:]) }
        let (host, session) = MockHermesProtocol.serve { _ in (307, ["location": "https://\(target)/stolen"]) }
        defer { session.invalidateAndCancel(); targetSession.invalidateAndCancel() }
        for (address, key) in [("http://\(host)/v1", remoteKey), ("https://\(host)/v1", ""), ("https://\(host)/v1", remoteKey)] {
            await #expect(throws: ManagedControlError.self) {
                try await ManagedRemoteControl.request(address: address, profile: "owner", key: key,
                                                        verb: "get", task: remoteTask, input: nil, session: session)
            }
        }
        #expect(MockHermesProtocol.recorded(target).isEmpty)
        #expect(MockHermesProtocol.recorded(host).count == 1)
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
            #expect(store.approvals.count == 1 && fixture.calls == ["get", "get", "decide"])
            store.decideManagedAction(try #require(store.approvals.first), approved: approved)
            try await waitUntil { store.approvals.isEmpty }
            #expect(fixture.calls == ["get", "get", "decide", "get"])
            #expect(bot.approvalAudit.last?.outcome == (approved ? .approved : .denied))
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
