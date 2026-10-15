import Foundation

/// P44 3: a bot answers exactly `[SILENT]` (trimmed, any case) when nothing needs the user (Jarvis's hourly heartbeat).
/// Such a routine run posts no card; any other delivered message with that text is kept (reconcile still pairs it) but
/// never shown, previewed, counted unread or notified. The Routines tab lists the run as "ok · silent".
enum SilentReply {
    static let marker = "[SILENT]"

    static func isSilent(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(marker) == .orderedSame
    }
}

extension ChatMessage {
    /// A bot's (or a routine's) `[SILENT]`; the user's own text is never hidden.
    var isSilent: Bool { role != .user && attachments.isEmpty && SilentReply.isSilent(content) }
}
