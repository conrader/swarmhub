import Foundation
import Testing
@testable import AgentApp

@Test func durablePeerCallsPersistTheirTaskAndPendingDeliveryMode() throws {
    let call = try #require(BotMessageCall.parse(command: "bot-msg --durable --task-id task.abc --from worker --to infra -- 'take the next step'"))
    #expect(call.durable == true && call.taskID == "task.abc" && call.isDeferred && !call.isHeld)
    #expect(call.text == "take the next step")
    #expect(try JSONDecoder().decode(BotMessageCall.self, from: JSONEncoder().encode(call)) == call)
    let old = try JSONDecoder().decode(BotMessageCall.self, from: Data(#"{"to":"infra","text":"old","noWait":false}"#.utf8))
    #expect(old.durable == nil && !old.isDeferred)
    #expect(BotMessageCopy.chip("Infra", .pending) == "Delivery to Infra pending")
}

@Test @MainActor func durableAdmissionReceiptIsNotAReplyOrAnActiveRecipient() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let sender = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "jarvis")
    let recipient = Bot(name: "Infra", backend: .hermes, hermesProfile: "infra")
    store.bots = [sender, recipient]; store.botMessages.autoLoad = false
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "durable", command: "bot-msg --to infra --durable -- retry later"), at: store.now())
    let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
    assistant.activity = activity; sender.messages = [assistant]
    let turn = store.beginTurn(in: sender, bot: sender, assistant: assistant)
    defer { store.endTurn(turn.token) }
    let key = BotThreadKey(from: "jarvis", to: "infra")
    #expect(store.incomingBotMessageLine(for: recipient) == nil)
    #expect(store.chipState(for: activity.steps[0], key: key, streaming: true) == .pending)
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "durable", result: "pending:delivery.abc"), at: store.now())
    assistant.activity = activity
    #expect(store.chipState(for: activity.steps[0], key: key, streaming: false) == .pending)
    #expect(store.knownThreadLines(key).map(\.text) == (["retry later"] as [String]))
    #expect(store.allBotThreads().first?.lastLine == "retry later")
}

/// The same ten acceptance replays can run on macOS from `swift test` without
/// network access or coding CLIs. Native parsing/state assertions are above.
/// The harness refuses to start on Linux outside an isolated PID namespace; on macOS it runs signal-guarded.
// Each replay starts Python/shell workers and a verifier. Running these in parallel competes with the full Mac suite
// for process startup and CPU; these acceptance cases do not need to overlap to exercise their concurrency rules.
@Test(.serialized, arguments: (1...10).map { String(format: "P%02d", $0) })
func observedPatternManagedRuntimeReplay(_ pattern: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory.appending(path: "patterns-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [root.appending(path: "sim/live_observed.py").path, "--offline", "--pattern", pattern, "--output", output.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": output.path, "PYTHONDONTWRITEBYTECODE": "1"]
    let (status, log) = try await runToEnd(process)
    #expect(status == 0, "\(pattern): \(log)")
    let data = try Data(contentsOf: output.appending(path: "results.json"))
    let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(report["patterns"] as? [[String: Any]])
    #expect(rows.count == 1 && rows.first?["grade"] as? String == "matches")
    #expect(report["model_calls"] as? Int == 0)
    // macOS has no PID namespaces: the harness ran only because its signal guard was installed (sim/ISOLATION.md).
    #expect(report["isolation"] as? String == "darwin-guarded", "\(pattern): \(log)")
}
