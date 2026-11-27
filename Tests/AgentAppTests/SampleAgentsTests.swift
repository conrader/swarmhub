import Foundation
import Testing
@testable import AgentApp

// P32 1: the sample agents' cards are the real draft and choices cards, so every control in them works.
@MainActor @Test func sampleAgentsUseTheRealCards() {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.loadSamples()
    let messages = store.bots.flatMap(\.messages)
    #expect(!messages.isEmpty && messages.allSatisfy { $0.presentation == .text }, "no fixed-presentation sample cards")
    let blocks = messages.flatMap { ChatCardParser.parse($0.content) }
    #expect(blocks.contains { if case .draft(let draft) = $0 { draft.to?.contains("maya@") == true && draft.subject?.contains(AppConstants.name) == true } else { false } })
    #expect(blocks.contains { if case .choices(let prompt, let options) = $0 { !prompt.isEmpty && options.count == 3 } else { false } })
}


@MainActor @Test func sampleHelpersBelongOnlyToTheLocalCoordinatorAndSurviveReopen() throws {
    let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
    let store = reopen()
    let servers = store.herdrServers
    store.loadSamples()
    let bot = try #require(store.bots.first(where: SampleWorkspace.isCoordinator))
    let root = try #require(store.sidebarRoots(for: bot).first)
    let sessions = store.sessionRows(under: root, for: bot)
    #expect(sessions.map(\.selection.helperID) == ["tests", "rename"])
    #expect(sessions.map(\.selection.native?.thread.provider) == [.claude, .codex])
    #expect(store.herdrServers == servers && !servers.contains(SampleWorkspace.server))
    let real = Bot(name: bot.name, backend: .herdr)
    store.bots.append(real)
    #expect(store.sidebarRoots(for: real).isEmpty && store.herdrServer(for: real) != SampleWorkspace.server)
    store.setSessionsExpanded(false, for: bot)
    store.stopSampleTests(of: bot)
    store.save()
    let restored = reopen()
    let same = try #require(restored.bots.first(where: { $0.id == bot.id }))
    #expect(!restored.sessionsExpanded(for: same))
    #expect(restored.herdrHelpers[same.id]?.claudeThreads?.first?.state == "stopped")
    restored.removeSampleBots()
    #expect(restored.herdrHelpers[same.id] == nil && restored.bots.contains { $0.id == real.id })
}

@MainActor @Test func sampleInspectorAndModelFollowOnlyTheSelectedExample() throws {
    let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
    let store = reopen()
    store.loadSamples()
    let patch = try #require(store.bots.first { $0.sampleRole == .patch })
    let scout = try #require(store.bots.first { $0.sampleRole == .scout })
    #expect(store.infoTabs(for: patch) == [.overview, .approvals, .routines, .media])
    #expect(patch.sampleModelLabel == "Codex · Sol")
    patch.sampleModel = "Gemini CLI · Beta"
    store.save()
    let restored = try #require(reopen().bots.first { $0.id == patch.id })
    #expect(restored.sampleModelLabel == "Gemini CLI · Beta" && store.sidebarProgram(for: restored) == "Gemini CLI")
    #expect(scout.sampleModelLabel == "Claude · Sonnet")
    restored.sampleModel = "Retired example"
    #expect(restored.sampleModelLabel == "Codex · Sol")
    restored.backend = .herdr
    #expect(restored.sampleProfile == nil && restored.sampleModelLabel == nil && store.infoTabs(for: restored) == AgentInfoTab.allCases)
}

@MainActor @Test func sampleInboxDecisionsAreScopedAndPersistWithChats() throws {
    for command in SampleReview.testCommand.choices {
        for proposal in SampleReview.paymentsBot.choices {
            let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
            func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
            let store = reopen()
            store.loadSamples()
            let patch = try #require(store.bots.first { $0.sampleRole == .patch })
            let jarvis = try #require(store.bots.first { $0.sampleRole == .jarvis })
            let count = patch.messages.count
            #expect(store.workspaceActivity(attentionOnly: true).count == 2)
            store.resolveSampleReview(.createBot, for: patch)
            #expect(patch.sampleDecision == nil)
            store.resolveSampleReview(command, for: patch)
            store.resolveSampleReview(proposal, for: jarvis)
            store.resolveSampleReview(command, for: patch)
            store.resolveSampleReview(proposal, for: jarvis)
            let restored = reopen()
            let same = try #require(restored.bots.first { $0.id == patch.id })
            #expect(same.sampleDecision == command && same.messages.count == count + 1)
            #expect(restored.workspaceActivity(attentionOnly: true).isEmpty)
            #expect(restored.bots.filter { $0.sampleRole == .payments }.count == (proposal == .createBot ? 1 : 0))
            #expect(store.herdrAgents.isEmpty && restored.herdrAgents.isEmpty)
        }
    }
}

@MainActor @Test func sampleWalkthroughsRestoreAndShareTheirDecisions() throws {
    let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
    let store = reopen()
    store.loadSamples()
    let patch = try #require(store.bots.first { $0.sampleRole == .patch })
    let scout = try #require(store.bots.first { $0.sampleRole == .scout })
    let opening = try #require(patch.messages.last)
    let recorded = try #require(opening.activity)
    #expect(ActivityCopy.summary(recorded, since: opening.createdAt) == "2 steps · 6 s")
    #expect(ActivityCopy.lastCommand(in: recorded) == "git log v0.8.15..HEAD --oneline")
    let start = try #require(patch.sampleWalkthrough)
    store.advanceSampleStory(in: patch, from: start)
    store.advanceSampleStory(in: patch, from: start)
    #expect(patch.messages.last?.authorID == scout.id)
    #expect(patch.messages.last?.activity?.steps.count == 3)
    let restored = reopen()
    let same = try #require(restored.bots.first { $0.id == patch.id })
    let second = try #require(same.sampleWalkthrough)
    #expect(second.step == .handoff && second.run == start.run)
    restored.advanceSampleStory(in: same, from: second)
    let row = try #require(same.messages.last)
    let blocks = ChatCardParser.parseVisibleReply(row.content)
    let index = try #require(blocks.firstIndex { if case .pageDraft = $0 { true } else { false } })
    let target = ConversationActionTarget.bot(botID: same.id)
    #expect(restored.performCardAction(target: target, sourceID: row.id, index: index, expected: blocks[index], pageDecision: .shorten))
    #expect(!restored.performCardAction(target: target, sourceID: row.id, index: index, expected: blocks[index], pageDecision: .approve))
    let short = try #require(same.messages.last)
    let revised = ChatCardParser.parseVisibleReply(short.content)
    #expect(restored.performCardAction(target: target, sourceID: short.id, index: index, expected: revised[index], pageDecision: .approve))
    let oldIDs = same.messages.map(\.id)
    restored.advanceSampleStory(in: same, from: try #require(same.sampleWalkthrough))
    #expect(same.messages.prefix(oldIDs.count).map(\.id) == oldIDs && same.sampleWalkthrough?.run != start.run)
    restored.resolveSampleReview(.decline, for: same)
    let writer = try #require(restored.bots.first { $0.id == scout.id })
    restored.advanceSampleStory(in: writer, from: try #require(writer.sampleWalkthrough))
    restored.advanceSampleStory(in: writer, from: try #require(writer.sampleWalkthrough))
    #expect(restored.sampleBriefs.first?.excerpt?.contains("1 pending item") == true)
    #expect(reopen().sampleBriefs.first?.revision == 1)
    #expect(restored.herdrAgents.isEmpty)
}

@MainActor @Test func sampleGoalTracksOnlyItsChatAcrossRelaunchAndStopsAtItsLimit() throws {
    let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
    let store = reopen()
    store.loadSamples()
    let patch = try #require(store.bots.first { $0.sampleRole == .patch })
    store.open(patch)
    #expect(store.handleGoalCommand(.start("Review PR #142", stepLimit: 3, budgetUSD: 0.25, perGoal: true), in: patch) == nil)
    let goalID = try #require(patch.goal?.id)
    #expect(patch.goal?.stepSpending?.chargedUSD == 0 && patch.goal?.state == .waiting)
    #expect(patch.sampleProfile?.contextPercent(in: patch) == 38)
    let first = try #require(patch.sampleWalkthrough)
    store.advanceSampleStory(in: patch, from: first)
    store.advanceSampleStory(in: patch, from: first)
    store.showSampleStory(.brief)
    #expect(store.selectedBot?.goal == nil && patch.goal?.iteration == 2)
    #expect(store.sidebarLayout.navigationOrder.map(\.id) == store.bots.map(\.id))
    let restored = reopen()
    let same = try #require(restored.bots.first { $0.id == patch.id })
    restored.open(same)
    #expect(same.goal?.id == goalID && same.goal?.objective == "Review PR #142")
    #expect(restored.handleGoalCommand(.status, in: same)?.contains("Steps: 2 of 3") == true)
    restored.advanceSampleStory(in: same, from: try #require(same.sampleWalkthrough))
    #expect(same.goal?.state == .stopped && same.goal?.detail.contains("Step 3 of 3") == true)
    #expect(restored.handleGoalCommand(.start("Again"), in: same) == nil)
    #expect(restored.handleGoalCommand(.stop, in: same) == nil)
    #expect(same.goal?.state == .stopped && restored.turns.scheduledGoals.isEmpty)
    let legal = try #require(restored.bots.first { $0.sampleRole == .legal })
    restored.open(legal)
    #expect(restored.handleGoalCommand(.start("Review contracts", budgetUSD: 0.05), in: legal) == nil)
    #expect(legal.goal?.state == .stopped && legal.goal?.iteration == 0 && legal.goal?.lastSpend?.usd == 0.06)
}

@Test func sampleScreenshotReplyMatchesTheBundledPixels() async throws {
    let sample = try #require(SampleScreenshot.dataURL)
    for (image, expected) in [(sample, "Keep editing"), ("data:image/png;base64,AAAA", "image is attached")] {
        let stream = try await MockBackend(sampleName: "Patch").send(.init(sessionID: "test", systemPrompt: "", messages: [], images: [image]))
        var text = ""
        for try await event in stream { if case .token(let word) = event { text += word } }
        #expect(text.contains(expected))
    }
}

@MainActor @Test func steeringSampleHelpersKeepsTheirSeparateInstructionsAfterReopening() throws {
    let file = temporaryStore(), defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    func reopen() -> AppStore { AppStore(storeURL: file, autoStart: false, keyStore: keys, defaults: defaults) }
    func sessions(_ store: AppStore, _ bot: Bot) throws -> [HerdrHelperSelection] {
        let root = try #require(store.sidebarRoots(for: bot).first)
        return store.sessionRows(under: root, for: bot, includingFolded: true).map(\.selection)
    }
    let store = reopen()
    store.loadSamples()
    let bot = try #require(store.bots.first(where: SampleWorkspace.isCoordinator))
    let targets = try sessions(store, bot)
    try #require(targets.count == 2)
    for target in targets {
        #expect(store.beginHelperSteering(target, of: bot))
        let draft = try #require(store.helperSteeringDrafts[bot.id])
        #expect(draft.text.isEmpty)
        draft.text = "Review " + target.helperID
    }
    for target in targets {
        #expect(store.beginHelperSteering(target, of: bot))
        let draft = try #require(store.helperSteeringDrafts[bot.id])
        #expect(draft.text == "Review " + target.helperID)
        #expect(store.submitHelperSteering(in: bot.id))
        let row = try #require(store.latestGuidance(for: target, of: bot))
        #expect(row.content == "Review " + target.helperID)
        #expect(row.modelText.contains("thread " + target.helperID + ", owner "))
    }
    store.stopSampleTests(of: bot)
    let restored = reopen()
    let jarvis = try #require(restored.bots.first(where: SampleWorkspace.isCoordinator))
    for target in try sessions(restored, jarvis) {
        #expect(restored.latestGuidance(for: target, of: jarvis)?.content == "Review " + target.helperID)
    }
}
