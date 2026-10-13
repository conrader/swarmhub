import Foundation

/// A server-path failure reduced to what is safe to show and keep: the request kind, the HTTP status, the Connect
/// `code` (only when it is a plain lowercase word) and an error type name. Never a URL, header, body or
/// `NSError.userInfo`, so no secret and no presigned URL can reach a message, report or log (Rule 2).
struct GrokServerError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    enum Kind: String, Sendable { case list, presign, blob }

    enum Reason: String, Sendable {
        /// HTTP 401 on an RPC: the sign-in is no longer valid (P10c pauses for a fresh one).
        case signInInvalid
        /// Not decodable, `not_found`/`unimplemented`, or the server ignored the paging cursor.
        case protocolChanged
        /// Any other 4xx (429 included) or a 5xx that is not retried: stops the run.
        case rejected
        /// 502/503/504 still failing after the retries (P10c pauses, resumable).
        case unavailable
        /// A network error, after the retries when it was retryable (P10c pauses, resumable).
        case network
        case redirectRefused
        case tooLarge
        /// A blob URL that is not https, or names localhost, a `.local` host or an IP literal; never contacted.
        case blobURLRejected
        /// `GrokProtocol.maxRequestsPerRun` reached; nothing more is sent this run.
        case requestCeiling
    }

    let kind: Kind?
    let reason: Reason
    var httpStatus: Int?
    var connectCode: String?
    var errorType: String?

    init(_ reason: Reason, kind: Kind?, httpStatus: Int? = nil, connectCode: String? = nil, errorType: String? = nil) {
        self.reason = reason
        self.kind = kind
        self.httpStatus = httpStatus
        self.connectCode = connectCode.flatMap(Self.safeCode)
        self.errorType = errorType
    }

    /// Network trouble and server overload pause the run (resumable); everything else stops it.
    var pausesRun: Bool { reason == .network || reason == .unavailable || reason == .signInInvalid }

    var description: String {
        var parts = [kind?.rawValue ?? "run", reason.rawValue]
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let connectCode { parts.append(connectCode) }
        if let errorType { parts.append(errorType) }
        return parts.joined(separator: " ")
    }

    var errorDescription: String? {
        switch reason {
        case .signInInvalid: return "Grok's service no longer accepts this sign-in."
        case .protocolChanged: return "Grok's service answered in a format Torvli does not know."
        case .rejected: return "Grok's service refused the request (HTTP \(httpStatus ?? 0))."
        case .unavailable: return "Grok's service is unavailable (HTTP \(httpStatus ?? 0)). Try again later."
        case .network: return "The network connection to Grok's service failed."
        case .redirectRefused: return "Grok's service redirected the request; Torvli does not follow redirects."
        case .tooLarge: return "Grok's service sent a larger answer than Torvli accepts."
        case .blobURLRejected: return "Grok's service named a download address Torvli does not contact."
        case .requestCeiling: return "Torvli stopped after \(GrokProtocol.maxRequestsPerRun) requests in one run."
        }
    }

    /// Connect codes are lowercase words (`not_found`, `unimplemented`, …); anything else is dropped unread.
    static func safeCode(_ code: String) -> String? {
        code.count <= 32 && !code.isEmpty && code.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }) ? code : nil
    }

    /// The `code` of a Connect JSON error body, if it is one; the rest of the body is never kept.
    static func connectCode(fromBody body: [UInt8]) -> String? {
        guard body.count <= 4096, let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let code = object["code"] as? String else { return nil }
        return safeCode(code)
    }
}
