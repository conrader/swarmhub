import Foundation

/// The offline example uses the same session rows, detail cards and terminal view as a connected bot.
enum SampleWorkspace {
    enum Role: String, Codable {
        case jarvis, patch, scout, legal, payments
    }

    static let server = HerdrServer(id: "sample-preview", name: "Sample workspace", kind: .address, address: "")
    static let core = "sample-preview"
    static let hosts = ["web-1", "studio-server"]

    /// Older samples retire once a workspace is configured. The offline preview stays until a real bot is added.
    static func hideConfiguredSamples(in bots: [Bot]) {
        let hasRealBots = FirstRun.hasRealAgents(bots)
        for bot in bots where bot.isDemo && (bot.sampleRole == nil || hasRealBots) { bot.isHidden = true }
    }

    @MainActor static func isCoordinator(_ bot: Bot) -> Bool {
        bot.isDemo && bot.backend == .mock && bot.sampleRole == .jarvis
    }

    struct Session {
        let thread: HerdrClient.NativeThread
        let activity: HerdrClient.ThreadActivity

        init(id: String, runtime: HerdrClient.ChildRuntime, model: String, sidebarSummary: String, task: String, reply: String,
             elapsed: Int64, working: Bool, steps: [String], command: String, output: String) {
            let now = Int64(Date.now.timeIntervalSince1970 * 1000)
            let state = working ? "working" : "answered"
            thread = .init(id: id, parent: "jarvis", runtime: runtime, name: id, model: model, createdMs: now - elapsed,
                           completedMs: working ? nil : now, state: state, task: task, reply: reply, sidebarSummary: sidebarSummary)
            let details = HerdrClient.ThreadActivity.Details(task: task, reply: reply,
                steps: steps.map { .init(text: $0, state: working && $0 == command ? "inProgress" : "completed") },
                terminal: .init(command: command, output: output))
            activity = .init(details: details, transcript: "$ " + command + "\n" + output, state: state, activeTurn: nil)
        }
    }

    static let tests = Session(id: "tests", runtime: .claude, model: "Haiku", sidebarSummary: "CSVReaderTests",
        task: "Run `CSVReaderTests` and isolate the blank-title assertion failure in `Sources/Importer/`.",
        reply: "Reproduced failure on line 84 of `CSVReader.swift`: whitespace-only titles bypass the empty check.",
        elapsed: 72000, working: true, steps: ["Read Sources/Importer/CSVReader.swift", "swift test --filter CSVReaderTests"],
        command: "swift test --filter CSVReaderTests", output: "CSVReaderTests started\ntestEmptyTitle failed: expected throw for a whitespace-only title")
    static let rename = Session(id: "rename", runtime: .codex, model: "Sol", sidebarSummary: "14 call sites",
        task: "Rename `fetchAll` to `loadAll` everywhere in `Sources/`.",
        reply: "Renamed 14 call sites across 6 files (`CSVReader.swift`, `ImportQueue.swift`, and 4 tests). `swift build` passed.",
        elapsed: 41000, working: false, steps: ["Search for fetchAll", "Edit Sources/Importer/CSVReader.swift", "swift build"],
        command: "swift build", output: "Build complete! (3.42s)\n14 call sites updated")

    static func stoppedTests(at finish: Int64) -> HerdrClient.NativeThread {
        let tests = tests.thread
        return .init(id: tests.id, parent: tests.parent, runtime: tests.provider, name: tests.name, model: tests.model,
                     createdMs: min(tests.createdMs, finish - 72000), completedMs: finish, state: "stopped", task: tests.task, reply: tests.reply, sidebarSummary: tests.sidebarSummary)
    }

    static func activity(for thread: HerdrClient.NativeThread) -> HerdrClient.ThreadActivity? {
        if thread.id == tests.thread.id, thread.provider == .claude, thread.state == "stopped", let details = tests.activity.details {
            return .init(details: .init(task: thread.task, reply: thread.reply,
                                        steps: details.steps.map { .init(text: $0.text, state: $0.state == "inProgress" ? "stopped" : $0.state) },
                                        terminal: details.terminal),
                         transcript: tests.activity.transcript + "\nStopped.", state: "stopped", activeTurn: nil)
        }
        return [tests, rename].first { $0.thread.id == thread.id && $0.thread.provider == thread.provider }?.activity
    }
}

extension AppStore {
    func stopSampleTests(of bot: Bot) {
        guard SampleWorkspace.isCoordinator(bot), bots.contains(bot),
              herdrHelpers[bot.id]?.claudeThreads?.first?.isWorking == true else { return }
        defaults.set(Int64(Date.now.timeIntervalSince1970 * 1000), forKey: "sample.tests.stopped." + bot.id.uuidString)
        restoreSampleSessions()
    }

    func restoreSampleSessions() {
        var lists = herdrHelpers.filter { $0.value.core != SampleWorkspace.core || $0.value.parent.address != $0.key.botID.uuidString }
        for bot in bots where SampleWorkspace.isCoordinator(bot) {
            let stopped = defaults.object(forKey: "sample.tests.stopped." + bot.id.uuidString) as? NSNumber
            let tests = stopped.map { SampleWorkspace.stoppedTests(at: $0.int64Value) } ?? SampleWorkspace.tests.thread
            lists[.init(botID: bot.id)] = .init(core: SampleWorkspace.core, parent: .init(address: bot.id.uuidString, createdMs: 1),
                helpers: [], codexThreads: [SampleWorkspace.rename.thread], claudeThreads: [tests])
        }
        if lists != herdrHelpers { herdrHelpers = lists }
    }
}
