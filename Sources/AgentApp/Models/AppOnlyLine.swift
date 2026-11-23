import Foundation

/// The fixed text of an app-only line around its variable parts (a bot's name, a list of names).
/// The producer renders it and the history filter matches it, so the two can't drift: `parts` are the fixed pieces,
/// and each gap between two pieces is one non-empty variable value.
struct LineTemplate: Sendable {
    let parts: [String]
    init(_ parts: String...) { self.parts = parts }

    /// The line for these values (one per gap; missing ones render empty, extra ones are ignored).
    func render(_ values: String...) -> String {
        parts.enumerated().map { index, part in index == 0 ? part : (index - 1 < values.count ? values[index - 1] : "") + part }.joined()
    }

    /// The values in the gaps of `text`, in order; nil when `text` is not this template (`matches`).
    func values(in text: String) -> [String]? {
        guard parts.count > 1, let head = parts.first, text.hasPrefix(head) else { return nil }
        var rest = text.dropFirst(head.count), found: [String] = []
        for (index, part) in parts.enumerated().dropFirst() {
            if index == parts.count - 1 {
                guard rest.count > part.count, rest.hasSuffix(part) else { return nil }
                return found + [String(rest.dropLast(part.count))]
            }
            guard !rest.isEmpty, let next = rest.dropFirst().range(of: part) else { return nil }
            found.append(String(rest[rest.startIndex..<next.lowerBound])); rest = rest[next.upperBound...]
        }
        return nil
    }

    /// True when `text` is this template with non-empty values in its gaps.
    func matches(_ text: String) -> Bool {
        guard let head = parts.first else { return false }
        guard parts.count > 1 else { return text == head }
        guard text.hasPrefix(head) else { return false }
        var rest = text.dropFirst(head.count)
        for (index, part) in parts.enumerated().dropFirst() {
            if index == parts.count - 1 { return rest.count > part.count && rest.hasSuffix(part) }
            // Each gap holds at least one character before the next fixed piece.
            guard !rest.isEmpty, let found = rest.dropFirst().range(of: part) else { return false }
            rest = rest[found.upperBound...]
        }
        return false
    }
}

/// Plain `system` rows that only say what the app did. They are shown in the chat and never sent as history.
/// Stop lines are NOT app-only: they carry the user's intent and stay in history.
enum AppOnlyLine {
    /// Tag on the rows the app writes.
    static let key = "appOnly"

    // The main bot's notices (`AppStore.notice`).
    static let created = LineTemplate("", " created ", "")
    // A bot's request for a new bot, passed on to its server's main bot (`AppStore+HerdrBots.swift`).
    static let botAskPassedOn = LineTemplate("", " asked for a bot named “", "”. The request was passed on to ", ", the main bot.")
    static let botAskNoMain = LineTemplate("", " asked for a new bot, but ", " has no main bot to decide. Make one bot the main bot: its settings → Advanced → Main bot.")
    static let botAskTooMany = LineTemplate("", "’s request for a bot named “", "” was not passed on: it has asked ", " times in the last ", " minutes.")
    static let botAskNotPassedOn = LineTemplate("", "’s request for a bot named “", "” could not be passed on to ", ".")
    static let botAskUnanswered = LineTemplate("", " did not finish its answer to ", "’s request for a bot. Ask ", " to try again.")
    static let botRemoved = LineTemplate("You removed ", ", which ", " had created.")
    // A change of the agent program and model of several bots (`AppStore+HerdrModels.swift`).
    static let modelsChanged = LineTemplate("", " switched ", " to ", ".")
    static let modelsAlready = LineTemplate("Nothing to change: ", " already on ", ".")
    static let modelsNotChanged = LineTemplate("", "’s model change was not applied. ", "")
    static let modelsUndone = LineTemplate("You undid the switch to ", ": ", " went back to what they ran before.")

    static func line(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text, metadata: [key: "1"]) }

    /// Rows the app wrote for the user only: tagged lines, the restart notes and the "Waiting" line.
    static func isAppOnly(_ row: ChatMessage, knownBotNames: [String] = []) -> Bool {
        if ReconcileNote.isNote(row) || row.metadata[key] != nil { return true }
        return row.role == .system && row.metadata[TurnWaitCopy.key] == "line"
    }
}

/// Plain `system` rows that carry the user's intent and stay model-bound history: the Stop lines. A title or an error text inside them can never make them app-only.
enum IntentLine {
    static let stopRequested = LineTemplate("Stop requested from ", ".")
    static let stoppedBeforeRunID = LineTemplate("Stopped here before ", " had an agent running.")
    static let stoppedNoRunControl = LineTemplate("Stopped here; this bot cannot be interrupted from the app.")
    static let stopFailed = LineTemplate("", " Stop failed: ", "")

    static let all = [stopRequested, stoppedBeforeRunID, stoppedNoRunControl, stopFailed]
    static func matches(_ text: String) -> Bool { all.contains { $0.matches(text) } }
}
