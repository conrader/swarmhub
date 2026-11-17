import Foundation
import Testing
@testable import AgentApp

// A message to a real agent on a real workspace server, through the code the app sends its own messages with
// (`HerdrBackend.send`). It runs only when asked: it starts an agent program, which uses that program's account.
//
//     SWARMHUB_LIVE_URL=http://127.0.0.1:8791 SWARMHUB_LIVE_TOKEN=… SWARMHUB_LIVE_TEMPLATE=swarmhub-claude \
//     SWARMHUB_LIVE_OUT=/tmp/live.json swift test --filter aRealAgentAnswersThroughTheAppsOwnClient
//
// `SWARMHUB_LIVE_MESSAGE` replaces the message, `SWARMHUB_LIVE_MODEL` names a model. The file named by
// `SWARMHUB_LIVE_OUT` gets what the chat would have shown: every status, every tool step, how often the reply grew,
// and the reply. The check itself only asks that a reply arrived; what it holds is for a person to read.

private struct LiveTranscript: Encodable {
    var template = "", statuses: [String] = [], tools: [String] = [], growths = 0, firstPartial = "", reply = "", failure: String?
    var seconds = 0.0
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_LIVE_URL"] != nil), .timeLimit(.minutes(6)))
func aRealAgentAnswersThroughTheAppsOwnClient() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = try #require(environment["SWARMHUB_LIVE_URL"].flatMap(HerdrClient.validatedBaseURL))
    let token = try #require(environment["SWARMHUB_LIVE_TOKEN"])
    let client = HerdrClient(baseURL: url, token: token)
    let template = environment["SWARMHUB_LIVE_TEMPLATE"]
    let message = environment["SWARMHUB_LIVE_MESSAGE"]
        ?? "Run this shell command: echo swarmhub-live-check. Then write three short sentences about the sea, and end with the word DONE."
    let backend = HerdrBackend(client: client, botName: "Live Check", botID: UUID(), template: template, model: environment["SWARMHUB_LIVE_MODEL"])
    var transcript = LiveTranscript(template: template ?? "")
    let began = Date()
    do {
        for try await event in try await backend.send(AgentRequest(sessionID: "live", systemPrompt: "", messages: [(role: "user", content: message)])) {
            switch event {
            case .status(let code): if transcript.statuses.last != code { transcript.statuses.append(code) }
            case .tool(let tool): transcript.tools.append("\(tool.phase) \(tool.name)\(tool.preview.map { ": \($0)" } ?? "")")
            case .replace(let text):
                if text != transcript.reply { transcript.growths += 1 }
                if transcript.firstPartial.isEmpty { transcript.firstPartial = text }
                transcript.reply = text
            case .token(let text): transcript.reply += text
            case .launchModel, .runActivity, .completed, .failed: break
            }
        }
    } catch { transcript.failure = error.localizedDescription }
    transcript.seconds = Date().timeIntervalSince(began)
    if let out = environment["SWARMHUB_LIVE_OUT"] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: URL(fileURLWithPath: out))
    }
    // The agent is ended either way, so a check leaves nothing running.
    if let agent = client.liveAgent(named: backend.agentName, in: try await client.workspace()) { try? await client.end(agent) }
    #expect(transcript.failure == nil, "\(transcript.failure ?? "")")
    #expect(!transcript.reply.isEmpty)
}

// "This Mac" set up for real through the app's own code: the release is read from a feed and checked against a key
// (`WorkspaceRelease`), the program is put in place and run (`HerdrLocalService`), the server it starts is read as
// the setup window reads it (`HerdrClient.offer`), updated as Software Update updates it, and removed again.
// `HerdrWorkspace/tests/app_setup_smoke.py` runs these three steps with a scratch home, a local feed, a throwaway
// key and a launchd job name of its own; nothing here runs without it.
//
//     SWARMHUB_LOCAL_LIVE_STEP=setup|update|remove  SWARMHUB_LOCAL_LIVE_HOME  SWARMHUB_LOCAL_LIVE_FEED
//     SWARMHUB_LOCAL_LIVE_KEY (the public key)  SWARMHUB_LOCAL_LIVE_PORT  SWARMHUB_LOCAL_LIVE_LABEL
//     SWARMHUB_LOCAL_LIVE_PATH (folders with hc and stand-in agent programs)  SWARMHUB_LOCAL_LIVE_SESSION

private struct LocalLive {
    let environment = ProcessInfo.processInfo.environment
    var step: String? { environment["SWARMHUB_LOCAL_LIVE_STEP"] }
    func value(_ name: String) throws -> String { try #require(environment["SWARMHUB_LOCAL_LIVE_\(name)"]) }
    func service() throws -> HerdrLocalService {
        HerdrLocalService(home: try value("HOME"), environment: ["SWARMHUB_UPDATE_FEED": try value("FEED"), "SWARMHUB_SERVICE_PATH": try value("PATH"), "HC_SESSION": try value("SESSION")],
                          label: try value("LABEL"))
    }
    func client() throws -> HerdrClient {
        let port = try #require(Int(try value("PORT")))
        let token = HerdrServerList.localToken(homes: [try value("HOME")])
        return HerdrClient(baseURL: try #require(HerdrClient.validatedBaseURL(HerdrServer.loopback(port: port))), token: token)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_LOCAL_LIVE_STEP"] == "setup"), .timeLimit(.minutes(5)))
func thisMacIsSetUpFromASignedReleaseAndNothingElse() async throws {
    let live = LocalLive(), service = try live.service(), feed = try live.value("FEED"), key = try live.value("KEY"), port = try #require(Int(try live.value("PORT")))
    #expect(!service.isPlaced)
    // A release that is not signed with the key the app trusts is not used: nothing is fetched, nothing is put in place.
    let stranger = "uqOCQdP4qfiw0rOKsjX65T+AaH7LKkTswhjeU22eju4="
    await #expect(throws: WorkspaceRelease.Failure.unsigned) { _ = try await WorkspaceRelease.latest(publicKey: stranger, mirror: feed) }
    #expect(!service.isPlaced)
    // The signed release: its program for this Mac's processor has the size and digest the signed manifest names.
    let release = try await WorkspaceRelease.latest(publicKey: key, mirror: feed)
    let asset = try #require(release.asset(for: HerdrLocalService.target), "the feed has a program for \(HerdrLocalService.target)")
    let program = try await release.program(for: HerdrLocalService.target, mirror: feed)
    #expect(WorkspaceRelease.matches(program, asset))
    var damaged = program; damaged[damaged.count - 1] ^= 0xFF
    #expect(!WorkspaceRelease.matches(damaged, asset), "a program that is not the one described would be refused")
    try service.place(program)
    let report = try await service.install(port: port)
    #expect(report.version == release.manifest.version && report.service.installed && report.service.loaded && report.service.answers && report.core.running)
    #expect(report.port == port && report.programs.allSatisfy(\.installed) && (report.did ?? []).contains { $0.contains("access key") })
    // The setup window's own reading of the server: it is there, and it offers the AIs the service found.
    let offer = try await live.client().offer()
    #expect(Set(offer.programs.map(\.name)) == Set(report.programs.map(\.name)), "\(offer.programs.map(\.name))")
    #expect(try await live.client().workspace().bridge?.version == release.manifest.version)
    // A second setup changes nothing a person made, and needs no download.
    let token = HerdrServerList.localToken(homes: [service.home])
    _ = try await service.install(port: port)
    #expect(HerdrServerList.localToken(homes: [service.home]) == token && token.count == 64)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_LOCAL_LIVE_STEP"] == "update"), .timeLimit(.minutes(5)))
func softwareUpdateUpdatesThisMacLikeAnyServer() async throws {
    let live = LocalLive(), client = try live.client()
    var state = HerdrServerUpdate()
    let before = try await client.workspace()
    state.take(.answered(bridge: before.bridge, core: before.version))
    let from = try #require(before.bridge?.version)
    let status = try await client.updateStatus()
    let port = try #require(Int(try live.value("PORT")))
    let process = try await live.service().status(port: port).service.pid
    let check = try await client.checkUpdate()
    state.take(.checked(check, canUpdate: status.canUpdate ?? false))
    let version = try #require(state.installable, "\(state.phase)")
    state.take(.installBegan(version: version))
    state.take(.accepted(try await client.applyUpdate(version: version)))
    #expect(state.phase == .restarting(from: from, to: version))
    let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
    while clock.now < deadline, state.phase != .updated(to: version) {
        try await Task.sleep(for: .milliseconds(500))
        if let now = try? await client.updateStatus() { state.take(.cameBack(version: now.bridge.version, last: now.last)) }
    }
    #expect(state.phase == .updated(to: version) && state.line.contains("Your agents kept running"))
    // launchd still runs it: the service says so, with the new version.
    let report = try await live.service().status(port: port)
    #expect(report.service.loaded && report.service.answers && report.service.pid == process && process != nil, "the same process became the new version")
    #expect(try await client.workspace().bridge?.version == version)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_LOCAL_LIVE_STEP"] == "remove"), .timeLimit(.minutes(3)))
func removingTheServiceLeavesConversationsAndNothingRunning() async throws {
    let live = LocalLive(), service = try live.service(), port = try #require(Int(try live.value("PORT")))
    let removal = try await service.remove()
    #expect(removal.did.contains { $0.contains("Stopped") } && removal.kept.contains { $0.contains("conversations") })
    #expect(!service.isPlaced && HerdrServerList.localToken(homes: [service.home]).isEmpty)
    #expect(await !HerdrTunnels.answers(port: port))
}
