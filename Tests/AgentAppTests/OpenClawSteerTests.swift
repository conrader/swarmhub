import Foundation
import Testing
import SwarmHubCore
@testable import AgentApp

// P28 D3: OpenClaw's steer (`chat.send` with `queueMode:"steer"`) also lands only after the current tool batch (docs:
// concepts/queue-steering, "Runtime boundary"), so the same rule applies: a running step queues the steer, text only
// stops the run (`chat.abort`) and sends the correction as the next `chat.send`. Fake Gateway only.

/// A store whose OpenClaw bot answers `chat.send` with `run-1`, `run-2`, … and streams nothing by itself.
@MainActor private func steerableClaw() async throws -> (AppStore, Bot, FakeGateway, String) {
    let fake = FakeGateway()
    fake.handlers["sessions.create"] = echoCreate()
    let runs = LockedValue(0)
    fake.handlers["chat.send"] = { _, _ in
        let next = runs.current + 1; _ = runs.swap(next)
        return .success(["runId": .string("run-\(next)"), "status": "started"])
    }
    let (store, bot, _, _) = clawStore(fake)
    #expect(store.send(text: "count"))
    try await fake.requestLog.wait { $0.contains("chat.send") }
    try await waitUntil { bot.hermesSessionID != nil }
    let key = bot.hermesSessionID ?? ""
    fake.emit("chat", chatEvent("delta", seq: 1, session: key, ["message": assistant("1 2 ")]))
    try await waitUntil { (store.soleTurn?.steerAvailable == true) && store.soleTurn?.assistant?.content == "1 2 " }
    return (store, bot, fake, key)
}

@MainActor @Test func anOpenClawSteerDuringTextStopsTheRunAndSendsTheCorrection() async throws {
    let (store, bot, fake, key) = try await steerableClaw()
    #expect(store.send(text: "stop counting"))
    try await waitUntil { fake.requestsFor("chat.send").count == 2 }
    let log = fake.requestLog.all.filter { $0.hasPrefix("chat.") }
    #expect(log == ["chat.send", "chat.abort", "chat.send"], "the abort goes out before the correction")
    #expect(fake.requestsFor("chat.abort").first?["runId"] == "run-1")
    let correction = try #require(fake.requestsFor("chat.send").last)
    #expect(correction["queueMode"] == nil && correction["message"]?.string.map(BotSystemPrompt.stripEnvelope) == SteerCopy.lead + "\nstop counting" && correction["sessionKey"]?.string == key)
    #expect(bot.messages[1].content == "1 2 " && bot.messages[1].turnState == .stopped)
    #expect(bot.messages[2].isCorrection && bot.messages[2].content == "stop counting")
    store.stop(); try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func anOpenClawSteerDuringAToolStepIsQueued() async throws {
    let (store, bot, fake, _) = try await steerableClaw()
    fake.emit("agent", ["runId": "run-1", "seq": 2, "stream": "tool", "ts": 1, "data": ["phase": "start", "name": "exec", "toolCallId": "t1"]])
    try await waitUntil { store.soleTurn?.assistant?.activity?.current != nil }
    #expect(store.send(text: "shorter please"))
    try await waitUntil { fake.requestsFor("chat.send").count == 2 }
    let steer = try #require(fake.requestsFor("chat.send").last)
    #expect(steer["queueMode"] == "steer" && steer["message"] == "shorter please")
    #expect(fake.requestsFor("chat.abort").isEmpty)
    try await waitUntil { bot.messages.last?.metadata["steer"] == "queued" }
    store.stop(); try await waitUntil { !store.anyTurnRunning }
}
