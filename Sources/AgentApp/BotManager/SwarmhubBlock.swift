import Foundation
import os

/// One action the manager bot reports in a ```swarmhub fence (`Resources/BotManager/manager-hermes.md`).
enum SwarmhubOp: Equatable {
    /// P35: `hasKey` (whether its .env has an `API_SERVER_KEY`, never the key) when the list came from "List every bot".
    struct ListedBot: Equatable { var name: String; var description: String; var hasKey: Bool? = nil }
    /// P35: one profile of a "Connect bots" run; `backup` is the key-file backup's name (nil: it had no key file).
    struct AdoptionResult: Equatable {
        var name: String; var ok: Bool; var backup: String?
        /// Only `.env.swarmhub-bak-<UTC stamp>` names, the ones the recipe writes.
        static func isValidBackup(_ text: String) -> Bool {
            text.range(of: #"^\.env\.swarmhub-bak-[0-9]{8}T[0-9]{6}Z$"#, options: .regularExpression) != nil
        }
    }
    struct InstalledSkill: Equatable {
        var name: String; var version: String
        /// P31: the variant the install turn wrote (e.g. `claude,codex,hermes`); nil for skills without one.
        var variant: String? = nil
        static func isValidVariant(_ text: String) -> Bool {
            (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || ",._-".contains($0)) }
        }
    }
    case botCreated(name: String, description: String, avatar: AvatarMark?)
    case avatar(name: String, mark: AvatarMark)
    case description(name: String, description: String)
    case instructionsChanged(name: String)
    case instructions(name: String, text: String)
    case botRetired(name: String)
    case bots([ListedBot])
    /// P27: the manager wrote SwarmHub skills into `bot`'s profile. Only names and versions; never the content.
    case skillsInstalled(bot: String, skills: [InstalledSkill])
    /// P35: the manager connected these profiles (backup + derived key), and restored one bot's old key.
    case botsAdopted([AdoptionResult])
    case keyRestored(name: String, ok: Bool)
    /// P31 C: the coding tools and ChatGPT pool on the manager's box, a login's link (and device code), its end.
    case accounts(AccountsReport)
    case loginLink(tool: CodingTool, url: URL, code: String?)
    case loginDone(tool: CodingTool, ok: Bool, pending: Bool)

    /// The op from one JSON object; nil for unknown ops, missing fields or an invalid profile name.
    init?(_ object: [String: Any]) {
        guard let op = object["op"] as? String else { return nil }
        func string(_ key: String) -> String? { (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = string("name").flatMap { HermesKeyPaste.isValidProfileName($0) ? $0 : nil }
        switch op {
        case "bot_created":
            guard let name else { return nil }
            let avatar = (object["avatar"] as? [String: Any]).flatMap { Self.mark(shape: $0["shape"], colour: $0["colour"] ?? $0["color"]) }
            self = .botCreated(name: name, description: string("description") ?? "", avatar: avatar)
        case "avatar":
            guard let name, let mark = Self.mark(shape: object["shape"], colour: object["colour"] ?? object["color"]) else { return nil }
            self = .avatar(name: name, mark: mark)
        case "description":
            guard let name, let description = string("description") else { return nil }
            self = .description(name: name, description: description)
        case "instructions_changed":
            guard let name else { return nil }
            self = .instructionsChanged(name: name)
        case "instructions":
            guard let name, let text = object["text"] as? String else { return nil }
            self = .instructions(name: name, text: text)
        case "bot_retired":
            guard let name else { return nil }
            self = .botRetired(name: name)
        case "bots":
            guard let rows = object["list"] as? [[String: Any]] else { return nil }
            self = .bots(rows.compactMap { row in
                guard let name = (row["name"] as? String).flatMap({ HermesKeyPaste.isValidProfileName($0) ? $0 : nil }) else { return nil }
                return ListedBot(name: name, description: row["description"] as? String ?? "", hasKey: row["has_key"] as? Bool)
            })
        case "bots_adopted":
            guard let rows = object["results"] as? [[String: Any]] else { return nil }
            self = .botsAdopted(rows.compactMap { row in
                guard let name = (row["name"] as? String).flatMap({ HermesKeyPaste.isValidProfileName($0) ? $0 : nil }) else { return nil }
                // A backup name the recipe would not write makes the row a failure: undo could not use it.
                let backup = (row["backup"] as? String) ?? ""
                let valid = backup.isEmpty || AdoptionResult.isValidBackup(backup)
                return AdoptionResult(name: name, ok: valid && row["ok"] as? Bool == true, backup: valid && !backup.isEmpty ? backup : nil)
            })
        case "key_restored":
            guard let name else { return nil }
            self = .keyRestored(name: name, ok: object["ok"] as? Bool ?? false)
        case "accounts":
            self = .accounts(AccountsReport(object))
        case "login_link":
            guard let tool = string("tool").flatMap(CodingTool.init(rawValue:)), let raw = string("url"), raw.hasPrefix("https://"),
                  AccountsReport.isPlain(raw, max: 2048), !raw.contains(" "), let url = URL(string: raw), url.host != nil else { return nil }
            let code = string("code").flatMap { (4...24).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } ? $0 : nil }
            self = .loginLink(tool: tool, url: url, code: code)
        case "login_done":
            guard let tool = string("tool").flatMap(CodingTool.init(rawValue:)) else { return nil }
            let pending = object["pending"] as? Bool == true
            self = .loginDone(tool: tool, ok: !pending && object["ok"] as? Bool == true, pending: pending)
        case "skills_installed":
            guard let bot = string("bot").flatMap({ HermesKeyPaste.isValidProfileName($0) ? $0 : nil }),
                  let rows = object["skills"] as? [[String: Any]] else { return nil }
            self = .skillsInstalled(bot: bot, skills: rows.compactMap { row in
                guard let name = row["name"] as? String, HermesKeyPaste.isValidProfileName(name),
                      let version = (row["version"] as? String).flatMap(SkillVersion.init) else { return nil }
                return InstalledSkill(name: name, version: version.description, variant: (row["variant"] as? String).flatMap { InstalledSkill.isValidVariant($0) ? $0 : nil })
            })
        default: return nil
        }
    }

    /// Both words must be ones SwarmHub can draw (`AvatarShape`, `AvatarColour`); anything else is ignored.
    private static func mark(shape: Any?, colour: Any?) -> AvatarMark? {
        guard let shape = (shape as? String)?.lowercased(), let colour = (colour as? String)?.lowercased(),
              AvatarShape.isValid(shape), AvatarColour(rawValue: colour) != nil else { return nil }
        return AvatarMark(shape: shape, colour: colour)
    }
}

enum SwarmhubBlock {
    static let log = Logger(subsystem: "com.konrad.agentapp", category: "bot-manager")

    /// The ops of the LAST ```swarmhub fence (object or array). Malformed or unknown entries are dropped and only their
    /// op name is logged; nil when the reply has no swarmhub fence at all.
    static func ops(in text: String) -> [SwarmhubOp]? {
        guard let body = fences(in: text).last?.body else { return nil }
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            log.notice("swarmhub block ignored: malformed JSON"); return []
        }
        let objects: [[String: Any]]
        if let object = json as? [String: Any] { objects = [object] }
        else if let array = json as? [Any] { objects = array.compactMap { $0 as? [String: Any] } }
        else { log.notice("swarmhub block ignored: not an object or array"); return [] }
        return objects.compactMap { object in
            if let op = SwarmhubOp(object) { return op }
            let name = (object["op"] as? String).map { String($0.prefix(40)) } ?? "(none)"
            log.notice("swarmhub op ignored: \(name, privacy: .public)")
            return nil
        }
    }

    /// The reply as the chat shows it: every ```swarmhub fence removed (the stored message keeps it).
    static func visibleText(_ text: String) -> String {
        let found = fences(in: text)
        guard !found.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        for fence in found.reversed() { lines.removeSubrange(fence.lines) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ```swarmhub fences: line range (an unclosed fence runs to the end, as while streaming) and body.
    static func fences(in text: String) -> [(lines: Range<Int>, body: String)] {
        let lines = text.components(separatedBy: "\n"); var result: [(Range<Int>, String)] = []; var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            guard ticks >= 3, trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased() == "swarmhub" else { index += 1; continue }
            var end = index + 1
            while end < lines.count {
                let line = lines[end].trimmingCharacters(in: .whitespaces)
                if line.count >= ticks, line.allSatisfy({ $0 == "`" }) { break }
                end += 1
            }
            result.append((index..<min(end + 1, lines.count), lines[(index + 1)..<min(end, lines.count)].joined(separator: "\n")))
            index = end + 1
        }
        return result
    }
}
