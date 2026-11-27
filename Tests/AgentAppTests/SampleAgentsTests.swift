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
