import AppKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import AgentApp

@Test func botUsageFollowsSessionLineageWithoutIncludingOtherAgents() throws {
    let row = try #require(SessionUsage.parse(["id": "child", "parent_session_id": "main", "_lineage_root_id": "main", "input_tokens": 10]))
    #expect(row.parentSessionID == "main" && row.lineageRootID == "main")
    let sessions = [
        SessionUsage(id: "grandchild", inputTokens: 20, parentSessionID: "child"), row,
        SessionUsage(id: "main", inputTokens: 30),
        SessionUsage(id: "continuation", inputTokens: 40, parentSessionID: "unread", lineageRootID: "main"),
        SessionUsage(id: "other-agent", inputTokens: 9_000),
        SessionUsage(id: "other-child", inputTokens: 9_000, parentSessionID: "other-agent"),
        SessionUsage(id: "cycle-a", parentSessionID: "cycle-b"), SessionUsage(id: "cycle-b", parentSessionID: "cycle-a")
    ]
    let owned = SessionUsage.owned(sessions + [row], by: ["main"])
    #expect(Set(owned.map(\.id)) == ["grandchild", "child", "main", "continuation"])
    #expect(UsageTotals.of(owned, window: .all).inputTokens == 100, "duplicate rows count once")
    #expect(SessionUsage.owned(sessions, by: []).isEmpty)
}

@MainActor @Test func sharedProfileUsageIsSeparateForEachAgent() async {
    let a = Bot(name: "A", backend: .hermes, hermesProfile: "shared")
    let b = Bot(name: "B", backend: .hermes, hermesProfile: "shared", hermesSessionID: "b-main")
    let thread = ChatThread(parentMessageID: UUID(), parentSessionID: nil, hermesSessionID: "a-thread")
    a.threads = [thread]
    let group = GroupChat(name: "Team", memberIDs: [a.id, b.id])
    group.sessions[b.id.uuidString.lowercased()] = "b-group"
    let aMain = "agentapp_\(a.id.uuidString.lowercased())"
    let aGroup = GroupRouting.sessionID(group: group.id, bot: a.id)
    let now = Date().timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url!.path.hasSuffix("v1/capabilities") { return (200, ["features": ["session_chat_streaming": true]]) }
        return (200, ["data": [
            ["id": "a-grandchild", "parent_session_id": "a-child", "started_at": now - 10, "input_tokens": 2],
            ["id": "a-child", "parent_session_id": aMain, "started_at": now - 10, "input_tokens": 3],
            ["id": aMain, "started_at": now - 10, "input_tokens": 5, "output_tokens": 4, "cache_read_tokens": 2],
            ["id": "a-thread", "started_at": now - 10, "input_tokens": 7],
            ["id": aGroup, "started_at": now - 10, "input_tokens": 11],
            ["id": "b-main", "started_at": now - 10, "input_tokens": 100],
            ["id": "b-group", "started_at": now - 10, "input_tokens": 200],
            ["id": "external", "started_at": now - 10, "input_tokens": 900],
            ["id": "archive", "source": "grok-import", "parent_session_id": aMain, "input_tokens": 9_999]
        ], "has_more": false])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(["hermes.shared": "fixture-key"]), defaults: isolatedDefaults(), hermesSession: session)
    for bot in [a, b] { bot.hermesBaseURL = "https://\(host)/v1" }
    b.hermesBaseURL = "https://\(host)/"
    store.bots = [a, b]; store.groups = [group]
    let aUsage = await store.loadUsage(for: a), bUsage = await store.loadUsage(for: b)
    #expect(aUsage.scope == .conversations && bUsage.scope == .conversations)
    #expect(aUsage.problem == nil && bUsage.problem == nil)
    #expect(aUsage.totals(.week).inputTokens == 28 && aUsage.totals(.week).outputTokens == 4 && aUsage.totals(.week).cacheReadTokens == 2)
    #expect(aUsage.totals(.week).sessions == 5)
    #expect(bUsage.totals(.week).inputTokens == 300 && bUsage.totals(.week).sessions == 2)
    #expect(store.usageSessionIDs(for: a).contains("agentapp_thread_\(thread.id.uuidString.lowercased())"))
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.httpMethod == "GET" && $0.url!.path.hasPrefix("/p/shared/") })
}

@MainActor @Test func dedicatedAgentUsageIncludesAllChannelsAndOnlyReadsItsProfile() async {
    let now = Date().timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        guard request.url!.path.hasPrefix("/p/solo/") else { return (500, ["error": "wrong profile"]) }
        if request.url!.path.hasSuffix("v1/capabilities") { return (200, ["features": ["session_chat_streaming": true]]) }
        return (200, ["data": [
            ["id": "cron-run", "source": "cron", "started_at": now - 60, "input_tokens": 1_000, "output_tokens": 200],
            ["id": "telegram", "source": "telegram", "started_at": now - 30 * 86_400, "input_tokens": 3_000]
        ], "has_more": false])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(["hermes.solo": "k", "hermes.other": "k2"]), defaults: isolatedDefaults(), hermesSession: session)
    let bot = Bot(name: "Solo", backend: .hermes, hermesProfile: "solo")
    let other = Bot(name: "Other", backend: .hermes, hermesProfile: "other")
    for bot in [bot, other] { bot.hermesBaseURL = "https://\(host)/v1" }
    store.bots = [bot, other]
    let usage = await store.loadUsage(for: bot)
    #expect(usage.scope == .profile && usage.problem == nil)
    #expect(usage.totals(.week).totalTokens == 1_200 && usage.totals(.all).totalTokens == 4_200)
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.httpMethod == "GET" && $0.url!.path.hasPrefix("/p/solo/") })
}

@MainActor @Test func unavailableAgentUsageDoesNotContactServers() async {
    let (host, session) = MockHermesProtocol.serve { _ in (500, ["error": "should not be called"]) }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(), hermesSession: session)
    let archive = Bot(name: "Archive", backend: .hermes); archive.archivedMembers = []
    let bots = [Bot(name: "Demo", backend: .hermes, isDemo: true), Bot(name: "Mock"),
                Bot(name: "OpenClaw", backend: .openClaw), Bot(name: "Missing key", backend: .hermes, hermesProfile: "missing"), archive]
    for bot in bots {
        bot.hermesBaseURL = "https://\(host)/v1"
        let usage = await store.loadUsage(for: bot)
        #expect(usage.problem != nil && usage.sessions.isEmpty)
    }
    #expect(MockHermesProtocol.recorded(host).isEmpty)
}

@MainActor @Test func tokenUsageSectionFitsNarrowInspector() async throws {
    let now = Date().timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url!.path.hasSuffix("v1/capabilities") { return (200, ["features": ["session_chat_streaming": true]]) }
        return (200, ["data": [["id": "fixture", "started_at": now - 60, "input_tokens": 1_000, "output_tokens": 200, "cache_read_tokens": 50]], "has_more": false])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(["hermes.fixture": "k"]), defaults: isolatedDefaults(), hermesSession: session)
    let bot = Bot(name: "Fixture", backend: .hermes, hermesProfile: "fixture")
    bot.hermesBaseURL = "https://\(host)/v1"; store.bots = [bot]; store.botInfo.autoLoad = true
    // This is a layout assertion on loaded data. Shared GET admission can outlast the renderer's
    // 300 ms settling pass, so await the fixture result instead of racing the status queue.
    let usage = await store.loadUsage(for: bot)
    #expect(usage.problem == nil && usage.totals(.week).totalTokens == 1_200)
    // Both appearances with SWARMHUB_RENDER_TESTS=1; a plain run renders the dark one (testspeed).
    for scheme in renderTests ? [ColorScheme.dark, .light] : [.dark] {
        let view = BotUsageView(bot: bot).environmentObject(store).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(AppColor.panel)
        let data = try #require(await SnapshotRenderer.png(view, size: NSSize(width: 300, height: 380), scheme: scheme))
        let bitmap = try #require(NSBitmapImageRep(data: data)), cgImage = try #require(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([recognition])
        let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        #expect(text.contains("Token usage") && text.contains(1_200.formatted()) && text.contains("Input") && text.contains("Output") && text.contains("Cache read") && text.contains("Sessions"), "The 300 pt Activity section renders loaded counts: \(text)")
        if let directory = ProcessInfo.processInfo.environment["SWARMHUB_USAGE_CAPTURE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appending(path: scheme == .dark ? "usage-dark.png" : "usage-light.png"))
        }
    }
}
