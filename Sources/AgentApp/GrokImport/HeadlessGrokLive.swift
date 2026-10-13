import Foundation

/// Steps (f)/(g) of the throwaway `--grok-spike` harness (deleted in P10c). Deliberately NOT `@MainActor`:
/// `HeadlessGrok.run` blocks the main thread on a semaphore while this work runs, so anything here that hopped to
/// the main actor (an inherited-isolation `Task`, `MainActor.run`, a URLSession delegate queue on main) would
/// never be scheduled and the run would hang after step (e). Every entry point is nonisolated and the work runs in
/// a `Task.detached` on the cooperative pool. No secrets leave this file; results are numbers/booleans only.
enum HeadlessGrokLive {
    struct Outcome: Sendable {
        var stepF: HeadlessGrok.Report.LiveStep?
        var stepG: Int?
    }

    /// Runs `work` off the main actor and blocks the calling thread (the main thread in the spike) until it
    /// finishes or `timeout` passes; returns nil on timeout. Safe to call on main because `work` never needs it.
    static func blockingRun<T: Sendable>(timeout: DispatchTime = .distantFuture, _ work: @escaping @Sendable () async -> T) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await work())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: timeout) == .success else { return nil }
        return box.get()
    }

    static func liveSteps(agentID: String, secretsData: Data, version: String) async -> Outcome {
        var outcome = Outcome()
        // Decrypt afresh for the live call; the key and token live only in this scope.
        guard let encrypted = try? GrokSecretsFile.encryptedAccount(data: secretsData) else { return outcome }
        var password = (try? GrokKeychain().readPassword()) ?? []
        defer { GrokSafeStorage.zero(&password) }
        guard !password.isEmpty, var key = try? GrokSafeStorage.deriveKey(password: password) else { return outcome }
        defer { GrokSafeStorage.zero(&key) }
        guard let creds = try? GrokCredentials.decrypt(from: encrypted, key: key, now: Date()) else { return outcome }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let body = GrokProtobuf.encodeListRequest(agentID: agentID, limit: 2)

        if let result = try? await liveRPC(body: body, creds: creds, nowMs: nowMs, version: version, honestUA: false) {
            outcome.stepF = result
        }
        if let honest = try? await liveRPC(body: body, creds: creds, nowMs: nowMs, version: version, honestUA: true) {
            outcome.stepG = honest.httpStatus
        }
        return outcome
    }

    private static func liveRPC(body: [UInt8], creds: GrokCredentials, nowMs: Int64, version: String, honestUA: Bool) async throws -> HeadlessGrok.Report.LiveStep {
        var request = URLRequest(url: GrokProtocol.url(for: .listTranscriptEntries))
        request.httpMethod = "POST"
        request.httpBody = Data(body)
        request.timeoutInterval = GrokProtocol.requestTimeout
        for (name, value) in GrokRequestHeaders.rpcHeaders(token: creds.token.reveal(), machineID: creds.machineID.reveal(),
                                                           teamID: creds.teamID, version: version, nowMs: nowMs) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(GrokProtocol.contentType, forHTTPHeaderField: "content-type")
        request.setValue(GrokProtocol.connectProtocolVersion, forHTTPHeaderField: "connect-protocol-version")
        request.setValue(GrokProtocol.connectTimeoutMs, forHTTPHeaderField: "connect-timeout-ms")
        request.setValue("gzip", forHTTPHeaderField: "accept-encoding")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        if honestUA { request.setValue("Torvli/\(version)", forHTTPHeaderField: "user-agent") }

        // delegateQueue nil: URLSession makes its own serial queue, never the (blocked) main queue.
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let bytes = [UInt8](data)
        let gzip = bytes.count >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
        var rows = 0
        var newest: Int64 = 0
        if let decoded = try? GrokProtobuf.decodeListResponse(bytes) {
            rows = decoded.count
            newest = decoded.map(\.seq).max() ?? 0
        }
        // networkProtocolName is only exposed via URLSessionTaskMetrics; the spike records "" when unknown.
        return .init(httpStatus: http?.statusCode ?? -1, networkProtocol: "",
                     bytesStartGzip: gzip, rowsDecoded: rows, newestSeq: newest)
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func get() -> T? { lock.withLock { value } }
}
