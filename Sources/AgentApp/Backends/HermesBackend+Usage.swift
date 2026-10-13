import Foundation

extension HermesBackend {
    /// Reads the profile's sessions with their token counters: `GET /api/sessions?limit=200&offset=…&include_children=true`
    /// (children carry the tokens of compressed/branched continuations), at most `maxPages` pages. GET only.
    func usageSessions(pageSize: Int = 200, maxPages: Int = 10) async throws -> (sessions: [SessionUsage], truncated: Bool) {
        guard try await transport() == .nativeSessions else { throw BackendError.unavailable("This Hermes server has no sessions API.") }
        var sessions: [SessionUsage] = []
        for page in 0..<maxPages {
            let json = try await jsonRequest(path: "api/sessions?limit=\(pageSize)&offset=\(page * pageSize)&include_children=true")
            let rows = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
            sessions += rows.compactMap(SessionUsage.parse)
            guard json["has_more"] as? Bool == true, !rows.isEmpty else { return (sessions, false) }
        }
        return (sessions, true)
    }
}
