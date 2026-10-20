import Foundation
import Testing
@testable import SwarmHubCore

/// Collects what `ConfigStore` logs.
final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ConfigReport] = []
    var reports: [ConfigReport] { lock.withLock { items } }
    func append(_ report: ConfigReport) { lock.withLock { items.append(report) } }
}

/// The shared P6a vectors (`Tests/Fixtures/release-bundles/config/vectors.json`, SCHEMAS.md §12), also run by
/// `scripts/test_swift_config_vectors.py` through the Python reference decoder.
enum ConfigVectors {
    static let catalog: [String: JCS.Value] = {
        guard case .object(let root)? = try? JCS.parse(UpdateFixtures.data("config/vectors.json")) else { return [:] }
        return root
    }()
    static var cases: [[String: JCS.Value]] { objects(catalog["cases"]) }

    static func objects(_ value: JCS.Value?) -> [[String: JCS.Value]] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            if case .object(let object) = item { return object }
            return nil
        }
    }

    static func string(_ value: JCS.Value?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    static func json(_ report: ConfigReport) -> JCS.Value {
        var object: [String: JCS.Value] = ["reason": .string(report.reason)]
        if let domain = report.domain { object["domain"] = .string(domain) }
        if let key = report.key { object["key"] = .string(key) }
        if let component = report.component { object["component"] = .string(component) }
        return .object(object)
    }

    /// A real store whose current bundle holds the case's components, in order. An `unreadable` component's
    /// record names a digest its stored bytes do not have, as after on-disk corruption.
    static func store(for components: [[String: JCS.Value]]) throws -> UpdateStore {
        let store = UpdateFixtures.temporaryStore()
        guard !components.isEmpty else { return store }
        var entries: [UpdateRecord.Component] = []
        var blobs: [String: Data] = [:]
        for component in components {
            let name = try #require(string(component["name"]))
            let blob = string(component["archive"]).map(UpdateFixtures.data) ?? Data("TEST unreadable\n".utf8)
            #expect(!blob.isEmpty, "\(name)")
            let sha256 = component["unreadable"] == .bool(true) ? String(repeating: "0", count: 64) : updateDigest(blob)
            entries.append(.init(name: name, kind: "config", contentClass: "data", version: "1.0.0", sha256: sha256,
                                 size: Int64(blob.count)))
            blobs[name] = blob
        }
        let manifest = Data("{\"config-vector\":true}".utf8)
        let record = UpdateRecord(bundleVersion: 12, manifestSHA256: updateDigest(manifest), appliedAt: "2026-10-20T12:00:00Z",
                                  platform: "ios", components: entries)
        try store.commit(UpdateSnapshot(record: record, keys: Data("{}".utf8), index: Data("{}".utf8), manifest: manifest,
                                        blobs: blobs))
        return store
    }

    /// One vector read through the typed key it names, returned as JSON for comparison.
    static func read(_ config: ConfigStore, _ read: [String: JCS.Value]) -> JCS.Value? {
        guard let domain = string(read["domain"]).flatMap(ConfigDomain.init(rawValue:)), let key = string(read["key"]),
              let type = string(read["type"]), let fallback = read["default"] else { return nil }
        var range: ClosedRange<Int64>? = nil
        if case .integer(let low)? = read["min"], case .integer(let high)? = read["max"] { range = low...high }
        switch (type, fallback) {
        case ("string", .string(let value)):
            let typed: ConfigKey<String>
            switch domain {
            case .policy: typed = .policy(key, default: value)
            case .prompts: typed = .prompt(key, default: value)
            default: typed = .copy(key, default: value)
            }
            return .string(config.value(typed))
        case ("bool", .bool(let value)):
            let typed: ConfigKey<Bool> = domain == .flags ? .flag(key, default: value) : .policy(key, default: value)
            return .bool(config.value(typed))
        case ("integer", .integer(let value)):
            return .integer(config.value(ConfigKey<Int64>.policy(key, default: value, range: range)))
        case ("string_list", .array(let items)):
            let value = items.compactMap { string($0) }
            return .array(config.value(ConfigKey<[String]>.policy(key, default: value)).map { .string($0) })
        case ("string_map", .object(let members)):
            let value = members.compactMapValues { string($0) }
            return .object(config.value(ConfigKey<[String: String]>.policy(key, default: value)).mapValues { .string($0) })
        case ("integer_map", .object(let members)):
            let value = members.compactMapValues { member -> Int64? in
                if case .integer(let number) = member { return number }
                return nil
            }
            return .object(config.value(ConfigKey<[String: Int64]>.policy(key, default: value, range: range))
                .mapValues { .integer($0) })
        default:
            return nil
        }
    }

    /// Decode reports exactly, every read's value and read-time reason, view kill states, and the log.
    static func check(_ config: ConfigStore, _ vector: [String: JCS.Value], log: ReportLog) {
        let id = string(vector["id"]) ?? "?"
        #expect(JCS.Value.array(config.decodeReports.map(json)) == vector["reports"], "\(id): decode reports")
        for read in objects(vector["reads"]) {
            let label = "\(id): \(string(read["domain"]) ?? "").\(string(read["key"]) ?? "") as \(string(read["type"]) ?? "")"
            let before = config.reports.count
            #expect(Self.read(config, read) == read["expect"], "\(label)")
            if let reason = string(read["report"]) {
                let report = ConfigReport(reason: reason, domain: string(read["domain"]), key: string(read["key"]))
                #expect(config.reports.contains(report), "\(label): \(reason) logged")
            } else {
                #expect(config.reports.count == before, "\(label): nothing logged")
            }
        }
        for view in objects(vector["views"]) {
            #expect(config.isViewKilled(string(view["type"]) ?? "") == (view["killed"] == .bool(true)), "\(id): view")
        }
        #expect(log.reports == config.reports, "\(id): every fallback reason logged once")
    }
}

/// The unchanged vectors describe decoder rules, including partial decode of unreadable input. Live store
/// snapshots enforce the stronger all-or-nothing integrity rule before calling that decoder.
struct ConfigStoreTests {
    @Test func everySharedDecoderVectorReadsAsExpected() throws {
        let cases = ConfigVectors.cases
        #expect(cases.count == 15)
        for vector in cases {
            let components = ConfigVectors.objects(vector["components"]).map { component in
                ConfigComponent(name: ConfigVectors.string(component["name"]) ?? "?",
                    archive: component["unreadable"] == .bool(true) ? nil
                        : ConfigVectors.string(component["archive"]).map(UpdateFixtures.data))
            }
            let log = ReportLog()
            ConfigVectors.check(ConfigStore(components: components, bundleVersion: nil, log: { log.append($0) }), vector, log: log)
        }
    }

    @Test func everyReadableSharedVectorReadsFromUpdateStore() throws {
        for vector in ConfigVectors.cases {
            let components = ConfigVectors.objects(vector["components"])
            guard !components.contains(where: { $0["unreadable"] == .bool(true) }) else { continue }
            let store = try ConfigVectors.store(for: components)
            defer { try? FileManager.default.removeItem(at: store.root) }
            let log = ReportLog()
            ConfigVectors.check(ConfigStore(updates: store, log: { log.append($0) }), vector, log: log)
        }
    }

    @Test func wrongTypeFallsBackAndIsLoggedOnceWithItsReason() throws {
        let vector = try #require(ConfigVectors.cases.first { $0["id"] == .string("wrong-type") })
        let store = try ConfigVectors.store(for: ConfigVectors.objects(vector["components"]))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let log = ReportLog()
        let config = ConfigStore(updates: store, log: { log.append($0) })
        let key = ConfigKey<String>.policy("codingOrder", default: "claude,codex,hermes")
        #expect(config.value(key) == "claude,codex,hermes")
        #expect(config.value(key) == "claude,codex,hermes")
        let reason = ConfigReport(reason: "wrong_type", domain: "policy", key: "codingOrder")
        #expect(log.reports.filter { $0 == reason }.count == 1)
        #expect(reason.description == "config fallback: wrong_type domain=policy key=codingOrder component=-")
    }

    @Test func killSwitchOnlyEverSelectsTheCompiledDefault() throws {
        let vector = try #require(ConfigVectors.cases.first { $0["id"] == .string("kill-switch") })
        let store = try ConfigVectors.store(for: ConfigVectors.objects(vector["components"]))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let config = ConfigStore(updates: store, log: { _ in })
        #expect(config.isKilled(.policy, "codingOrder") && !config.isKilled(.policy, "coding_job_limit"))
        #expect(config.isKilled(.flags, "routineCards") && !config.isKilled(.copy, "onboardingSubtitle"))
        // A killed flag reads the compiled default whichever default the app compiled in.
        #expect(config.value(ConfigKey<Bool>.flag("routineCards", default: true)) == true)
        #expect(config.value(ConfigKey<Bool>.flag("routineCards", default: false)) == false)
        #expect(config.isViewKilled("routine_card") && !config.isViewKilled("settings_pane"))
    }

    @Test func storedComponentChangedOnDiskIsNotRead() throws {
        let vector = try #require(ConfigVectors.cases.first { $0["id"] == .string("full") })
        let store = try ConfigVectors.store(for: ConfigVectors.objects(vector["components"]))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let current = try FileManager.default.destinationOfSymbolicLink(atPath: store.root.appendingPathComponent("current").path)
        let path = store.root.appendingPathComponent(current).appendingPathComponent("components/app-config")
        var bytes = try Data(contentsOf: path)
        bytes[bytes.startIndex + 600] ^= 0x01
        try bytes.write(to: path)
        let config = ConfigStore(updates: store, log: { _ in })
        #expect(config.decodeReports == ([ConfigReport(reason: "component_unreadable", component: "app-config")] as [ConfigReport]))
        #expect(config.value(ConfigKey<String>.policy("codingOrder", default: "claude,codex,hermes")) == "claude,codex,hermes")
    }
}
