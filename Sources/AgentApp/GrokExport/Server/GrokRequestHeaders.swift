import Foundation

/// Builds the request headers Grok Bot sends (`getSandBackendClientHeaders` + `o_e` in main-app.cjs;
/// port of `request_headers`). The `Authorization` string is transient and cannot be wiped (Rule 6).
/// Never set `Accept-Encoding` by hand (P10 traps); the RPC client adds `accept-encoding: gzip` itself.
enum GrokRequestHeaders {
    /// Headers common to both RPCs. `nowMs` feeds the checksum so it is recomputed per request.
    static func rpcHeaders(token: String, machineID: String, teamID: String?, version: String, nowMs: Int64) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("user-agent", GrokProtocol.userAgent(version: version)),
            ("x-cursor-client-version", version),
            ("authorization", "Bearer \(token)"),
        ]
        headers.append(contentsOf: GrokProtocol.clientHeaders)
        if let teamID { headers.append(("x-cursor-team-id", teamID)) }
        if !machineID.isEmpty { headers.append(("x-cursor-checksum", GrokChecksum.header(machineID: machineID, nowMs: nowMs))) }
        return headers
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
}
