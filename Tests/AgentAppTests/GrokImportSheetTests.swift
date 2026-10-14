import Foundation
import Security
import Testing
@testable import AgentApp

// P10d: the sheet's coordinator over the shared GrokImportRun, a fake password provider and FakeGrok
// (briefs/P10.md P10d 5). Nothing here reads the real Keychain, Grok Bot's folder or the network.

@MainActor func makeCoordinator(_ world: GrokWorld, _ store: AppStore) -> GrokImportCoordinator {
    GrokImportCoordinator(store: store, environment: world.environment(), isGrokRunning: { false })
}

/// Scan, then Continue through the Permission step; returns once the run settled.
@MainActor func runFull(_ coordinator: GrokImportCoordinator) async {
    await coordinator.proceed()
    coordinator.continueToMacOS()
    await coordinator.settled()
}

@MainActor @Test func theSheetReadsNothingBeforeContinueAndOnceAfterIt() async throws {
    let world = try GrokWorld()
    let store = world.store(server: "https://box.test/v1")
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    #expect(coordinator.step == .found && coordinator.availability == .ready && coordinator.mode == .full)
    #expect(coordinator.items.map(\.name) == ["Jarvis", "Finance Controller", "Plain Bot", "Konrad, Jarvis, Plain Bot"])
    #expect(coordinator.items.map(\.profile) == ["grok-jarvis", "grok-finance-controller", "grok-plain-bot", nil])
    #expect(coordinator.selected.count == 4 && coordinator.grokVersion == "0.70.2")
    // One canary plus at least one page per conversation, 0.5 s apart.
    #expect(coordinator.requestEstimate.requests == 5)
    #expect(world.passwords.reads == 0 && world.passwords.probeCount == 1 && world.fake.requests.isEmpty)
    await coordinator.proceed()
    #expect(coordinator.step == .permission)
    #expect(world.passwords.reads == 0 && world.fake.requests.isEmpty)
    coordinator.continueToMacOS()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 1)
    #expect(coordinator.progress.map(\.status) == [.done, .done, .done, .done])
    // Counts read back from the archive files.
    #expect(coordinator.outcomes.map(\.archiveLines) == [27, 5, 3, 4])
    #expect(coordinator.botOutcomes.allSatisfy { $0.connection == .needsKey } && coordinator.addKeysPrefill ==
            "grok-jarvis=\ngrok-finance-controller=\ngrok-plain-bot=")
    #expect(await coordinator.run?.holder.lifetime == GrokSecretLifetime.none)
    #expect(coordinator.requests == 5)
}

@MainActor @Test func recentMessagesNeedNoPermissionStepNoPromptAndNoNetwork() async throws {
    let world = try GrokWorld()
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    coordinator.mode = .recent
    await coordinator.proceed()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 0 && world.fake.requests.isEmpty)
    #expect(coordinator.outcomes.allSatisfy { $0.row.coverage == .cacheOnly })
    // No server and no keys: every bot is history only.
    #expect(coordinator.botOutcomes.map(\.connection) == [.historyOnly, .historyOnly, .historyOnly])
}

@MainActor @Test func aNetworkPauseAndRetryStayWithinOneReadPerSheetSession() async throws {
    let world = try GrokWorld()
    world.fake.pageCap = 10
    let outage = GrokSwitch()
    outage.isOn = true
    world.fake.intercept = { index, _ in outage.isOn && index >= 3 ? .fail(.networkConnectionLost) : nil }
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    guard case .paused(.network) = coordinator.step else { Issue.record("expected a network pause"); return }
    #expect(coordinator.progress.first?.status == .paused && coordinator.progress.first?.pages == 2)
    #expect(coordinator.holdsSignIn)
    outage.isOn = false
    coordinator.retryRemaining()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 1)
    #expect(coordinator.outcomes.first?.archiveLines == 27)
}

@MainActor @Test func denyOffersTryAgainAndRecentOnly() async throws {
    let world = try GrokWorld()
    world.passwords.failure = .denied(errSecAuthFailed)
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    #expect(coordinator.step == .failed(.keychain(.denied(errSecAuthFailed))) && coordinator.isRetryAfterDeny)
    #expect(world.fake.requests.isEmpty && store.bots.allSatisfy { $0.grokSourceID == nil })
    coordinator.recentOnly()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 1 && world.fake.requests.isEmpty)
    #expect(coordinator.outcomes.count == 4)
}

@MainActor @Test func anExpiredSignInPausesAndCheckAgainNeedsNoSecondRead() async throws {
    let world = try GrokWorld(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30)
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    #expect(coordinator.step == .paused(.tokenExpired) && coordinator.holdsSignIn)
    try world.writeSecrets(tokenExp: 4_102_444_800)
    coordinator.checkAgain()
    await coordinator.settled()
    #expect(coordinator.step == .finished && world.passwords.reads == 1)
}

@MainActor @Test func cancelKeepsWhatWasCommittedAndCanImportWhatWasFetched() async throws {
    let world = try GrokWorld(history: [GrokRunIDs.jarvis: 30, GrokRunIDs.finance: 25, GrokRunIDs.plain: 3, GrokRunIDs.group: 4])
    world.fake.pageCap = 10
    let reached = GrokSwitch(), release = DispatchSemaphore(value: 0)
    world.fake.intercept = { index, _ in
        if index == 4 { reached.isOn = true; release.wait() }
        return nil
    }
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await coordinator.proceed()
    coordinator.continueToMacOS()
    try await grokWait { reached.isOn }
    // Committed as it goes: Jarvis is in the store while Finance is still fetching.
    #expect(store.grokArchiveLines(sourceID: GrokRunIDs.jarvis) == 27 && coordinator.progress.first?.status == .done)
    coordinator.cancel()
    release.signal()
    await coordinator.settled()
    #expect(coordinator.step == .cancelled && coordinator.canImportWhatWasFetched)
    #expect(await coordinator.run?.holder.lifetime == GrokSecretLifetime.none)
    coordinator.importWhatWasFetched()
    await coordinator.settled()
    #expect(coordinator.step == .finished)
    let finance = try #require(coordinator.outcomes.first { $0.id == GrokRunIDs.finance })
    #expect(finance.row.status == .incomplete && finance.coverageText.hasPrefix("Incomplete"))
}

@MainActor @Test func dismissingTheSheetForgetsEverySecret() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index >= 1 ? .fail(.timedOut) : nil }
    let store = world.store()
    let coordinator = makeCoordinator(world, store)
    await coordinator.scan()
    await runFull(coordinator)
    guard case .paused(.network) = coordinator.step else { Issue.record("expected a network pause"); return }
    #expect(await coordinator.run?.holder.lifetime == GrokSecretLifetime(derivedKey: false, credentials: true))
    await coordinator.dismiss()
    #expect(await coordinator.run?.holder.lifetime == GrokSecretLifetime.none && coordinator.step == .cancelled)
}

@MainActor @Test func closingTheSheetWhileMacOSAsksCannotStackASecondDialog() async throws {
    let world = try GrokWorld()
    let answer = DispatchSemaphore(value: 0)
    world.passwords.hold = answer
    let store = world.store()
    let first = makeCoordinator(world, store)
    await first.scan()
    await first.proceed()
    first.continueToMacOS()
    try await grokWait { world.gate.isReading }
    if case .awaitingMacOS = first.step {} else { Issue.record("expected the macOS wait, got \(first.step)") }
    await first.dismiss()
    #expect(first.step == .cancelled)
    // The sheet reopened: Continue stays off until the stale call returns.
    let second = makeCoordinator(world, store)
    await second.scan()
    await second.proceed()
    #expect(second.step == .permission)
    second.continueToMacOS()
    #expect(second.step == .permission && world.passwords.reads == 1)
    answer.signal()
    try await grokWait { !world.gate.isReading }
    #expect(await first.run?.holder.lifetime == GrokSecretLifetime.none)
    #expect(store.bots.allSatisfy { $0.grokSourceID == nil })
}

@MainActor @Test func tickingAGroupTicksItsMembers() async throws {
    let world = try GrokWorld()
    let coordinator = makeCoordinator(world, world.store())
    await coordinator.scan()
    coordinator.selected = []
    coordinator.toggle(GrokRunIDs.group)
    #expect(coordinator.selected == [GrokRunIDs.group, GrokRunIDs.jarvis, GrokRunIDs.plain])
    coordinator.toggle(GrokRunIDs.group)
    #expect(coordinator.selected == [GrokRunIDs.jarvis, GrokRunIDs.plain])
    // Only the ticked conversations are imported.
    coordinator.selected = [GrokRunIDs.finance]
    coordinator.mode = .recent
    await coordinator.proceed()
    await coordinator.settled()
    #expect(coordinator.outcomes.map(\.id) == [GrokRunIDs.finance])
}

@MainActor @Test func leakScanOverTheCoordinatorFindsNoSecret() async throws {
    let fresh = GrokWorld.jwt(exp: 4_102_444_800), expired = GrokWorld.jwt(exp: GrokWorld.now.timeIntervalSince1970 + 30)
    let storeURL = temporaryStore(), defaults = isolatedDefaults()
    var texts: [String] = []
    let scenarios: [(GrokWorld) -> Void] = [
        { _ in },
        { world in world.fake.intercept = { index, _ in (2...5).contains(index) ? .fail(.timedOut) : nil } },
        { world in world.fake.intercept = { index, _ in index == 2 ? .http(401, Array(#"{"code":"unauthenticated"}"#.utf8)) : nil } },
        { world in try? world.writeSecrets(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30) },
        { world in world.passwords.failure = .denied(errSecUserCanceled) },
        { world in world.fake.intercept = { index, _ in index == 0 ? .http(200, [0x0a, 0x05, 0x01]) : nil } },
    ]
    for prepare in scenarios {
        let world = try GrokWorld()
        prepare(world)
        let store = AppStore(storeURL: storeURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: defaults)
        let coordinator = makeCoordinator(world, store)
        await coordinator.scan()
        await runFull(coordinator)
        func record() {
            texts += [String(describing: coordinator.step), String(reflecting: coordinator.progress),
                      String(describing: coordinator.outcomes), String(describing: coordinator.items)]
            if case .failed(let error) = coordinator.step { texts.append(error.errorDescription ?? "") }
            for row in coordinator.progress { texts.append(row.label) }
        }
        record()
        if coordinator.step.isPaused {
            try world.writeSecrets(tokenExp: 4_102_444_800)
            world.fake.intercept = nil
            coordinator.retryRemaining()
            await coordinator.settled()
            record()
        }
        await coordinator.dismiss()
        record()
    }
    texts += grokFilesText(under: storeURL.deletingLastPathComponent())
    texts.append(String(describing: defaults.dictionaryRepresentation()))
    #expect(texts.contains { $0.contains("grokSourceID") }, "the scan saw the store")
    for text in texts {
        for secret in grokLeakSecrets([fresh, expired]) { #expect(!text.contains(secret), "a secret leaked: \(secret.prefix(6))…") }
        #expect(!text.contains("eyJzeW50aGV0aWMi"), "a JWT-shaped string leaked")
    }
}
