import Foundation

/// What the chat shows of a message the app put into it for an agent: a bot's request for a new bot, a bot's message
/// or answer, the outcome of a request, or the app's own note. The agent reads the whole text, with the line that
/// says who wrote it and the lines that tell it how to answer; the person sees only the part that is someone's
/// words. Nothing is stored twice: this reads the stored text, so messages passed on by an older version read the
/// same way. Foundation only.
struct HerdrPassedOn: Equatable, Sendable {
    /// A bot asked for a new bot: its name, as a heading above the purpose.
    var botName: String? = nil
    /// The words to show; empty when the message was only instructions.
    var body: String

    /// Lines that are for the agent alone, by how they start.
    static let agentOnly = ["The person did not write this.", "(The person did not write this.", "(This is ", HerdrBotRelay.noReply, HerdrBotMessage.rosterLead]

    /// Words that are shown as they are (the app's own line about a message a bot sent).
    init(words: String) { body = words.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        // "[Request from the bot Boppy, passed on by SwarmHub]": the caption says that in plain words.
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("["), first.hasSuffix("]") { lines.removeFirst() }
        lines.removeAll { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return Self.agentOnly.contains { line.hasPrefix($0) }
        }
        var words = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // `Boppy asks for a new bot named "Legal". Purpose: …` reads as the name and the purpose.
        if let asks = words.range(of: " asks for a new bot named \""), let purpose = words.range(of: "\". Purpose: ", range: asks.upperBound..<words.endIndex) {
            botName = String(words[asks.upperBound..<purpose.lowerBound])
            words = String(words[purpose.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if words == "(none given)" { words = "" }
        }
        body = words
    }

    /// The card's one line while it is folded: the bot it asks for, when it asks for one, and the first sentence of
    /// the words.
    var summary: String { summary(limit: Self.summaryLength) }

    /// The same line cut to at most about `limit` characters, at a word.
    func summary(limit: Int) -> String {
        let first = Self.firstSentence(of: body, limit: limit)
        guard let botName else { return first }
        return first.isEmpty ? botName : "\(botName): \(first)"
    }

    /// The longest a folded line gets before it is cut at a word.
    static let summaryLength = 110

    /// The first line of `text` with words in it, without the marks that open a heading, a list item or a quote; of
    /// a long line only its first sentence; and of a sentence that is still too long, whole words up to
    /// `summaryLength` and "…". Never cut inside a word.
    static func firstSentence(of text: String, limit: Int = summaryLength) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard var line = lines.first(where: { line in line.contains { $0.isLetter || $0.isNumber } }) else { return "" }
        line = line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+|>\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
        // A long line gives its first sentence, when that is a sentence and not an abbreviation's full stop.
        if line.count > limit / 2, let sentence = line.range(of: #"^.{20,}?[.!?](?=\s+\S)"#, options: .regularExpression), line[sentence].count <= limit {
            return String(line[sentence])
        }
        guard line.count > limit else { return line }
        let head = line.prefix(limit)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—")) + "…"
    }
}

/// Which cards of one chat are unfolded. A message between bots is folded when it is drawn, an old one and a new
/// one alike; a click unfolds it and another folds it again. This is kept while the chat is on screen, and never
/// saved: the next time the chat opens, every card is folded.
struct FoldState: Equatable, Sendable {
    private(set) var open: Set<UUID> = []

    init(open: Set<UUID> = []) { self.open = open }

    func isOpen(_ id: UUID) -> Bool { open.contains(id) }
    mutating func toggle(_ id: UUID) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
    /// Another chat is shown: its cards start folded.
    mutating func foldAll() { open = [] }
}
