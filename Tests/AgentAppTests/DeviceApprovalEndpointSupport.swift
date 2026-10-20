import CryptoKit
import Foundation
import Testing
@testable import AgentApp

let deviceTask = "task." + String(repeating: "a", count: 32)
let deviceRuntime = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

/// A TLS endpoint stand-in. CryptoKit verifies both domains; no sockets or shared-key verifier.
final class DeviceEndpoint: @unchecked Sendable {
    let identity: DeviceApprovalIdentity
    private let lock = NSLock()
    private var committed: ManagedRecord?
    private var events: [String] = []
    var issued = Int64(Date().timeIntervalSince1970)
    var receiptTime: Int64?
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
                    response["observed_at"] = .int(receiptTime ?? Int64(Date().timeIntervalSince1970))
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
                    "issued": .int(issued), "expires": .int(issued + 60),
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
