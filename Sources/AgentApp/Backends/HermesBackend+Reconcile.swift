import Foundation

/// P16 reads for the reconcile: GET only, never a POST.
extension HermesBackend {
    /// `GET api/sessions/{id}/messages?order=latest&limit=<window>&offset=<offset>`: the box returns the page oldest first.
    /// 404 `session_not_found` means the box has no copy (not an error). A connection-level failure is repeated once at
    /// once, except `.timedOut` (a dead link would only double the wait).
    func recentMessages(sessionID: String, window: Int, offset: Int) async throws -> MessagePage {
        guard try await transport() == .nativeSessions else { return MessagePage(rows: [], full: false, missing: true) }
        let escaped = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let path = "api/sessions/\(escaped)/messages?order=latest&limit=\(window)&offset=\(offset)"
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await rawRequest(path: path, timeout: timeouts.read) }
        catch let error as URLError where error.code != .timedOut && error.code != .cancelled {
            (data, response) = try await rawRequest(path: path, timeout: timeouts.read)
        }
        let http = response as? HTTPURLResponse
        if http?.statusCode == 404 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (json?["error"] as? [String: Any])?["code"] as? String ?? json?["code"] as? String
            if code == "session_not_found" || code == nil { return MessagePage(rows: [], full: false, missing: true, serverDate: Self.serverDate(http)) }
        }
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["data"] as? [[String: Any]] else {
            throw BackendError.unavailable("Hermes returned an invalid messages page.")
        }
        return MessagePage(rows: rows.compactMap(Self.parseMessage), full: rows.count >= window, serverDate: Self.serverDate(http), bytes: data.count)
    }

    /// `GET /v1/runs/{id}` (capability `run_status`): queued, running, waiting_for_approval, stopping, completed, failed,
    /// cancelled. Unknown (no capability, 404, expired after 3,600 s) is nil.
    func runStatus(runID: String) async throws -> String? {
        guard try await features().contains("run_status") else { return nil }
        let escaped = runID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runID
        do { return try await jsonRequest(path: "v1/runs/\(escaped)", timeout: timeouts.read)["status"] as? String }
        catch BackendError.http(let code, _) where code == 404 { return nil }
    }

    static func serverDate(_ response: HTTPURLResponse?) -> Date? {
        guard let value = response?.value(forHTTPHeaderField: "Date") else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
