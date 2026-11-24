import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@Suite struct HerdrRoutinesTests {
    private typealias Schedule = HerdrClient.RoutineSchedule

    @Test @MainActor func allFiveTabsRenderAtTheDetailsMinimumWidth() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false,
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Ada", backend: .herdr)
        store.bots = [bot]
        store.selectedBot = bot
        store.showInfo = false
        let tabs = store.infoTabs(for: bot)
        #expect(tabs == [.overview, .model, .routines, .skills, .media])
        #expect(AppCommand.routines.isEnabled(in: store))
        AppCommand.routines.performWorkspaceAction(in: store)
        #expect(store.showInfo && store.visibleInfoTab(for: bot) == .routines)

        let sample = Bot(name: "Sample", backend: .mock)
        store.selectedBot = sample
        #expect(!AppCommand.routines.isEnabled(in: store))
        #expect(store.infoTabs(for: sample) == [.overview, .media])
        #expect(store.visibleInfoTab(for: sample) == .overview)

        _ = NSApplication.shared
        let bar = InfoTabBar(tabs: tabs, selection: .routines) { _ in }
        // A fixed-size caption always asks for its full width. The ideal render shows
        // how much space the complete labels need before the spaces between tabs expand.
        let ideal = try #require(ImageRenderer(content: bar.fixedSize()).cgImage)
        #expect(ideal.width <= 280)
        let renderer = ImageRenderer(content: bar.frame(width: 300).environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        #expect(image.width == 900)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let inkedColumns = (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
        }
        // Separate the five painted controls by their gutters, allowing letter and icon spacing.
        let gutters = zip(inkedColumns, inkedColumns.dropFirst()).count { $1 - $0 > 18 }
        #expect(gutters == tabs.count - 1)
        #expect((inkedColumns.first ?? 0) >= 18 && (inkedColumns.last ?? image.width) < image.width - 18)
    }

    @Test func decodesServerSchedulesAndSummaries() throws {
        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        let cases: [(String, Schedule, String)] = [
            (#"{"kind":"interval","minutes":60}"#, .interval(minutes: 60), "Every 60 minutes"),
            (#"{"kind":"interval","minutes":1}"#, .interval(minutes: 1), "Every minute"),
            (#"{"kind":"daily","hour":9,"minute":5,"weekdays":false}"#,
             .daily(hour: 9, minute: 5, timezone: nil, weekdays: false), "Daily at 09:05"),
            (#"{"kind":"daily","hour":9,"minute":0,"timezone":"Asia/Bangkok","weekdays":true}"#,
             .daily(hour: 9, minute: 0, timezone: "Asia/Bangkok", weekdays: true), "Weekdays at 09:00"),
            (#"{"kind":"daily","hour":9,"minute":0,"timezone":"America/Los_Angeles","weekdays":true}"#,
             .daily(hour: 9, minute: 0, timezone: "America/Los_Angeles", weekdays: true), "Weekdays at 09:00 (America/Los_Angeles)"),
            (#"{"kind":"webhook"}"#, .webhook(source: nil, filters: [], review: false), "Webhook"),
            (#"{"kind":"webhook","source":"github","filters":[{"field":"action","equals":"opened"}],"review":true}"#,
             .webhook(source: .github, filters: [.init(field: "action", equals: "opened")], review: true), "GitHub webhook"),
            (#"{"kind":"webhook","source":"slack","filters":[{"field":"team_id","equals":"T123"},{"field":"channel","equals":"C123"}]}"#,
             .webhook(source: .slack, filters: [.init(field: "team_id", equals: "T123"),
                                                .init(field: "channel", equals: "C123")], review: false), "Slack mention")
        ]
        for (json, expected, summary) in cases {
            let schedule = try decode(Schedule.self, json)
            #expect(schedule == expected)
            #expect(schedule.summary(in: bangkok) == summary)
            let encoded = try JSONEncoder().encode(schedule)
            #expect(try jsonObject(encoded) == jsonObject(Data(json.utf8)))
        }
    }

    @Test func decodesRoutineAndRunsWithOptionalFields() throws {
        let detail = try decode(HerdrClient.RoutineDetail.self, Self.detailJSON)
        let routine = detail.routine
        #expect(routine.id == 42 && routine.core == "core-a" && routine.agent == "ada-123456")
        #expect(routine.target == .init(address: "pane:4", createdMs: 1700000000000))
        #expect(routine.name == "Morning brief" && routine.task == "Summarize the queue.")
        #expect(routine.state == .active && routine.nextAt == 1700003600000)
        #expect(routine.schedule == .interval(minutes: 60))
        #expect(!routine.webhookReady && routine.profileId == 9)

        let test = try #require(detail.runs.first)
        #expect(test.id == 7 && test.kind == "test" && test.atMs == 1700000010000)
        #expect(test.state == "sent" && test.detail == "Sent" && test.taskId == 51)
        #expect(test.conversation?.core == "core-a" && test.conversation?.address == "pane:4")
        #expect(test.conversation?.createdMs == 1700000000000 && test.conversation?.agent == "ada-123456")
        #expect(test.result?.id == 52 && test.result?.state == "succeeded")
        #expect(test.result?.summary == "All clear" && test.result?.atMs == 1700000020000)
        let pending = try #require(detail.runs.dropFirst().first)
        #expect(pending.awaitingResult == true && pending.result == nil)
        let skipped = try #require(detail.runs.last)
        #expect(skipped.state == "skipped" && skipped.detail == nil)
        #expect(skipped.taskId == nil && skipped.conversation == nil && skipped.awaitingResult == nil)
    }

    @Test func filtersByRuntimeNameAndCurrentOrSavedSessionIdentity() throws {
        let id = try #require(UUID(uuidString: "12345600-0000-0000-0000-000000000001"))
        let name = HerdrBackend.agentName(botName: "Renamed Ada", botID: id)
        let live = HerdrClient.Agent(address: "pane:4", name: name, state: "live", createdMs: 81, template: nil, status: nil)
        let workspace = HerdrClient.Workspace(core: "core-a", version: nil, agents: [live], templates: [])
        let profile = HerdrClient.Profile(id: 9, runtimeName: "old-ada-123456",
                                          sessions: [.init(address: "pane:3", createdMs: 60, core: "old-core")])
        let sessions = HerdrRoutineSessions(agentName: name, workspace: workspace, profiles: [profile])
        #expect(sessions.liveTarget == live.ref)

        let rows = [
            row(1, agent: name, age: 81),
            row(2, agent: "old-ada-123456", age: 70, state: .paused),
            row(3, agent: "manually-renamed", age: 81),
            row(4, agent: "manually-renamed", age: 70, profile: 9),
            row(5, agent: "another-bot-abcdef", age: 10),
            row(6, agent: "another-bot-abcdef", age: 81, core: "other-core"),
            row(7, agent: "another-bot-abcdef", age: 80),
            row(8, agent: name, age: 81, state: .archived),
            row(9, agent: "manually-renamed", address: "pane:3", age: 60, core: "old-core")
        ]
        #expect(routinesForBot(rows, agentName: name, sessions: sessions).map(\.id) == [1, 2, 3, 4, 9])
        #expect(routinesForBot(rows, agentName: name, sessions: nil).map(\.id) == [1, 2])
        #expect(sessions.isLive(rows[0]) == true && sessions.isLive(rows[1]) == false)
        #expect(sessions.isLive(rows[5]) == false)

        let stopped = HerdrClient.Agent(address: live.address, name: name, state: "live", createdMs: live.createdMs,
                                        template: nil, status: nil, reason: "The process exited.")
        let aliased = HerdrClient.Agent(address: "pane:8", name: "new-terminal-name", state: "live", createdMs: 82,
                                        template: nil, status: nil)
        let renamedWorkspace = HerdrClient.Workspace(core: "core-a", version: nil, agents: [stopped, aliased], templates: [])
        let updatedProfile = HerdrClient.Profile(id: 9, runtimeName: profile.runtimeName,
            sessions: [.init(address: aliased.address, createdMs: aliased.createdMs, core: "core-a")])
        let renamed = HerdrRoutineSessions(agentName: name, workspace: renamedWorkspace, profiles: [updatedProfile])
        #expect(renamed.liveTarget == aliased.ref)
        #expect(renamed.isLive(rows[0]) == false)
    }

    @Test func routesUseServerPayloadsAndReturnCheckinsIndependently() async throws {
        let (host, session) = MockHTTPProtocol.serve { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/routines"): return (200, Data("[\(Self.routineJSON)]".utf8))
            case ("GET", "/api/routines/42"): return (200, Data(Self.detailJSON.utf8))
            case ("POST", "/api/routines"): return (201, Data(Self.routineJSON.utf8))
            case ("POST", "/api/routines/42"), ("POST", "/api/routines/42/state"):
                return (200, Data(Self.routineJSON.utf8))
            case ("POST", "/api/routines/42/test"): return (202, ["id": 7])
            case ("GET", "/api/bots/12345600-0000-0000-0000-000000000001/checkins"):
                return (200, Data(#"{"checkins":[{"id":5,"what":"Check the build.","paused":true,"schedule":{"kind":"ci","url":"https://example.test/pr/42","failure":null},"next_ms":null}],"limit":10,"gap_seconds":30}"#.utf8))
            default: return (404, Data())
            }
        }
        let client = HerdrClient(baseURL: try #require(URL(string: "http://\(host)")), token: "test", session: session)
        let target = HerdrClient.AgentRef(address: "pane:4", createdMs: 1700000000000)
        let edit = HerdrClient.RoutineEdit(name: "Morning brief", task: "Summarize the queue.",
                                          schedule: .daily(hour: 9, minute: 0, timezone: "Asia/Bangkok", weekdays: true))
        #expect(try await client.routines().map(\.id) == [42])
        #expect(try await client.routine(42).runs.count == 3)
        #expect(try await client.createRoutine(edit, target: target).id == 42)
        #expect(try await client.editRoutine(42, edit).id == 42)
        for action in [HerdrClient.RoutineControl.pause, .resume, .archive] {
            #expect(try await client.controlRoutine(42, action).id == 42)
        }
        #expect(try await client.testRoutine(42).id == 7)
        let id = try #require(UUID(uuidString: "12345600-0000-0000-0000-000000000001"))
        let plan = try #require(try await client.botCheckins(id).first)
        #expect(plan.what == "Check the build." && plan.paused && plan.nextMs == nil)
        #expect(plan.schedule.kind == "ci" && plan.schedule.url == "https://example.test/pr/42")

        let posts = MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }
        try #require(posts.count == 6)
        let expectedEdit = #"{"name":"Morning brief","task":"Summarize the queue.","schedule":{"kind":"daily","hour":9,"minute":0,"timezone":"Asia/Bangkok","weekdays":true}}"#
        let expectedCreate = #"{"name":"Morning brief","task":"Summarize the queue.","schedule":{"kind":"daily","hour":9,"minute":0,"timezone":"Asia/Bangkok","weekdays":true},"target":{"address":"pane:4","created_ms":1700000000000}}"#
        #expect(try jsonObject(#require(posts[0].bodyData)) == jsonObject(Data(expectedCreate.utf8)))
        #expect(try jsonObject(#require(posts[1].bodyData)) == jsonObject(Data(expectedEdit.utf8)))
        for (post, action) in zip(posts[2...4], ["pause", "resume", "archive"]) {
            #expect(try JSONDecoder().decode(String.self, from: #require(post.bodyData)) == action)
        }
        #expect(posts[5].bodyData?.isEmpty ?? true)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func row(_ id: Int64, agent: String, address: String = "pane:4", age: UInt64,
                     core: String = "core-a", state: HerdrClient.Routine.State = .active, profile: Int? = nil) -> HerdrClient.Routine {
        .init(id: id, core: core, target: .init(address: address, createdMs: age), agent: agent, name: "Routine",
              task: "Check the queue.", schedule: .interval(minutes: 30), state: state,
              nextAt: nil, webhookReady: false, profileId: profile)
    }

    private static let routineJSON = """
        {"id":42,"core":"core-a","target":{"address":"pane:4","created_ms":1700000000000},"agent":"ada-123456",
         "name":"Morning brief","task":"Summarize the queue.","schedule":{"kind":"interval","minutes":60},
         "state":"active","next_at":1700003600000,"webhook_ready":false,"profile_id":9}
        """

    private static let detailJSON = """
        {"routine":\(routineJSON),"runs":[
          {"id":7,"kind":"test","at_ms":1700000010000,"state":"sent","detail":"Sent","task_id":51,
           "conversation":{"core":"core-a","address":"pane:4","created_ms":1700000000000,"agent":"ada-123456"},
           "result":{"id":52,"state":"succeeded","summary":"All clear","at_ms":1700000020000}},
          {"id":6,"kind":"webhook","at_ms":1700000009000,"state":"pending","detail":null,"awaiting_result":true},
          {"id":5,"kind":"schedule","at_ms":1700000008000,"state":"skipped","detail":null}],
         "reviews":[],"slack_ready":false}
        """
}
