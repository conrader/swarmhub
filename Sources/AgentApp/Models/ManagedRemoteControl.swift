import CryptoKit
import Foundation

/// The app-owned service shares the Hermes HTTPS origin and profile key. No model-mediated decisions,
/// separate secret store, redirects, URL credentials, cookies or plaintext remote connections.
enum ManagedRemoteControl {
    /// The same HTTPS origin rule as the device-signed client (one implementation, in SwarmHubCore since P5d).
    static func origin(address: String) throws -> String { try DeviceApprovalWire.baseOrigin(address: address) }

    static func signature(_ data: Data, key: String, purpose: String) -> String {
        let message = Data("swarmhub-approval-v1:\(purpose)\n".utf8) + data
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(key.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func request(address: String, profile: String, key: String, verb: String, task: String, input: Data?,
                        session: URLSession? = nil, timeout: TimeInterval = 15) async throws -> ManagedRecord {
        var started = false
        do {
            let origin = try origin(address: address)
            guard !key.isEmpty, ManagedApproval.profileName(profile) != nil,
                  ManagedApproval.validTask(task) != nil, ["get", "decide"].contains(verb),
                  let url = URL(string: origin + "/swarmhub/control/v1/" + profile) else { throw ManagedControlError.unavailable }
            let issued = Int(Date().timeIntervalSince1970)
            var body: [String: Any] = ["version": 1, "origin": origin, "profile": profile, "verb": verb,
                                      "task": task, "nonce": UUID().uuidString.lowercased(), "issued": issued, "expires": issued + 60]
            if verb == "decide" {
                guard let input, let decision = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                      Set(decision.keys) == ["approved", "fingerprint", "gate", "binding"] else { throw ManagedControlError.invalidRecord }
                body.merge(decision) { _, value in value }
            }
            let raw = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpBody = raw; request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue(signature(raw, key: key, purpose: "request"), forHTTPHeaderField: "X-SwarmHub-Signature")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            #if DEBUG
            if QAMode.enabled { request = try QAMode.boundary.native(request) }
            #endif
            let client: URLSession
            if let session { client = session }
            else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.urlCache = nil; configuration.timeoutIntervalForResource = 20
                client = URLSession(configuration: configuration)
            }
            defer { if session == nil { client.finishTasksAndInvalidate() } }
            // Task delegate also applies to injected sessions; never leak credentials through a redirect.
            let outbound = request
            let redirects = NoRedirect()
            started = true
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
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw URLError(.timedOut)
                }
                guard let result = try await group.next() else { throw ManagedControlError.unavailable }
                return result
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
                  data.count <= 1_048_576 else { throw ManagedControlError.rejected }
            return try verify(data, request: raw, key: key, origin: origin, task: task)
        } catch {
            if verb == "decide" && !started { throw ManagedControlError.unsent(error.localizedDescription) }
            throw error
        }
    }

    static func verify(_ data: Data, request: Data, key: String, origin: String, task: String,
                       now: TimeInterval = Date().timeIntervalSince1970) throws -> ManagedRecord {
        struct Envelope: Decodable { let payload: String; let signature: String }
        struct Retirement: Decodable { let task: String; let origin: String; let runtime: String; let reason: String }
        struct Response: Decodable { let request: String; let expires: Int; let record: ManagedRecord?; let retired: Retirement? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), envelope.signature.count == 64 else { throw ManagedControlError.invalidRecord }
        // CryptoKit constant-time verification, with strict lowercase hexadecimal decoding.
        var bytes = Data()
        let hex = Array(envelope.signature)
        for offset in stride(from: 0, to: hex.count, by: 2) {
            guard hex[offset...offset + 1].allSatisfy({ "0123456789abcdef".contains($0) }),
                  let byte = UInt8(String(hex[offset...offset + 1]), radix: 16) else { throw ManagedControlError.invalidRecord }
            bytes.append(byte)
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data("swarmhub-approval-v1:response\n".utf8) + payload,
                                                   using: SymmetricKey(data: Data(key.utf8))) else { throw ManagedControlError.invalidRecord }
        let response = try JSONDecoder().decode(Response.self, from: payload)
        let digest = SHA256.hash(data: request).map { String(format: "%02x", $0) }.joined()
        let sent = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        guard response.request == digest, Double(response.expires) > now,
              response.expires == (sent?["expires"] as? Int) else { throw ManagedControlError.invalidRecord }
        if let retired = response.retired {
            guard response.record == nil, sent?["verb"] as? String == "get",
                  retired.task == task, retired.origin == origin, UUID(uuidString: retired.runtime) != nil,
                  ["gone", "superseded"].contains(retired.reason) else { throw ManagedControlError.invalidRecord }
            throw ManagedControlError.retired(task: task, origin: origin, runtime: retired.runtime, reason: retired.reason)
        }
        guard let record = response.record, record.id == task, let binding = record.remoteBinding,
              binding.origin == origin, UUID(uuidString: binding.runtime) != nil,
              binding.profile == record.decider else { throw ManagedControlError.invalidRecord }
        return record
    }

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
