import Foundation
import Testing
@testable import SwarmHubCore

private final class ComponentReads: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var names: [String] { lock.withLock { items } }
    func append(_ name: String) { lock.withLock { items.append(name) } }
}

/// Deterministic interleaving of real store switches/collection and a multi-component config read.
struct ConfigStoreSnapshotTests {
    /// One regular JSON file in an in-memory ustar. No fixture bytes are changed.
    func archive(_ domain: String, _ members: [String: JCS.Value]) throws -> Data {
        var document = members
        document["schema"] = .string("swarmhub/config-\(domain)/1")
        let body = try JCS.canonical(.object(document))
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ start: Int) {
            header.replaceSubrange(start..<start + text.utf8.count, with: text.utf8)
        }
        func octal(_ number: Int, _ width: Int) -> String {
            let digits = String(number, radix: 8)
            return String(repeating: "0", count: width - 1 - digits.count) + digits + "\0"
        }
        put(domain + ".json", 0)
        put(octal(0o644, 8), 100)
        put(octal(body.count, 12), 124)
        put("        ", 148)
        header[156] = 48
        put("ustar\0", 257)
        put("00", 263)
        put(octal(header.reduce(0) { $0 + Int($1) }, 7) + " ", 148)
        return Data(header) + body + Data(repeating: 0, count: (512 - body.count % 512) % 512 + 1024)
    }

    func snapshot(_ version: Int64, flagsFirst: Bool = false) throws -> UpdateSnapshot {
        let first = version == 12
        let blobs = [
            "policy": try archive("policy", ["codingOrder": .string(first ? "TEST-old" : "TEST-new"),
                "coding_job_limit": .integer(first ? 3 : 7), "autoRoutines": .bool(true)]),
            "flags": try archive("flags", ["routineCards": .bool(true), "kill.policy.codingOrder": .bool(first),
                "kill.view.routine_card": .bool(first)])
        ]
        let entries = (flagsFirst ? ["flags", "policy"] : ["policy", "flags"]).map { name in
            let bytes = blobs[name]!
            return UpdateRecord.Component(name: name, kind: "config", contentClass: "data", version: "1.0.0",
                                          sha256: updateDigest(bytes), size: Int64(bytes.count))
        }
        let manifest = Data("TEST snapshot \(version)".utf8)
        let record = UpdateRecord(bundleVersion: version, manifestSHA256: updateDigest(manifest),
                                  appliedAt: "2026-10-20T12:00:00Z", platform: "ios", components: entries)
        return UpdateSnapshot(record: record, keys: Data(), index: Data(), manifest: manifest, blobs: blobs)
    }

    func expectDefaults(_ config: ConfigStore) {
        #expect(config.bundleVersion == nil)
        #expect(config.value(ConfigKey<String>.policy("codingOrder", default: "compiled")) == "compiled")
        #expect(config.value(ConfigKey<Int64>.policy("coding_job_limit", default: 1)) == 1)
        #expect(!config.value(ConfigKey<Bool>.policy("autoRoutines", default: false)))
        #expect(!config.value(ConfigKey<Bool>.flag("routineCards", default: false)))
        #expect(config.value(ConfigKey<String>.copy("onboardingTitle", default: "Welcome")) == "Welcome")
        #expect(config.value(ConfigKey<String>.prompt("managerTemplate", default: "compiled")) == "compiled")
        #expect(!config.isKilled(.policy, "codingOrder") && !config.isViewKilled("routine_card"))
    }

    @Test(arguments: ["policy", "flags"])
    func switchAfterRecordOrBetweenComponentsKeepsOneBundle(_ switchBefore: String) throws {
        let writer = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: writer.root) }
        try writer.commit(snapshot(12))
        let next = try snapshot(13)
        let reads = ComponentReads()
        var reader = writer
        reader.beforeComponentRead = { name in
            reads.append(name)
            if name == switchBefore { try writer.commit(next) }
        }
        let config = ConfigStore(updates: reader, log: { _ in })
        #expect(writer.record()?.bundleVersion == 13 && config.bundleVersion == 12)
        #expect(reads.names == (["policy", "flags"] as [String]) && config.decodeReports.isEmpty)
        #expect(config.value(ConfigKey<Int64>.policy("coding_job_limit", default: 1)) == 3)
        #expect(config.isKilled(.policy, "codingOrder") && config.isViewKilled("routine_card"))
        #expect(config.value(ConfigKey<String>.policy("codingOrder", default: "compiled")) == "compiled")
        // Later snapshots follow the new bundle; the existing snapshot never re-reads the store.
        let after = ConfigStore(updates: writer, log: { _ in })
        #expect(after.bundleVersion == 13 && !after.isKilled(.policy, "codingOrder"))
        #expect(after.value(ConfigKey<Int64>.policy("coding_job_limit", default: 1)) == 7)
        #expect(config.isViewKilled("routine_card") && reads.names == (["policy", "flags"] as [String]))
    }

    @Test(arguments: ["missing", "hash", "size", "collected"])
    func failedPinnedReadDiscardsAllValuesAndKills(_ failure: String) throws {
        let writer = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: writer.root) }
        let original = try snapshot(12), next = try snapshot(13), latest = try snapshot(14)
        try writer.commit(original)
        let directory = writer.root.appendingPathComponent("versions/" + UpdateStore.versionID(original.record))
        let flags = directory.appendingPathComponent("components/flags")
        let reads = ComponentReads(), log = ReportLog()
        var reader = writer
        reader.beforeComponentRead = { name in
            reads.append(name)
            guard name == "flags" else { return }
            switch failure {
            case "collected":
                try writer.commit(next)
                try writer.commit(latest) // Collection removes 12 after its policy bytes were read.
            case "missing": try FileManager.default.removeItem(at: flags)
            case "size": try Data().write(to: flags)
            default:
                var bytes = try Data(contentsOf: flags)
                bytes[bytes.startIndex + 600] ^= 1 // Same size, wrong hash.
                try bytes.write(to: flags)
            }
        }
        let config = ConfigStore(updates: reader, log: { log.append($0) })
        expectDefaults(config)
        #expect(reads.names == (["policy", "flags"] as [String]))
        #expect(config.decodeReports == ([ConfigReport(reason: "component_unreadable", component: "flags")] as [ConfigReport]))
        #expect(config.reports == config.decodeReports && log.reports == config.decodeReports)
    }

    @Test func pinnedRecordIsReadOnlyOnce() throws {
        let writer = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: writer.root) }
        let original = try snapshot(12)
        try writer.commit(original)
        let record = writer.root.appendingPathComponent("versions/" + UpdateStore.versionID(original.record) + "/record.json")
        var reader = writer
        reader.beforeComponentRead = { name in
            if name == "policy" { try FileManager.default.removeItem(at: record) }
        }
        let config = ConfigStore(updates: reader, log: { _ in })
        #expect(config.bundleVersion == 12 && config.decodeReports.isEmpty)
        #expect(config.value(ConfigKey<Int64>.policy("coding_job_limit", default: 1)) == 3)
        #expect(config.isKilled(.policy, "codingOrder"))
    }

    @Test func failedPolicyDiscardsAlreadyReadKillFlags() throws {
        let writer = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: writer.root) }
        let original = try snapshot(12, flagsFirst: true)
        try writer.commit(original)
        let policy = writer.root.appendingPathComponent("versions/" + UpdateStore.versionID(original.record) + "/components/policy")
        let reads = ComponentReads()
        var reader = writer
        reader.beforeComponentRead = { name in
            reads.append(name)
            if name == "policy" { try FileManager.default.removeItem(at: policy) }
        }
        let config = ConfigStore(updates: reader, log: { _ in })
        expectDefaults(config)
        #expect(reads.names == (["flags", "policy"] as [String]))
        #expect(config.reports == ([ConfigReport(reason: "component_unreadable", component: "policy")] as [ConfigReport]))
    }

    @Test func missingPinnedRecordReportsWholeSnapshotFailure() throws {
        let store = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let original = try snapshot(12)
        try store.commit(original)
        let directory = store.root.appendingPathComponent("versions/" + UpdateStore.versionID(original.record))
        try FileManager.default.removeItem(at: directory)
        let log = ReportLog()
        let config = ConfigStore(updates: store, log: { log.append($0) })
        expectDefaults(config)
        #expect(config.reports == ([ConfigReport(reason: "bundle_unreadable")] as [ConfigReport]))
        #expect(log.reports == config.reports)
    }
}
