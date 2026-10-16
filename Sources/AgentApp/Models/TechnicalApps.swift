import Foundation

/// P51 rule 1: the one line of a connected-apps request and its result (`ConnectedAppsChat`'s protocol rows), and their
/// JSON pretty-printed for unfold.
enum TechnicalApps {
    /// Unfold shows this much of each part; "Show all" the rest.
    static let previewLimit = 4_096

    /// "Jarvis used GitHub · Get the authenticated user · ok", "Jarvis looked up GitHub tools · 3 found".
    static func summary(request: String, result: String?, waiting: Bool, context: TechnicalContext) -> String {
        let json = object(requestBody(request)), bot = context.botName
        let resultJSON = result.flatMap { object(resultBody($0)) }
        let failed = result != nil && resultJSON?["error"] != nil
        let status = result == nil ? (waiting ? "waiting for approval" : "no result") : failed ? "failed" : "ok"
        switch json?["action"] as? String {
        case "search":
            let tools = resultJSON?["tools"] as? [[String: Any]]
            let apps = Array(Set((tools ?? []).compactMap { ($0["app"] ?? $0["toolkit"]) as? String })).sorted().map(context.appName)
            let what = apps.isEmpty ? "app tools" : apps.joined(separator: ", ") + " tools"
            let found = result == nil || failed ? status : tools.map { "\($0.count) found" } ?? status
            return "\(bot) looked up \(what) · \(found)"
        case "execute":
            let slug = json?["tool"] as? String ?? ""
            let (app, tool) = split(slug)
            let account = (json?["account"] as? String).map { context.accountName($0) ?? $0 }
            return "\(bot) used \(context.appName(app))\(account.map { " (\($0))" } ?? "") · \(tool) · \(status)"
        case "readArtifact": return "\(bot) read a saved app result · \(status)"
        case "workflow": return "\(bot) updated the workflow · \(status)"
        default: return "\(bot) made an app request · \(status)"
        }
    }

    /// A result row with no request before it.
    static func summary(result: String, context: TechnicalContext) -> String {
        "\(context.botName) got an app result · " + (object(resultBody(result))?["error"] != nil ? "failed" : "ok")
    }

    /// `GITHUB_GET_THE_AUTHENTICATED_USER` → ("github", "Get the authenticated user").
    static func split(_ slug: String) -> (app: String, tool: String) {
        let parts = slug.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return (slug.lowercased(), slug.isEmpty ? "app action" : slug) }
        let words = parts[1].replacingOccurrences(of: "_", with: " ").lowercased()
        return (parts[0].lowercased(), words.prefix(1).uppercased() + words.dropFirst())
    }

    /// The JSON after the request's marker.
    static func requestBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = trimmed.range(of: "]]") else { return trimmed }
        return trimmed[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON after the result's prefix, without SwarmHub's closing instruction ("Continue the original task…").
    static func resultBody(_ text: String) -> String {
        var body = Substring(text.drop { $0.isWhitespace })
        let prefix = ConnectedAppsChat.resultPrefix.trimmingCharacters(in: .newlines)
        if body.hasPrefix(prefix) { body = body.dropFirst(prefix.count) }
        for tail in ["\nContinue the original task", "\nNext offset: ", "\n[Excerpt. "] {
            if let range = body.range(of: tail, options: .backwards) { body = body[..<range.lowerBound] }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Request and result for unfold: each part's JSON pretty-printed (text that is not JSON as it is).
    static func parts(request: String?, result: String?) -> [(title: String, text: String)] {
        var parts: [(String, String)] = []
        if let request { parts.append(("Request", pretty(requestBody(request)))) }
        if let result {
            let body = resultBody(result), note = result.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(body) ? "" : "\n\n" + trailer(result, body)
            parts.append(("Result", pretty(body) + note))
        }
        return parts
    }

    static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return text }
        return String(decoding: out, as: UTF8.self)
    }

    /// `text` capped at `previewLimit` characters, and whether it was cut.
    static func capped(_ text: String, all: Bool) -> (text: String, cut: Bool) {
        all || text.count <= previewLimit ? (text, false) : (String(text.prefix(previewLimit)) + "\n…", true)
    }

    private static func trailer(_ result: String, _ body: String) -> String {
        guard let range = result.range(of: body) else { return "" }
        return result[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
