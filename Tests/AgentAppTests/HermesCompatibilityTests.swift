import Foundation
import Testing
@testable import AgentApp

// P24: the Hermes version per connection, its status, and the 0.21.7+ `/v1/skills` 500 shown as a known limitation.
// `/health` and the 500 body follow Hermes `gateway/platforms/api_server.py` (v0.21.7); all values are synthetic.

@Test func hermesVersionParsesReleaseStringsAndRejectsGarbage() {
    #expect(HermesVersion.parse("0.21.7") == HermesVersion(0, 21, 7))
    #expect(HermesVersion.parse("0.22.0") == HermesVersion(0, 22, 0))
    #expect(HermesVersion.parse(" v0.21.7\n") == HermesVersion(0, 21, 7))
    #expect(HermesVersion.parse("0.22.0+fleet.1") == HermesVersion(0, 22, 0))
    #expect(HermesVersion.parse("0.22.0-rc1") == HermesVersion(0, 22, 0))
    for garbage: Any? in [nil, NSNull(), 21, "", "unknown", "0.21", "0.21.x", "1.2.3.4", "version 0.21.7", "0.21.7.1"] {
        #expect(HermesVersion.parse(garbage) == nil, "\(String(describing: garbage))")
    }
    #expect(HermesVersion(0, 21, 7).description == "0.21.7")
    #expect(HermesVersion(0, 21, 7) < HermesVersion(0, 22, 0) && HermesVersion(0, 9, 9) < HermesVersion(0, 10, 0))
}

@Test func statusLookupFollowsTheList() {
    #expect(HermesCompatibility.status(for: .init(0, 21, 7)) == .works)
    #expect(HermesCompatibility.status(for: .init(0, 20, 5)) == .works)
    #expect(HermesCompatibility.status(for: .init(0, 22, 0)) == .notTestedYet)
    #expect(HermesCompatibility.status(for: .init(0, 22, 1)) == .notTestedYet, "newer than any listed")
    #expect(HermesCompatibility.status(for: .init(0, 21, 0)) == .notTestedYet, "between listed versions")
    #expect(HermesCompatibility.status(for: .init(0, 19, 9)) == .notSupported, "older than the oldest listed")
    #expect(HermesVersionReading(raw: "0.21.7").label == "Hermes 0.21.7 · works")
    #expect(HermesVersionReading(raw: "0.22.0").label == "Hermes 0.22.0 · not tested yet")
    #expect(HermesVersionReading(raw: "0.22.1").label == "Hermes 0.22.1 · not tested yet")
    #expect(HermesVersionReading(raw: "nightly").label == "Hermes nightly · version not recognised")
    #expect(HermesVersionReading(raw: nil, problem: "HTTP 404: no route").label == "Hermes version unknown")
}

@Test func skillsBugMapsOnlyItsExactSymptomOnListedVersions() {
    let bug = BackendError.http(500, "Failed to enumerate skills")
    #expect(HermesCompatibility.limitation(for: bug, version: .init(0, 21, 7)) == .skillsEnumeration)
    #expect(HermesCompatibility.limitation(for: bug, version: .init(0, 22, 0)) == .skillsEnumeration)
    #expect(HermesCompatibility.limitation(for: bug, version: .init(0, 20, 5)) == nil, "not listed with the issue")
    #expect(HermesCompatibility.limitation(for: bug, version: .init(0, 22, 1)) == nil, "unlisted version")
    #expect(HermesCompatibility.limitation(for: bug, version: nil) == nil, "version unknown")
    #expect(HermesCompatibility.limitation(for: BackendError.http(500, "Internal Server Error"), version: .init(0, 21, 7)) == nil)
    #expect(HermesCompatibility.limitation(for: BackendError.http(502, "Failed to enumerate skills"), version: .init(0, 21, 7)) == nil)
    #expect(HermesCompatibility.limitation(for: BackendError.unavailable("Failed to enumerate skills"), version: .init(0, 21, 7)) == nil)
    #expect(HermesKnownIssue.skillsEnumeration.note == "This Hermes version can't list skills (known Hermes bug)")
}

/// `docs/hermes-versions.md` and `HermesCompatibility.versions` name the same versions, statuses and `/v1/skills` issue.
@Test func compatibilityListMirrorsTheDocs() throws {
    let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/hermes-versions.md")
    let rows = try String(contentsOf: docs, encoding: .utf8).split(separator: "\n").compactMap { line -> (HermesVersion, String, Bool)? in
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 4, let first = cells.first?.replacingOccurrences(of: "*", with: "").split(separator: " ").first,
              let version = HermesVersion.parse(String(first)) else { return nil }
        return (version, cells[2], cells[3].contains("/v1/skills"))
    }
    #expect(rows.count == HermesCompatibility.versions.count)
    for (version, status, skillsIssue) in rows {
        let entry = try #require(HermesCompatibility.entry(for: version), "\(version) is in the docs but not in the app")
        #expect(entry.status.label == status, "\(version)")
        #expect(entry.issues.contains(.skillsEnumeration) == skillsIssue, "\(version)")
    }
}

// MARK: through the Overview load

private func healthHandler(version: Any?, skillsStatus: Int, skillsMessage: String) -> MockHermesProtocol.Handler {
    let version = version as? String
    return { request in
        let path = request.url!.path
        guard path.hasPrefix("/p/grok-boppy/") else { return (404, ["error": "no route"]) }
        switch String(path.dropFirst("/p/grok-boppy".count)) {
        case "/health": return (200, ["status": "ok", "platform": "hermes-agent", "version": version ?? NSNull()] as [String: Any])
        case "/v1/capabilities": return (200, ["features": ["skills_api": true, "session_resources": false], "endpoints": ["skills": [:], "toolsets": [:]]] as [String: Any])
        case "/v1/skills":
            guard skillsStatus == 200 else { return (skillsStatus, ["error": ["message": skillsMessage, "type": "server_error"]] as [String: Any]) }
            return (200, ["object": "list", "data": [["name": "tide-check", "description": "Looks up tides."]]] as [String: Any])
        case "/v1/toolsets": return (200, ["object": "list", "data": [] as [Any]] as [String: Any])
        default: return (404, ["error": "no route"])
        }
    }
}

@MainActor private func overviewLoad(version: Any?, skillsStatus: Int = 500, skillsMessage: String = "Failed to enumerate skills") async -> (AppStore, Bot, BotServerInfo?) {
    let (host, session) = MockHermesProtocol.serve(healthHandler(version: version, skillsStatus: skillsStatus, skillsMessage: skillsMessage))
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes.grok-boppy": "boppy-key"]), defaults: defaults, hermesSession: session)
    let bot = Bot(name: "Boppy", backend: .hermes, hermesProfile: "grok-boppy")
    store.bots = [bot]
    await store.loadServerInfo(for: bot, force: true)
    return (store, bot, store.botInfo.info(for: bot.id))
}

@MainActor @Test func skills500OnAListedVersionIsAKnownLimitationNotAnError() async throws {
    let (store, bot, loaded) = await overviewLoad(version: "0.21.7")
    let info = try #require(loaded)
    #expect(info.skills == .unavailable(HermesKnownIssue.skillsEnumeration.note))
    #expect(info.knownLimitations == [.skillsEnumeration])
    #expect(!info.failedAnything && !info.lastLoadFailed, "a known limitation is not retried as a failure")
    #expect(info.toolsets.value == [])
    #expect(store.hermesVersion(for: bot)?.label == "Hermes 0.21.7 · works", "cached per connection")
    #expect(store.connectionVersionLines.map(\.reading?.label) == ["Hermes 0.21.7 · works"])

    var errors: [String] = [], limitations: [String] = []
    let report = UISmoke.overview(info, errors: &errors, limitations: &limitations)
    #expect(errors.isEmpty)
    #expect(limitations == ["overview: This Hermes version can't list skills (known Hermes bug)"])
    #expect(report["state"] as? String == "known_limitation")
    #expect((report["hermes_version"] as? [String: Any])?["raw"] as? String == "0.21.7")
}

@MainActor @Test func other500sStayErrors() async throws {
    for (version, message) in [("0.21.7", "Internal Server Error"), ("0.20.5", "Failed to enumerate skills")] as [(Any?, String)] + [(nil, "Failed to enumerate skills")] {
        let (_, _, loaded) = await overviewLoad(version: version, skillsMessage: message)
        let info = try #require(loaded)
        guard case .failed(let reason) = info.skills else { Issue.record("\(String(describing: version)) \(message): \(info.skills)"); continue }
        #expect(reason == "HTTP 500: \(message)")
        #expect(info.knownLimitations.isEmpty && info.failedAnything)
        var errors: [String] = [], limitations: [String] = []
        _ = UISmoke.overview(info, errors: &errors, limitations: &limitations)
        #expect(errors == ["overview: HTTP 500: \(message)"] && limitations.isEmpty)
    }
}

@MainActor @Test func healthySkillsLoadAndRecordTheVersion() async throws {
    let (store, bot, loaded) = await overviewLoad(version: "0.22.0", skillsStatus: 200)
    let info = try #require(loaded)
    #expect(info.skills.value?.map(\.name) == ["tide-check"] && info.knownLimitations.isEmpty)
    #expect(store.hermesVersion(for: bot)?.label == "Hermes 0.22.0 · not tested yet")
    var errors: [String] = [], limitations: [String] = []
    let report = UISmoke.overview(info, errors: &errors, limitations: &limitations)
    #expect(errors.isEmpty && limitations.isEmpty && report["state"] as? String == "loaded")
}

@MainActor @Test func settingsReadsVersionsForConnectionsTheOverviewNeverLoaded() async throws {
    let (host, session) = MockHermesProtocol.serve(healthHandler(version: "0.21.7", skillsStatus: 200, skillsMessage: ""))
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes.grok-boppy": "boppy-key"]), defaults: defaults, hermesSession: session)
    let bot = Bot(name: "Boppy", backend: .hermes, hermesProfile: "grok-boppy"), other = Bot(name: "Nokey", backend: .hermes, hermesProfile: "grok-nokey")
    store.bots = [bot, other]
    #expect(store.hermesVersion(for: bot) == nil)
    await store.loadHermesVersions()
    #expect(store.hermesVersion(for: bot)?.raw == "0.21.7")
    #expect(store.hermesVersion(for: other) == nil, "no key, no request")
    #expect(MockHermesProtocol.recorded(host).map { $0.url!.path } == ["/p/grok-boppy/health"])
    await store.loadHermesVersions()
    #expect(MockHermesProtocol.recorded(host).count == 1, "already read; Settings does not read again")
}
