import AppKit
import Foundation
import Testing
@testable import AgentApp

// P39: one turn slot per conversation. Chats never block each other; Stop, steer, the composer and the next-message
// queue act on their own chat; at most 6 turns run app-wide (4 per connection). Scripted backends; no network.

private let skill = BundledSkill(name: "swarmhub-chat", version: SkillVersion("1.2.0")!,
                                 template: "---\nname: swarmhub-chat\ndescription: \"Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")

@MainActor struct ConcurrentTurnsTests {
    /// Bots with a scripted backend each; `boxes` puts bot i on connection `i % boxes`.
    func concurrentStore(_ names: [String], boxes: Int? = nil, url: URL = temporaryStore()) -> (AppStore, [Bot], [ScriptedTurnBackend]) {
        let bots = names.enumerated().map { index, name in
            let bot = Bot(name: name, backend: .hermes, hermesProfile: "default", hermesSessionID: "session-\(name.lowercased())")
            bot.hermesBaseURL = "http://box-\(index % (boxes ?? names.count)).test"; return bot
        }
        let backends = bots.map { _ in ScriptedTurnBackend() }
        let byID = Dictionary(uniqueKeysWithValues: zip(bots.map(\.id), backends))
        let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { bot in byID[bot.id]! },
                             keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
        store.bots = bots
        return (store, bots, backends)
    }

    /// Opens `bot`'s chat and sends `text` the way the composer does; waits until its backend has the turn.
    func send(_ text: String, to bot: Bot, in store: AppStore, _ backend: ScriptedTurnBackend) async throws {
        store.selectedGroup = nil; store.selectedBot = bot
        #expect(store.send(text: text))
        try await backend.calls.wait { $0.contains("send:\(text)") }
    }

    func reply(_ text: String, _ backend: ScriptedTurnBackend, stream: Int? = nil) async {
        await backend.emit(.token(text), .completed, stream: stream); await backend.end(stream: stream)
    }

    @Test func twoDirectChatsStreamAtOnceAndBothFinish() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        try await send("one", to: bots[0], in: store, backends[0])
        try await send("two", to: bots[1], in: store, backends[1])
        #expect(store.isStreaming(in: bots[0]) && store.isStreaming(in: bots[1]) && store.runningTurns.count == 2)
        #expect(store.isWorking(bots[0]) && store.isWorking(bots[1]), "the sidebar shows both bots working")
        await reply("Second.", backends[1])
        try await waitUntil { store.isIdle(bots[1]) }
        #expect(store.isStreaming(in: bots[0]), "the first chat still answers")
        await reply("First.", backends[0])
        try await waitUntil { !store.anyTurnRunning }
        for (bot, text) in zip(bots, ["First.", "Second."]) {
            let row = try #require(bot.messages.last)
            #expect(row.role == .assistant && row.content == text && row.turnState == .finished)
        }
    }

    @Test func stopInOneChatLeavesTheOtherStreaming() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        try await send("one", to: bots[0], in: store, backends[0])
        try await send("two", to: bots[1], in: store, backends[1])
        await backends[0].emit(.token("Partial "))
        try await waitUntil { bots[0].messages.last?.content == "Partial " }
        store.selectedBot = bots[0]
        store.stop()
        try await backends[0].calls.wait { $0.contains { $0.hasPrefix("stop:") } }
        try await waitUntil { store.isIdle(bots[0]) }
        #expect(bots[0].messages.contains { $0.turnState == .stopped && $0.content == "Partial " })
        #expect(store.isStreaming(in: bots[1]) && !backends[1].calls.all.contains { $0.hasPrefix("stop:") })
        await reply("Done.", backends[1])
        try await waitUntil { store.isIdle(bots[1]) }
        #expect(bots[1].messages.last?.turnState == .finished && bots[1].messages.last?.content == "Done.")
    }

    @Test func steerGoesToTheOpenChatsOwnTurn() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        for (index, bot) in bots.enumerated() {
            try await send("go \(index)", to: bot, in: store, backends[index])
            await backends[index].emit(.token("Before. "), step(.started))
        }
        try await waitUntil { bots.allSatisfy { store.canSteer(in: $0) && store.turn(in: $0)?.assistant?.activity?.current != nil } }
        store.selectedBot = bots[1]
        #expect(store.send(text: "check the logs"))
        try await backends[1].calls.wait { $0.contains("steer:check the logs") }
        #expect(!backends[0].calls.all.contains { $0.hasPrefix("steer:") })
        #expect(bots[1].messages.last?.isSteer == true && !bots[0].messages.contains(where: \.isSteer))
        store.stop(bots[0]); store.stop(bots[1])
        try await waitUntil { !store.anyTurnRunning }
    }

    @Test func managerInstallTurnRunsWhileAnotherBotIsSentToAndAnswers() async throws {
        let (store, bots, backends) = concurrentStore(["Jarvis", "Worker"], boxes: 1)
        let (manager, worker) = (bots[0], bots[1])
        manager.canManageBots = true; worker.hermesProfile = "worker"
        store.skillLibraryOverride = [skill]; store.managerTemplateOverride = "manager text"
        #expect(store.installSkills(for: worker))
        try await backends[0].calls.wait { $0.contains("send:Install SwarmHub’s instructions for Worker.") }
        #expect(store.isStreaming(in: manager) && !store.managerIdle(for: worker))
        try await send("hello", to: worker, in: store, backends[1])
        await reply("Hi.", backends[1])
        try await waitUntil { store.isIdle(worker) }
        #expect(worker.messages.last?.content == "Hi." && store.isStreaming(in: manager), "the install turn is still running")
        await reply("Installed.", backends[0])
        try await waitUntil { !store.anyTurnRunning }
        #expect(manager.messages.last(where: { $0.role == .assistant })?.content == "Installed.")
    }

    @Test func allBotsInstallResumesAfterAQueuedManagerMessage() async throws {
        let (store, bots, backends) = concurrentStore(["Jarvis", "First", "Second", "Third"], boxes: 1)
        let manager = bots[0], backend = backends[0], targets = Array(bots.dropFirst())
        let feedback = BundledSkill(name: "swarmhub-feedback", version: SkillVersion("1.0.0")!,
            template: "---\nname: swarmhub-feedback\nversion: 1.0.0\n---\nFeedback.\n")
        manager.canManageBots = true; manager.installedSkills[feedback.name] = "1.0.0"
        for bot in targets { bot.hermesProfile = bot.name.lowercased() }
        store.skillLibraryOverride = [feedback]; store.managerTemplateOverride = "manager text"
        store.boxInstallTransport.boxes = [:]
        // One bot per turn, so the queued message lands between installs (batches are AllBotsSkillTests' subject).
        store.allBotsBatchLimit = 1
        #expect(store.installSkillsOnAllBots(manager: manager))
        try await backend.calls.wait { $0.contains("send:\(AllBotsSkillCopy.request(1))") }

        let bubble = ChatMessage(role: .user, content: "How is the install going?", metadata: [SteerKey.steer: "failed"])
        manager.messages.append(bubble)
        #expect(store.sendAsNextMessage(bubble))
        #expect(store.turns.nextMessages.count == 1)

        func installed(_ bot: Bot) -> String {
            "Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"\(bot.hermesProfile!)\",\"skills\":[{\"name\":\"swarmhub-feedback\",\"version\":\"1.0.0\"}]}\n```"
        }
        await reply(installed(targets[0]), backend)
        try await backend.calls.wait { $0.contains("send:How is the install going?") }
        #expect(store.allBotsSkillQueue[manager.id]?.map(\.bot.id) == targets.dropFirst().map(\.id))
        #expect(targets.dropFirst().allSatisfy { store.skillInstallResults[$0.id] == nil && $0.skillInstallFailures.isEmpty })
        #expect(store.pendingSkillChecks[manager.id] == nil && store.pendingSkillInstalls[manager.id] == nil)

        await reply("One bot installed; two to go.", backend)
        try await backend.calls.wait { $0.filter { $0 == "send:\(AllBotsSkillCopy.request(1))" }.count == 2 }
        await reply(installed(targets[1]), backend)
        try await backend.calls.wait { $0.filter { $0 == "send:\(AllBotsSkillCopy.request(1))" }.count == 3 }
        await reply(installed(targets[2]), backend)
        try await waitUntil { !store.anyTurnRunning && store.allBotsSkillQueue.isEmpty }
        #expect(targets.allSatisfy { $0.installedSkills[feedback.name] == "1.0.0" && $0.skillInstallFailures.isEmpty && store.skillInstallResults[$0.id]?.status == .installed })
        #expect(manager.messages.filter { $0.metadata["skill-install-result"] != nil }.count == 3)
        #expect(backend.calls.all.filter { $0.hasPrefix("send:") } == ["send:\(AllBotsSkillCopy.request(1))", "send:How is the install going?", "send:\(AllBotsSkillCopy.request(1))", "send:\(AllBotsSkillCopy.request(1))"])
        #expect(bubble.metadata[SteerKey.steer] == "sentNext" && store.turns.nextMessages.isEmpty)
    }

    @Test func aGroupTurnAndADirectChatToAMemberRunAtOnce() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        let group = try #require(store.createGroup(name: "Team", memberIDs: bots.map(\.id)))
        #expect(store.send(text: "@Alpha group question", to: group))
        try await backends[0].calls.wait { $0.contains { $0.hasPrefix("send:") && $0.contains("group question") } }
        #expect(store.isWorking(bots[0], in: group))
        try await send("direct question", to: bots[0], in: store, backends[0])
        #expect(store.isStreaming(in: group) && store.isStreaming(in: bots[0]))
        #expect(store.send(text: "@Alpha again", to: group) && group.messages.contains { $0.content == "@Alpha again" && $0.isSteer }, "the group's own turn is steered, never stopped")
        await reply("Direct answer.", backends[0], stream: 2)
        try await waitUntil { store.isIdle(bots[0]) }
        #expect(bots[0].messages.last?.content == "Direct answer." && store.isStreaming(in: group))
        await reply("Group answer.", backends[0], stream: 1)
        try await waitUntil { store.isIdle(group) }
        #expect(group.messages.contains { $0.authorID == bots[0].id && $0.content == "Group answer." && $0.turnState == .finished })
    }

    @Test func theNextMessageQueueDrainsPerChat() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        try await send("one", to: bots[0], in: store, backends[0])
        try await send("two", to: bots[1], in: store, backends[1])
        let bubbles = bots.map { bot in ChatMessage(role: .user, content: "after \(bot.name)", metadata: [SteerKey.steer: "failed"]) }
        for (bot, bubble) in zip(bots, bubbles) { bot.messages.append(bubble); #expect(store.sendAsNextMessage(bubble)) }
        #expect(store.turns.nextMessages.count == 2)
        await reply("Beta done.", backends[1])
        try await backends[1].calls.wait { $0.contains("send:after Beta") }
        #expect(!backends[0].calls.all.contains("send:after Alpha"), "Alpha's message waits for Alpha's turn only")
        #expect(store.turns.nextMessages.map(\.bubble.content) == (["after Alpha"] as [String]))
        await reply("Alpha done.", backends[0])
        try await backends[0].calls.wait { $0.contains("send:after Alpha") }
        await reply("A2.", backends[0]); await reply("B2.", backends[1])
        try await waitUntil { !store.anyTurnRunning && store.turns.nextMessages.isEmpty }
        #expect(bubbles.allSatisfy { $0.metadata[SteerKey.steer] == "sentNext" })
    }

    @Test func aRestartWithTwoTurnsInFlightRecoversBoth() async throws {
        let url = temporaryStore()
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"], url: url)
        for (index, bot) in bots.enumerated() {
            try await send("go \(index)", to: bot, in: store, backends[index])
            await backends[index].emit(.token("Part \(index) "))
            let bubble = ChatMessage(role: .user, content: "queued \(index)", metadata: [SteerKey.steer: "failed"])
            try await waitUntil { bot.messages.last?.content == "Part \(index) " }
            bot.messages.append(bubble); #expect(store.sendAsNextMessage(bubble))
        }
        store.save()
        // The app quits with both turns in flight; the reopened store sees two cut replies and two queued messages.
        let fresh = [ScriptedTurnBackend(), ScriptedTurnBackend()]
        let ids = bots.map(\.id)
        let reopened = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { bot in fresh[ids.firstIndex(of: bot.id)!] },
                                keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
        let restored = ids.map { id in reopened.bots.first { $0.id == id }! }
        for (index, bot) in restored.enumerated() {
            #expect(bot.messages.contains { $0.role == .assistant && $0.turnState == .incomplete && $0.content == "Part \(index) " })
        }
        #expect(reopened.turns.nextMessages.map(\.bubble.content).sorted() == (["queued 0", "queued 1"] as [String]))
        // The launch reconcile confirmed both cut replies; both chats' messages then go at once.
        for bot in restored { bot.messages.first { $0.role == .assistant }?.turnState = .finished }
        reopened.resumeRestoredNextMessages()
        for (index, backend) in fresh.enumerated() { try await backend.calls.wait { $0.contains("send:queued \(index)") } }
        #expect(reopened.runningTurns.count == 2)
        for backend in fresh { await reply("ok", backend) }
        try await waitUntil { !reopened.anyTurnRunning }
        // The quit store's own queue went with it; its held streams only need closing.
        store.turns.nextMessages = []
        for backend in backends { await backend.end() }
        try await waitUntil { !store.anyTurnRunning }
    }

    @Test func theSeventhTurnWaitsWithOneLineAndGoesWhenATurnEnds() async throws {
        let (store, bots, backends) = concurrentStore((1...7).map { "Bot\($0)" }, boxes: 3)
        for index in 0..<6 { try await send("q\(index)", to: bots[index], in: store, backends[index]) }
        store.selectedBot = bots[6]
        #expect(store.send(text: "q6"))
        #expect(store.runningTurns.count == 6 && store.isIdle(bots[6]))
        let line = try #require(bots[6].messages.last)
        #expect(line.role == .system && line.content == "Waiting: 6 replies are already running.")
        #expect(store.turns.nextMessages.map(\.kind) == ([.turn] as [NextMessageRecord.Kind]) && backends[6].calls.all.isEmpty)
        await reply("done", backends[0])
        try await backends[6].calls.wait { $0.contains("send:q6") }
        #expect(!bots[6].messages.contains { $0.content.hasPrefix("Waiting:") }, "the line goes when the turn starts")
        #expect(bots[6].messages.filter { $0.role == .user }.map(\.content) == (["q6"] as [String]), "the waiting message itself is answered")
        for index in 1..<7 { await reply("done", backends[index]) }
        try await waitUntil { !store.anyTurnRunning }
    }

    @Test func oneConnectionTakesAtMostFourTurns() async throws {
        let (store, bots, backends) = concurrentStore((1...5).map { "Box\($0)" }, boxes: 1)
        for index in 0..<4 { try await send("q\(index)", to: bots[index], in: store, backends[index]) }
        store.selectedBot = bots[4]
        #expect(store.send(text: "q4"))
        #expect(bots[4].messages.last?.content == "Waiting: 4 replies are already running on this connection.")
        await reply("done", backends[2])
        try await backends[4].calls.wait { $0.contains("send:q4") }
        for index in [0, 1, 3, 4] { await reply("done", backends[index]) }
        try await waitUntil { !store.anyTurnRunning }
    }

    @Test func eachComposerReflectsOnlyItsOwnChat() async throws {
        let (store, bots, backends) = concurrentStore(["Alpha", "Beta"])
        try await send("one", to: bots[0], in: store, backends[0])
        await backends[0].emit(.token("Before. "))
        try await waitUntil { store.canSteer(in: bots[0]) }
        #expect(store.isStreaming(in: bots[0]) && !store.isStreaming(in: bots[1]) && !store.canSteer(in: bots[1]))
        store.selectedBot = bots[1]
        #expect(!AppCommand.stopResponse.isEnabled(in: store), "Stop is off in the idle chat")
        #expect(store.send(text: "two"), "the idle chat sends instead of steering the other")
        try await backends[1].calls.wait { $0.contains("send:two") }
        #expect(!backends[0].calls.all.contains { $0.hasPrefix("steer:") })
        store.selectedBot = bots[0]
        #expect(AppCommand.stopResponse.isEnabled(in: store))
        await reply("A.", backends[0]); await reply("B.", backends[1])
        try await waitUntil { !store.anyTurnRunning }
    }
}

@MainActor @Test func p39ShotsRenderFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppP39-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "p39", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessP39Shots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP39Shots.names.count, "only the P39 shots")
}
