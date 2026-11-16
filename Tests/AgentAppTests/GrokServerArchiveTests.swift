import Foundation
import Testing
@testable import AgentApp

/// Synthetic rows only: a P9 archive session is an open `grok-import` session (one per Warsaw day).
private func archiveRow(_ id: String, startedAt: Double) -> [String: Any] {
    ["id": id, "source": "grok-import", "title": "Grok archive · Jarvis · 2026-10-13", "started_at": startedAt, "ended_at": NSNull(),
     "message_count": 400, "input_tokens": 0, "output_tokens": 0, "archived": false, "hidden": false]
}

@Test func grokImportSessionsAreRecognisedAndDropped() {
    let rows: [[String: Any]] = [archiveRow("grok-import-0a1b2c3d-20261013", startedAt: 1), ["id": "live", "source": "api_server"], ["id": "nosource"], ["id": "tg", "source": "telegram"]]
    #expect(GrokServerArchive.isArchiveSession(rows[0]) && !GrokServerArchive.isArchiveSession(rows[1]) && !GrokServerArchive.isArchiveSession(rows[2]))
    #expect(GrokServerArchive.excludingArchives(rows).compactMap { $0["id"] as? String } == ["live", "nosource", "tg"])
    #expect(!GrokServerArchive.isArchiveSession(["id": "x", "source": "Grok-Import"]), "the source is matched exactly")
}

@Test func localArchiveWinsAndServerArchiveIsNeverShown() {
    #expect(GrokServerArchive.choice(hasLocalArchive: true) == .local)
    #expect(GrokServerArchive.choice(hasLocalArchive: false) == .none, "no server fallback: at most one archive per bot")
}

