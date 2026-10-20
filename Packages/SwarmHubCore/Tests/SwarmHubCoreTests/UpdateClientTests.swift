import Foundation
import Testing
@testable import SwarmHubCore

/// P4a acceptance: the P3a failure matrix against URLProtocol stubs, plus platform filtering, floors,
/// freshness and the launch/6 h schedule. No network: every host is an in-process stub.
struct UpdateClientTests {
    typealias Reply = UpdateHostProtocol.Reply

    struct MatrixCase: Sendable, CustomStringConvertible {
        let name: String
        let overrides: [String: Reply]
        let stage: String
        let reason: String
        var description: String { name }
    }

    static let matrix: [MatrixCase] = {
        let policy = "/blobs/sha256/" + UpdateFixtures.digest("policy")
        let blob = UpdateFixtures.blob("policy")
        var tampered = blob; tampered[tampered.startIndex] ^= 0x01
        return [
            MatrixCase(name: "unreachable", overrides: ["/keys.json": .fail(.cannotConnectToHost)], stage: "fetch", reason: "unreachable"),
            MatrixCase(name: "dns", overrides: ["/keys.json": .fail(.cannotFindHost)], stage: "fetch", reason: "unreachable"),
            MatrixCase(name: "index-404", overrides: ["/channels/stable.json": .status(404)], stage: "fetch", reason: "http_404"),
            MatrixCase(name: "manifest-404", overrides: ["/bundles/11.json": .status(404)], stage: "fetch", reason: "http_404"),
            MatrixCase(name: "server-error", overrides: ["/keys.json": .status(503)], stage: "fetch", reason: "http_503"),
            MatrixCase(name: "redirect-same-host", overrides: ["/channels/stable.json": .redirect("/channels/beta.json")],
                       stage: "fetch", reason: "redirect_refused"),
            MatrixCase(name: "bad-index-signature", overrides: ["/channels/stable.json": .body(UpdateFixtures.data("channels/stable--tampered-byte.json"))],
                       stage: "index", reason: "bad_signature"),
            MatrixCase(name: "bad-keys-signature", overrides: ["/keys.json": .body(UpdateFixtures.data("keys/keys-2--tampered-byte.json"))],
                       stage: "keys", reason: "keys_bad_signature"),
            MatrixCase(name: "wrong-key", overrides: ["/channels/stable.json": .body(UpdateFixtures.data("channels/stable--wrong-key.json"))],
                       stage: "index", reason: "bad_signature"),
            MatrixCase(name: "wrong-channel", overrides: ["/channels/stable.json": .body(UpdateFixtures.data("channels/stable--beta.json"))],
                       stage: "index", reason: "channel_mismatch"),
            MatrixCase(name: "stale-index", overrides: ["/channels/stable.json": .body(UpdateFixtures.data("channels/stable--expired.json"))],
                       stage: "index", reason: "index_expired"),
            MatrixCase(name: "oversized-index", overrides: ["/channels/stable.json": .body(Data(repeating: 0x20, count: 1_048_577))],
                       stage: "fetch", reason: "oversize"),
            MatrixCase(name: "oversized-blob", overrides: [policy: .body(blob + Data([0]))], stage: "fetch", reason: "oversize"),
            MatrixCase(name: "truncated-keys", overrides: ["/keys.json": .body(UpdateFixtures.data("keys/keys-2.json").prefix(200))],
                       stage: "keys", reason: "schema_invalid"),
            MatrixCase(name: "truncated-manifest", overrides: ["/bundles/11.json": .body(UpdateFixtures.data("bundles/11.json").dropLast(1))],
                       stage: "manifest", reason: "manifest_hash_mismatch"),
            MatrixCase(name: "truncated-blob", overrides: [policy: .body(blob.dropLast(1))], stage: "component", reason: "blob_size_mismatch"),
            MatrixCase(name: "tampered-blob", overrides: [policy: .body(tampered)], stage: "component", reason: "blob_hash_mismatch"),
        ]
    }()

    /// A store already holding an earlier bundle, so "no change" is observable.
    func seededStore() throws -> UpdateStore {
        let store = UpdateFixtures.temporaryStore()
        try store.commit(UpdateFixtures.synthetic(10))
        return store
    }

    func cleanup(_ store: UpdateStore) { try? FileManager.default.removeItem(at: store.root) }

    @Test(arguments: UpdateClientTests.matrix)
    func failureLeavesStoreAndBehaviourUnchanged(_ entry: MatrixCase) async throws {
        let store = try seededStore()
        defer { cleanup(store) }
        let before = UpdateFixtures.tree(store)
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route(entry.overrides))
        defer { session.invalidateAndCancel() }
        let clock = TestClock()
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store,
                                  session: session, clock: { clock.now })
        let result = await client.check()
        #expect(result.verdict.verdict == "reject", "\(entry.name)")
        #expect(result.verdict.stage == entry.stage, "\(entry.name)")
        #expect(result.verdict.reason == entry.reason, "\(entry.name)")
        #expect(UpdateFixtures.tree(store) == before, "\(entry.name)")
        #expect(result.status.current?.bundleVersion == 10, "\(entry.name)")
        #expect(store.component("policy") == UpdateFixtures.synthetic(10).blobs["policy"], "\(entry.name)")
        let state = try #require(try store.loadState())
        // Only a key manifest that verified raises a floor (keys-2: version 2); the rest stay at the baseline.
        let keysVerified = entry.overrides["/keys.json"] == nil
        #expect([state.keysVersion, state.indexSequence, state.bundleVersion] == [keysVerified ? 2 : 1, 4, 10], "\(entry.name)")
        #expect(state.lastResult == result.verdict)
        // Never verified anything: stale since this first failed check.
        #expect(result.status.staleSince == "2026-10-20T12:00:00Z", "\(entry.name)")
    }

    @Test(arguments: ["ios", "mac"])
    func validChainStoresOnlyThisPlatformsDataComponents(_ platform: String) async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host, platform: platform),
                                  store: store, session: session, clock: { TestClock().now })
        let result = await client.check()
        #expect(result.verdict.verdict == "accept")
        #expect(result.verdict.apply == ["policy", "routine-card"])
        // Box archives (skills, tools, box config) are never requested by an app.
        let paths = UpdateHostProtocol.paths(host)
        #expect(paths == ["/keys.json", "/channels/stable.json", "/bundles/11.json",
                          "/blobs/sha256/" + UpdateFixtures.digest("policy"), "/blobs/sha256/" + UpdateFixtures.digest("routine-card")])
        for name in UpdateFixtures.boxComponents { #expect(!paths.contains("/blobs/sha256/" + UpdateFixtures.digest(name))) }
        for request in UpdateHostProtocol.requests(host) {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        let record = try #require(store.record())
        #expect(record.bundleVersion == 11 && record.platform == platform)
        #expect(record.manifestSHA256 == updateDigest(UpdateFixtures.data("bundles/11.json")))
        #expect(record.components.map(\.name) == ["policy", "routine-card"])
        #expect(record.components.allSatisfy { $0.contentClass == "data" && ["config", "ui"].contains($0.kind) })
        #expect(store.component("policy") == UpdateFixtures.blob("policy"))
        #expect(store.component("routine-card") == UpdateFixtures.blob("routine-card"))
        for name in UpdateFixtures.boxComponents { #expect(store.component(name) == nil) }
        // Opaque bytes only: nothing extracted, nothing executable.
        let id = UpdateStore.versionID(record)
        let files = UpdateFixtures.tree(store).filter { $0.key.hasPrefix("versions/") }
        #expect(Set(files.keys) == Set(["record.json", "keys.json", "index.json", "bundle.json",
                                        "components/policy", "components/routine-card"].map { "versions/\(id)/" + $0 }))
        for value in files.values {
            let mode = Int(value.split(separator: ":")[1], radix: 8) ?? 0o777
            #expect(mode & 0o111 == 0)
        }
        let state = try #require(try store.loadState())
        #expect([state.keysVersion, state.indexSequence, state.bundleVersion] == [2, 5, 11])
        #expect(state.freshUntil == "2026-10-26T00:00:00Z" && state.failingSince == nil)
        #expect(result.status.staleSince == nil)
    }

    @Test func persistedFloorsMakeTheNextCheckANoUpdateWithoutBlobFetches() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let first = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                 clock: { TestClock().now })
        #expect(await first.check().verdict.verdict == "accept")
        let before = UpdateFixtures.tree(store)
        let relaunched = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                      clock: { TestClock().now })
        let again = await relaunched.check()
        #expect(again.verdict == UpdateVerdict(verdict: "no_update", stage: "index", reason: "already_applied"))
        #expect(UpdateHostProtocol.paths(host).count == 5 + 2)
        #expect(UpdateFixtures.tree(store) == before)
    }

    struct FloorCase: Sendable, CustomStringConvertible {
        let floors: [Int64]
        let stage: String
        let reason: String
        var description: String { reason }
    }

    @Test(arguments: [FloorCase(floors: [1, 6, 10], stage: "index", reason: "index_rollback"),
                      FloorCase(floors: [1, 4, 12], stage: "index", reason: "bundle_rollback"),
                      FloorCase(floors: [3, 4, 10], stage: "keys", reason: "keys_rollback")])
    func rollbackBelowPersistedFloorIsRejected(_ entry: FloorCase) async throws {
        let (floors, stage, reason) = (entry.floors, entry.stage, entry.reason)
        let store = try seededStore()
        defer { cleanup(store) }
        var state = UpdateState(installID: "TEST-install-0001")
        state.keysVersion = floors[0]; state.indexSequence = floors[1]; state.bundleVersion = floors[2]
        try store.saveState(state)
        let before = UpdateFixtures.tree(store)
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now })
        let result = await client.check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: stage, reason: reason))
        #expect(UpdateFixtures.tree(store) == before)
        let after = try #require(try store.loadState())
        // keys-2 verified unless the keys floor itself refused it; nothing else moves.
        let keys = stage == "keys" ? floors[0] : max(floors[0], 2)
        #expect([after.keysVersion, after.indexSequence, after.bundleVersion] == [keys, floors[1], floors[2]])
    }

    @Test func persistedFloorsBelowTheCompiledBaselineAreRaised() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.saveState(UpdateState(installID: "TEST-install-0001"))
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route(["/keys.json": .fail(.cannotConnectToHost)]))
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now })
        _ = await client.check()
        let state = try #require(try store.loadState())
        #expect([state.keysVersion, state.indexSequence, state.bundleVersion] == [1, 4, 10])
    }

    @Test func redirectToAnotherHostIsRefusedAndNeverFollowed() async throws {
        let (target, targetSession) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { targetSession.invalidateAndCancel() }
        for destination in ["https://\(target)/channels/stable.json", "http://\(target)/channels/stable.json"] {
            let store = try seededStore()
            defer { cleanup(store) }
            let before = UpdateFixtures.tree(store)
            let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route(["/keys.json": .redirect(destination)]))
            defer { session.invalidateAndCancel() }
            let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                      clock: { TestClock().now })
            let start = ContinuousClock.now
            let result = await client.check()
            #expect(ContinuousClock.now - start < .seconds(2))
            #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "fetch", reason: "redirect_refused"))
            #expect(UpdateHostProtocol.paths(host) == ["/keys.json"])
            #expect(UpdateFixtures.tree(store) == before)
        }
        #expect(UpdateHostProtocol.requests(target).isEmpty)
    }

    @Test(arguments: ["http://updates.test/", "https://user:secret@updates.test/", "https://updates.test/?a=1",
                      "https://updates.test/#x"])
    func nonHTTPSOrCredentialedHostsAreRefusedBeforeAnyRequest(_ address: String) async throws {
        let store = try seededStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        var configuration = UpdateFixtures.configuration(host: host)
        configuration.baseURL = try #require(URL(string: address))
        let client = UpdateClient(configuration: configuration, store: store, session: session, clock: { TestClock().now })
        let result = await client.check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "fetch", reason: "invalid_host"))
        #expect(UpdateHostProtocol.requests("updates.test").isEmpty && UpdateHostProtocol.requests(host).isEmpty)
    }

    @Test func boxPlatformAndBadChannelAreCallerErrorsWithoutRequests() async throws {
        for (platform, channel) in [("box", "stable"), ("ios", "../stable"), ("ios", "")] {
            let store = UpdateFixtures.temporaryStore()
            defer { cleanup(store) }
            let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
            defer { session.invalidateAndCancel() }
            var configuration = UpdateFixtures.configuration(host: host, platform: platform)
            configuration.channel = channel
            let client = UpdateClient(configuration: configuration, store: store, session: session, clock: { TestClock().now })
            #expect(await client.check().verdict == UpdateVerdict(verdict: "reject", stage: "config", reason: "invalid_configuration"))
            #expect(UpdateHostProtocol.requests(host).isEmpty)
        }
    }

    @Test func staleSinceIsTheExpiryOfTheLastVerifiedIndexWhileTheHostIsDown() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let up = UpdateHostProtocol.serve(UpdateFixtures.route())
        let down = UpdateHostProtocol.serve(UpdateFixtures.route(["/keys.json": .fail(.notConnectedToInternet)]))
        defer { up.session.invalidateAndCancel(); down.session.invalidateAndCancel() }
        let clock = TestClock()
        let online = UpdateClient(configuration: UpdateFixtures.configuration(host: up.host), store: store,
                                  session: up.session, clock: { clock.now })
        #expect(await online.check().verdict.verdict == "accept")
        let applied = UpdateFixtures.tree(store)
        let offline = UpdateClient(configuration: UpdateFixtures.configuration(host: down.host), store: store,
                                   session: down.session, clock: { clock.now })
        clock.set("2026-10-21T12:00:00Z")
        let early = await offline.check()
        #expect(early.verdict.reason == "unreachable" && early.status.staleSince == nil)
        clock.set("2026-10-27T00:00:00Z")
        let late = await offline.check()
        #expect(late.verdict.reason == "unreachable")
        #expect(late.status.staleSince == "2026-10-26T00:00:00Z")
        #expect(late.status.current?.bundleVersion == 11)
        #expect(UpdateFixtures.tree(store) == applied)
        // The host returns serving the same, now expired, index: still stale, still running bundle 11.
        let expired = await online.check()
        #expect(expired.verdict == UpdateVerdict(verdict: "reject", stage: "index", reason: "index_expired"))
        #expect(expired.status.staleSince == "2026-10-26T00:00:00Z")
        #expect(store.component("policy") == UpdateFixtures.blob("policy"))
    }

    @Test func firstLaunchOfflineStoresNothingButState() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route(["/keys.json": .fail(.cannotConnectToHost)]))
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now })
        let result = await client.check()
        #expect(result.status.current == nil && result.status.previous == nil)
        #expect(Set(UpdateFixtures.tree(store).keys).isEmpty)
        #expect(try store.loadState()?.failingSince == "2026-10-20T12:00:00Z")
    }

    @Test func launchCheckThenRepeatsOnTheIntervalUntilStopped() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host, interval: 0.05), store: store,
                                  session: session, clock: { TestClock().now })
        await client.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while UpdateHostProtocol.paths(host).filter({ $0 == "/channels/stable.json" }).count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await client.stop()
        #expect(UpdateHostProtocol.paths(host).filter { $0 == "/channels/stable.json" }.count >= 3)
        #expect(store.record()?.bundleVersion == 11)
    }

    @Test func checkIfDueWaitsForTheInterval() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let clock = TestClock()
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { clock.now })
        #expect(await client.checkIfDue()?.verdict.verdict == "accept")
        clock.advance(3600)
        #expect(await client.checkIfDue() == nil)
        clock.advance(5 * 3600 + 1)
        #expect(await client.checkIfDue()?.verdict.reason == "already_applied")
    }
}
