import CryptoKit
import Foundation
import Testing
@testable import SwarmHubCore

/// An in-process stand-in for a device-required P5b box, one unique host per test. It verifies both signature
/// domains with the enrolled public key and refuses anything carrying a shared-key header. No sockets.
/// Like the box (skill 1.4.4), receipt reads other than `gone` and challenges report `mode`; a missing entry in
/// `modes` stands for an older box that reports none.
final class DeviceBoxProtocol: URLProtocol, @unchecked Sendable {
    final class Box: @unchecked Sendable {
        let origin: String
        let publicKey: Curve25519.Signing.PublicKey
        let keyID: String
        let lock = NSLock()
        var calls: [String] = []
        var committed: ManagedRecord?
        var refuseDecision: String?
        var loseAcknowledgement = false
        /// A lost acknowledgement for a decision the box did not commit (for example another device won the race).
        var dropDecision = false
        var gone = false
        var modes: [String: String] = ["receipt": "required", "challenge": "required"]
        var modeAfterChallenge: String?
        var challengeMode: String?
        init(origin: String, identity: DeviceApprovalIdentity) throws {
            self.origin = origin; keyID = identity.keyID
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: DeviceApprovalFixtures.hex(identity.publicKey))
        }
    }
    static let task = "task." + String(repeating: "a", count: 32)
    static let runtime = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var boxes: [String: Box] = [:]

    static func serve(_ identity: DeviceApprovalIdentity) throws -> (Box, URLSession) {
        let host = "box-\(UUID().uuidString.lowercased()).test"
        let box = try Box(origin: "https://" + host, identity: identity)
        lock.withLock { boxes[host] = box }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceBoxProtocol.self]
        return (box, URLSession(configuration: configuration))
    }

    static func operation(_ origin: String, binding: Bool = true) -> ManagedRecord {
        ManagedRecord(id: task, fingerprint: String(repeating: "b", count: 64), gate: "owner", status: "awaiting-owner", decider: "owner",
                      spec: .init(kind: "outbound", bot: "worker", intent: "TEST full operation", risks: ["money"],
                                  argv: ["/bin/true", "café"], to: "nobody@example.invalid", text: "TEST never sent ☃", fake: true),
                      remoteBinding: binding ? .init(origin: origin, runtime: runtime, profile: "owner") : nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let box = Self.lock.withLock { Self.boxes[request.url?.host ?? ""] }
        let (status, body) = box.map { box in box.lock.withLock { handle(box) } } ?? (404, Data("{}".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func body() -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return data
    }

    private func handle(_ box: Box) -> (Int, Data) {
        let refused = { (reason: String) in (403, Data(#"{"error":"control request refused","reason":"\#(reason)"}"#.utf8)) }
        guard request.value(forHTTPHeaderField: "Authorization") == nil, request.value(forHTTPHeaderField: "X-SwarmHub-Signature") == nil,
              let url = request.url, url.path.hasPrefix("/swarmhub/control/v2/owner/") else { return refused("schema_invalid") }
        let verb = url.lastPathComponent, raw = body()
        box.calls.append(verb)
        guard let envelope = try? DeviceApprovalJSON.parse(raw), let signed = envelope["signed"]?.objectValue,
              let signature = envelope["signature"]?.stringValue, signed["key_id"] == .string(box.keyID),
              signed["origin"] == .string(box.origin), let message = try? DeviceApprovalWire.message(signed, read: verb != "decide"),
              box.publicKey.isValidSignature(DeviceApprovalFixtures.hex(signature), for: message) else { return refused("signature_invalid") }
        var response: [String: JSONValue] = ["request": .string(DeviceApprovalWire.digest(raw))]
        let encode = { (record: ManagedRecord) in (try? DeviceApprovalJSON.parse(JSONEncoder().encode(record))) ?? .null }
        switch verb {
        case "receipt":
            if let committed = box.committed { response["receipt"] = encode(committed); response["mode"] = box.modes["receipt"].map(JSONValue.string) }
            else if box.gone { response["receipt"] = .null; response["status"] = .string("gone") }
            else {
                response["receipt"] = .null; response["status"] = .string("awaiting-owner"); response["mode"] = box.modes["receipt"].map(JSONValue.string)
                response["observed_at"] = .int(Int64(Date().timeIntervalSince1970)); response["record"] = encode(Self.operation(box.origin))
            }
        case "challenge":
            box.challengeMode = box.modes["challenge"]
            let record = Self.operation(box.origin, binding: false)
            let issued = Int64(Date().timeIntervalSince1970)
            response["record"] = encode(record); response["mode"] = box.modes["challenge"].map(JSONValue.string)
            response["challenge"] = .object([
                "version": .int(2), "domain": .string(DeviceApprovalWire.domain), "key_id": .string(box.keyID), "origin": .string(box.origin),
                "runtime": .string(Self.runtime), "profile": .string("owner"), "task": .string(Self.task), "gate": .string("owner"),
                "nonce": .string(String(repeating: "1", count: 64)), "issued": .int(issued), "expires": .int(issued + 60),
                "fingerprint": .string((try? DeviceApprovalWire.digest(DeviceApprovalWire.canonical(.object(record.spec.fields)))) ?? "")])
            if let mode = box.modeAfterChallenge { box.modes = ["receipt": mode, "challenge": mode] }
        case "decide":
            guard box.committed == nil else { return refused("operation_not_pending") }
            guard box.challengeMode == box.modes["challenge"] else { return refused("mode_changed") }
            if let reason = box.refuseDecision { box.refuseDecision = nil; return refused(reason) }
            if box.dropDecision { return (503, Data(#"{"error":"TEST lost acknowledgement"}"#.utf8)) }
            let approved = signed["approved"]?.boolValue ?? false
            let base = Self.operation(box.origin)
            box.committed = ManagedRecord(id: base.id, fingerprint: base.fingerprint, gate: base.gate, status: approved ? "queued" : "denied",
                decider: "owner", spec: base.spec, decided_by: "owner", decided_at: 1020, remoteBinding: base.remoteBinding,
                remoteReceipt: .init(id: "11111111-2222-3333-4444-555555555555", approved: approved, `protocol`: 2, device: box.keyID,
                                     nonce: signed["nonce"]?.stringValue, fingerprint: signed["fingerprint"]?.stringValue,
                                     message: DeviceApprovalWire.digest(message)))
            if box.loseAcknowledgement { return (503, Data(#"{"error":"TEST lost acknowledgement"}"#.utf8)) }
            response["receipt"] = encode(box.committed!)
        default: return refused("schema_invalid")
        }
        return (200, (try? JSONEncoder().encode(JSONValue.object(response))) ?? Data())
    }

    /// A receipt as the box stores it when another enrolled device (for example the Mac) decided this operation.
    static func receipt(_ origin: String, approved: Bool, device: String, nonce: String = String(repeating: "2", count: 64),
                        fingerprint: String? = nil, bindingOrigin: String? = nil) -> ManagedRecord {
        let base = operation(origin)
        let digest = (try? DeviceApprovalWire.digest(DeviceApprovalWire.canonical(.object(base.spec.fields)))) ?? ""
        return ManagedRecord(id: base.id, fingerprint: base.fingerprint, gate: base.gate, status: approved ? "queued" : "denied",
            decider: "owner", spec: base.spec, decided_by: "owner", decided_at: 1020,
            remoteBinding: .init(origin: bindingOrigin ?? origin, runtime: runtime, profile: "owner"),
            remoteReceipt: .init(id: "11111111-2222-3333-4444-555555555555", approved: approved, `protocol`: 2, device: device,
                                 nonce: nonce, fingerprint: fingerprint ?? digest, message: String(repeating: "c", count: 64)))
    }
}

struct ManagedApprovalFlowTests {
    struct Harness {
        let box: DeviceBoxProtocol.Box
        let session: URLSession
        let identity: DeviceApprovalIdentity
        let settings: DeviceApprovalSettings
        let target: ManagedApprovalTarget
        init() throws {
            let identity = try DeviceApprovalFixtures.identity()
            let (box, session) = try DeviceBoxProtocol.serve(identity)
            let settings = DeviceApprovalSettings(defaults: DeviceApprovalFixtures.defaults())
            settings.confirmOperatorCutover(box.origin)
            self.identity = identity; self.box = box; self.session = session; self.settings = settings
            target = ManagedApprovalTarget(agentID: "agent", address: box.origin, origin: box.origin, profile: "owner", task: DeviceBoxProtocol.task)
        }
        func load() async throws -> ManagedRecord {
            try await ManagedApprovalFlow.load(target, identity: identity, settings: settings, session: session, timeout: 5)
        }
        func decide(_ reviewed: ManagedRecord, _ approved: Bool) async throws -> ManagedRecord {
            try await ManagedApprovalFlow.decide(target, reviewed: reviewed, approved: approved, identity: identity, settings: settings,
                                                 session: session, timeout: 5)
        }
        var calls: [String] { box.lock.withLock { box.calls } }
    }

    @Test func pendingReadShowsTheFullOperationAndCreatesNoNonce() async throws {
        let harness = try Harness()
        let record = try await harness.load()
        #expect(record.awaiting && record.remoteReceipt == nil && record.spec == DeviceBoxProtocol.operation(harness.box.origin).spec)
        #expect(record.remoteBinding == .init(origin: harness.box.origin, runtime: DeviceBoxProtocol.runtime, profile: "owner"))
        #expect(harness.calls == ["receipt"])
        #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
    }

    @Test func approvalIsDeviceSignedAndACommittedReceiptIsNeverResent() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        let receipt = try await harness.decide(reviewed, true)
        #expect(receipt.remoteReceipt?.approved == true && receipt.remoteReceipt?.device == harness.identity.keyID && receipt.status == "queued")
        #expect(harness.calls == ["receipt", "receipt", "challenge", "decide"])
        // A repeated tap, even with the other choice, only reads the receipt.
        let again = try await harness.decide(reviewed, false)
        #expect(again.remoteReceipt?.approved == true)
        #expect(harness.calls.last == "receipt" && harness.calls.filter { $0 == "decide" }.count == 1)
    }

    @Test func refusedDecisionClearsTheAttemptAndDenyCanFollow() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        harness.box.lock.withLock { harness.box.refuseDecision = "nonce_expired" }
        await #expect(throws: ManagedControlError.self) { try await harness.decide(reviewed, true) }
        #expect(!harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
        let denied = try await harness.decide(reviewed, false)
        #expect(denied.remoteReceipt?.approved == false && denied.status == "denied")
    }

    @Test func lostAcknowledgementKeepsTheAttemptUntilTheReceiptSettlesIt() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        harness.box.lock.withLock { harness.box.loseAcknowledgement = true }
        await #expect(throws: ManagedControlError.self) { try await harness.decide(reviewed, true) }
        #expect(harness.settings.hasAttempt(origin: harness.box.origin, task: DeviceBoxProtocol.task))
        let settled = try await harness.load()
        #expect(settled.remoteReceipt?.approved == true && harness.calls.filter { $0 == "decide" }.count == 1)
    }

    @Test func goneOperationAndMismatchedTargetsFailClosed() async throws {
        let harness = try Harness()
        let reviewed = try await harness.load()
        let other = ManagedApprovalTarget(agentID: "agent", address: harness.box.origin, origin: harness.box.origin, profile: "worker",
                                          task: DeviceBoxProtocol.task)
        await #expect(throws: ManagedControlError.self) {
            try await ManagedApprovalFlow.decide(other, reviewed: reviewed, approved: true, identity: harness.identity,
                                                 settings: harness.settings, session: harness.session, timeout: 5)
        }
        #expect(harness.calls == ["receipt"])
        harness.box.lock.withLock { harness.box.gone = true }
        do { _ = try await harness.load(); Issue.record("a gone operation must not load") }
        catch ManagedControlError.operationGone {} catch { Issue.record(error) }
    }
}
