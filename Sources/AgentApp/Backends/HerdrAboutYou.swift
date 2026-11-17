import Foundation

/// "About you": a short text about the person that the app keeps, the person can read and edit in Settings, and
/// every bot's agent is given with its instructions, so no bot has to ask again. A server's main bot proposes an
/// addition in its reply: a ```swarmhub fence holding `{"op":"about_you","add":"One short sentence."}` (or
/// `"add":["…","…"]`). The app shows the addition above the composer and saves it only when the person agrees
/// (`AppStore+HerdrIntro.swift`). The fence is the family of `HerdrBotRequest`. Foundation only, so the parser and
/// the notes also build on Linux for the live checks.
enum HerdrAboutYou {
    static let op = "about_you"
    /// The whole text, one addition, and how many additions one reply may carry.
    static let limit = 800, lineLimit = 200, perReply = 4
    /// Only the note that explains the block (and a block that follows it) contains it: a running agent reads it once.
    static let marker = "\"op\":\"\(op)\""
    /// How every version of the text an agent is given starts (`HerdrClient.notes`' `changing`).
    static let lead = "About the person you work for (SwarmHub keeps this, and they can edit it):"

    /// The text as the app keeps it: trimmed, no control characters, at most `limit` characters.
    static func clean(_ text: String) -> String {
        let plain = String(String.UnicodeScalarView(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { $0 == "\n" || $0.properties.generalCategory != .control }))
        return String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// What every bot's agent is given: the lead and the text. Nothing while the text is empty.
    static func note(_ text: String) -> String {
        let text = clean(text)
        return text.isEmpty ? "" : "\(lead)\n\(text)"
    }

    /// The additions a reply proposes, in order: one line each, trimmed, none twice. A fence that is not valid JSON,
    /// or is still being written, yields nothing.
    static func additions(in reply: String) -> [String] {
        var found: [String] = []
        for object in HerdrBotRequest.objects(in: reply) where object["op"] as? String == op {
            let raw = object["add"] ?? object["text"] ?? object["note"]
            let lines = (raw as? String).map { [$0] } ?? (raw as? [Any])?.compactMap { $0 as? String } ?? []
            for line in lines.compactMap(Self.line) where !found.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) { found.append(line) }
        }
        return Array(found.prefix(perReply))
    }

    /// An addition as the app keeps it: one line, at most `lineLimit` characters; nil when nothing is left.
    static func line(_ raw: String) -> String? {
        let joined = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let line = String(String.UnicodeScalarView(joined.unicodeScalars.filter { $0.properties.generalCategory != .control })).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(lineLimit))
    }

    /// The text with `addition` as a new last line. A line that is already there (in any case) changes nothing, and
    /// so does one that would not fit: nil then, so the caller can say that the text is full.
    static func adding(_ addition: String, to text: String) -> String? {
        guard let line = line(addition) else { return clean(text) }
        let current = clean(text)
        if current.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(line) == .orderedSame }) { return current }
        let next = current.isEmpty ? line : current + "\n" + line
        return next.count > limit ? nil : next
    }

    /// What a server's main bot is told, after its standing instructions and once to a running agent: how to propose
    /// an addition. Only the main bot proposes; every bot reads the text.
    static let how = """
        SwarmHub keeps a short text about the person, "About you", and gives it to every bot. When the person tells \
        you something lasting about themselves that other bots should know too, you may propose to add it: end your \
        reply with a fenced block like this:

        ```swarmhub
        {"op":"\(op)","add":"One short sentence about the person, in the third person."}
        ```

        SwarmHub hides the block and keeps the sentence only if the person agrees, so say you noted it for them to \
        confirm. Never propose secrets or anything they did not tell you themselves.
        """
}

/// The main bot's first conversation: after the setup wizard created it, the app asks it to open the conversation
/// itself (`AppStore+HerdrIntro.swift`). The note below is the whole request: the agent greets, says what it can do,
/// and asks a few short questions, one at a time and skippable. It offers first: it proposes bots and additions to
/// "About you" in blocks the person answers, and does no work unasked. The same note, with `again`, is what "Get to
/// know me" in the main bot's menu sends later. Foundation only.
enum HerdrIntro {
    /// On the message that carries the note, so the chat shows one small line instead of the note, and so an answer
    /// to it is never taken for an answer to another bot.
    enum Key { static let kind = "herdrIntro" }
    static let first = "first", again = "again"
    /// The item in the main bot's + menu that asks for the introduction later.
    static let menu = "Get to know me"
    /// How the note starts: it says who wrote it, like the messages the app passes on between bots.
    static var lead: String { "[From \(AppConstants.name), the app the person is chatting from. The person did not write this.]" }

    /// `name`: the bot's. `about`: what "About you" holds now (empty: nothing). `projects`: where in the app the
    /// person adds a project server, or nil when this server cannot add any. `again`: the person asked for the
    /// introduction later, from the menu.
    static func note(name: String, about: String = "", projects: String? = nil, again: Bool = false) -> String {
        let known = HerdrAboutYou.clean(about)
        let opening = again
            ? "The person asked you to get to know them (again). Open with one friendly line, then go on with the questions below."
            : "The person has just finished setting you up and has not written anything yet. Open the conversation yourself: greet them in one line as \(HerdrBotMessage.line(name)), then say in two short sentences what you can do for them here: work with them on this computer (files, commands, research, writing), and set up other bots for jobs that deserve their own chat."
        let have = known.isEmpty ? "\"About you\" is empty so far." : "\"About you\" already says:\n\(known)\nDo not ask what it already answers."
        let servers = projects.map { "you cannot connect a server yourself, so if they have one, tell them to add it under \($0), and that they then choose which projects you may use" }
            ?? "you cannot connect a server yourself; if they have one, say that this server cannot add project servers yet"
        return """
        \(lead) \(opening)

        Then get to know them with these questions, in this order, ONE per reply: ask one short question (a single question mark in the whole reply), stop, and wait for their answer.
        1. What should you call them?
        2. What do they work on?
        3. What would they like help with first?
        4. Should you set up other bots for that? Only if they say yes, propose them with a create_bot block whose "decision" is "ask"; never create a bot they did not ask for.
        5. Are any of their projects on another server? (\(servers).)
        With your first question, tell them once that they can skip any question or stop whenever they like. A question they skip is not asked again. \(have)

        When an answer tells you something lasting about them, end that reply with an about_you block holding one short sentence in the third person, for example {"op":"\(HerdrAboutYou.op)","add":"Goes by Sam."} in a ```swarmhub fence. \(AppConstants.name) shows it to them and keeps it only if they agree. No block for a skipped question. Every block goes into one reply only: never repeat a block in a later reply.

        Until they ask you for something, do no other work: run no commands, read no files, start no helpers, write to no other bot. After the last question, sum up in two lines what you learned and ask what to do first.

        Reply now with the opening and question 1 only.
        """
    }

    /// The one line the chat shows in place of the note.
    static func caption(bot: String, again: Bool) -> String {
        again ? "You asked \(bot) to get to know you" : "\(AppConstants.name) asked \(bot) to say hello"
    }
}
