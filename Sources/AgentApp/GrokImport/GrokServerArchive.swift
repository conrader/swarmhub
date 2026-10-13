import Foundation

/// P9 wrote each bot's Grok history into its `grok-*` profile's `state.db` as open sessions with `source == "grok-import"`
/// (one per day). They are archives, not activity: they never count as usage and never appear where the app lists sessions.
enum GrokServerArchive {
    static let source = "grok-import"

    /// True for a `GET /api/sessions` row that is a server-side Grok archive session.
    static func isArchiveSession(_ row: [String: Any]) -> Bool { row["source"] as? String == source }

    /// Drops the archive sessions from a session listing.
    static func excludingArchives(_ rows: [[String: Any]]) -> [[String: Any]] { rows.filter { !isArchiveSession($0) } }

    enum Choice: Equatable { case local, none }

    /// The one archive a bot shows. LOCAL WINS: the Mac's archive is complete and lossless, the server copy is lossy.
    /// The server copy is never shown (no server fallback is built), so a bot shows at most one archive, never two.
    static func choice(hasLocalArchive: Bool) -> Choice { hasLocalArchive ? .local : .none }
}
