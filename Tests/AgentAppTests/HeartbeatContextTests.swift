import Foundation
import Testing
@testable import AgentApp

// P56: every Hermes turn says which routine is the bot's heartbeat (or that there is none). Synthetic boxes only.

private func instructions(_ state: SessionServer.State) -> [String] { state.chatPosts.map { $0.body?["instructions"] as? String ?? "" } }
private func inputs(_ state: SessionServer.State) -> [String] { state.chatPosts.map { $0.body?["input"] as? String ?? "" } }

@MainActor @Test func theTurnSaysThereIsNoHeartbeatOnlyOnceTheRoutinesWereRead() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0]
    #expect(store.heartbeatContextLine(for: bot) == nil, "routines never read: unknown, not none")
    #expect(store.withHeartbeatContext(bot.persona, bot: bot) == bot.persona)
    await store.refreshRoutines(for: bot)
    let none = "No heartbeat is set; \(store.userName) can turn one on in SwarmHub."
    #expect(store.heartbeatContextLine(for: bot) == none)
    store.selectedBot = bot
    #expect(store.send(text: "do you have a heartbeat?"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(instructions(states[0]).last?.hasSuffix("\n\n" + none) == true, "with the other SwarmHub instructions")
    #expect(inputs(states[0]).last?.contains("heartbeat is set") == false, "never in the user's text")
}

@MainActor @Test func theTurnNamesAnAdoptedRoutineAndThenSwarmHubsPlan() async throws {
    let (store, bots, states, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], table = tables[0]
    var own = jobPayload(id: "00000000beef", name: "jarvis-hourly-heartbeat-cet", schedule: "0 7-22 * * *", prompt: "Check in")
    own["deliver"] = "bot-chat:grok-jarvis"; own["next_run_at"] = "2026-10-15T09:00:00+00:00"
    table.add(own)
    await store.refreshRoutines(for: bot)
    let user = store.userName, tail = "\(user) changes it in SwarmHub (Settings → Heartbeat, or /heartbeat every …)."
    #expect(store.heartbeatContextLine(for: bot) == "Your heartbeat: routine jarvis-hourly-heartbeat-cet, 0 7-22 * * *, next 11:00 (Europe/Warsaw). " + tail)
    await store.heartbeatCommand("every 1h 08:00-23:00", bot: bot, conversation: bot).value
    let line = "Your heartbeat: routine jarvis-hourly-heartbeat-cet, hourly 08–23, next 11:00 (Europe/Warsaw). " + tail
    #expect(store.heartbeatContextLine(for: bot) == line)
    store.selectedBot = bot
    #expect(store.send(text: "when do you wake up?"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(instructions(states[0]).last?.hasSuffix("\n\n" + line) == true && inputs(states[0]).last == "when do you wake up?")
    await store.heartbeatCommand("pause", bot: bot, conversation: bot).value
    #expect(store.heartbeatContextLine(for: bot) == "Your heartbeat: routine jarvis-hourly-heartbeat-cet, hourly 08–23, paused. " + tail)
}
