import Foundation
import CoreFoundation

/// A server's main bot (the one Herdr bot there that creates bots) asks the app for one in its reply: a ```swarmhub
/// fence holding `{"op":"create_bot","decision":…,"name":…,"instructions":…,"avatar":{"shape":…,"colour":…},
/// "runtime":…,"model":…}` (or an array of them). On Herdr a bot is only a record in the app, so nothing is created
/// on the server: the app reads the request from the finished reply. With `"decision":"decided"` the main bot has
/// decided and the app adds the bot at once; with `"ask"`, or no decision, the app shows the request to the person
/// and adds the bot only when they accept. Other bots ask the main bot (`HerdrBotRelay.swift`).
/// Foundation only, so the parser and the note also build on Linux beside `HerdrClient`.
struct HerdrBotRequest: Codable, Equatable, Sendable {
    var name: String
    /// The new bot's standing instructions; empty keeps the app's default.
    var instructions: String
    /// Avatar words as the bot wrote them, lowercased; the app keeps only the ones it can draw.
    var shape: String?, colour: String?
    /// An agent program by its name, or a template name; nil runs it like the bot that asked.
    var runtime: String?
    var model: String?
    var reviewReason: String?
    var documentReadOnly: Bool?
    var sessionCapCents: Int?
    /// The main bot wrote `"decision":"decided"`: it created the bot on its own decision. False asks the person.
    var decided = false

    static let op = "create_bot", nameLimit = 40, instructionsLimit = 6_000, perReply = 8
    static let decidedWord = "decided", askWord = "ask"
    /// Active sessions that only received the older creation instructions need the updated note.
    static let marker = "\"document_read_only\""

    /// Every creation request in a reply, in order; one per name. A fence that is not valid JSON, or still being
    /// written, yields nothing.
    static func requests(in reply: String) -> [HerdrBotRequest] {
        var found: [HerdrBotRequest] = []
        for object in objects(in: reply) {
            guard let request = HerdrBotRequest(object) else { continue }
            if let existing = found.firstIndex(where: { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }) {
                let readOnly = found[existing].documentReadOnly == true || request.documentReadOnly == true
                let caps = [found[existing].sessionCapCents, request.sessionCapCents].compactMap { $0 }
                if found[existing].reviewReason == nil, request.reviewReason != nil { found[existing] = request }
                found[existing].sessionCapCents = caps.min()
                found[existing].documentReadOnly = readOnly ? true : nil
            } else if found.count < perReply { found.append(request) }
        }
        return found
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
        if let value = object["document_read_only"] {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            documentReadOnly = flag.boolValue ? true : nil
        }
        if let value = object["spend_cap_usd"] {
            // Zero keeps a malformed limit visible for correction and prevents uncapped creation.
            sessionCapCents = Self.parseCap(value) ?? 0
        }
        let avatar = object["avatar"] as? [String: Any]
        shape = word(avatar?["shape"])?.lowercased(); colour = word(avatar?["colour"] ?? avatar?["color"])?.lowercased()
        runtime = word(object["runtime"]); model = word(object["model"], limit: 160)
        if object["review_reason"] != nil {
            let reason = (object["review_reason"] as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            reviewReason = reason.isEmpty ? "The main bot flagged this role for your review." : String(reason.prefix(500))
        }
        decided = reviewReason == nil && word(object["decision"])?.lowercased() == Self.decidedWord
    }

    private static func parseCap(_ value: Any) -> Int? {
        let text: String
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else if let literal = value as? String { text = literal }
        else { return nil }
        guard text.utf8.count < 20, text.wholeMatch(of: #/[0-9]+(?:\.[0-9]{1,2})?/#) != nil,
              let dollars = Decimal(string: text), dollars > 0, dollars <= Decimal(900_719_925) / 100 else { return nil }
        return NSDecimalNumber(decimal: dollars * 100).intValue
    }

    static func capLabel(_ cents: Int) -> String {
        guard cents > 0 else { return "Invalid session limit. Ask for a positive USD amount with up to two decimal places." }
        return "Session cap: " + (Decimal(cents) / 100).formatted(.currency(code: "USD"))
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
            ? "The person chose to confirm every new bot. Describe yours as proposed until they choose Create."
            : "Use \"decided\" to create a routine bot the person needs. Use \"ask\" to propose one for their decision."
        return """
        You are the main bot here. Only you can ask SwarmHub to create a bot. If a new role serves a specific need, end your reply with a block like:

        ```swarmhub
        {"op":"create_bot","decision":"\(decidedWord)","name":"Research","instructions":"Find and cite primary sources.","avatar":{"shape":"\(shapes.first ?? "star")","colour":"\(colours.first ?? "blue")"}}
        ```

        \(decision) For payments, credentials, access grants or production changes, always add "review_reason" explaining the sensitive responsibility, even when the person requested the role. A flagged bot is only proposed until the person chooses Create. Omit this field for routine roles. \
        Limit the name to \(nameLimit) characters. Address the standing instructions to the new bot. Optional avatar shapes: \(shapes.joined(separator: ", ")). Colours: \(colours.joined(separator: ", ")). \
        For read-only document review, set "document_read_only":true and "runtime":"OpenCode". The workspace limits model tools to reading files. This can be combined with spend_cap_usd.
        Optional "runtime" names an agent program such as Claude, Codex or OpenCode; default is yours. Set "model" only for an explicitly requested model ID; otherwise use Recommended. For a capped OpenCode role include "spend_cap_usd" in USD. Put multiple proposals in one JSON array. The app hides the block. \
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

/// A proposal keeps its identity when it outlives the conversation page that introduced it.
struct HerdrCreationProposal: Codable, Identifiable, Equatable {
    let id: String
    let request: HerdrBotRequest
    var taken: Bool
    var askerID: UUID? = nil
}
