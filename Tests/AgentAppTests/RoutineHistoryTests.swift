import Foundation
import Testing
@testable import AgentApp

/// P38: `completedRuns` reads every run after a cursor by the job's cron session id, oldest first, GET only.
@Test func completedRunsMatchTheJobIDNotItsTitleOldestFirst() async throws {
    let job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Brief", lastRunAt: "2026-10-13T10:00:30+00:00", lastStatus: "ok")))
    let ten = try #require(RoutineTime.date("2026-10-13T10:00:00+00:00")).timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        let path = request.url!.path, query = request.url!.query ?? ""
        if path.hasSuffix("/api/sessions"), query.contains("source=cron") {
            return (200, ["data": [
                ["id": "cron_00000000beef_late", "source": "cron", "started_at": ten + 7_200],                 // after last_run_at, not finished
                ["id": "cron_00000000beef_ten", "source": "cron", "started_at": ten, "ended_at": ten + 20, "status": "ok"],
                ["id": "cron_feed00000000_ten", "source": "cron", "title": "Brief · Oct 13 10:00", "started_at": ten, "ended_at": ten + 20],
                ["id": "cron_00000000beef_nine", "source": "cron", "started_at": ten - 3_600, "ended_at": ten - 3_580, "status": "error", "error": "boom"],
                ["id": "cron_00000000beef_old", "source": "cron", "started_at": ten - 86_400, "ended_at": ten - 86_380]
            ]])
        }
        let id = path.components(separatedBy: "/api/sessions/").last?.components(separatedBy: "/").first ?? ""
        return (200, ["data": [["role": "user", "content": "prompt"], ["role": "assistant", "content": "reply \(id)"]]])
    }
    let backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "fixture", profile: "solo", session: session)
    let runs = try await HermesJobsClient(backend: backend).completedRuns(for: job, after: "2026-10-12T12:00:00+00:00")
    #expect(runs.map(\.result.sessionID) == ["cron_00000000beef_nine", "cron_00000000beef_ten"])
    #expect(runs.map(\.result.text) == ["reply cron_00000000beef_nine", "reply cron_00000000beef_ten"])
    #expect(runs[0].result.status == "error" && runs[0].result.error == "boom")
    #expect(runs[1].stamp == "2026-10-13T10:00:20Z")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.httpMethod == "GET" })
}

@Test func completedRunsRefuseAnOutputThatIsNotReadyAndTooLongAHistory() async throws {
    let job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Brief", lastRunAt: "2026-10-13T10:00:30+00:00", lastStatus: "ok")))
    let ten = try #require(RoutineTime.date("2026-10-13T10:00:00+00:00")).timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url!.path.hasSuffix("/api/sessions") { return (200, ["data": [["id": "cron_00000000beef_ten", "started_at": ten, "ended_at": ten + 20]]]) }
        return (200, ["data": [["role": "user", "content": "prompt"]]])
    }
    let client = HermesJobsClient(backend: HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "fixture", profile: "solo", session: session))
    await #expect(throws: BackendError.self) { _ = try await client.completedRuns(for: job, after: "") }

    let size = HermesJobsClient.historyPageSize
    let (busy, busySession) = MockHermesProtocol.serve { _ in (200, ["data": (0..<size).map { ["id": "cron_feed00000000_\($0)", "started_at": ten] as [String: Any] }]) }
    let crowded = HermesJobsClient(backend: HermesBackend(baseURL: URL(string: "https://\(busy)/v1")!, apiKey: "fixture", profile: "solo", session: busySession))
    await #expect(throws: BackendError.self) { _ = try await crowded.completedRuns(for: job, after: "") }
    #expect(MockHermesProtocol.recorded(busy).count == HermesJobsClient.historyPages)
}
