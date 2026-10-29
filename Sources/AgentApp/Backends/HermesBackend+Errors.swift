import Foundation

extension HermesBackend {
    static let errorBodyLimit = 64 * 1024
    static let diagnosticLimit = 2_000

    /// HTTP refusals use ordinary JSON or text even when the request negotiated SSE.
    /// Read only a bounded prefix, with a separate deadline; a broken error body must
    /// still report the known HTTP status rather than becoming an ambiguous stream break.
    func validateStreamResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
            try validate(response)
            return
        }
        let data = await withTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= Self.errorBodyLimit { bytes.task.cancel(); break }
                    }
                } catch { /* Best effort: retain the prefix and the HTTP status. */ }
                return data
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeouts.control)) }
                catch { return Data() }
                bytes.task.cancel()
                return Data()
            }
            let first = await group.next() ?? Data()
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        try validate(response, data: data)
    }

    static func resultFailed(_ json: [String: Any]) -> Bool {
        let sources = [json, json["hermes"] as? [String: Any] ?? [:]]
        return sources.contains {
            ($0["completed"] as? Bool) == false || ($0["failed"] as? Bool) == true ||
            ($0["partial"] as? Bool) == true || ($0["interrupted"] as? Bool) == true ||
            ["failed", "error", "cancelled"].contains($0["status"] as? String ?? "")
        }
    }

    /// Native failures may omit error text entirely; keep the preceding unsuccessful
    /// assistant result as the fallback. Legacy failures carry both error and hermes.
    func failureMessage(_ json: [String: Any], fallback: String = "Hermes run failed.") -> String {
        diagnosticText(errorDetail(json) ?? fallback, fallback: "Hermes run failed.")
    }

    /// autoctx1: a failure the box coded as a context overflow carries `ContextOverflow.tag`, whatever its wording.
    func taggedFailure(_ json: [String: Any], _ text: String) -> String {
        ContextOverflow.hasCode(json) && !text.hasPrefix(ContextOverflow.tag) ? ContextOverflow.tag + text : text
    }

    func errorDetail(_ json: [String: Any]) -> String? {
        let error = json["error"] as? [String: Any] ?? [:]
        let hermes = json["hermes"] as? [String: Any] ?? [:]
        func firstText(_ values: [Any?]) -> String? {
            values.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let message = firstText([error["message"], json["error"], json["message"], json["detail"], hermes["error"]])
        let code = firstText([error["code"], json["error_code"], json["code"], hermes["error_code"]])
        if let message, let code { return "\(message) (\(code))" }
        return message ?? code
    }

    func diagnosticText(_ raw: String, fallback: String) -> String {
        // Redact before truncating so a key crossing the display limit cannot leak.
        let redacted = ToolEvent.redacted(apiKey.isEmpty ? raw : raw.replacingOccurrences(of: apiKey, with: "[key]"), key: apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return fallback }
        return redacted.count > Self.diagnosticLimit ? String(redacted.prefix(Self.diagnosticLimit - 1)) + "…" : redacted
    }
}

/// uxfix3: refusals the app answers by itself (a steer the run cannot take any more, a session title already in use).
extension HermesBackend {
    static let noRunYet = "Hermes has not reported a run for this turn yet."
    static let steerNotAccepted = "Hermes did not accept the steer message."

    /// The title, the title with a short tag of the session (or a random one), then no title.
    static func sessionTitles(_ title: String, id: String?) -> [String] {
        guard !title.isEmpty else { return [""] }
        let tag = String((id ?? UUID().uuidString).lowercased().filter { $0.isLetter || $0.isNumber }.suffix(8))
        return [title, "\(title) · \(tag)", ""]
    }

    /// Hermes answers 400 `invalid_title` when the title is taken (some versions 409); a 409 `session_exists` is not one.
    static func isTitleClash(_ code: Int, _ text: String) -> Bool { (code == 400 || code == 409) && text.contains("invalid_title") }
}
