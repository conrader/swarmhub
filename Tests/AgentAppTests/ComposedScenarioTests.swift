import Foundation
import Testing
@testable import AgentApp

// backlog6 (backlog1 rank 5): the steer, context-overflow, turn-limit and internal setup-session paths composed in one
// store. `AutoContextTests`, `ChatParityTests`, `SteerUnreadTests` and the team recovery tests cover each path alone;
// these hold an install turn in its retry wait (`RetryGate`) while the user types, steers another bot or hits the turn
// limit, then check that nothing crossed into the manager's main session and that no modal alert opened.
// Stub backends only (`ComposedBox`, `ScriptedTurnBackend`); unique fixture names; the store folder is removed after.

@MainActor @Suite(.serialized) struct ComposedScenarioTests {

    /// Install → 503 → (user types in the manager's chat while the retry waits) → install lands in a fresh setup session
    /// → the typed message goes to the main session, overflows twice, continues in a new session and is answered.
    @Test func aMessageTypedDuringAnInstallRetryWaitsThenRecoversFromOverflowInTheMainChat() async throws {
        let world = ComposedWorld(install: [.status(503), .installed], chat: [.overflow(composedOverflowCopy), .overflow(composedOverflowCopy), .reply("Here is your week.")])
        defer { world.tearDown() }
        let (store, manager, box) = (world.store, world.manager, world.box)
        #expect(store.installSkills(for: manager))
        try await world.waitForRetry(1)
        #expect(store.turn(in: manager) != nil, "the install turn holds the manager's chat while it waits to retry")

        // The user types in the manager's chat: an install turn is never steered, the text waits as the next message.
        #expect(world.type("Summarise my week", in: manager))
        let typed = try #require(manager.messages.last { $0.role == .user && $0.content == "Summarise my week" })
        #expect(typed.metadata[TurnWaitCopy.key] == "waiting" && typed.metadata[ContextKey.setup] == nil)
        #expect(box.steerRequests == 0)
        await world.gate.release()

        try await waitUntil { !store.anyTurnRunning && manager.messages.last { $0.role == .assistant }?.content == "Here is your week." }
        let sent = box.streams
        let setup = sent.filter { $0.session.contains("agentapp_setup_") }
        let chat = sent.filter { !$0.session.contains("agentapp_setup_") }
        // The install went only to throwaway sessions, one per attempt, and each was deleted.
        #expect(setup.count == 2 && Set(setup.map(\.session)).count == 2)
        #expect(setup.allSatisfy { !$0.input.contains("Summarise my week") })
        #expect(Set(box.createdSetupSessions) == Set(setup.map(\.session)) && Set(setup.map(\.session)).isSubset(of: box.deletedSessions))
        // The user's text went to the main session (twice: compaction), then to a new chat session, never a setup one.
        #expect(chat.map(\.input) == ["Summarise my week", "Summarise my week", "Summarise my week"])
        #expect(chat.prefix(2).map(\.session) == [world.mainSession, world.mainSession])
        let continued = try #require(chat.last?.session)
        #expect(continued != world.mainSession && !continued.contains("agentapp_setup_") && manager.hermesSessionID == continued)
        #expect(!box.deletedSessions.contains(world.mainSession) && !box.deletedSessions.contains(continued))
        // The install's result was recorded; its rows stay out of the manager's conversation.
        #expect(manager.installedSkills["swarmhub-manager"] == "1.2.0")
        #expect(world.managerHistory().allSatisfy { !$0.content.contains("Install SwarmHub") && !$0.content.contains("Installed.") })
        #expect(manager.messages.filter { $0.role == .user }.map(\.content) == ["Install SwarmHub’s instructions for \(manager.name).", "Summarise my week"])
        #expect(manager.messages.contains { $0.content == TurnErrorCopy.newSession && $0.metadata[ContextKey.boundary] == "1" })
        #expect(world.noSlashAdvice(manager) && world.noPopup(), "no slash advice, no alert")
        #expect(box.steerRequests == 0)
    }

    /// Two jobs at once: a worker's turn runs a step on its own connection while the manager's install waits to retry.
    /// The user steers the worker and types in the manager's chat; each lands only where it was typed.
    @Test func concurrentJobsKeepTheirSteersAndQueuedMessagesApart() async throws {
        let world = ComposedWorld(install: [.status(503), .installed], chat: [.reply("Disk is fine.")])
        defer { world.tearDown() }
        let (store, manager, worker, box, scripted) = (world.store, world.manager, world.other, world.box, world.worker)

        world.store.selectedBot = worker
        try await startSteerableTurn(store, scripted, "go", running: true)
        #expect(store.installSkills(for: manager))
        try await world.waitForRetry(1)
        #expect(store.runningTurns.count == 2, "both jobs run at once")

        // Steer the worker's running step: it goes to the worker's session through its own backend.
        #expect(world.type("use metric", in: worker))
        try await waitUntil { worker.messages.last { $0.content == "use metric" }?.metadata[SteerKey.steer] == "queued" }
        // Type in the manager's chat: queued behind the install, never a steer of the setup session.
        #expect(world.type("check disk", in: manager))
        #expect(manager.messages.last { $0.content == "check disk" }?.metadata[TurnWaitCopy.key] == "waiting")

        // The worker's answer ends before it read the steer: the steer goes as its next message.
        await scripted.emit(.steer(.accepted), .token("Done."), .completed); await scripted.end()
        let followUp = "send:\(SteerCopy.lead)\nuse metric"
        try await scripted.calls.wait { $0.contains(followUp) }
        await scripted.emit(.token("Metric it is."), .completed); await scripted.end()

        await world.gate.release()
        try await waitUntil { !store.anyTurnRunning && manager.messages.last { $0.role == .assistant }?.content == "Disk is fine." }

        #expect(await scripted.calls.all == ["send:go", "steer:use metric", followUp])
        #expect(worker.hermesSessionID == world.workerSession && manager.hermesSessionID == world.mainSession)
        #expect(!worker.messages.contains { $0.metadata[ContextKey.setup] != nil || $0.content.contains("check disk") || $0.content.contains("Install") })
        #expect(!manager.messages.contains { $0.content.contains("use metric") || $0.content.contains("Metric it is.") })
        #expect(!box.wire.contains("use metric") && !box.wire.contains(SteerCopy.lead) && box.steerRequests == 0)
        let chat = box.streams.filter { !$0.session.contains("agentapp_setup_") }
        #expect(chat.map(\.session) == [world.mainSession] && chat.map(\.input) == ["check disk"])
        #expect(manager.installedSkills["swarmhub-manager"] == "1.2.0")
        #expect(Set(box.createdSetupSessions).isSubset(of: box.deletedSessions) && box.createdSetupSessions.count == 2)
        #expect(world.managerHistory().map(\.content) == ["check disk", "Disk is fine."])
        #expect(world.noPopup())
    }

    /// The app-wide turn limit is full (the worker runs): the install waits as the manager's next message, the user's
    /// message waits behind it. When the worker ends, the install runs (retrying once) in setup sessions, then the
    /// user's message goes to the main session. Neither crosses into the other's session.
    @Test func anInstallWaitingForAFreeTurnStillRunsInASetupSessionAheadOfTheUsersMessage() async throws {
        let world = ComposedWorld(install: [.status(503), .installed], chat: [.reply("Hello back.")])
        defer { world.tearDown() }
        let (store, manager, worker, box, scripted) = (world.store, world.manager, world.other, world.box, world.worker)
        store.turnLimits = TurnLimits(total: 1, perConnection: 4)

        world.store.selectedBot = worker
        try await startSteerableTurn(store, scripted, "go", running: false)
        #expect(store.installSkills(for: manager), "accepted: it waits for a free turn")
        let install = try #require(manager.messages.last { $0.role == .user })
        #expect(install.metadata[TurnWaitCopy.key] == "waiting" && box.streams.isEmpty)
        #expect(world.type("hello", in: manager))
        #expect(manager.messages.last { $0.role == .user }?.metadata[TurnWaitCopy.key] == "waiting")

        await scripted.emit(.token("Done."), .completed); await scripted.end()
        try await world.waitForRetry(1)
        #expect(box.streams.count == 1 && box.streams[0].session.contains("agentapp_setup_"), "the install went first, alone")
        await world.gate.release()
        try await waitUntil { !store.anyTurnRunning && manager.messages.last { $0.role == .assistant }?.content == "Hello back." }

        let sent = box.streams
        #expect(sent.count == 3)
        #expect(sent.prefix(2).allSatisfy { $0.session.contains("agentapp_setup_") && !$0.input.contains("hello") })
        #expect(sent.last?.session == world.mainSession && sent.last?.input == "hello")
        #expect(manager.installedSkills["swarmhub-manager"] == "1.2.0" && manager.hermesSessionID == world.mainSession)
        #expect(install.metadata[ContextKey.setup] == "1" && install.metadata[TurnWaitCopy.key] == nil)
        #expect(!manager.messages.contains { $0.metadata[TurnWaitCopy.key] == "line" }, "the waiting lines are gone")
        #expect(world.managerHistory().map(\.content) == ["hello", "Hello back."])
        #expect(Set(box.createdSetupSessions).isSubset(of: box.deletedSessions))
        #expect(world.noPopup())
    }

    /// Every install attempt fails while the user's message waits: the install ends as a line (no alert), its setup
    /// sessions are deleted, and the waiting message still goes to the main session, not as an install.
    @Test func aFailedInstallLeavesTheWaitingMessageForTheMainSessionAndNoAlert() async throws {
        let world = ComposedWorld(install: [.status(503), .status(503), .status(503)], chat: [.reply("Still here.")])
        defer { world.tearDown() }
        let (store, manager, box) = (world.store, world.manager, world.box)

        #expect(store.installSkills(for: manager))
        try await world.waitForRetry(1)
        #expect(world.type("are you there?", in: manager))
        await world.gate.release()
        try await waitUntil { !store.anyTurnRunning && manager.messages.last { $0.role == .assistant }?.content == "Still here." }

        let sent = box.streams
        #expect(sent.count == 4 && sent.prefix(3).allSatisfy { $0.session.contains("agentapp_setup_") })
        #expect(sent.last?.session == world.mainSession && sent.last?.input == "are you there?")
        #expect(Set(box.createdSetupSessions).count == 3 && Set(box.createdSetupSessions).isSubset(of: box.deletedSessions))
        let installRow = try #require(manager.messages.first { $0.role == .assistant })
        #expect(installRow.metadata[ContextKey.setup] == "1" && installRow.turnState == .notSent && store.canRetry(installRow))
        #expect(manager.installedSkills["swarmhub-manager"] == nil && manager.hermesSessionID == world.mainSession)
        #expect(world.managerHistory().map(\.content) == ["are you there?", "Still here."])
        #expect(!manager.messages.contains { $0.content.contains("Service unavailable") })
        #expect(world.noPopup(), "an install failure is never the alert")
    }
}
