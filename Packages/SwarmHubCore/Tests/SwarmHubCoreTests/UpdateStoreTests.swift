import Foundation
import Testing
@testable import SwarmHubCore

/// P4a store: atomic switch of `current`/`previous`, failed staging, local rollback, read-time integrity.
struct UpdateStoreTests {
    func cleanup(_ store: UpdateStore) { try? FileManager.default.removeItem(at: store.root) }
    func versionDirectories(_ store: UpdateStore) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("versions").path)) ?? [])
    }

    @Test func commitsSwapCurrentToPreviousAndCollectOlderVersions() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        #expect(store.record() == nil && store.record(.previous) == nil)
        try store.commit(UpdateFixtures.synthetic(10))
        #expect(store.record()?.bundleVersion == 10 && store.record(.previous) == nil)
        try store.commit(UpdateFixtures.synthetic(11))
        #expect(store.record()?.bundleVersion == 11 && store.record(.previous)?.bundleVersion == 10)
        try store.commit(UpdateFixtures.synthetic(12))
        #expect(store.record()?.bundleVersion == 12 && store.record(.previous)?.bundleVersion == 11)
        #expect(store.component("policy") == UpdateFixtures.synthetic(12).blobs["policy"])
        #expect(store.component("policy", in: .previous) == UpdateFixtures.synthetic(11).blobs["policy"])
        #expect(versionDirectories(store) == [UpdateStore.versionID(UpdateFixtures.synthetic(12).record),
                                              UpdateStore.versionID(UpdateFixtures.synthetic(11).record)])
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: store.root.appendingPathComponent("current").path)
                == "versions/" + UpdateStore.versionID(UpdateFixtures.synthetic(12).record))
        #expect(!fm.fileExists(atPath: store.root.appendingPathComponent("staging").path))
        #expect(try fm.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".") }.isEmpty)
        // Re-committing the current bundle (state save lost after a switch) changes nothing.
        let before = UpdateFixtures.tree(store)
        try store.commit(UpdateFixtures.synthetic(12))
        #expect(UpdateFixtures.tree(store) == before)
    }

    @Test func failureBeforeTheSwitchLeavesCurrentAndPreviousUntouched() throws {
        var store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        try store.commit(UpdateFixtures.synthetic(11))
        let before = UpdateFixtures.tree(store)
        store.beforeSwitch = { throw TestStop() }
        #expect(throws: TestStop.self) { try store.commit(UpdateFixtures.synthetic(12)) }
        #expect(UpdateFixtures.tree(store) == before)
        #expect(store.record()?.bundleVersion == 11 && store.record(.previous)?.bundleVersion == 10)
        // A component the snapshot lacks is a storage error, also before the switch.
        store.beforeSwitch = nil
        let broken = UpdateFixtures.synthetic(12)
        #expect(throws: UpdateStoreError.storage) {
            try store.commit(UpdateSnapshot(record: broken.record, keys: broken.keys, index: broken.index,
                                            manifest: broken.manifest, blobs: [:]))
        }
        #expect(UpdateFixtures.tree(store) == before)
    }

    @Test func leftoverFromAnInterruptedCommitIsReplaced() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let next = UpdateFixtures.synthetic(11)
        let leftover = store.root.appendingPathComponent("versions").appendingPathComponent(UpdateStore.versionID(next.record))
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover.appendingPathComponent("record.json"))
        try store.commit(next)
        #expect(store.record() == next.record)
        #expect(store.component("policy") == next.blobs["policy"])
    }

    @Test func revertToPreviousSwapsWithoutTouchingFloors() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        #expect(throws: UpdateStoreError.noPrevious) { try store.revertToPrevious() }
        try store.commit(UpdateFixtures.synthetic(10))
        #expect(throws: UpdateStoreError.noPrevious) { try store.revertToPrevious() }
        // A verified bundle 11 arrives through the client; synthetic 10 becomes previous.
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now })
        #expect(await client.check().verdict.verdict == "accept")
        #expect(store.record()?.bundleVersion == 11 && store.record(.previous)?.bundleVersion == 10)
        try store.revertToPrevious()
        #expect(store.record()?.bundleVersion == 10 && store.record(.previous)?.bundleVersion == 11)
        #expect(store.component("policy") == UpdateFixtures.synthetic(10).blobs["policy"])
        // The local pin holds: floors stay at 11, so the next check does not re-apply 11 or go lower.
        let next = await client.check()
        #expect(next.verdict.reason == "already_applied")
        #expect(next.status.current?.bundleVersion == 10)
        let state = try #require(try store.loadState())
        #expect(state.bundleVersion == 11)
    }

    @Test func storedBytesAreReturnedOnlyWhileTheyMatchTheRecord() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        let snapshot = UpdateFixtures.synthetic(10)
        try store.commit(snapshot)
        #expect(store.component("policy") == snapshot.blobs["policy"])
        #expect(store.component("routine-card") == nil)
        #expect(store.component("../record.json") == nil)
        let file = store.root.appendingPathComponent("versions").appendingPathComponent(UpdateStore.versionID(snapshot.record))
            .appendingPathComponent("components/policy")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: file)
        #expect(store.component("policy") == nil)
    }

    @Test func slotLinksOutsideTheVersionsDirectoryAreIgnored() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent("current").path,
                                                   withDestinationPath: "/etc")
        #expect(store.record() == nil)
        #expect(store.component("hosts") == nil)
    }

    @Test func unreadableStateRefusesToCheckAndKeepsTheStoredBundle() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        try Data("{not json".utf8).write(to: store.root.appendingPathComponent("state.json"))
        #expect(throws: UpdateStoreError.unreadableState) { try store.loadState() }
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now })
        let result = await client.check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "store", reason: "state_unreadable"))
        #expect(UpdateHostProtocol.requests(host).isEmpty)
        #expect(result.status.current?.bundleVersion == 10)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("state.json")) == Data("{not json".utf8))
    }

    @Test func failedPostApplyCheckKeepsTheStoredBundleAndFloors() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        try store.commit(UpdateFixtures.synthetic(10))
        let before = UpdateFixtures.tree(store)
        let (host, session) = UpdateHostProtocol.serve(UpdateFixtures.route())
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store, session: session,
                                  clock: { TestClock().now }, validate: { record, blobs in
                                      #expect(record.bundleVersion == 11 && Set(blobs.keys) == ["policy", "routine-card"])
                                      return false
                                  })
        let result = await client.check()
        #expect(result.verdict == UpdateVerdict(verdict: "reject", stage: "store", reason: "post_apply_check_failed"))
        #expect(UpdateFixtures.tree(store) == before)
        #expect(try store.loadState()?.bundleVersion == 10)
    }

    @Test func stateRoundTripsWithSnakeCaseKeys() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { cleanup(store) }
        var state = UpdateState(installID: "TEST-install-0001")
        state.keysVersion = 2; state.indexSequence = 5; state.bundleVersion = 11
        state.freshUntil = "2026-10-26T00:00:00Z"
        state.lastResult = UpdateVerdict(verdict: "no_update", stage: "index", reason: "already_applied")
        try store.saveState(state)
        #expect(try store.loadState() == state)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.root.appendingPathComponent("state.json"))) as? [String: Any]
        #expect(Set(raw?.keys.map { $0 } ?? []) == ["keys_version", "index_seq", "bundle_version", "install_id",
                                                     "fresh_until", "last_result"])
        #expect(state.staleSince(now: "2026-10-25T23:59:59Z") == nil)
        #expect(state.staleSince(now: "2026-10-26T00:00:00Z") == "2026-10-26T00:00:00Z")
    }
}
