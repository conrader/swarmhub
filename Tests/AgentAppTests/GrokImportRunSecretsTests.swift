import Foundation
import Security
import Testing
@testable import AgentApp

// P10c: the secret lifetime table state by state, the leak scan over the whole pipeline (P10b's, extended with a
// synthetic password), and the two commands. Synthetic data only; nothing reaches the real Keychain or Grok.

@MainActor private func makeRun(_ world: GrokWorld, _ store: AppStore, mode: GrokImportMode = .full) -> GrokImportRun {
    GrokImportRun(store: store, environment: world.environment(), options: GrokImportOptions(mode: mode))
}

@MainActor @Test func secretLifetimeStateByState() async throws {
    // idle and awaitingMacOS: nothing (the Keychain bytes live only inside the read and are zeroed at derivation).
    let waiting = try GrokWorld()
    let answer = DispatchSemaphore(value: 0)
    waiting.passwords.hold = answer
    let pending = makeRun(waiting, waiting.store())
    #expect(await pending.holder.lifetime == .none)
    let started = Task { await pending.start() }
    try await grokWait { pending.state == .awaitingMacOS }
    #expect(await pending.holder.lifetime == .none)
    answer.signal()
    #expect(await started.value == .finished)
    #expect(await pending.holder.lifetime == .none)

    // running: the three values only, never the key.
    let world = try GrokWorld()
    let reached = GrokSwitch(), release = DispatchSemaphore(value: 0)
    world.fake.intercept = { index, _ in
        if index == 1 { reached.isOn = true; release.wait() }
        return nil
    }
    let run = makeRun(world, world.store())
    let running = Task { await run.start() }
    try await grokWait { reached.isOn }
    #expect(run.state == .running)
    #expect(await run.holder.lifetime == GrokSecretLifetime(derivedKey: false, credentials: true))
    release.signal()
    #expect(await running.value == .finished)
    #expect(await run.holder.lifetime == .none)

    // stopped (a 4xx) and cancelled from a pause: nothing.
    let stopped = try GrokWorld()
    stopped.fake.intercept = { index, _ in index == 1 ? .http(404, []) : nil }
    let stopping = makeRun(stopped, stopped.store())
    guard case .stopped = await stopping.start() else { Issue.record("expected a stop"); return }
    #expect(await stopping.holder.lifetime == .none)
    let paused = try GrokWorld()
    paused.fake.intercept = { _, _ in .http(503, []) }
    let pausing = makeRun(paused, paused.store())
    guard case .paused(.network) = await pausing.start() else { Issue.record("expected a pause"); return }
    #expect(await pausing.holder.lifetime == GrokSecretLifetime(derivedKey: false, credentials: true))
    pausing.cancel()
    try await grokWait { pausing.state == .cancelled }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await pausing.holder.lifetime == .none)
    // A network pause also lapses after ten minutes.
    let lapsing = makeRun(paused, paused.store())
    guard case .paused(.network) = await lapsing.start() else { Issue.record("expected a pause"); return }
    paused.clock.advance(GrokProtocol.signInHold)
    await lapsing.expireHoldIfDue()
    #expect(await lapsing.holder.lifetime == .none)
    #expect(await lapsing.willAskMacOS())
}

/// Every secret the synthetic world holds, plus the markers that would mean one leaked.
func grokLeakSecrets(_ tokens: [String]) -> [String] {
    tokens + [GrokFixtureSecrets.machineID, FakePasswords.password, "refresh-SECRET-never-read", "Bearer "]
}

func grokFilesText(under folder: URL) -> [String] {
    guard let names = FileManager.default.subpaths(atPath: folder.path) else { return [] }
    return names.compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
}

@MainActor @Test func leakScanOverThePipelineFindsNoSecretAnywhere() async throws {
    let fresh = GrokWorld.jwt(exp: 4_102_444_800), expired = GrokWorld.jwt(exp: GrokWorld.now.timeIntervalSince1970 + 30)
    var texts: [String] = []
    let defaults = isolatedDefaults()
    let storeURL = temporaryStore()
    func store(_ world: GrokWorld) -> AppStore {
        AppStore(storeURL: storeURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: defaults)
    }
    func record(_ run: GrokImportRun, _ state: GrokImportRunState) {
        texts += [String(describing: state), String(reflecting: state), String(describing: run.rows)]
        if case .stopped(let error) = state { texts += [error.localizedDescription, error.errorDescription ?? ""] }
    }
    // Finished, network pause + retry, 401 + retry, expired + check again, deny, protocolChanged, rejected, cancel.
    let scenarios: [(GrokWorld) -> Void] = [
        { _ in },
        { world in world.fake.intercept = { index, _ in (2...5).contains(index) ? .fail(.timedOut) : nil } },
        { world in world.fake.intercept = { index, _ in index == 2 ? .http(401, Array(#"{"code":"unauthenticated"}"#.utf8)) : nil } },
        { world in try? world.writeSecrets(tokenExp: GrokWorld.now.timeIntervalSince1970 + 30) },
        { world in world.passwords.failure = .denied(errSecUserCanceled) },
        { world in world.fake.intercept = { index, _ in index == 0 ? .http(200, [0x0a, 0x05, 0x01]) : nil } },
        { world in
            let body = Array(#"{"code":"invalid_argument","message":"Bearer x"}"#.utf8)
            world.fake.intercept = { index, _ in index == 1 ? .http(400, body) : nil }
        },
    ]
    for prepare in scenarios {
        let world = try GrokWorld()
        prepare(world)
        let run = makeRun(world, store(world))
        var state = await run.start()
        record(run, state)
        if state.isPaused {
            try world.writeSecrets(tokenExp: 4_102_444_800)
            world.fake.intercept = nil
            state = await run.retryRemaining()
            record(run, state)
        }
        // The commands' output and reports, over the same world.
        let report = world.root.appending(path: "reports/fetch.json")
        let lines = LockedTrace()
        _ = await HeadlessGrok.fetch(arguments: ["--grok-fetch", "--mode", "full", "--report", report.path], store: store(world),
                                     environment: world.environment(), output: { lines.add($0) })
        let probeReport = world.root.appending(path: "reports/probe.json").path
        _ = await HeadlessGrok.probe(arguments: ["--grok-probe", "--live", "--report", probeReport],
                                     environment: world.environment(), output: { lines.add($0) })
        texts += lines.read() + grokFilesText(under: world.root.appending(path: "reports"))
    }
    texts += grokFilesText(under: storeURL.deletingLastPathComponent())
    texts.append(String(describing: defaults.dictionaryRepresentation()))
    #expect(texts.contains { $0.contains("grokSourceID") } && texts.contains { $0.contains("Ledger checked") },
            "the scan saw the store and archives")
    for text in texts {
        for secret in grokLeakSecrets([fresh, expired]) { #expect(!text.contains(secret), "a secret leaked: \(secret.prefix(6))…") }
        #expect(!text.contains("eyJzeW50aGV0aWMi"), "a JWT-shaped string leaked")
    }
}

@MainActor @Test func grokFetchPrintsTheNoticeFirstCountsOnlyAndExitsZeroOnlyWhenComplete() async throws {
    let world = try GrokWorld()
    let store = world.store()
    let report = world.root.appending(path: "Torvli-snapshots/fetch.json")
    let lines = LockedTrace()
    let code = await HeadlessGrok.fetch(arguments: ["--grok-fetch", "--mode", "full", "--report", report.path], store: store,
                                        environment: world.environment(), output: { lines.add($0) })
    let output = lines.read()
    #expect(code == 0 && world.passwords.reads == 1)
    #expect(output.first?.hasPrefix("Mode full:") == true && output.dropFirst().first == HeadlessGrok.keychainNotice)
    #expect(output.contains { $0.hasPrefix("state=finished conversations=4 done=4") })
    let attributes = try FileManager.default.attributesOfItem(atPath: report.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let text = (output + [try String(contentsOf: report, encoding: .utf8)]).joined(separator: "\n")
    for name in ["Jarvis", "Finance", "Plain Bot", GrokRunIDs.jarvis, "synthetic"] { #expect(!text.contains(name), "\(name) in output") }

    let again = LockedTrace()
    #expect(await HeadlessGrok.fetch(arguments: ["--grok-fetch", "--mode", "full"], store: store, environment: world.environment(),
                                     output: { again.add($0) }) == 0)
    #expect(again.read().contains { $0.contains(" added=0 ") })
    #expect(await HeadlessGrok.fetch(arguments: ["--grok-fetch"], store: store, environment: world.environment(), output: { _ in }) == 64)

    let paused = try GrokWorld()
    paused.fake.intercept = { _, _ in .fail(.notConnectedToInternet) }
    let pausedLines = LockedTrace()
    #expect(await HeadlessGrok.fetch(arguments: ["--grok-fetch", "--mode", "full"], store: paused.store(),
                                     environment: paused.environment(),
                                     output: { pausedLines.add($0) }) == 1)
    #expect(pausedLines.read().contains { $0.hasPrefix("paused: network") })
}

@MainActor @Test func grokProbeWithoutLiveNeverReadsOrConnectsAndLiveReadsOnce() async throws {
    let world = try GrokWorld()
    let lines = LockedTrace()
    let code = await HeadlessGrok.probe(arguments: ["--grok-probe"], environment: world.environment(), output: { lines.add($0) })
    #expect(code == 0 && world.passwords.reads == 0 && world.passwords.probeCount == 1 && world.fake.requests.isEmpty)
    let output = lines.read().joined(separator: "\n")
    #expect(output.contains("version=0.70.2") && output.contains("rosterRows=4 bots=3 groups=1 cachedTranscripts=3"))
    #expect(output.contains("keychainItemPresent=true") && output.contains("accountBinding=noSlot") && !output.contains("live "))
    #expect(output.hasSuffix("probe OK") && !output.contains(HeadlessGrok.keychainNotice))

    let live = LockedTrace()
    #expect(await HeadlessGrok.probe(arguments: ["--grok-probe", "--live"], environment: world.environment(),
                                     output: { live.add($0) }) == 0)
    #expect(world.passwords.reads == 1 && world.fake.requests.count == 1)
    #expect(live.read().contains(HeadlessGrok.keychainNotice))
    let liveLine = "tokenShapeOK=true tokenValid=true machineIDPresent=true teamIDPresent=true canaryOK=true canaryRows=1"
    #expect(live.read().contains { $0.contains(liveLine) })

    world.passwords.probeStatus = errSecItemNotFound
    #expect(await HeadlessGrok.probe(arguments: ["--grok-probe"], environment: world.environment(), output: { _ in }) == 1)
}
