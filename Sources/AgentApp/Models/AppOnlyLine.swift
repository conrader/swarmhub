import Foundation

/// backlog10: the fixed text of an app-only line around its variable parts (a bot's name, a list of names).
/// The producer renders it and the history filter matches it, so the two can't drift: `parts` are the fixed pieces,
/// and each gap between two pieces is one non-empty variable value.
struct LineTemplate: Sendable {
    let parts: [String]
    init(_ parts: String...) { self.parts = parts }

    /// The line for these values (one per gap; missing ones render empty, extra ones are ignored).
    func render(_ values: String...) -> String {
        parts.enumerated().map { index, part in index == 0 ? part : (index - 1 < values.count ? values[index - 1] : "") + part }.joined()
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

/// backlog10: plain `system` rows that only say what the app did. They are shown in the chat and never sent as
/// history: the legacy `v1/chat/completions` path puts every history row on the wire, a `system` one included.
/// Approved/Declined lines and stop lines are NOT app-only: they carry the user's intent and stay in history.
enum AppOnlyLine {
    /// Tag on rows written from backlog10 on. Rows saved before carry no tag and are matched by `legacy`.
    static let key = "appOnly"

    // Manager notices (`AppStore.notice`).
    static let created = LineTemplate("", " created ", "")
    static let couldNotReach = LineTemplate("Couldn’t reach ", " yet")
    static let couldNotSee = LineTemplate("Couldn’t see ", " yet")
    static let connected = LineTemplate("Connected ", ".")
    static let couldNotConnect = LineTemplate("Couldn’t connect ", "; they are listed under “not connected”.")
    static let nothingConnected = LineTemplate("Nothing was connected.")
    static let keyRestored = LineTemplate("", "’s old key is back on the box; ", " is no longer connected here.")
    static let keyRestoreFailed = LineTemplate("Couldn’t restore ", "’s old key; nothing changed here.")
    // P49's orientation that was given up.
    static let orientationGaveUp = LineTemplate("", " could not be reached for 24 h, so it was not given an orientation.")
    // P37's review card while it waits (it is `presentation: .review`, which is the card's tag from its first build).
    static let reviewing = LineTemplate("", " is reviewing this reply…")
    // backlog11: `insertNote` lines. A default model that was skipped (app name, model, reason), and a compacted resend.
    static let modelNotApplied = LineTemplate("", "'s default model ", " was not applied: ", " This chat runs on the agent default.")
    /// The same note before P17 (2026-10-14) said "box default"; saved rows may still carry it. Never rendered.
    static let modelNotAppliedBoxDefault = LineTemplate("", "'s default model ", " was not applied: ", " This chat runs on the box default.")
    static let compacted = LineTemplate("Conversation was compacted to fit the model; your message was sent again.")

    /// Unambiguous legacy templates. Creation/connection notices additionally require known bot names.
    static let legacy: [LineTemplate] = [couldNotReach, couldNotSee, couldNotConnect, nothingConnected,
                                         keyRestored, keyRestoreFailed, orientationGaveUp, reviewing,
                                         modelNotApplied, modelNotAppliedBoxDefault, compacted]

    static func line(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text, metadata: [key: "1"]) }

    /// Rows the app wrote for the user only: backlog7's reconcile notes, tagged lines, review and bot-work/bot-message
    /// cards (their `presentation` is saved with them), P39's "Waiting" line (backlog11: one a crash left behind), and
    /// untagged lines saved before the tag.
    static func legacyIdentityNotice(_ text: String, knownBotNames: [String]) -> Bool {
        let names = Set(knownBotNames.filter { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") })
        let createdParts = text.components(separatedBy: " created ")
        if createdParts.count == 2 && createdParts.allSatisfy({ names.contains($0) }) { return true }
        func nameList(_ value: String) -> Bool {
            let parts = value.components(separatedBy: ", ")
            return !parts.isEmpty && parts.allSatisfy { names.contains($0) }
        }
        guard text.hasPrefix("Connected ") else { return false }
        let parts = String(text.dropFirst("Connected ".count)).components(separatedBy: ". Couldn’t connect ")
        if parts.count == 1 && text.hasSuffix(".") { return nameList(String(parts[0].dropLast())) }
        let suffix = "; they are listed under “not connected”."
        return parts.count == 2 && nameList(parts[0]) && parts[1].hasSuffix(suffix)
            && nameList(String(parts[1].dropLast(suffix.count)))
    }

    static func isAppOnly(_ row: ChatMessage, knownBotNames: [String] = []) -> Bool {
        if ReconcileNote.isNote(row) || row.metadata[key] != nil { return true }
        guard row.role == .system else { return false }
        if row.metadata[TurnWaitCopy.key] == "line" { return true }
        if row.presentation == .review || row.presentation == .botMessage { return true }
        return row.presentation == .text && !IntentLine.matches(row.content) && (legacy.contains { $0.matches(row.content) } || legacyIdentityNotice(row.content, knownBotNames: knownBotNames))
    }
}

/// backlog10: plain `system` rows that carry the user's intent and stay model-bound history: the user's own
/// Approved/Declined lines and the Stop lines. A title or an error text inside them can never make them app-only.
enum IntentLine {
    static let approved = LineTemplate("Approved: ", ""), declined = LineTemplate("Declined: ", "")
    static let stopRequested = LineTemplate("Stop requested from ", ".")
    static let stoppedBeforeRunID = LineTemplate("Stopped locally before ", " supplied a run ID.")
    static let stoppedNoAbort = LineTemplate("Stopped locally; this OpenClaw Gateway does not offer chat.abort.")
    static let stoppedNoRunControl = LineTemplate("Stopped locally; this Hermes version has no run-control endpoint.")
    static let stopFailed = LineTemplate("", " Stop failed: ", "")

    static let all = [approved, declined, stopRequested, stoppedBeforeRunID, stoppedNoAbort, stoppedNoRunControl, stopFailed]
    static func matches(_ text: String) -> Bool { all.contains { $0.matches(text) } }
}
