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

@MainActor @Test func usageSkipsGrokArchivesAcrossPages() async throws {
    let now = Date().timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url!.path == "/p/grok-jarvis/v1/capabilities" { return (200, ["features": ["session_chat_streaming": true]]) }
        guard request.url!.path == "/p/grok-jarvis/api/sessions" else { return (404, ["error": "no route"]) }
        let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
        // First page holds only archives (still paged on), second a live session and one more archive from today.
        let page: [[String: Any]] = offset == 0
            ? [archiveRow("grok-import-0a1b2c3d-20261013", startedAt: now - 600), archiveRow("grok-import-0a1b2c3d-20261008", startedAt: now - 5 * 86_400)]
            : [["id": "live", "source": "api_server", "started_at": now - 60, "message_count": 2, "input_tokens": 10, "output_tokens": 5],
               archiveRow("grok-import-group-0a1b2c3d-20261013", startedAt: now - 30)]
        return (200, ["object": "list", "data": page, "has_more": offset == 0])
    }
    let backend = HermesBackend(baseURL: URL(string: "https://\(host)/p/grok-jarvis/v1")!, apiKey: "fixture-key", session: session)
    let read = try await backend.usageSessions()
    #expect(read.sessions.map(\.id) == ["live"] && !read.truncated)
    for window in UsageWindow.allCases {
        #expect(UsageTotals.of(read.sessions, window: window) == UsageTotals(sessions: 1, messages: 2, inputTokens: 10, outputTokens: 5), "\(window.rawValue)")
    }
    #expect(await HeadlessCommands.usageSummary(backend) == "1 sessions, 2 messages, 10 in / 5 out (7 d: 1 sessions)")
}

@MainActor @Test func sessionListingAndRoutineResultsSkipGrokArchives() async throws {
    let (_, backend) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        guard request.url?.path == "/api/sessions" else { return .json(404, ["error": "no route"]) }
        return .json(200, ["object": "list", "data": [archiveRow("grok-import-0a1b2c3d-20261013", startedAt: 1), ["id": "live", "source": "api_server", "title": "Chat"]]])
    }
    #expect(try await backend.listSessions().map(\.id) == ["live"])

    let job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Morning")))
    var titled = archiveRow("grok-import-0a1b2c3d-20261012", startedAt: 2); titled["title"] = "cron 00000000beef"
    #expect(HermesJobsClient.latestRunSession([titled], job: job, finishedAt: nil) == nil, "an archive titled like a run is not a run")
}
