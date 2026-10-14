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

@Test func incompleteCoverageNamesTheSeqItStoppedAt() {
    var row = GrokImportRunRow(sourceID: "a", name: "A", isGroup: false, status: .incomplete, coverage: .incomplete)
    row.stoppedAtSeq = 412
    let outcome = GrokImportOutcome(id: "a", name: "A", isGroup: false, archiveLines: 0, connection: .historyOnly, row: row)
    #expect(outcome.coverageText == "Incomplete: stopped at seq 412, nothing older was fetched")
}
