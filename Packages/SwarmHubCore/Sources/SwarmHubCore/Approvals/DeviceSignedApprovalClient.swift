import Foundation

/// Host hooks around the shared client. iOS uses `.standard`; the Mac passes its QA boundary and test-run guard.
public struct DeviceApprovalEnvironment: Sendable {
    public var prepare: @Sendable (URLRequest) throws -> URLRequest
    public var configure: @Sendable (URLSessionConfiguration) -> URLSessionConfiguration
    public init(prepare: @escaping @Sendable (URLRequest) throws -> URLRequest = { $0 },
                configure: @escaping @Sendable (URLSessionConfiguration) -> URLSessionConfiguration = { $0 }) {
        self.prepare = prepare; self.configure = configure
    }
    public static let standard = DeviceApprovalEnvironment()
}

/// Direct app → box v2 only, shared by Mac and iOS (P5d). TLS authenticates responses; reads and decisions use
/// separate domains. There is no shared-key path here: no Bearer key, no HMAC, no v1 endpoint.
public enum DeviceSignedApprovalClient {
    private struct Refusal: Error { let reason: String }
    public static func request(address: String, profile: String, verb: String, task: String, input: Data?,
                               identity: DeviceApprovalIdentity, settings: DeviceApprovalSettings, reviewed: ManagedRecord? = nil,
                               session: URLSession? = nil, timeout: TimeInterval = 15,
                               environment: DeviceApprovalEnvironment = .standard) async throws -> ManagedRecord {
        var dispatched = false
        do {
            let origin = try DeviceApprovalWire.origin(address: address)
            guard DeviceApprovalWire.validProfile(profile), DeviceApprovalWire.validTask(task),
                  ["get", "decide"].contains(verb) else { throw ManagedControlError.unavailable }
            let pending = try settings.attempt(origin: origin, task: task)
            if verb == "get" {
                let response = try await read("receipt", origin: origin, profile: profile, task: task,
                                              identity: identity, session: session, timeout: timeout, environment: environment)
                if let value = response["receipt"], !value.isNull {
                    let record = try decodeRecord(value)
                    try validateReceipt(record, origin: origin, profile: profile, task: task, identity: identity, expected: pending)
                    return record
                }
                if response["receipt"] == .null, response["status"] == .string("gone"),
                   Set(response.keys) == ["request", "receipt", "status"] {
                    // No receipt and no stored operation: no decision can commit for this task any more.
                    if let pending { try settings.clearExpiredAttempt(pending, origin: origin, task: task) }
                    throw ManagedControlError.operationGone
                }
                guard response["receipt"] == .null, response["status"]?.stringValue == "awaiting-owner"
                        || response["status"]?.stringValue == "awaiting-coordinator" else { throw ManagedControlError.invalidRecord }
                guard let value = response["record"] else { throw ManagedControlError.invalidRecord }
                let record = try decodeRecord(value)
                guard record.id == task, record.decider == profile, record.awaiting,
                      record.status == response["status"]?.stringValue,
                      ["owner", "coordinator"].contains(record.gate), let binding = record.remoteBinding,
                      binding.origin == origin, binding.profile == profile,
                      DeviceApprovalWire.matches(binding.runtime, "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") else {
                    throw ManagedControlError.invalidRecord
                }
                if let pending {
                    // The box snapshots time and pending state under its decision lock. A local
                    // clock ahead of the box, or a read from before expiry, cannot unlock a nonce.
                    guard pending["approved"]?.boolValue != nil, let expires = pending["expires"]?.intValue,
                          let observed = response["observed_at"]?.intValue, observed >= expires,
                          observed <= 9_007_199_254_740_991 else { throw ManagedControlError.rejected }
                    var challenge = pending
                    challenge.removeValue(forKey: "approved")
                    try DeviceApprovalWire.validateChallenge(challenge, identity: identity, origin: origin,
                                                             profile: profile, task: task, record: record)
                    guard pending["runtime"] == .string(binding.runtime), record.remoteReceipt == nil,
                          record.decided_by == nil, record.decided_at == nil else { throw ManagedControlError.invalidRecord }
                    try settings.clearExpiredAttempt(pending, origin: origin, task: task)
                    // Stop card reconciliation here. Another explicit user choice is required.
                    throw ManagedControlError.attemptExpired
                }
                return record
            }
            if pending != nil { throw ManagedControlError.rejected }
            // Each decide obtains a new box-owned binding. No nonce or times are constructed locally.
            let response = try await read("challenge", origin: origin, profile: profile, task: task,
                                          identity: identity, session: session, timeout: timeout, environment: environment)
            guard var signed = response["challenge"]?.objectValue, let value = response["record"] else { throw ManagedControlError.invalidRecord }
            var record = try decodeRecord(value)
            try DeviceApprovalWire.validateChallenge(signed, identity: identity, origin: origin, profile: profile, task: task, record: record)
            record.remoteBinding = .init(origin: origin, runtime: signed["runtime"]!.stringValue!, profile: profile)
            guard let reviewed, record.sameOperation(as: reviewed), let input,
                  let decision = try DeviceApprovalJSON.parse(input).objectValue,
                  let approved = decision["approved"]?.boolValue,
                  decision["fingerprint"] == .string(reviewed.fingerprint), decision["gate"] == .string(reviewed.gate),
                  decision["binding"] == .object(["origin": .string(origin), "runtime": signed["runtime"]!, "profile": .string(profile)]) else {
                throw ManagedControlError.invalidRecord
            }
            signed["approved"] = .bool(approved)
            let raw = try DeviceApprovalWire.envelope(signed, identity: identity)
            // Persist the exact message binding before dispatch, including across app restarts/lost ACKs.
            try settings.remember(signed, origin: origin, task: task)
            dispatched = true
            let result: [String: JSONValue]
            do {
                result = try await post(raw, origin: origin, profile: profile, verb: "decide", session: session, timeout: timeout,
                                       environment: environment)
            } catch let refusal as Refusal {
                // Only an authenticated, explicit box refusal proves this dispatch did not commit.
                try settings.clearRefusedAttempt(origin: origin, task: task)
                throw ManagedControlError.refused(refusal.reason)
            }
            guard let receipt = result["receipt"] else { throw ManagedControlError.invalidRecord }
            let confirmed = try decodeRecord(receipt)
            try validateReceipt(confirmed, origin: origin, profile: profile, task: task, identity: identity, expected: signed)
            guard confirmed.confirms(approved, original: reviewed) else { throw ManagedControlError.invalidRecord }
            return confirmed
        } catch {
            if verb == "decide", !dispatched {
                // Existing pending metadata means an earlier dispatch was uncertain, even if this call sent nothing.
                if let box = try? DeviceApprovalWire.origin(address: address),
                   settings.hasAttempt(origin: box, task: task) { throw ManagedControlError.rejected }
                throw ManagedControlError.unsent(error.localizedDescription)
            }
            throw error
        }
    }

    public static func read(_ verb: String, origin: String, profile: String, task: String, identity: DeviceApprovalIdentity,
                            session: URLSession?, timeout: TimeInterval,
                            environment: DeviceApprovalEnvironment = .standard) async throws -> [String: JSONValue] {
        let body: [String: JSONValue] = ["version": .int(2), "domain": .string(DeviceApprovalWire.readDomain), "verb": .string(verb),
            "key_id": .string(identity.keyID), "origin": .string(origin), "profile": .string(profile), "task": .string(task),
            "issued": .int(Int64(Date().timeIntervalSince1970))]
        do {
            return try await post(DeviceApprovalWire.envelope(body, identity: identity, read: true), origin: origin,
                                  profile: profile, verb: verb, session: session, timeout: timeout, environment: environment)
        } catch is Refusal {
            throw ManagedControlError.rejected
        }
    }

    public static func decodeRecord(_ value: JSONValue) throws -> ManagedRecord {
        // Validate the original spec before Codable can normalize a float such as 1.0 to an integer.
        guard let spec = value["spec"], spec.objectValue != nil else { throw ManagedControlError.invalidRecord }
        _ = try DeviceApprovalWire.canonical(spec)
        return try JSONDecoder().decode(ManagedRecord.self, from: JSONEncoder().encode(value))
    }

    public static func validateReceipt(_ record: ManagedRecord, origin: String, profile: String, task: String,
                                       identity: DeviceApprovalIdentity, expected: [String: JSONValue]?) throws {
        guard record.id == task, record.decider == profile, ["owner", "coordinator"].contains(record.gate), let binding = record.remoteBinding,
              binding.origin == origin, binding.profile == profile, DeviceApprovalWire.matches(binding.runtime, "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"),
              let receipt = record.remoteReceipt, receipt.`protocol` == 2, receipt.device == identity.keyID,
              let nonce = receipt.nonce, DeviceApprovalWire.matches(nonce, "[a-f0-9]{64}"),
              let message = receipt.message, DeviceApprovalWire.matches(message, "[a-f0-9]{64}"),
              receipt.fingerprint == (try DeviceApprovalWire.digest(DeviceApprovalWire.canonical(.object(record.spec.fields)))),
              record.confirms(receipt.approved, original: record),
              (receipt.approved ? ["queued", "running", "done", "failed"].contains(record.status) : record.status == "denied") else { throw ManagedControlError.invalidRecord }
        if let expected {
            guard expected["origin"] == .string(origin), expected["runtime"] == .string(binding.runtime),
                  expected["profile"] == .string(profile), expected["task"] == .string(task),
                  expected["key_id"] == .string(identity.keyID), expected["gate"] == .string(record.gate),
                  expected["approved"] == .bool(receipt.approved), expected["nonce"] == .string(nonce),
                  expected["fingerprint"] == receipt.fingerprint.map(JSONValue.string),
                  message == (try DeviceApprovalWire.digest(DeviceApprovalWire.message(expected))) else { throw ManagedControlError.invalidRecord }
        }
    }

    static func post(_ raw: Data, origin: String, profile: String, verb: String, session: URLSession?,
                     timeout: TimeInterval, environment: DeviceApprovalEnvironment) async throws -> [String: JSONValue] {
        guard let url = URL(string: origin + "/swarmhub/control/v2/" + profile + "/" + verb) else { throw ManagedControlError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = raw; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request = try environment.prepare(request)
        let client: URLSession
        if let session { client = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 20
            client = URLSession(configuration: environment.configure(configuration))
        }
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        let outbound = request, redirects = NoRedirect()
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            defer { group.cancelAll() }
            group.addTask {
                do {
                    let result = try await client.data(for: outbound, delegate: redirects)
                    guard !redirects.rejected else { throw ManagedControlError.rejected }
                    return result
                } catch {
                    if redirects.rejected { throw ManagedControlError.rejected }
                    throw error
                }
            }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw URLError(.timedOut) }
            guard let result = try await group.next() else { throw ManagedControlError.unavailable }
            return result
        }
        guard let http = response as? HTTPURLResponse, http.url == url, data.count <= 1_048_576,
              let result = try DeviceApprovalJSON.parse(data).objectValue else { throw ManagedControlError.rejected }
        let refusals: Set<String> = ["schema_invalid", "protocol_unsupported", "device_unknown", "device_revoked",
            "signature_invalid", "box_mismatch", "profile_mismatch", "device_unauthorized", "task_mismatch",
            "fingerprint_mismatch", "gate_mismatch", "operation_not_pending", "nonce_unknown", "nonce_mismatch",
            "nonce_replayed", "nonce_not_yet_valid", "nonce_expired", "state_invalid"]
        if http.statusCode == 403, Set(result.keys) == ["error", "reason"],
           result["error"] == .string("control request refused"), let reason = result["reason"]?.stringValue,
           refusals.contains(reason) { throw Refusal(reason: reason) }
        guard http.statusCode == 200, result["request"] == .string(DeviceApprovalWire.digest(raw)) else {
            throw ManagedControlError.rejected
        }
        return result
    }

    /// Declines redirects and cancels the task, so a redirect can never carry a signed request elsewhere.
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var sawRedirect = false
        var rejected: Bool { lock.withLock { sawRedirect } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            lock.withLock { sawRedirect = true }
            // Declining alone can wait for the original response body indefinitely. Cancel this
            // task as well, recording the policy error first so cancellation cannot mask it.
            task.cancel()
            completionHandler(nil)
        }
    }
}
