import AppKit
import Foundation
import Testing
@testable import AgentApp

// MARK: --e2e step runner

@MainActor @Test func e2eRunsEveryStepThroughTheStoreInSelfTestSessions() async throws {
    let (store, bots, state) = e2eStore()
    var lines: [String] = []
    let steps = await HeadlessE2E.run(store: store, bots: bots, timing: .fast, output: { lines.append($0) })

    #expect(steps.map { $0.id } == ["a", "b1", "b2", "c", "d", "e", "f", "h"])
    #expect(steps.allSatisfy { $0.passed }, "\(lines)")
    #expect(lines.prefix(8).allSatisfy { $0.hasPrefix("PASS ") })
    #expect(lines.last == "E2E: 8 passed, 0 failed")
    // P28 D4: b1 stopped the count and sent the correction; b2's steer landed after the terminal step.
    #expect(steps[1].detail.contains("partial kept") && steps[1].detail.contains("E2E-STEER"))
    #expect(steps[2].detail.contains("after the terminal step") && steps[2].detail.contains("E2E-STEER"))
    // P39 h: both copies answered at once; Stop on the first left the second complete.
    #expect(steps[7].detail.contains("first stopped") && steps[7].detail.contains("second complete: E2E-CONCURRENT"))

    let requests = state.requests()
    // Every session created or forked is a new AppConstants.selfTestPrefix session; every message carries the preamble.
    let created = requests.filter { $0.method == "POST" && ($0.path.hasSuffix("/api/sessions") || $0.path.hasSuffix("/fork")) }.compactMap { $0.body?["id"] as? String }
    #expect(created.count == 7, "a, b1, b2, the group and h's two bots create a session; c forks one")
    #expect(created.allSatisfy { $0.hasPrefix(AppConstants.selfTestPrefix) })
    let inputs = requests.filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["input"] as? String ?? "" }
    #expect(inputs.count == 9, "a, b1, b1's correction, b2, c, d, e and h's two")
    #expect(inputs.allSatisfy { $0.contains(HeadlessE2E.preamble) })
    // b1: Stop was requested for the count's run before the correction went out, with its lead line.
    let stop = try #require(requests.firstIndex { $0.path.hasSuffix("/stop") })
    let correction = try #require(requests.firstIndex { ($0.body?["input"] as? String)?.hasPrefix(SteerCopy.lead) == true })
    #expect(stop < correction)
    #expect(requests.allSatisfy { !$0.path.hasPrefix("/p/grok-achilles/") || $0.method == "GET" }, "Achilles was not mentioned, so nothing is sent to it")
    // Model: switched to the other offered model, then back.
    let locks = requests.filter { $0.path.hasSuffix("/model") }.compactMap { $0.body?["model"] as? String }
    #expect(locks == ["model-b", "model-a"])
    // Routines are listed only; the temporary group is gone.
    #expect(requests.filter { $0.path.contains("/api/jobs") }.allSatisfy { $0.method == "GET" })
    #expect(store.groups.isEmpty)
}

@MainActor @Test func e2eFailsStepsTheServerDoesNotSupport() async throws {
    var features = E2EServer.allFeatures; features["run_steer"] = false; features["session_fork"] = false
    let (store, bots, state) = e2eStore(features: features)
    // The client sees the first tokens at once and finds no steer; the held runs need not last 5 s each.
    state.with { $0.unsteeredHold = 1 }
    var lines: [String] = []
    let steps = await HeadlessE2E.run(store: store, bots: bots, timing: .fast, output: { lines.append($0) })

    #expect(steps.filter { !$0.passed }.map { $0.id } == ["b1", "b2", "c"], "\(lines)")
    #expect(lines.contains { $0.hasPrefix("FAIL b1 steer during text") && $0.contains("steer not offered") })
    #expect(lines.contains { $0.hasPrefix("FAIL b2 steer during a tool step") && $0.contains("steer not offered") })
    #expect(lines.contains { $0.hasPrefix("FAIL c fork") && $0.contains("session_fork") })
    #expect(lines.last == "E2E: 5 passed, 3 failed")
    #expect(!state.requests().contains { $0.path.hasSuffix("/fork") || $0.path.hasSuffix("/steer") })
}

@MainActor @Test func e2eFindsTheGrokBotBeforeOtherBotsWithTheSameName() {
    let demo = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "default")
    let grok = Bot(name: "jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); grok.grokSourceID = "src"
    let mock = Bot(name: "Jarvis", backend: .mock)
    #expect(HeadlessE2E.find("Jarvis", in: [mock, demo, grok]) === grok)
    #expect(HeadlessE2E.find("Nobody", in: [demo, grok]) == nil)
}

// MARK: --ui-smoke report

@MainActor @Test func uiSmokeReportsWindowChatHistoryAndPanels() async throws {
    _ = NSApplication.shared
    let (store, _, _) = e2eStore()
    let bot = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-jarvis"); bot.grokSourceID = "src"; bot.grokHistoryCount = 0
    store.bots.insert(bot, at: 0)
    store.groups = [GroupChat(name: "Konrad, DMT, Achilles", memberIDs: [store.bots[2].id, store.bots[3].id])]
    UISmokeProbe.renderedChats.insert(bot.id); UISmokeProbe.historyHeaders[bot.id] = 0
    await store.loadServerInfo(for: bot)
    let window = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    // The window budget is the asserted miss; the chat, overview and routines waits end as soon as their state
    // arrives, so their budgets are the hang ceiling (a loaded Mac outlasted 2 s and 10 s).
    let budget = UISmoke.Budget(window: .milliseconds(50), chat: waitCeiling, overview: waitCeiling, routines: waitCeiling)
    let report = await UISmoke.collect(store: store, budget: budget, window: { window })

    #expect(store.selectedBot === bot)
    #expect(report["window_visible"] as? Bool == false)
    #expect((report["errors"] as? [String])?.first?.hasPrefix("main window not visible") == true)
    #expect((report["window_frame"] as? [String: Any])?["width"] as? CGFloat == 300)
    #expect((report["sidebar_rows"] as? [String: Int]) == ["bots": 4, "groups": 1, "total": 5])
    #expect((report["selected_bot"] as? [String: Any])?["name"] as? String == "Infra")
    let history = try #require(report["grok_history"] as? [String: Any])
    #expect(history["header_shown"] as? Bool == true && history["matches"] as? Bool == true)
    #expect((report["overview"] as? [String: Any])?["state"] as? String == "unavailable", "skills_api is off on the mock")
    #expect((report["routines"] as? [String: Any])?["jobs"] as? Int == 1)

    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-uismoke-\(UUID().uuidString)")
    let url = directory.appending(path: "ui-smoke.json")
    try UISmoke.write(report, to: url)
    let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(written["sidebar_rows"] != nil)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    try? FileManager.default.removeItem(at: directory)
}

@MainActor @Test func uiSmokeReadsItsReportPath() {
    #expect(UISmoke.reportPath(arguments: [AppConstants.name, "--ui-smoke", "~/x/ui.json"]) == ("~/x/ui.json" as NSString).expandingTildeInPath)
    #expect(UISmoke.reportPath(arguments: [AppConstants.name, "--ui-smoke"]) == nil)
    #expect(UISmoke.reportPath(arguments: [AppConstants.name]) == nil)
}

// MARK: P39 h

/// Case h against the fake backend: the held count and the second bot's reply run at once; only the first is stopped.
@MainActor @Test func e2eConcurrentCaseStopsOneAndLeavesTheOtherComplete() async throws {
    let (store, bots, state) = e2eStore()
    store.sessionNamespace = HeadlessE2E.namespace
    let step = await HeadlessE2E.concurrentStep(store: store, bots: bots, tag: "unit", timing: .fast)
    #expect(step.passed, "\(step.line)")
    #expect(step.id == "h" && step.detail.contains("first stopped"))
    let requests = state.requests()
    let streams = requests.filter { $0.path.hasSuffix("/chat/stream") }
    #expect(streams.count == 2 && Set(streams.map { $0.path.split(separator: "/")[1] }).count == 2, "two bots, two profiles")
    #expect(requests.filter { $0.path.hasSuffix("/stop") }.count == 1, "only the first turn is stopped")
    #expect(!store.anyTurnRunning && !store.bots.contains { $0.name.contains(" h unit") }, "the copies are removed afterwards")
}

@MainActor @Test func e2eConcurrentVerdictNeedsBothTurnsAtOnceAndACompleteSecondReply() {
    let partial = ChatMessage(role: .assistant, content: "1\n", turnState: .stopped)
    let done = ChatMessage(role: .assistant, content: "1 2 3 4 5 \(HeadlessE2E.concurrentToken)", turnState: .finished)
    let cut = ChatMessage(role: .assistant, content: "1 2", turnState: .stopped)
    #expect(HeadlessE2E.concurrentOutcome(first: [partial], second: [done], both: true, stopped: true, ended: true).passed)
    #expect(!HeadlessE2E.concurrentOutcome(first: [partial], second: [done], both: false, stopped: true, ended: true).passed)
    #expect(HeadlessE2E.concurrentOutcome(first: [partial], second: [cut], both: true, stopped: true, ended: true).detail.contains("left the second incomplete"))
    #expect(!HeadlessE2E.concurrentOutcome(first: [done], second: [done], both: true, stopped: false, ended: true).passed)
}
