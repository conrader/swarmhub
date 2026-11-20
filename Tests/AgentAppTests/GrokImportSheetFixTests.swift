import Foundation
import Testing
@testable import AgentApp

// P10d review fixes: Cancel from a pause, the app-wide Keychain flag without a ticker, member/group ticking, the
// Done step's "Retry remaining" and the incomplete coverage line. Fakes only, as in GrokImportSheetTests.

@MainActor @Test func cancellingAPauseShowsWhatWasCommitted() async throws {
    let world = try GrokWorld(history: [GrokRunIDs.jarvis: 30, GrokRunIDs.finance: 25, GrokRunIDs.plain: 3, GrokRunIDs.group: 4])
    world.fake.pageCap = 10
    world.fake.intercept = { index, _ in index >= 5 ? .fail(.timedOut) : nil }
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    guard case .paused(.network) = coordinator.step else { Issue.record("expected a network pause, got \(coordinator.step)"); return }
    coordinator.cancel()
    await coordinator.settled()
    #expect(coordinator.step == .cancelled)
    #expect(coordinator.outcomes.map(\.id) == [GrokRunIDs.jarvis] && coordinator.outcomes.first?.archiveLines == 27)
    #expect(await coordinator.run?.holder.lifetime == GrokSecretLifetime.none)
    // "Retry remaining" covers the paused conversation and the ones never reached, and asks before macOS does.
    #expect(coordinator.unfinishedIDs == [GrokRunIDs.finance, GrokRunIDs.plain, GrokRunIDs.group])
    world.fake.intercept = nil
    await coordinator.retryUnfinished()
    #expect(coordinator.step == .permission && world.passwords.reads == 1)
    coordinator.continueToMacOS()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 2)
    #expect(Set(coordinator.outcomes.map(\.id)) == [GrokRunIDs.jarvis, GrokRunIDs.finance, GrokRunIDs.plain, GrokRunIDs.group])
    #expect(coordinator.unfinishedIDs.isEmpty)
}

@MainActor @Test func continueStaysOffUntilAStaleReadReturnsWithoutATicker() async throws {
    let world = try GrokWorld()
    let answer = DispatchSemaphore(value: 0)
    world.passwords.hold = answer
    let store = world.store()
    let first = makeCoordinator(world, store)
    await first.scan()
    await first.proceed()
    first.continueToMacOS()
    try await grokWait { world.gate.isReading }
    await first.dismiss()
    let second = makeCoordinator(world, store)
    await second.scan()
    await second.proceed()
    #expect(second.step == .permission && second.keychainBusy)
    answer.signal()
    try await grokWait { !second.keychainBusy }
    #expect(world.passwords.reads == 1)
}

@MainActor @Test func untickingAMemberUnticksItsGroup() async throws {
    let world = try GrokWorld()
    let coordinator = makeCoordinator(world, world.store())
    await coordinator.scan()
    coordinator.toggle(GrokRunIDs.jarvis)
    #expect(!coordinator.selected.contains(GrokRunIDs.jarvis) && !coordinator.selected.contains(GrokRunIDs.group))
    #expect(coordinator.selected == [GrokRunIDs.finance, GrokRunIDs.plain])
}


@MainActor @Test func exportReviewUsesTheTestedPlanAndRetrySeparatesSkippedFromImported() async throws {
    let world = try GrokWorld()
    let store = world.store()
    let host = HerdrServer(id: "studio", name: "Studio", kind: .address, address: "http://127.0.0.1:8788")
    store.saveHerdrServers([host])
    let offer = HerdrOffer(programs: [.init(template: "claude", name: "Claude Code", takesModel: false, models: [])],
        workspaceRoot: "/private/workspaces")
    let coordinator = GrokImportCoordinator(store: store, environment: world.environment(),
        destination: .init(serverID: host.id, offer: offer, testedHost: host), requiresTestedHost: true)
    let bundles = try GrokBundleLoader.load(from: grokGoldenExport).filter { $0.isGroup != true }
    let chosen = try #require(bundles.first)
    coordinator.useExportBundles([chosen])
    let item = try #require(coordinator.items.first)
    #expect(coordinator.destination(for: item).contains("New bot"))
    #expect(coordinator.destination(for: item).contains("Studio") && coordinator.destination(for: item).contains("Claude Code"))
    let id = try #require(coordinator.destinationPlan?.newBotIDs[item.id])
    try GrokHistoryStore.prepareDirectory(store.grokHistory.directory)
    try Data("invalid archive".utf8).write(to: store.grokHistory.fileURL(for: id))

    await coordinator.proceed()
    await coordinator.settled()
    #expect(coordinator.outcomeHeadline == "0 imported · 0 partial · 1 skipped")
    #expect(coordinator.botOutcomes.isEmpty && coordinator.unfinishedIDs == [chosen.sourceId])
    await coordinator.retryUnfinished()
    await coordinator.settled()
    #expect(coordinator.outcomeHeadline == "1 imported · 0 partial · 0 skipped")
    let imported = try #require(store.bots.first { $0.id == id })
    let done = try #require(coordinator.outcomes.first.flatMap(coordinator.savedDestination(for:)))
    #expect(done.location.contains("Created bot") && done.location.contains("Studio"))
    #expect(done.workspace == "/private/workspaces/" + id.uuidString.lowercased())
    #expect(store.herdrServer(for: imported) == host && store.herdrTemplate(for: imported) == "claude")
    imported.name = "Local name"
    imported.persona = "Local instructions"
    coordinator.useExportBundles([chosen])
    #expect(coordinator.destination(for: item).contains("Update history"))
    await coordinator.proceed()
    await coordinator.settled()
    #expect(imported.name == "Local name" && imported.persona == "Local instructions")
}
