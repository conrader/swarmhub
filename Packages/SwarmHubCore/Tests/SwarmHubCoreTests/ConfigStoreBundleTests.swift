import Foundation
import Testing
@testable import SwarmHubCore

/// P6a end to end: config read from a bundle the update client fetched and verified (TEST keys, in-process
/// host), and "no bundle or unreachable host → behaviour identical to today".
struct ConfigStoreBundleTests {
    typealias Reply = UpdateHostProtocol.Reply

    /// The signed config bundle 12 from `config/` (keys and pins are the shared P0a TEST fixtures).
    static func bundle12Route(_ path: String) -> Reply {
        let file: String
        switch path {
        case "/keys.json": file = "keys/keys-2.json"
        case "/channels/stable.json": file = "config/channels/stable.json"
        case "/bundles/12.json": file = "config/bundles/12.json"
        default:
            guard path.hasPrefix("/blobs/sha256/") else { return .status(404) }
            file = "config" + path
        }
        let bytes = UpdateFixtures.data(file)
        return bytes.isEmpty ? .status(404) : .body(bytes)
    }

    /// Every read of the no-bundle vector, as JSON.
    static func compiledReads(_ config: ConfigStore) -> [JCS.Value?] {
        let vector = ConfigVectors.cases.first { $0["id"] == .string("no-bundle") } ?? [:]
        return ConfigVectors.objects(vector["reads"]).map { ConfigVectors.read(config, $0) }
    }

    func check(_ store: UpdateStore, route: @escaping UpdateHostProtocol.Route, clock: TestClock = TestClock()) async -> UpdateCheckResult {
        let (host, session) = UpdateHostProtocol.serve(route)
        defer { session.invalidateAndCancel() }
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store,
                                  session: session, clock: { clock.now })
        return await client.check()
    }

    @Test func signedBundleIsFetchedVerifiedAndRead() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        guard case .object(let vector)? = ConfigVectors.catalog["bundle"] else {
            Issue.record("config/vectors.json has no bundle vector")
            return
        }
        #expect(vector["id"] == .string("signed-bundle-12"))
        let result = await check(store, route: { Self.bundle12Route($0) })
        #expect(result.verdict.verdict == "accept" && result.verdict.bundleVersion == 12)
        #expect(result.verdict.apply == ["app-config"])
        // The box-only config component is neither fetched nor stored, so it can never become app config.
        #expect(store.record()?.components.map(\.name) == ["app-config"])
        let log = ReportLog()
        let config = ConfigStore(updates: store, log: { log.append($0) })
        #expect(config.bundleVersion == 12)
        ConfigVectors.check(config, vector, log: log)

        // The host goes away: the installed bundle and every value stay as they were.
        let before = ConfigVectors.objects(vector["reads"]).map { ConfigVectors.read(config, $0) }
        let unreachable = await check(store, route: { _ in .fail(.cannotConnectToHost) })
        #expect(unreachable.verdict.stage == "fetch" && unreachable.verdict.reason == "unreachable")
        let after = ConfigStore(updates: store, log: { _ in })
        #expect(ConfigVectors.objects(vector["reads"]).map { ConfigVectors.read(after, $0) } == before)
        #expect(after.isViewKilled("routine_card") && after.bundleVersion == 12)
    }

    @Test func noBundleOrUnreachableHostIsTodaysBehaviour() async throws {
        let compiled = ConfigStore()
        #expect(compiled.bundleVersion == nil && compiled.reports.isEmpty)
        let expected = Self.compiledReads(compiled)
        #expect(!expected.isEmpty && !expected.contains(nil))

        // A store that never had a bundle.
        let empty = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: empty.root) }
        let none = ConfigStore(updates: empty, log: { _ in })
        #expect(Self.compiledReads(none) == expected && none.reports.isEmpty && none.bundleVersion == nil)
        #expect(!FileManager.default.fileExists(atPath: empty.root.path))  // reading never creates the store

        // An unreachable host on first launch: nothing installed, every value compiled, nothing logged.
        let result = await check(empty, route: { _ in .fail(.cannotConnectToHost) })
        #expect(result.verdict.verdict == "reject" && result.verdict.reason == "unreachable")
        #expect(empty.record() == nil)
        let log = ReportLog()
        let unreachable = ConfigStore(updates: empty, log: { log.append($0) })
        #expect(Self.compiledReads(unreachable) == expected)
        #expect(unreachable.reports.isEmpty && log.reports.isEmpty && !unreachable.isViewKilled("routine_card"))
    }

    @Test func documentWithoutSchemaInAVerifiedBundleFallsBack() async throws {
        // P0a bundle 11 ships `policy` to apps as a bare JSON object with no `schema`: refused as a whole.
        let store = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let result = await check(store, route: UpdateFixtures.route())
        #expect(result.verdict.verdict == "accept" && store.record()?.bundleVersion == 11)
        let config = ConfigStore(updates: store, log: { _ in })
        #expect(config.decodeReports == [ConfigReport(reason: "schema_invalid", domain: "policy", component: "policy")])
        #expect(config.value(ConfigKey<Int64>.policy("coding_job_limit", default: 1)) == 1)
        #expect(config.value(ConfigKey<String>.policy("default_model", default: "")) == "")
    }
}
