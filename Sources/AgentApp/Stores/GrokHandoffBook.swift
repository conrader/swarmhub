import Foundation

/// What the app remembers of a bot's last handoff, for the line on its Grok history (`UserDefaults`). Whether an agent
/// session has had the handoff is never read from here (`GrokHandoffState.read` and the server's saved rows say that).
struct GrokHandoffRecord: Codable, Equatable, Sendable {
    var marker: String
    var summarised: Bool
    var older: Int, recent: Int
    var at: Date
    /// True when the server took no files, so only the note with its excerpt went.
    var partial: Bool? = nil
    /// How many lines the archive had then; a different number now means lines were added since.
    var lines: Int? = nil
}

/// The handoffs' bookkeeping that lives beside the store (memory only).
@MainActor final class GrokHandoffBook {
    /// The summaries being made right now, by bot, and how many older messages each stands for.
    var summaries: [UUID: Task<GrokHandoffCache?, Never>] = [:]
    var summarising: [UUID: Int] = [:]
    /// The newest summary started on each server: the next one there waits for it, so one runs at a time per server.
    var queue: [String: Task<Void, Never>] = [:]
    /// Each bot's `GrokHandoffState` as last read from or written to its file.
    var states: [UUID: GrokHandoffState] = [:]
    /// The summary made of the older part of a bot's own chat, kept until its fresh agent has read the chat
    /// (`AppStore+HerdrCarryOver.swift`), so that a second try does not make it again.
    var carrySummaries: [UUID: GrokHandoffCache] = [:]
    /// How long a turn waits for a summary before the handoff goes without one; how long making one may take when
    /// the app starts it by itself, and when the person asked for it.
    var turnWait: Duration = .seconds(180)
    var summaryLimit: Duration = .seconds(240)
    var askedLimit: Duration = .seconds(900)
}

/// The words about a bot's handoff: the line under its Grok history, the lines in its chat, and its Details.
enum GrokHandoffCopy {
    static func switchLabel(_ bot: String) -> String { "Hand this history over to \(bot)" }
    static func switchHelp(_ bot: String) -> String {
        "On: \(bot) reads this conversation before its next reply whenever its agent starts anew, so it can carry on. It is sent to \(bot)’s server. Off: \(bot) does not get it."
    }
    static let tryAgain = "Try again", trySummary = "Try summary again"
    static func off(_ bot: String) -> String { "Not handed over to \(bot): switched off" }
    static func pending(_ bot: String) -> String { "\(bot) reads this before its next reply" }
    static func preparing(_ older: Int) -> String { "Preparing handover: summarising \(older) older messages…" }
    static let noSummary = "the summary of the older part could not be made"
    static let tooLong = "the older part is too long to summarise unasked"
    static let newer = "lines added since go to its next agent"

    /// In the chat, once: the agent has the conversation, or only the excerpt a server without files can take.
    static func read(_ bot: String) -> String { "\(bot) has read its Grok history" }
    static func readExcerpt(_ bot: String) -> String { "\(bot) was given an excerpt of its Grok history: its server takes no files" }

    /// "Handed over to Ada · summary of 268 + last 120 messages · 3 May 2026 at 14:02", then what else is worth knowing.
    static func handedOver(_ bot: String, record: GrokHandoffRecord, when: String, notes: [String] = []) -> String {
        let what: String
        if record.partial == true { what = "an excerpt only, because its server takes no files" }
        else if record.older == 0 { what = "all \(record.recent) messages" }
        else if record.summarised { what = "summary of \(record.older) + last \(record.recent) messages" }
        else { what = "last \(record.recent) messages and the full transcript, without a summary" }
        return (["Handed over to \(bot)", what, when] + notes).joined(separator: " · ")
    }

    /// Under the Grok history while the last handoff failed. `again`: the next message tries once more by itself.
    static func notHandedOver(_ bot: String, why: String, again: Bool) -> String {
        "Not handed over to \(bot). \(why) " + (again ? "It is tried once more with your next message." : "It is not tried again until its agent starts anew or you choose \(tryAgain).")
    }

    /// In the chat when a handoff failed and the person's message went without it.
    static func failed(_ bot: String, why: String, again: Bool) -> String {
        let next = again ? "It is tried once more with your next message." : "It is not tried again by itself."
        return "\(bot) could not be given its Grok history. \(why) Your message was sent without it. \(next) To try again or switch it off, see Grok history at the top of this chat."
    }

    /// Details → Advanced → New conversation: a bot that is handed its Grok history does not start with nothing.
    static func newConversation(_ bot: String, readsHistory: Bool) -> String {
        readsHistory
            ? "Start \(bot) anew. It reads its Grok history again before its next reply; switch that off under Grok history at the top of its chat. Earlier messages stay visible here."
            : "Start \(bot) with empty context. Earlier messages stay visible here."
    }
}
