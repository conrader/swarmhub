import Foundation

/// Builds the request headers Grok Bot sends (`getSandBackendClientHeaders` + `o_e` in main-app.cjs;
/// port of `request_headers`), except the user-agent, which names Torvli (drift register in `GrokProtocol`).
/// The `Authorization` string is transient and cannot be wiped (Rule 6).
/// Never set `Accept-Encoding` by hand (P10 traps): URLSession negotiates it and decodes the body itself.
enum GrokRequestHeaders {
    /// Headers common to both RPCs. `nowMs` feeds the checksum so it is recomputed per request.
    static func rpcHeaders(token: String, machineID: String, teamID: String?, clientVersion: String, appVersion: String,
                           nowMs: Int64) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("user-agent", GrokProtocol.userAgent(appVersion: appVersion)),
            ("x-cursor-client-version", clientVersion),
            ("authorization", "Bearer \(token)"),
        ]
        headers.append(contentsOf: GrokProtocol.clientHeaders)
        if let teamID { headers.append(("x-cursor-team-id", teamID)) }
        if !machineID.isEmpty { headers.append(("x-cursor-checksum", GrokChecksum.header(machineID: machineID, nowMs: nowMs))) }
        return headers
    }

    /// The Connect unary headers, with a new `x-request-id` per request.
    static func connectHeaders(requestID: UUID = UUID()) -> [(String, String)] {
        [("content-type", GrokProtocol.contentType), ("connect-protocol-version", GrokProtocol.connectProtocolVersion),
         ("connect-timeout-ms", GrokProtocol.connectTimeoutMs), ("x-request-id", requestID.uuidString.lowercased())]
    }

    /// The client version read live from the installed app's Info.plist: `version.split("-")[0]` must be three
    /// numeric groups, else the fallback. Mirrors `client_version`.
    static func clientVersion(fromShortVersion raw: String?) -> String {
        guard let raw else { return GrokProtocol.clientVersionFallback }
        let base = raw.split(separator: "-", maxSplits: 1).first.map(String.init) ?? raw
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        let threeNumeric = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        return threeNumeric ? base : GrokProtocol.clientVersionFallback
    }

    /// Torvli's own version for the user-agent: one to four dot-separated ASCII number groups, else `dev`.
    static func appVersion(fromShortVersion raw: String?) -> String {
        guard let raw else { return GrokProtocol.appVersionFallback }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = (1...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        return numeric ? raw : GrokProtocol.appVersionFallback
    }
}
