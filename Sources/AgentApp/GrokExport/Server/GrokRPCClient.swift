import Foundation

/// Read-only client for Grok's private history service (Rule 1). It can express exactly two RPCs
/// (`GrokProtocol.Method`) plus a GET of a validated presigned blob URL with no custom headers. Requests are strictly
/// paced, retried only per decision D2, and every failure is a `GrokServerError` that carries no URL, header or body.
actor GrokRPCClient {
    struct Limits: Sendable {
        var rpcMaxBytes = GrokProtocol.maxRPCResponseBytes
        var blobMaxBytes = GrokProtocol.maxBlobResponseBytes
        var retryDelays = GrokProtocol.retryDelays
        var minInterval = GrokProtocol.minRequestInterval
        var maxRequests = GrokProtocol.maxRequestsPerRun
    }

    private let session: GrokSession
    private let credentials: GrokCredentials
    private let clientVersion: String
    private let appVersion: String
    private let baseURL: URL
    private let clock: any GrokClock
    private let limits: Limits
    private var pacer: GrokPacer

    /// Every request started so far, retries and blob GETs included.
    var requestCount: Int { pacer.requests }

    init(session: GrokSession, credentials: GrokCredentials, clientVersion: String, appVersion: String,
         baseURL: URL = GrokProtocol.baseURL, clock: any GrokClock, limits: Limits = Limits()) {
        self.session = session
        self.credentials = credentials
        self.clientVersion = clientVersion
        self.appVersion = appVersion
        self.baseURL = baseURL
        self.clock = clock
        self.limits = limits
        pacer = GrokPacer(interval: limits.minInterval, maxRequests: limits.maxRequests)
    }

    // MARK: The two calls

    func listEntries(agentID: String, limit: UInt32, beforeSeq: Int64?) async throws -> [GrokProtobuf.TranscriptRow] {
        let body = GrokProtobuf.encodeListRequest(agentID: agentID, limit: limit, beforeSeq: beforeSeq)
        let data = try await rpc(.listTranscriptEntries, kind: .list, body: body)
        return try decoded(.list) { try GrokProtobuf.decodeListResponse(data) }
    }

    func presign(relPaths: [String]) async throws -> [String: String] {
        let data = try await rpc(.presignReads, kind: .presign, body: GrokProtobuf.encodePresignRequest(relPaths: relPaths))
        return try decoded(.presign) { try GrokProtobuf.decodePresignResponse(data) }
    }

    /// The blob's bytes, or nil when it is gone (HTTP 404). No auth header, no cookies, redirects refused.
    func fetchBlob(_ urlString: String) async throws -> [UInt8]? {
        guard let url = GrokBlobURL.validated(urlString) else { throw GrokServerError(.blobURLRejected, kind: .blob) }
        let (status, data) = try await send(kind: .blob, maxBytes: limits.blobMaxBytes) {
            var request = URLRequest(url: url, timeoutInterval: GrokProtocol.requestTimeout)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            return request
        }
        switch status {
        case 200: return data
        case 404: return nil
        default: throw Self.failure(kind: .blob, status: status, body: data, authenticated: false)
        }
    }

    // MARK: Transport

    private func rpc(_ method: GrokProtocol.Method, kind: GrokServerError.Kind, body: [UInt8]) async throws -> [UInt8] {
        let url = GrokProtocol.url(for: method, base: baseURL)
        let (status, data) = try await send(kind: kind, maxBytes: limits.rpcMaxBytes) {
            var request = URLRequest(url: url, timeoutInterval: GrokProtocol.requestTimeout)
            request.httpMethod = "POST"
            request.httpBody = Data(body)
            request.httpShouldHandleCookies = false
            // Built per attempt: a fresh checksum and x-request-id every time.
            let headers = GrokRequestHeaders.rpcHeaders(
                token: credentials.token.reveal(), machineID: credentials.machineID.reveal(), teamID: credentials.teamID,
                clientVersion: clientVersion, appVersion: appVersion, nowMs: clock.wallMs()) + GrokRequestHeaders.connectHeaders()
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            return request
        }
        guard status == 200 else { throw Self.failure(kind: kind, status: status, body: data, authenticated: true) }
        return data
    }

    /// One logical request: paced, retried on network errors and 502/503/504 only (D2), each retry paced again.
    private func send(kind: GrokServerError.Kind, maxBytes: Int,
                      _ makeRequest: () -> URLRequest) async throws -> (Int, [UInt8]) {
        var attempt = 0
        while true {
            try await pace(kind: kind)
            do {
                let (status, data) = try await perform(makeRequest(), kind: kind, maxBytes: maxBytes)
                guard GrokProtocol.retriedStatuses.contains(status), attempt < limits.retryDelays.count else { return (status, data) }
            } catch let failure as NetworkFailure {
                guard failure.retryable, attempt < limits.retryDelays.count else {
                    throw GrokServerError(.network, kind: kind, errorType: failure.type)
                }
            }
            try await clock.sleep(for: limits.retryDelays[attempt])
            attempt += 1
        }
    }

    private func pace(kind: GrokServerError.Kind) async throws {
        try Task.checkCancellation()
        guard let wait = pacer.reserve(now: clock.now()) else { throw GrokServerError(.requestCeiling, kind: kind) }
        if wait > .zero { try await clock.sleep(for: wait) }
    }

    private func perform(_ request: URLRequest, kind: GrokServerError.Kind, maxBytes: Int) async throws -> (Int, [UInt8]) {
        do {
            let (bytes, response) = try await session.urlSession.bytes(for: request, delegate: session.delegate)
            guard let http = response as? HTTPURLResponse else { throw GrokServerError(.protocolChanged, kind: kind) }
            if (300..<400).contains(http.statusCode) {
                bytes.task.cancel()
                throw GrokServerError(.redirectRefused, kind: kind, httpStatus: http.statusCode)
            }
            if http.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                throw GrokServerError(.tooLarge, kind: kind, httpStatus: http.statusCode)
            }
            var data: [UInt8] = []
            for try await byte in bytes {
                guard data.count < maxBytes else {
                    bytes.task.cancel()
                    throw GrokServerError(.tooLarge, kind: kind, httpStatus: http.statusCode)
                }
                data.append(byte)
            }
            return (http.statusCode, data)
        } catch let error as GrokServerError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            let retryable = (error as? URLError).map { Self.retryableCodes.contains($0.code) } ?? false
            throw NetworkFailure(retryable: retryable, type: String(describing: Swift.type(of: error)))
        }
    }

    /// A transport error before `send` decides on a retry; only the type name survives.
    private struct NetworkFailure: Error {
        let retryable: Bool
        let type: String
    }

    private static let retryableCodes: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
        .resourceUnavailable, .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    private static func failure(kind: GrokServerError.Kind, status: Int, body: [UInt8], authenticated: Bool) -> GrokServerError {
        let code = GrokServerError.connectCode(fromBody: body)
        if let code, GrokProtocol.protocolChangedCodes.contains(code) {
            return GrokServerError(.protocolChanged, kind: kind, httpStatus: status, connectCode: code)
        }
        if status == 401, authenticated { return GrokServerError(.signInInvalid, kind: kind, httpStatus: status, connectCode: code) }
        if GrokProtocol.retriedStatuses.contains(status) {
            return GrokServerError(.unavailable, kind: kind, httpStatus: status, connectCode: code)
        }
        return GrokServerError(.rejected, kind: kind, httpStatus: status, connectCode: code)
    }

    private func decoded<T>(_ kind: GrokServerError.Kind, _ decode: () throws -> T) throws -> T {
        do { return try decode() } catch {
            throw GrokServerError(.protocolChanged, kind: kind, errorType: String(describing: Swift.type(of: error)))
        }
    }
}
