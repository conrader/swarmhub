import Foundation

/// A Herdr bot that may create bots asks for one in its reply: a ```swarmhub fence holding
/// `{"op":"create_bot","name":…,"instructions":…,"avatar":{"shape":…,"colour":…},"runtime":…,"model":…}` (or an
/// array of them). On Herdr a bot is only a record in the app, so nothing is created on the server: the app reads
/// the request from the finished reply, shows it to the person and adds the bot only when they accept.
/// Foundation only, so the parser and the note also build on Linux beside `HerdrClient`.
struct HerdrBotRequest: Equatable, Sendable {
    var name: String
    /// The new bot's standing instructions; empty keeps the app's default.
    var instructions: String
    /// Avatar words as the bot wrote them, lowercased; the app keeps only the ones it can draw.
    var shape: String?, colour: String?
    /// An agent program ("Claude Code", "Codex") or a template name; nil runs it like the bot that asked.
    var runtime: String?
    var model: String?

    static let op = "create_bot", nameLimit = 40, instructionsLimit = 6_000, perReply = 8

    /// Every creation request in a reply, in order; one per name. A fence that is not valid JSON, or still being
    /// written, yields nothing.
    static func requests(in reply: String) -> [HerdrBotRequest] {
        var found: [HerdrBotRequest] = []
        for body in fences(in: reply) {
            guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [String: Any]).map { [$0] } ?? (json as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            for object in objects {
                guard let request = HerdrBotRequest(object), !found.contains(where: { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }) else { continue }
                found.append(request)
            }
        }
        return Array(found.prefix(perReply))
    }

    init(name: String, instructions: String = "", shape: String? = nil, colour: String? = nil, runtime: String? = nil, model: String? = nil) {
        self.name = name; self.instructions = instructions; self.shape = shape; self.colour = colour; self.runtime = runtime; self.model = model
    }

    /// nil unless the object is a `create_bot` with a usable name.
    init?(_ object: [String: Any]) {
        guard object["op"] as? String == Self.op, let raw = object["name"] as? String else { return nil }
        let name = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.nameLimit, name.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
        func word(_ value: Any?) -> String? {
            (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0.count > 80 ? nil : $0 }
        }
        self.name = name
        instructions = String(((object["instructions"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.instructionsLimit))
        let avatar = object["avatar"] as? [String: Any]
        shape = word(avatar?["shape"])?.lowercased(); colour = word(avatar?["colour"] ?? avatar?["color"])?.lowercased()
        runtime = word(object["runtime"]); model = word(object["model"])
    }

    /// The template a request's `runtime` means: a template by name, else the first one whose agent program has that
    /// name or contains it as a word ("claude" finds "Claude Code"). nil when nothing matches.
    static func template(for runtime: String?, in templates: [HerdrClient.Template]) -> HerdrClient.Template? {
        guard let wanted = runtime?.lowercased(), !wanted.isEmpty else { return nil }
        if let exact = templates.first(where: { $0.name.lowercased() == wanted || $0.runtime?.harness?.lowercased() == wanted }) { return exact }
        return templates.first { template in
            (template.runtime?.harness ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == wanted }
        }
    }

    /// What a bot that may create bots is told, once in its standing instructions and again when the person asks a
    /// running agent for a bot. `shapes` and `colours` are the avatar words the app can draw.
    static func note(shapes: [String], colours: [String]) -> String {
        """
        You can ask SwarmHub, the app the person is chatting from, to create another bot for them. When they ask for \
        a new bot, settle its name and purpose with them, then end your reply with one fenced block like this:

        ```swarmhub
        {"op":"create_bot","name":"Research","instructions":"Who this bot is and how it should work, written to the bot itself.","avatar":{"shape":"\(shapes.first ?? "star")","colour":"\(colours.first ?? "blue")"}}
        ```

        "name" is at most \(nameLimit) characters. "instructions" become the new bot's standing instructions. "avatar" is optional: \
        "shape" is one of \(shapes.joined(separator: ", ")); "colour" is one of \(colours.joined(separator: ", ")). \
        Optional "runtime" names the agent program to run it on (for example "Claude Code" or "Codex"); leave it out to run it like you. \
        For several bots put the objects in one JSON array. The app hides the block, shows the person each request and \
        creates the bot only when they accept: say that you proposed it, not that it exists. Do not start agents or write files for this yourself.
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
