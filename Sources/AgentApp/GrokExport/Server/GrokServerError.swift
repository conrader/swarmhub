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
    /// What Grok said about a refusal, as plain words (`diagnosticMessage`). Shown to the user; not part of `description`
    /// or of equality, so reports, logs and comparisons keep the five fields above.
    var serverMessage: String?

    static func == (left: GrokServerError, right: GrokServerError) -> Bool {
        left.kind == right.kind && left.reason == right.reason && left.httpStatus == right.httpStatus &&
            left.connectCode == right.connectCode && left.errorType == right.errorType
    }

    init(_ reason: Reason, kind: Kind?, httpStatus: Int? = nil, connectCode: String? = nil, errorType: String? = nil) {
        self.reason = reason
        self.kind = kind
        self.httpStatus = httpStatus
        self.connectCode = connectCode.flatMap(Self.safeCode)
        self.errorType = errorType
    }

    /// Network trouble and server overload pause the run (resumable); everything else stops it.
    var pausesRun: Bool { reason == .network || reason == .unavailable || reason == .signInInvalid }

    /// "HTTP 401, unauthenticated": the status and the Connect code, for a message that says what Grok answered.
    var statusDetail: String? { httpStatus.map { "HTTP \($0)" + (connectCode.map { ", \($0)" } ?? "") } }
    /// One sentence for the user: what Grok said when it said something readable, else what happened.
    var userSummary: String {
        guard let serverMessage else { return errorDescription ?? "Grok's service did not answer as expected." }
        return "Grok said: “\(serverMessage)”" + (httpStatus.map { " (HTTP \($0))" } ?? "") + "."
    }
    /// " Grok said: “…”." for a message shown to the user; empty when Grok said nothing readable.
    var saidSentence: String { serverMessage.map { " Grok said: “\($0)”." } ?? "" }

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
        case .protocolChanged: return "Grok's service answered in a format \(AppConstants.name) does not know."
        case .rejected: return "Grok's service refused the request (HTTP \(httpStatus ?? 0))."
        case .unavailable: return "Grok's service is unavailable (HTTP \(httpStatus ?? 0)). Try again later."
        case .network: return "The network connection to Grok's service failed."
        case .redirectRefused: return "Grok's service redirected the request; \(AppConstants.name) does not follow redirects."
        case .tooLarge: return "Grok's service sent a larger answer than \(AppConstants.name) accepts."
        case .blobURLRejected: return "Grok's service named a download address \(AppConstants.name) does not contact."
        case .requestCeiling: return "\(AppConstants.name) stopped after \(GrokProtocol.maxRequestsPerRun) requests in one run."
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

    /// The `message` of a Connect JSON error body, reduced to plain words: what Grok said about a refusal ("… requires
    /// a subscription"). A word survives only if it is at most 24 letters (inner `-` and `'` allowed) once the
    /// punctuation around it is trimmed, so a token, an id, a number or a URL cannot pass; a message that mentions a
    /// bearer credential is dropped whole. At most 30 words.
    static func diagnosticMessage(fromBody body: [UInt8]) -> String? {
        guard body.count <= 4096, let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let message = object["message"] as? String, !message.lowercased().contains("bearer") else { return nil }
        let punctuation = CharacterSet(charactersIn: ".,:;!?()\"“”‘’")
        var kept: [String] = []
        for piece in String(message.prefix(600)).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let word = String(piece).trimmingCharacters(in: punctuation)
            guard (1...24).contains(word.count), word.first?.isLetter == true, word.last?.isLetter == true,
                  word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "'") }) else { continue }
            kept.append(word)
            if kept.count == 30 { break }
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }
}
