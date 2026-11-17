import Foundation

/// Whether a message asks for a new bot (English and Polish). A Herdr bot's agent is reminded how to ask the app for
/// one in front of such a message (`HerdrBackend.send`).
enum ManagementIntent {
    private static let createVerbs = ["create", "new", "make", "add", "build", "set up", "setup", "spin up",
                                      "stwórz", "stworz", "utwórz", "utworz", "nowy", "nowego", "nową", "dodaj", "zrób", "zrob"]
    private static let botNouns = ["bot", "bots", "agent", "agents", "assistant", "assistants", "subagent", "subagents",
                                   "bota", "boty", "botów", "botow", "agenta", "agentów", "asystenta"]

    static func createsBot(_ text: String) -> Bool {
        let joined = " " + tokens(text).joined(separator: " ") + " "
        return createVerbs.contains { joined.contains(" \($0) ") } && botNouns.contains { joined.contains(" \($0) ") }
    }

    /// Lowercased words; letters, digits, `.`, `-` and `'` stay inside a word, everything else separates.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'")) }.filter { !$0.isEmpty }
    }
}

/// The main bot's "+" menu in its composer. "New bot…" fills the composer with a plain request; "Get to know me"
/// has the bot ask its few questions about the person (again), which the app sends at once.
enum ManageBotsAction: String, CaseIterable, Identifiable {
    case newBot, getToKnowMe
    var id: String { rawValue }
    var title: String { self == .newBot ? "New bot…" : HerdrIntro.menu }
    var systemImage: String { self == .newBot ? "plus.circle" : "hand.wave" }
    /// The request placed in the composer; nil for an action the app carries out itself.
    var request: String? { self == .newBot ? "Create a new bot called <name> that " : nil }
}
