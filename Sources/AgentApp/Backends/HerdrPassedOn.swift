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
}
