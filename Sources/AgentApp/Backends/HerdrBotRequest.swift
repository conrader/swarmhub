import Foundation

/// A server's main bot (the one Herdr bot there that creates bots) asks the app for one in its reply: a ```swarmhub
/// fence holding `{"op":"create_bot","decision":…,"name":…,"instructions":…,"avatar":{"shape":…,"colour":…},
/// "runtime":…,"model":…}` (or an array of them). On Herdr a bot is only a record in the app, so nothing is created
/// on the server: the app reads the request from the finished reply. With `"decision":"decided"` the main bot has
/// decided and the app adds the bot at once; with `"ask"`, or no decision, the app shows the request to the person
/// and adds the bot only when they accept. Other bots ask the main bot (`HerdrBotRelay.swift`).
/// Foundation only, so the parser and the note also build on Linux beside `HerdrClient`.
struct HerdrBotRequest: Equatable, Sendable {
    var name: String
    /// The new bot's standing instructions; empty keeps the app's default.
    var instructions: String
    /// Avatar words as the bot wrote them, lowercased; the app keeps only the ones it can draw.
    var shape: String?, colour: String?
    /// An agent program by its name, or a template name; nil runs it like the bot that asked.
    var runtime: String?
    var model: String?
    /// The main bot wrote `"decision":"decided"`: it created the bot on its own decision. False asks the person.
    var decided = false

    static let op = "create_bot", nameLimit = 40, instructionsLimit = 6_000, perReply = 8
    static let decidedWord = "decided", askWord = "ask"
    /// Only the note that explains the decision contains it: an agent that started before reads that note once.
    static let marker = "\"decision\":\"\(decidedWord)\""

    /// Every creation request in a reply, in order; one per name. A fence that is not valid JSON, or still being
    /// written, yields nothing.
    static func requests(in reply: String) -> [HerdrBotRequest] {
        var found: [HerdrBotRequest] = []
        for object in objects(in: reply) {
            guard let request = HerdrBotRequest(object), !found.contains(where: { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }) else { continue }
            found.append(request)
        }
        return Array(found.prefix(perReply))
    }

    init(name: String, instructions: String = "", shape: String? = nil, colour: String? = nil, runtime: String? = nil, model: String? = nil, decided: Bool = false) {
        self.name = name; self.instructions = instructions; self.shape = shape; self.colour = colour; self.runtime = runtime; self.model = model; self.decided = decided
    }

    /// A bot's name as a block gives it: one line, trimmed, at most `nameLimit` characters; nil when it is none of that.
    static func name(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let name = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= nameLimit, name.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
        return name
    }

    /// The JSON objects in a reply's closed ```swarmhub fences, in order.
    static func objects(in reply: String) -> [[String: Any]] {
        fences(in: reply).flatMap { body -> [[String: Any]] in
            guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
            return (json as? [String: Any]).map { [$0] } ?? (json as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }
    }

    /// nil unless the object is a `create_bot` with a usable name.
    init?(_ object: [String: Any]) {
        guard object["op"] as? String == Self.op, let name = Self.name(object["name"]) else { return nil }
        func word(_ value: Any?, limit: Int = 80) -> String? {
            (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0.count > limit ? nil : $0 }
        }
        self.name = name
        instructions = String(((object["instructions"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.instructionsLimit))
        let avatar = object["avatar"] as? [String: Any]
        shape = word(avatar?["shape"])?.lowercased(); colour = word(avatar?["colour"] ?? avatar?["color"])?.lowercased()
        runtime = word(object["runtime"]); model = word(object["model"], limit: 160)
        decided = word(object["decision"])?.lowercased() == Self.decidedWord
    }

    /// The template a request's `runtime` means: a template by name, else the first one whose agent program has that
    /// name or contains it as a word ("claude" finds "Claude Code"). nil when nothing matches.
    static func template(for runtime: String?, in templates: [HerdrClient.Template]) -> HerdrClient.Template? {
        guard let wanted = runtime?.lowercased(), !wanted.isEmpty else { return nil }
        if let exact = templates.first(where: { $0.name.lowercased() == wanted }) { return exact }
        if let exact = templates.first(where: { $0.runtime?.harness?.lowercased() == wanted || $0.runtime?.displayName?.lowercased() == wanted }) { return exact }
        if let friendly = templates.first(where: { $0.programName?.lowercased() == wanted }) { return friendly }
        return templates.first { template in
            (template.runtime?.harness ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == wanted }
        }
    }

    /// What a server's main bot is told, after its standing instructions and again when the person asks a running
    /// agent for a bot. `shapes` and `colours` are the avatar words the app can draw. `asksFirst`: the person chose to
    /// confirm every bot, so the main bot is told that nothing is created before they accept.
    static func note(shapes: [String], colours: [String], asksFirst: Bool = false) -> String {
        let decision = asksFirst
            ? "The person has chosen to confirm every new bot: whatever \"decision\" says, the app shows them your request with Create and Dismiss, so say that you proposed the bot, not that it exists."
            : "\"decision\" is \"\(decidedWord)\" when you have decided the bot should exist (the person asked you for it, or you judge it clearly worth having): the app creates it at once. Use \"\(askWord)\" for a role that would handle payments, credentials, access grants or production changes, and whenever the person should decide: the app shows them your request with Create and Dismiss, so say that you proposed the bot, not that it exists."
        return """
        You are the main bot here: the only bot that can have SwarmHub, the app the person is chatting from, create \
        another bot. Propose a bot when it serves a specific need the person has described. To create one, settle its name and purpose, then end your reply with one fenced block like this:

        ```swarmhub
        {"op":"create_bot","decision":"\(decidedWord)","name":"Research","instructions":"Who this bot is and how it should work, written to the bot itself.","avatar":{"shape":"\(shapes.first ?? "star")","colour":"\(colours.first ?? "blue")"}}
        ```

        \(decision) "name" is at most \(nameLimit) characters. "instructions" become the new bot's standing instructions. "avatar" is optional: \
        "shape" is one of \(shapes.joined(separator: ", ")); "colour" is one of \(colours.joined(separator: ", ")). \
        Optional "runtime" names the agent program to run it on (for example "Claude", "Codex" or "OpenCode"); leave it out to use your agent program. Supply "model" only when the person specifies a model ID. Otherwise SwarmHub uses Recommended. \
        For several bots put the objects in one JSON array. The app hides the block. \
        Other bots cannot create bots and ask you instead. Such a request reaches you as a message that starts with \
        "\(HerdrBotRelay.requestLead)". Answer it with a create_bot block, or refuse with \
        {"op":"\(HerdrBotDecline.op)","name":"…","reason":"…"} in the same kind of block; SwarmHub tells the asking bot the outcome. \
        Do not start agents or write files to create a bot yourself.
        """
    }

    /// The bodies of the reply's closed ```swarmhub fences (the rules of `SwarmhubBlock.fences`, which hides them
    /// from the chat; an unclosed fence is a reply still being written and is left out here).
    static func fences(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n"); var bodies: [String] = []; var index = 0
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
            if end < lines.count { bodies.append(lines[(index + 1)..<end].joined(separator: "\n")) }
            index = end + 1
        }
        return bodies
    }
}
