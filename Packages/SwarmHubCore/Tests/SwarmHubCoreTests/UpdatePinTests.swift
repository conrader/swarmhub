import Foundation
import CryptoKit
import Testing
@testable import SwarmHubCore

/// P8a on the Swift client: the local pin (CORE-PLAN §2.2) and the two channel drills (§8 step 8). Bundles 12
/// and 13 are bundle 11's signed body re-signed at those versions (what `republish` does), and key manifests 3
/// and 4 are re-signed by TEST-root-1; TEST-release-2's seed is derived as SCHEMAS.md §11. The fixture files are
/// not changed. Python parity: scripts/release/drill.py runs the same scenarios (drill_world.App).
struct UpdatePinTests {
    typealias Reply = UpdateHostProtocol.Reply

    func cleanup(_ store: UpdateStore) { try? FileManager.default.removeItem(at: store.root) }

    func floors(_ store: UpdateStore) throws -> [Int64] {
        let state = try #require(try store.loadState())
        return [state.keysVersion, state.indexSequence, state.bundleVersion]
    }

    /// A client on a fresh host serving `overrides` over the valid chain. All state lives in the store.
    func withClient<T>(_ store: UpdateStore, _ overrides: [String: Reply] = [:],
                       _ body: (UpdateClient) async throws -> T) async rethrows -> T {
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route(overrides))
        defer { session.invalidateAndCancel() }
        return try await body(UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store,
                                           session: session, clock: { TestClock().now }))
    }

    func check(_ store: UpdateStore, _ overrides: [String: Reply] = [:]) async -> UpdateCheckResult {
        await withClient(store, overrides) { await $0.check() }
    }

    /// Bundle `version` (bundle 11's content) and an index at `seq` naming it, both signed by `signer`.
    func offering(_ version: Int64, seq: Int64, signer: String = "TEST-release-1", keys: Data? = nil) -> [String: Reply] {
        var signed = UpdateFixtures.signedObject("bundles/11.json")
        signed["version"] = .integer(version)
        let manifest = RotationKeys.envelope(signed, by: signer)
        var index = UpdateFixtures.signedObject("channels/stable.json")
        index["seq"] = .integer(seq)
        if case .array(let lines)? = index["lines"], case .object(var line)? = lines.first {
            line["bundle_version"] = .integer(version)
            line["manifest_sha256"] = .string(updateDigest(manifest))
            index["lines"] = .array([.object(line)])
        }
        var replies: [String: Reply] = ["/channels/stable.json": .body(RotationKeys.envelope(index, by: signer)),
                                        "/bundles/\(version).json": .body(manifest)]
        if let keys { replies["/keys.json"] = .body(keys) }
        return replies
    }

    // MARK: Local pin

    @Test func pinPreviousHoldsAndClearingReturnsToTheNewest() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        #expect(await check(store).verdict.bundleVersion == 11)
        let pinned = try await withClient(store) { try await $0.pin(.previous) }
        #expect(pinned.current?.bundleVersion == 10 && pinned.previous?.bundleVersion == 11)
        #expect(pinned.pin?.mode == .previous && pinned.pin?.bundleVersion == 11)
        #expect(try floors(store) == [2, 5, 11], "a pin never lowers a floor")
        // A newer bundle verifies and raises the index floor, but nothing is stored.
        let held = await check(store, offering(12, seq: 6))
        #expect(held.verdict == UpdateVerdict(verdict: "no_update", stage: "pin", reason: "pinned", bundleVersion: 12))
        #expect(held.status.current?.bundleVersion == 10 && held.status.staleSince == nil)
        #expect(try floors(store) == [2, 6, 11])
        // Pinning again (either mode) does not swap back: the store is already on the previous bundle.
        let again = try await withClient(store) { try await $0.pin(.current) }
        let thrice = try await withClient(store) { try await $0.pin(.previous) }
        #expect(again.current?.bundleVersion == 10 && thrice.current?.bundleVersion == 10)
        #expect(thrice.pin?.mode == .previous && thrice.pin?.bundleVersion == 11)
        // Clearing checks first: the newer bundle 12 is applied directly, 10 stays previous.
        let cleared = try await withClient(store, offering(12, seq: 6)) { try await $0.clearPin() }
        #expect(cleared.verdict.verdict == "accept" && cleared.status.pin == nil)
        #expect(cleared.status.current?.bundleVersion == 12 && cleared.status.previous?.bundleVersion == 10)
        #expect(try floors(store) == [2, 6, 12])
    }

    @Test func clearingWithNothingNewerReturnsToTheBundleAtTheFloor() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        _ = await check(store)
        _ = try await withClient(store) { try await $0.pin(.previous) }
        let cleared = try await withClient(store) { try await $0.clearPin() }
        #expect(cleared.verdict.reason == "already_applied" && cleared.status.pin == nil)
        #expect(cleared.status.current?.bundleVersion == 11 && cleared.status.previous?.bundleVersion == 10)
        #expect(store.component("policy") == UpdateFixtures.blob("policy"))
        // Host down while clearing: same outcome, the stored bundle at the floor is current again.
        _ = try await withClient(store) { try await $0.pin(.previous) }
        let offline = try await withClient(store, ["/keys.json": .fail(.cannotConnectToHost)]) { try await $0.clearPin() }
        #expect(offline.verdict.stage == "fetch" && offline.status.current?.bundleVersion == 11)
        #expect(try floors(store) == [2, 5, 11])
    }

    @Test func aClearInterruptedBeforeItsCheckIsCompletedByTheNextCheck() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        _ = await check(store)
        _ = try await withClient(store) { try await $0.pin(.previous) }
        // What clearPin writes before its check; the app is killed right after.
        var state = try #require(try store.loadState())
        state.pin = nil
        state.restoreBundle = 11
        try store.saveState(state)
        #expect(store.record()?.bundleVersion == 10)
        let next = await check(store)
        #expect(next.verdict.reason == "already_applied" && next.status.current?.bundleVersion == 11)
        #expect(try store.loadState()?.restoreBundle == nil)
    }

    @Test func pinCurrentHoldsUntilCleared() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        _ = await check(store)
        let pinned = try await withClient(store) { try await $0.pin(.current) }
        #expect(pinned.current?.bundleVersion == 11 && pinned.pin?.mode == .current)
        let held = await check(store, offering(12, seq: 6))
        #expect(held.verdict.reason == "pinned" && held.status.current?.bundleVersion == 11)
        let reloaded = try #require(try store.loadState())
        #expect(reloaded.pin == pinned.pin, "the pin survives a relaunch")
        let cleared = try await withClient(store, offering(12, seq: 6)) { try await $0.clearPin() }
        #expect(cleared.status.current?.bundleVersion == 12 && cleared.status.previous?.bundleVersion == 11)
    }

    @Test func pinPreviousWithoutAPreviousBundleLeavesNoPin() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let before = UpdateFixtures.tree(store)
        do {
            _ = try await withClient(store) { try await $0.pin(.previous) }
            Issue.record("pinned previous with no previous bundle")
        } catch {
            #expect(error as? UpdateStoreError == .noPrevious)
        }
        #expect(try store.loadState()?.pin == nil && UpdateFixtures.tree(store) == before)
    }

    // MARK: Drills

    /// Drill 1: a bad bundle reaches the app, the user pins previous, the publisher republishes 11 as 13, and the
    /// app recovers without a build. A mirror replaying the index that offered 12 is refused.
    @Test func rollForwardDrillRecoversWithoutABuild() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        #expect(await check(store).verdict.bundleVersion == 11)
        let bad = offering(12, seq: 6)
        #expect(await check(store, bad).status.current?.bundleVersion == 12)
        let pinned = try await withClient(store) { try await $0.pin(.previous) }
        #expect(pinned.current?.bundleVersion == 11)
        let fixed = offering(13, seq: 7)
        #expect(await check(store, fixed).verdict.reason == "pinned")
        let recovered = try await withClient(store, fixed) { try await $0.clearPin() }
        #expect(recovered.verdict.verdict == "accept" && recovered.status.current?.bundleVersion == 13)
        #expect(store.component("policy") == UpdateFixtures.blob("policy"), "13 carries 11's bytes unchanged")
        #expect(try floors(store) == [2, 7, 13])
        let replay = await check(store, bad)
        #expect(replay.verdict == UpdateVerdict(verdict: "reject", stage: "index", reason: "index_rollback"))
        #expect(store.record()?.bundleVersion == 13)
    }

    /// Drill 2: release key 2 is added beside key 1, signs bundle 12, then key 1 is rotated out. An index signed by
    /// key 1 is refused, also with the old key manifest replayed; the app stays on the bundle key 2 signed.
    @Test func keyRotationDrillRefusesTheRotatedOutKey() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        _ = await check(store)
        let overlap = RotationKeys.keyManifest(3, releaseKeys: ["TEST-release-1", "TEST-release-2"])
        let rotated = RotationKeys.keyManifest(4, releaseKeys: ["TEST-release-2"])
        let second = await check(store, offering(12, seq: 6, signer: "TEST-release-2", keys: overlap))
        #expect(second.verdict.verdict == "accept" && second.status.current?.bundleVersion == 12)
        let third = await check(store, offering(13, seq: 7, signer: "TEST-release-2", keys: rotated))
        #expect(third.verdict.verdict == "accept" && third.status.current?.bundleVersion == 13)
        #expect(try floors(store) == [4, 7, 13])
        let before = UpdateFixtures.tree(store)
        let forged = await check(store, offering(14, seq: 100, signer: "TEST-release-1", keys: rotated))
        #expect(forged.verdict == UpdateVerdict(verdict: "reject", stage: "index", reason: "unknown_key"))
        let replayed = await check(store, offering(14, seq: 100, signer: "TEST-release-1", keys: overlap))
        #expect(replayed.verdict == UpdateVerdict(verdict: "reject", stage: "keys", reason: "keys_rollback"))
        #expect(UpdateFixtures.tree(store) == before && store.record()?.bundleVersion == 13)
        #expect(try floors(store) == [4, 7, 13])
    }
}

/// TEST keys from public fixed seeds (SCHEMAS.md §11), for keys the fixture listing does not carry.
enum RotationKeys {
    static func privateKey(_ keyID: String) -> Curve25519.Signing.PrivateKey? {
        let seed = Data(SHA256.hash(data: Data(("swarmhub-release-vectors/TEST-seed/" + keyID).utf8)))
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    static func publicHex(_ keyID: String) -> String {
        (privateKey(keyID)?.publicKey.rawRepresentation ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    static func envelope(_ signed: [String: JCS.Value], by keyID: String) -> Data {
        guard let key = privateKey(keyID), let canonical = try? JCS.canonical(.object(signed)),
              let signature = try? key.signature(for: Data("swarmhub-signature/1\n".utf8) + canonical) else { return Data() }
        let hex = signature.map { String(format: "%02x", $0) }.joined()
        let envelope: [String: JCS.Value] = ["signed": .object(signed),
                                             "signatures": .array([.object(["key_id": .string(keyID), "sig": .string(hex)])])]
        return (try? JCS.canonical(.object(envelope))) ?? Data()
    }

    /// `keys/keys-2.json` at `version` listing exactly `releaseKeys` (roles bundle and index), signed by TEST-root-1.
    static func keyManifest(_ version: Int64, releaseKeys: [String]) -> Data {
        var signed = UpdateFixtures.signedObject("keys/keys-2.json")
        signed["version"] = .integer(version)
        signed["keys"] = .array(releaseKeys.map { keyID -> JCS.Value in
            .object(["key_id": .string(keyID), "ed25519_pub": .string(publicHex(keyID)),
                     "roles": .array([.string("bundle"), .string("index")]), "not_after": .string("2027-01-01T00:00:00Z")])
        })
        return envelope(signed, by: "TEST-root-1")
    }
}
