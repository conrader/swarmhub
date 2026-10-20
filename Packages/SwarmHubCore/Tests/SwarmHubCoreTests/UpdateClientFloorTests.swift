import Foundation
import Testing
@testable import SwarmHubCore

/// What is on disk at one instant: the persisted bundle floor and the current bundle. A kill at that instant
/// leaves exactly this behind.
final class DiskProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[Int64]] = []
    private let store: UpdateStore
    init(_ root: URL) { store = UpdateStore(root: root) }
    func capture() {
        let row = [(try? store.loadState())?.bundleVersion ?? -1, store.record()?.bundleVersion ?? -1]
        lock.withLock { rows.append(row) }
    }
    var seen: [[Int64]] { lock.withLock { rows } }
}

/// P4a review fixes: floors reach disk before the switch, a verified key manifest is kept after a later
/// failure, and skipped components keep their installed version. Bundle 12, its index and key manifest 3 are
/// re-signed at test time with TEST keys; the fixture files are not changed.
struct UpdateClientFloorTests {
    typealias Reply = UpdateHostProtocol.Reply

    func cleanup(_ store: UpdateStore) { try? FileManager.default.removeItem(at: store.root) }

    func client(_ host: String, _ session: URLSession, _ store: UpdateStore, platform: String = "ios") -> UpdateClient {
        UpdateClient(configuration: UpdateFixtures.configuration(host: host, platform: platform), store: store,
                     session: session, clock: { TestClock().now })
    }

    func floors(_ store: UpdateStore) throws -> [Int64] {
        let state = try #require(try store.loadState())
        return [state.keysVersion, state.indexSequence, state.bundleVersion]
    }

    @Test func floorsReachDiskBeforeTheSwitchSoAKillThereCannotReopenALowerBundle() async throws {
        var store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let probe = DiskProbe(store.root)
        let manifest12 = UpdateFixtures.manifest(12)
        let index12 = UpdateFixtures.index(seq: 6, version: 12, manifest: manifest12)
        let up = UpdateHostProtocol.serve(UpdateFixtures.route(["/channels/stable.json": .body(index12),
                                                                "/bundles/12.json": .body(manifest12)]))
        defer { up.session.invalidateAndCancel() }
        // 10 -> 12, killed at the switch: after the floor write, before `current` moves.
        store.beforeSwitch = { probe.capture(); throw TestStop() }
        let killed = await client(up.host, up.session, store).check()
        #expect(killed.verdict == UpdateVerdict(verdict: "reject", stage: "store", reason: "storage_error"))
        #expect(probe.seen == ([[12, 10]] as [[Int64]]))
        #expect(try floors(store) == ([2, 6, 12] as [Int64]))
        #expect(try store.loadState()?.pendingBundle == 12)
        #expect(store.record()?.bundleVersion == 10)
        let stopped = UpdateFixtures.tree(store)

        // A mirror replaying bundle 11, under a newer index or the old one, is refused and nothing switches.
        let replay = UpdateFixtures.index(seq: 7, version: 11, manifest: UpdateFixtures.data("bundles/11.json"))
        let replays: [(Reply, String)] = [(.body(replay), "bundle_rollback"),
                                          (.body(UpdateFixtures.data("channels/stable.json")), "index_rollback")]
        for (reply, reason) in replays {
            let mirror = UpdateHostProtocol.serve(UpdateFixtures.route(["/channels/stable.json": reply]))
            defer { mirror.session.invalidateAndCancel() }
            let result = await client(mirror.host, mirror.session, UpdateStore(root: store.root)).check()
            #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "index", reason: reason))
            #expect(!UpdateHostProtocol.paths(mirror.host).contains("/bundles/11.json"))
            #expect(UpdateFixtures.tree(store) == stopped)
            #expect(try floors(store) == ([2, 6, 12] as [Int64]))
        }

        // The host serving 12 again: exactly the interrupted bundle is applied; the floor never sat below current.
        var resumed = UpdateStore(root: store.root)
        resumed.afterSwitch = { probe.capture() }
        let result = await client(up.host, up.session, resumed).check()
        #expect(result.verdict.verdict == "accept" && result.verdict.bundleVersion == 12)
        #expect(probe.seen == ([[12, 10], [12, 12]] as [[Int64]]))
        #expect(store.record()?.bundleVersion == 12 && store.record(.previous)?.bundleVersion == 10)
        #expect(try floors(store) == ([2, 6, 12] as [Int64]))
        #expect(try store.loadState()?.pendingBundle == nil)
        // Applied and recorded: the same index is now an ordinary no_update.
        #expect(await client(up.host, up.session, UpdateStore(root: store.root)).check().verdict.reason == "already_applied")
    }

    @Test func aFailedFloorWriteNeverReachesTheSwitch() async throws {
        var store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let before = UpdateFixtures.tree(store)
        let probe = DiskProbe(store.root)
        store.beforeSwitch = { probe.capture() }
        store.beforeStateWrite = { state in if state.pendingBundle != nil { throw TestStop() } }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let result = await client(host, session, store).check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "store", reason: "storage_error"))
        #expect(probe.seen.isEmpty)
        #expect(UpdateFixtures.tree(store) == before)
        #expect(result.status.current?.bundleVersion == 10)
        // The key manifest's floor was written before the index was fetched; the bundle floor never was.
        #expect(try floors(store) == ([2, 4, 10] as [Int64]))
        #expect(try store.loadState()?.pendingBundle == nil)
    }

    @Test(arguments: ["unknown_key", "http_404"])
    func aVerifiedKeyRevocationSurvivesALaterFailure(_ reason: String) async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let before = UpdateFixtures.tree(store)
        // Key manifest 3 drops TEST-release-1. The index it is served with is signed by that key, or missing.
        var overrides: [String: Reply] = ["/keys.json": .body(UpdateFixtures.keysRevokingRelease1())]
        if reason == "http_404" { overrides["/channels/stable.json"] = .status(404) }
        let revoking = UpdateHostProtocol.serve(UpdateFixtures.route(overrides))
        let mirror = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { revoking.session.invalidateAndCancel(); mirror.session.invalidateAndCancel() }
        let first = await client(revoking.host, revoking.session, store).check()
        #expect(first.verdict == UpdateVerdict(verdict: "reject", stage: reason == "http_404" ? "fetch" : "index", reason: reason))
        #expect(try floors(store) == ([3, 4, 10] as [Int64]))
        // Relaunched against a mirror still serving keys-2 (which lists the dropped key) and the index it signed.
        let replay = await client(mirror.host, mirror.session, UpdateStore(root: store.root)).check()
        #expect(replay.verdict == UpdateVerdict(verdict: "reject", stage: "keys", reason: "keys_rollback"))
        #expect(!UpdateHostProtocol.paths(mirror.host).contains("/bundles/11.json"))
        #expect(UpdateFixtures.tree(store) == before && store.record()?.bundleVersion == 10)
        #expect(try floors(store) == ([3, 4, 10] as [Int64]))
    }

    @Test(arguments: ["ios", "mac"])
    func aSkippedComponentKeepsItsInstalledVersion(_ platform: String) async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let first = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { first.session.invalidateAndCancel() }
        #expect(await client(first.host, first.session, store, platform: platform).check().verdict.bundleVersion == 11)
        // Bundle 12 moves routine-card to 1.1.0 for a UI catalogue this build lacks: skipped, `incompatible`.
        let manifest12 = UpdateFixtures.manifest(12, component: "routine-card") { component in
            component["version"] = .string("1.1.0")
            component["requires"] = .object(["ui_catalog": .string(">=9.0")])
        }
        let route = UpdateFixtures.route(["/channels/stable.json": .body(UpdateFixtures.index(seq: 6, version: 12, manifest: manifest12)),
                                          "/bundles/12.json": .body(manifest12)])
        let second = UpdateHostProtocol.serve(route)
        defer { second.session.invalidateAndCancel() }
        let result = await client(second.host, second.session, store, platform: platform).check()
        #expect(result.verdict.verdict == "accept" && result.verdict.bundleVersion == 12)
        #expect(result.verdict.apply == (["policy"] as [String]))
        #expect(result.verdict.skipped == ([UpdateVerdict.Skipped(name: "routine-card", reason: "incompatible")] as [UpdateVerdict.Skipped]))
        let record = try #require(store.record())
        #expect(record.bundleVersion == 12 && record.components.map(\.name) == (["policy", "routine-card"] as [String]))
        let kept = try #require(record.components.first { $0.name == "routine-card" })
        #expect(kept == store.record(.previous)?.components.first { $0.name == "routine-card" })
        #expect(kept.version == "1.0.0" && kept.sha256 == UpdateFixtures.digest("routine-card"))
        #expect(store.component("routine-card") == UpdateFixtures.blob("routine-card"))
        // The kept archive comes from the store, not the host.
        #expect(UpdateHostProtocol.paths(second.host) == (["/keys.json", "/channels/stable.json", "/bundles/12.json",
                                                          "/blobs/sha256/" + UpdateFixtures.digest("policy")] as [String]))

        // Nothing installed to keep: a fresh install of 12 stores only what it applied.
        let fresh = UpdateFixtures.temporaryStore()
        defer { cleanup(fresh) }
        #expect(await client(second.host, second.session, fresh, platform: platform).check().verdict.bundleVersion == 12)
        #expect(fresh.record()?.components.map(\.name) == (["policy"] as [String]))
        #expect(fresh.component("routine-card") == nil)
    }

    @Test func anUnreadableKeptComponentFailsClosed() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let first = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { first.session.invalidateAndCancel() }
        #expect(await client(first.host, first.session, store).check().verdict.bundleVersion == 11)
        let id = try #require(store.record().map(UpdateStore.versionID))
        let stored = store.root.appendingPathComponent("versions/\(id)/components/routine-card")
        try Data("altered\n".utf8).write(to: stored)
        let before = UpdateFixtures.tree(store)
        let manifest12 = UpdateFixtures.manifest(12, component: "routine-card") { component in
            component["requires"] = .object(["ui_catalog": .string(">=9.0")])
        }
        let second = UpdateHostProtocol.serve(UpdateFixtures.route([
            "/channels/stable.json": .body(UpdateFixtures.index(seq: 6, version: 12, manifest: manifest12)),
            "/bundles/12.json": .body(manifest12)]))
        defer { second.session.invalidateAndCancel() }
        let result = await client(second.host, second.session, store).check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "store", reason: "storage_error"))
        #expect(UpdateFixtures.tree(store) == before && store.record()?.bundleVersion == 11)
        #expect(try floors(store) == ([2, 5, 11] as [Int64]))
    }
}
