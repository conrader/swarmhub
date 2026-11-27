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
