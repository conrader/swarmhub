import Foundation
import Security
import Testing
@testable import AgentApp

// P10c: the pipeline the command and the sheet share, over a fake password provider and FakeGrok (briefs/P10.md P10c 4).

@MainActor private func makeRun(_ world: GrokWorld, _ store: AppStore, mode: GrokImportMode = .full,
                                selection: [String]? = nil) -> GrokImportRun {
    GrokImportRun(store: store, environment: world.environment(), options: GrokImportOptions(mode: mode, selection: selection))
}

@MainActor private func archive(_ store: AppStore, _ id: String) -> Int { store.grokArchiveLines(sourceID: id) }

@MainActor @Test func fullRunReadsTheKeychainOnceOnlyAfterStartAndImportsEveryConversation() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "https://box.test/v1")
    let run = makeRun(world, store)
    #expect(await run.willAskMacOS())
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty && run.state == .idle)
    var events: [String] = []
    run.onEvent = { event in
        if case .keychainReadComing = event { events.append("keychain") }
        if case .committed = event { events.append("commit") }
    }
    #expect(await run.start() == .finished)
    #expect(world.passwords.reads == 1 && run.keychainReads == 1)
    #expect(events.first == "keychain" && events.filter { $0 == "commit" }.count == 4)
    // Bots first in roster order, the group last; every one reached seq 1.
    #expect(run.rows.map(\.sourceID) == [GrokRunIDs.jarvis, GrokRunIDs.finance, GrokRunIDs.plain, GrokRunIDs.group])
    #expect(run.rows.allSatisfy { $0.status == .done && $0.coverage == .complete })
    // Archive lines are messages plus rename events; Jarvis's cache also holds entries that are not imported.
    #expect(run.rows.map(\.archiveLines) == [27, 5, 3, 4] && run.rows.map(\.cachedEntries) == [12, 2, 0, 3])
    // The canary (limit 1, newest) comes first, then one page per conversation; only the list RPC was used.
    let lists = grokListRequests(world.fake)
    #expect(lists.first?.agent == GrokRunIDs.jarvis && lists.first?.limit == 1 && lists.first?.before == nil)
    #expect(lists.count == 5 && world.fake.requests.count == 5)
    #expect(await run.requestCount() == 5)
    #expect(await run.holder.lifetime == .none)
    let jarvis = try #require(store.bots.first { $0.grokSourceID == GrokRunIDs.jarvis })
    #expect(jarvis.hermesBaseURL == "https://box.test/v1" && jarvis.hermesProfile == "grok-jarvis")
}

@MainActor @Test func recentModeNeedsNoPromptAndNoNetwork() async throws {
    let world = try GrokWorld()
    let store = world.store()
    let run = makeRun(world, store, mode: .recent)
    #expect(await !run.willAskMacOS())
    #expect(await run.start() == .finished)
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty)
    #expect(run.rows.allSatisfy { $0.coverage == .cacheOnly && $0.status == .done })
    #expect(run.rows.map(\.archiveLines) == [9, 2, 0, 3] && archive(store, GrokRunIDs.jarvis) == 9)
}

@MainActor @Test func aNetworkPauseResumesFromTheCursorWithoutASecondRead() async throws {
    let world = try GrokWorld()
    world.fake.pageCap = 10
    let outage = GrokSwitch()
    outage.isOn = true
    // Request 0 is the canary, 1–3 Jarvis's three pages: the outage starts at Jarvis's third page.
    world.fake.intercept = { index, _ in outage.isOn && index >= 3 ? .fail(.networkConnectionLost) : nil }
    let store = world.store()
    let run = makeRun(world, store)
    guard case .paused(.network(let error)) = await run.start() else { Issue.record("expected a network pause"); return }
    #expect(error.reason == .network)
    #expect(await run.holder.lifetime == GrokSecretLifetime(derivedKey: false, credentials: true))
    #expect(store.bots.first { $0.grokSourceID == GrokRunIDs.jarvis } == nil)
    outage.isOn = false
    #expect(await run.retryRemaining() == .finished)
    #expect(world.passwords.reads == 1)
    // The retry asked for the page below the last complete one (seq 11), not the newest page again.
    let jarvisPages = grokListRequests(world.fake).filter { $0.agent == GrokRunIDs.jarvis && $0.limit == 500 }.map(\.before)
    #expect(jarvisPages.first! == nil && jarvisPages.dropFirst().allSatisfy { $0 == 21 || $0 == 11 })
    #expect(archive(store, GrokRunIDs.jarvis) == 27 && run.rows.count == 4)
}

@MainActor @Test func denyStopsWithNothingReadAndOffersRecentMessages() async throws {
    let world = try GrokWorld()
    world.passwords.failure = .denied(errSecAuthFailed)
    let store = world.store()
    let run = makeRun(world, store)
    guard case .stopped(let error) = await run.start() else { Issue.record("expected a stop"); return }
    #expect(error == .keychain(.denied(errSecAuthFailed)) && error.recentStillAvailable)
    #expect(world.passwords.reads == 1 && world.fake.requests.isEmpty && store.bots.allSatisfy { $0.grokSourceID == nil })
    #expect(await run.start(GrokImportOptions(mode: .recent)) == .finished && world.passwords.reads == 1)
}

@MainActor @Test func aStartWhileAReadIsPendingIsRefusedAndALateResultAfterCancelIsDropped() async throws {
    let world = try GrokWorld()
    let answer = DispatchSemaphore(value: 0)
    world.passwords.hold = answer
    let store = world.store()
    let run = makeRun(world, store)
    let first = Task { await run.start() }
    try await grokWait { world.gate.isReading && run.state == .awaitingMacOS }
    // A second run (a reopened sheet) on the same app-wide gate cannot stack a second dialog.
    let second = makeRun(world, world.store())
    #expect(await second.start() == .stopped(.keychainReadInFlight))
    #expect(await run.start() == .awaitingMacOS)
    run.cancel()
    #expect(await first.value == .cancelled)
    #expect(world.gate.isReading)
    answer.signal()
    try await grokWait { !world.gate.isReading }
    #expect(await run.holder.lifetime == .none)
    #expect(world.passwords.reads == 1 && world.fake.requests.isEmpty && run.state == .cancelled)
}

@MainActor @Test func anExpiredTokenPausesHoldsTheKeyAndCheckAgainNeedsNoSecondRead() async throws {
    let world = try GrokWorld(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30)
    let store = world.store()
    let run = makeRun(world, store)
    #expect(await run.start() == .paused(.tokenExpired))
    #expect(await run.holder.lifetime == GrokSecretLifetime(derivedKey: true, credentials: false))
    #expect(world.fake.requests.isEmpty)
    #expect(await !run.willAskMacOS())
    // Still expired: the pause stays, the key is still held, still one read.
    #expect(await run.checkAgain() == .paused(.tokenExpired))
    try world.writeSecrets(tokenExp: 4_102_444_800)
    #expect(await run.checkAgain() == .finished)
    #expect(world.passwords.reads == 1 && archive(store, GrokRunIDs.jarvis) == 27)
    #expect(await run.holder.lifetime == .none)
}

@MainActor @Test func theHeldKeyLapsesAfterTenMinutesOrForgetAndTheNextStepAnnouncesANewRead() async throws {
    let world = try GrokWorld(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30)
    let store = world.store()
    let run = makeRun(world, store)
    #expect(await run.start() == .paused(.tokenExpired))
    world.clock.advance(.seconds(599))
    await run.expireHoldIfDue()
    #expect(await run.holder.lifetime.derivedKey)
    world.clock.advance(.seconds(1))
    await run.expireHoldIfDue()
    #expect(await run.holder.lifetime == .none)
    #expect(await run.willAskMacOS())
    try world.writeSecrets(tokenExp: 4_102_444_800)
    var announced = 0
    run.onEvent = { if case .keychainReadComing = $0 { announced += 1 } }
    #expect(await run.checkAgain() == .finished)
    #expect(announced == 1 && world.passwords.reads == 2)

    let other = try GrokWorld(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30)
    let forgetting = makeRun(other, other.store())
    #expect(await forgetting.start() == .paused(.tokenExpired))
    await forgetting.forgetSignIn()
    #expect(await forgetting.holder.lifetime == .none)
    #expect(await forgetting.willAskMacOS())
}

@MainActor @Test func a401MidRunPausesWithoutAKeyAndContinuingAsksMacOSAgain() async throws {
    let world = try GrokWorld()
    let refused = GrokSwitch()
    refused.isOn = true
    world.fake.intercept = { index, _ in refused.isOn && index == 2 ? .http(401, []) : nil }
    let store = world.store()
    let run = makeRun(world, store)
    #expect(await run.start() == .paused(.signInInvalid))
    #expect(await run.holder.lifetime == .none)
    #expect(await run.willAskMacOS())
    // Jarvis (request 1) was committed before the 401 on Finance's page.
    #expect(archive(store, GrokRunIDs.jarvis) == 27 && run.rows.count == 1)
    refused.isOn = false
    #expect(await run.retryRemaining() == .finished)
    #expect(world.passwords.reads == 2 && run.rows.count == 4)
}

@MainActor @Test func cancelKeepsFinishedBotsAndCanImportWhatWasFetchedAsIncomplete() async throws {
    let world = try GrokWorld(history: [GrokRunIDs.jarvis: 30, GrokRunIDs.finance: 25, GrokRunIDs.plain: 3, GrokRunIDs.group: 4])
    world.fake.pageCap = 10
    let reached = GrokSwitch(), release = DispatchSemaphore(value: 0)
    // Request 0 is the canary, 1–3 Jarvis's pages, 4 Finance's first page: it is held until the run is cancelled.
    world.fake.intercept = { index, _ in
        if index == 4 { reached.isOn = true; release.wait() }
        return nil
    }
    let store = world.store()
    let run = makeRun(world, store)
    let running = Task { await run.start() }
    try await grokWait { reached.isOn }
    run.cancel()
    release.signal()
    #expect(await running.value == .cancelled)
    #expect(await run.holder.lifetime == .none)
    #expect(archive(store, GrokRunIDs.jarvis) == 27 && store.bots.first { $0.grokSourceID == GrokRunIDs.finance } == nil)
    #expect(await run.importWhatWasFetched() == .cancelled)
    let finance = try #require(run.rows.last)
    #expect(finance.sourceID == GrokRunIDs.finance && finance.status == .incomplete && finance.coverage == .incomplete)
    // The cache's two entries plus whatever of the held page arrived before the cancel took effect (never all 25).
    #expect((2...12).contains(archive(store, GrokRunIDs.finance)))
    #expect(store.bots.first { $0.grokSourceID == GrokRunIDs.plain } == nil && world.fake.requests.count <= 6)
}

@MainActor @Test func aSecondRunAddsNoBotsAndNoLines() async throws {
    let world = try GrokWorld()
    let store = world.store()
    #expect(await makeRun(world, store).start() == .finished)
    let bots = store.bots.count, groups = store.groups.count
    let again = makeRun(world, store)
    #expect(await again.start() == .finished)
    #expect(store.bots.count == bots && store.groups.count == groups)
    #expect(again.rows.allSatisfy { $0.addedLines == 0 } && again.rows.map(\.archiveLines) == [27, 5, 3, 4])
}

@MainActor @Test func protocolChangedAtTheCanaryWritesNothing() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index == 0 ? .http(200, [0x0b]) : nil }
    let store = world.store()
    let run = makeRun(world, store)
    guard case .stopped(.server(let error)) = await run.start() else { Issue.record("expected a stop"); return }
    #expect(error.reason == .protocolChanged && world.fake.requests.count == 1)
    #expect(run.rows.isEmpty && store.bots.allSatisfy { $0.grokSourceID == nil })
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.deletingLastPathComponent().appending(path: "grok-history").path))
    #expect(await run.holder.lifetime == .none)
}

@MainActor @Test func otherClientErrorsStopAndKeepWhatWasCommitted() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index == 2 ? .http(403, []) : nil }
    let store = world.store()
    let run = makeRun(world, store)
    guard case .stopped(.server(let error)) = await run.start() else { Issue.record("expected a stop"); return }
    #expect(error.reason == .rejected && error.httpStatus == 403 && world.fake.requests.count == 3)
    #expect(archive(store, GrokRunIDs.jarvis) == 27 && run.rows.count == 1)
}

@MainActor @Test func selectionByNameBringsAGroupsMembersAndRefusesUnknownNames() async throws {
    let world = try GrokWorld()
    let cache = try GrokCacheReader(folder: world.location.cacheFolder).read()
    let picked = try GrokImportRun.conversations(in: cache, selection: ["konrad, jarvis, plain bot"])
    #expect(picked == [GrokRunIDs.jarvis, GrokRunIDs.plain, GrokRunIDs.group])
    #expect(try GrokImportRun.conversations(in: cache, selection: ["finance controller"]) == [GrokRunIDs.finance])
    #expect(throws: GrokImportRunError.unknownBots(1)) { try GrokImportRun.conversations(in: cache, selection: ["Jarvis", "Nobody"]) }
    let run = makeRun(world, world.store(), selection: ["Finance Controller"])
    #expect(await run.start() == .finished && run.rows.map(\.sourceID) == [GrokRunIDs.finance])
}

@MainActor @Test func aMissingKeychainItemOrSignedOutGrokBotStopsBeforeAnyRead() async throws {
    let world = try GrokWorld()
    world.passwords.probeStatus = errSecItemNotFound
    let run = makeRun(world, world.store())
    #expect(await run.start() == .stopped(.keychainItemMissing))
    try FileManager.default.removeItem(at: world.location.secretsFile)
    #expect(await run.start() == .stopped(.signedOut))
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty)
}

@MainActor @Test func theAccountBindingHashesTheSlotsRawValueNotItsEncodedSegment() async throws {
    // An `@` makes the encoded segment differ from the raw value; Grok Bot hashes the raw one (seen on Konrad's Mac).
    let slot = "synthetic+user@example.test"
    let world = try GrokWorld(slot: slot)
    let preflight = await GrokPreflight.run(location: world.location, passwords: world.passwords)
    #expect(preflight.cache?.account == "synthetic%2Buser%40example.test" && preflight.binding == .holds && preflight.serverReady)
    let store = world.store()
    #expect(await makeRun(world, store).start() == .finished && archive(store, GrokRunIDs.jarvis) == 27)

    let other = try GrokWorld(slot: slot, activeAccount: GrokCredentials.sha256Hex(Array("synthetic%2Buser%40example.test".utf8)))
    let mismatch = await GrokPreflight.run(location: other.location, passwords: other.passwords)
    #expect(mismatch.binding == .mismatch && !mismatch.serverReady)
    #expect(await makeRun(other, other.store()).start() == .stopped(.cache(.accountMismatch)))
    #expect(other.passwords.reads == 0 && other.fake.requests.isEmpty)
    let recent = makeRun(other, other.store(), mode: .recent)
    #expect(await recent.start() == .finished)
}
