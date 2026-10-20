import Foundation
import Testing
@testable import SwarmHubCore

/// P6b: the one resolution of bundle-configurable app settings (`AppConfig`) that the Mac and iOS apps share, against
/// the shared vectors `config/app-config.json` (also checked by `scripts/test_app_config.py` through the Python
/// reference). No bundle, a wrong type, a value out of limits, a kill switch or an unreachable host: compiled values.
struct AppConfigTests {
    static let catalog: [String: JCS.Value] = {
        guard case .object(let root)? = try? JCS.parse(UpdateFixtures.data("config/app-config.json")) else { return [:] }
        return root
    }()
    static var cases: [[String: JCS.Value]] { ConfigVectors.objects(catalog["cases"]) }

    func check(_ store: UpdateStore, route: @escaping UpdateHostProtocol.Route) async -> UpdateCheckResult {
        let (host, session) = UpdateHostProtocol.serve(route)
        defer { session.invalidateAndCancel() }
        let clock = TestClock()
        let client = UpdateClient(configuration: UpdateFixtures.configuration(host: host), store: store,
                                  session: session, clock: { clock.now })
        return await client.check()
    }

    @Test func everySharedCaseResolvesToItsSnapshotAndReports() throws {
        #expect(Self.cases.map { ConfigVectors.string($0["id"]) ?? "" }
                == ["no-bundle", "release-policy", "bundle", "wrong-type", "out-of-range", "kill-switch", "denied"])
        for vector in Self.cases {
            let id = ConfigVectors.string(vector["id"]) ?? "?"
            let store = try ConfigVectors.store(for: ConfigVectors.objects(vector["components"]))
            defer { try? FileManager.default.removeItem(at: store.root) }
            let log = ReportLog()
            let config = ConfigStore(updates: store, log: { log.append($0) })
            let resolved = AppConfig(config)
            #expect(JCS.Value.object(resolved.snapshot) == vector["snapshot"], "\(id)")
            #expect(JCS.Value.array(config.reports.map(ConfigVectors.json)) == vector["reports"], "\(id)")
            #expect(log.reports == config.reports, "\(id): each fallback is logged once")
            // The same bytes through the loader both apps call give the same values.
            #expect(AppConfig.load(root: store.root, log: { _ in }) == resolved, "\(id)")
        }
    }

    /// The snapshot of today's compiled values, written out, so a changed default cannot hide in the fixtures.
    @Test func noBundleResolvesToTodaysCompiledValues() throws {
        let noBundle = try #require(Self.cases.first { $0["id"] == .string("no-bundle") })
        #expect(JCS.Value.object(AppConfig.compiled.snapshot) == noBundle["snapshot"])
        #expect(AppConfig(ConfigStore(log: { _ in })) == .compiled)
        let compiled = AppConfig.compiled
        #expect(compiled.codingOrder == "claude,codex,hermes")
        #expect(compiled.conversationModel == nil && compiled.codingModel == nil)
        #expect(compiled.teamActions == ["assign", "reportResult", "requestHelp", "requestReview"])
        let limits = compiled.teamLimits
        #expect([limits.tasks, limits.reviewRounds, limits.handoffDepth, limits.operations, limits.parallelTasks,
                 limits.activeSeconds] == [12, 2, 3, 48, 1, 1800])
        #expect(compiled.managerTemplate == nil && compiled.managerTemplateOpenClaw == nil && compiled.managerRecipes.isEmpty)
        let prompt = compiled.botPrompt
        #expect(prompt.owner == "the user" && prompt.role == "Personal assistant" && prompt.coordinator == "automatic")
        #expect(prompt.language == "Match the user's current language; follow an explicit language preference.")
        #expect(prompt.quietHoursStart == 22 * 60 && prompt.quietHoursEnd == 8 * 60)
        #expect(compiled.setupTitle == "Bring your agents.")

        // No store at all: compiled, and loading never creates one.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppConfigTests-\(UUID().uuidString)")
        #expect(AppConfig.load(root: root, log: { _ in }) == .compiled)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func fetchedBundleChangesValuesWithoutABuildAndUnreachableHostChangesNothing() async throws {
        let store = UpdateFixtures.temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let down = await check(store, route: { _ in .fail(.cannotConnectToHost) })
        #expect(down.verdict.reason == "unreachable")
        #expect(AppConfig.load(root: store.root, log: { _ in }) == .compiled)

        // Signed bundle 12 (TEST keys) sets codingOrder and an `approvers` list the §4 denylist refuses.
        let fetched = await check(store, route: { ConfigStoreBundleTests.bundle12Route($0) })
        #expect(fetched.verdict.verdict == "accept" && fetched.verdict.bundleVersion == 12)
        let log = ReportLog()
        let resolved = AppConfig.load(root: store.root, log: { log.append($0) })
        var expected = AppConfig.compiled
        expected.codingOrder = "codex,claude,hermes"
        #expect(resolved == expected)
        #expect(log.reports == [ConfigReport(reason: "denied_key", domain: "policy", key: "approvers", component: "app-config")])

        let again = await check(store, route: { _ in .fail(.cannotConnectToHost) })
        #expect(again.verdict.reason == "unreachable")
        #expect(AppConfig.load(root: store.root, log: { _ in }) == resolved)
    }

    @Test func everyKeyPassesTheDenylistAndMatchesTheSharedKeyList() {
        let listed = ConfigVectors.objects(Self.catalog["keys"]).map {
            (ConfigVectors.string($0["domain"]) ?? "") + "." + (ConfigVectors.string($0["key"]) ?? "")
        }
        #expect(listed == AppConfigKeys.names)
        for name in AppConfigKeys.names {
            let key = String(name.split(separator: ".", maxSplits: 1)[1])
            #expect(ConfigDecoder.nameProblem(key) == nil, "\(name)")
        }
        // Approval rules are not configurable at all: such a name never reaches a key.
        #expect(ConfigDecoder.nameProblem("botPrompt.approvalRules") == "denied_key")
        // Compiled values sit inside their own limits.
        #expect(AppConfigKeys.codingOrders.contains(AppConfig.compiled.codingOrder))
        #expect(AppConfigKeys.coordinators.contains(AppConfig.compiled.botPrompt.coordinator))
        let ranges = AppConfigKeys.teamLimitRanges, limits = AppConfig.compiled.teamLimits
        #expect(ranges["tasks"]!.contains(Int64(limits.tasks)) && ranges["activeSeconds"]!.contains(Int64(limits.activeSeconds)))
        #expect(AppConfigKeys.usableID("TEST-model/v1:free") && !AppConfigKeys.usableID("two words") && !AppConfigKeys.usableID(""))
    }

    @Test func explicitModelPreferencesBeatBundleDefaultsForBothRoles() throws {
        let vector = try #require(Self.cases.first { $0["id"] == .string("bundle") })
        let store = try ConfigVectors.store(for: ConfigVectors.objects(vector["components"]))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bundled = AppConfig.load(root: store.root, log: { _ in })
        let local = AppConfig.ModelPair(provider: "TEST-local", model: "TEST-choice")
        for role in [AppConfig.ModelRole.conversation, .coding] {
            #expect(AppConfig.compiled.modelDefault(for: role) == nil)
            #expect(AppConfig.compiled.modelDefault(for: role, preference: .agentDefault) == nil)
            #expect(AppConfig.compiled.modelDefault(for: role, preference: .choice(local)) == local)
            #expect(bundled.modelDefault(for: role, preference: .agentDefault) == nil)
            #expect(bundled.modelDefault(for: role, preference: .choice(local)) == local)
        }
        #expect(bundled.modelDefault(for: .conversation) == bundled.conversationModel)
        #expect(bundled.modelDefault(for: .coding) == bundled.codingModel)
        #expect(bundled.conversationModel != nil && bundled.codingModel != nil)
    }
}
