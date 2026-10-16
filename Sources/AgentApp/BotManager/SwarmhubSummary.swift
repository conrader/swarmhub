import Foundation

/// P51 rule 2: a ```swarmhub fence reads as one line made from its ops (no chat card draws them), e.g. "Installed
/// swarmhub-manager 1.0.0 on grok-jarvis"; the raw block shows only unfolded. Unknown ops still get a line.
enum SwarmhubSummary {
    struct Line: Equatable { var summary: String; var block: String }

    /// One line per fence, in order (an unclosed fence, as while streaming, too).
    static func lines(in text: String) -> [Line] {
        guard text.contains("`") else { return [] }
        return SwarmhubBlock.fences(in: text).map { Line(summary: summary(body: $0.body), block: $0.body) }
    }

    static func summary(body: String) -> String {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return "SwarmHub update" }
        let objects = (json as? [String: Any]).map { [$0] } ?? (json as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let parts = objects.map(line)
        guard !parts.isEmpty else { return "SwarmHub update" }
        let shown = parts.prefix(2).joined(separator: " · ")
        return parts.count > 2 ? shown + " · \(parts.count - 2) more" : shown
    }

    private static func line(_ object: [String: Any]) -> String {
        let op = object["op"] as? String ?? "", name = object["name"] as? String ?? "a bot"
        func count(_ key: String) -> Int { (object[key] as? [Any])?.count ?? 0 }
        switch op {
        case "skills_installed":
            let bot = object["bot"] as? String
            let skills = ((object["skills"] as? [[String: Any]]) ?? []).compactMap { skill in
                (skill["name"] as? String).map { [$0, skill["version"] as? String].compactMap { $0 }.joined(separator: " ") }
            }
            let on = bot.map { " on \($0)" } ?? ""
            return skills.count == 1 ? "Installed \(skills[0])\(on)" : "Skills installed\(on): " + skills.joined(separator: ", ")
        case "bot_created": return "Created bot \(name)"
        case "avatar": return "Changed \(name)'s avatar"
        case "description": return "Updated \(name)'s description"
        case "instructions_changed": return "Updated \(name)'s instructions"
        case "instructions": return "Read \(name)'s instructions"
        case "bot_retired": return "Retired \(name)"
        case "bots": return "Listed \(count("list")) bots"
        case "bots_adopted": return "Connected \(count("results")) bots"
        case "key_restored": return "Restored \(name)'s key"
        case "models": return "Read the models of \(count("list")) bots"
        case "models_changed":
            let model = object["model"] as? String ?? "a new model", bots = object["count"] as? Int
            return "Switched \(bots.map { "\($0) bots" } ?? "bots") to \(model)"
        case "accounts": return "Read the coding accounts"
        case "login_link": return "Login link for \(object["tool"] as? String ?? "a tool")"
        case "login_done": return "Login \(object["ok"] as? Bool == true ? "finished" : "not finished")"
        case "report": return "Filed report: \(object["title"] as? String ?? "untitled")"
        case "reports": return "Listed \(count("list")) reports"
        case "reports_closed": return "Closed \(count("sent") + count("deleted")) reports"
        case "box_capacity": return "Read the box capacity"
        case "goal": return "Goal \(object["status"] as? String ?? "updated")"
        case "": return "SwarmHub update"
        default: return "SwarmHub update: " + op.replacingOccurrences(of: "_", with: " ")
        }
    }
}
