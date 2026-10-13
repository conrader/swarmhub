import Foundation
import Testing
@testable import AgentApp

// MARK: Usage

/// Synthetic `GET /api/sessions` rows in the `_session_response` shape (Hermes v2026.8.19).
private func sessionRows(now: Date) -> [[String: Any]] {
    let t = now.timeIntervalSince1970
    return [
        ["id": "a", "source": "api_server", "started_at": t - 600, "ended_at": NSNull(), "message_count": 6, "input_tokens": 1_000, "output_tokens": 200, "cache_read_tokens": 50, "reasoning_tokens": 10],
        ["id": "b", "source": "telegram", "started_at": t - 3 * 86_400, "ended_at": t - 3 * 86_400 + 60, "message_count": 2, "input_tokens": 400, "output_tokens": 100],
        ["id": "c", "source": "cron", "started_at": t - 40 * 86_400, "message_count": 10, "input_tokens": 9_000, "output_tokens": 1_000],
        ["id": "d", "started_at": NSNull(), "message_count": NSNull(), "input_tokens": "70", "output_tokens": true],
        ["source": "no id"],
    ]
}

@Test func usageParsesSessionPayloads() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessions = sessionRows(now: now).compactMap(SessionUsage.parse)
    #expect(sessions.map(\.id) == ["a", "b", "c", "d"], "a row without id is skipped")
    #expect(sessions[0].startedAt == now.addingTimeInterval(-600) && sessions[0].endedAt == nil)
    #expect(sessions[0].cacheReadTokens == 50 && sessions[0].reasoningTokens == 10)
    #expect(sessions[3].messages == 0 && sessions[3].inputTokens == 70 && sessions[3].outputTokens == 0, "null → 0, numeric string read, bool is not a count")
    #expect(SessionUsage.date(1_800_000_000_000.0) == now, "milliseconds")
    #expect(SessionUsage.date("2027-01-15T08:00:00Z") == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
    #expect(SessionUsage.date("2027-01-15T08:00:00.250Z") != nil && SessionUsage.date("soon") == nil && SessionUsage.date(0) == nil)
    #expect(SessionUsage.count(-5) == 0 && SessionUsage.count(12.0) == 12)
}

@Test func usageAggregatesByWindow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessions = sessionRows(now: now).compactMap(SessionUsage.parse)
    #expect(UsageTotals.of(sessions, window: .day, now: now) == UsageTotals(sessions: 1, messages: 6, inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 50, reasoningTokens: 10))
    #expect(UsageTotals.of(sessions, window: .week, now: now) == UsageTotals(sessions: 2, messages: 8, inputTokens: 1_400, outputTokens: 300, cacheReadTokens: 50, reasoningTokens: 10))
    let all = UsageTotals.of(sessions + [sessions[0]], window: .all, now: now)
    #expect(all.sessions == 4 && all.messages == 18 && all.inputTokens == 10_470 && all.totalTokens == 11_770, "duplicate ids count once; undated sessions only in All")

    let jarvis = ProfileUsage(botNames: ["Jarvis"], profile: "grok-jarvis", server: "box", sessions: sessions)
    let doc = ProfileUsage(botNames: ["Doc"], profile: "grok-doc", server: "box", sessions: [SessionUsage(id: "x", startedAt: now.addingTimeInterval(-60), messages: 1, inputTokens: 5, outputTokens: 5)])
    let broken = ProfileUsage(botNames: ["Vised"], profile: "grok-vised", server: "box", problem: "No API key")
    #expect(ProfileUsage.total([jarvis, doc, broken], window: .day, now: now) == UsageTotals(sessions: 2, messages: 7, inputTokens: 1_005, outputTokens: 205, cacheReadTokens: 50, reasoningTokens: 10))
    #expect(ProfileUsage.compact(999) == "999" && ProfileUsage.compact(1_250) == "1.2k" && ProfileUsage.compact(3_400_000) == "3.4M")
}

@MainActor @Test func usageLoadsEveryProfilePageByPageWithGETOnly() async {
    let now = Date().timeIntervalSince1970
    let (host, session) = MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "p" else { return (404, ["error": "no route"]) }
        let route = parts[2...].joined(separator: "/")
        if route == "v1/capabilities" { return (200, ["features": ["session_chat_streaming": parts[1] != "grok-legacy"]]) }
        guard route == "api/sessions" else { return (404, ["error": "no route"]) }
        let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
        let page = offset == 0 ? [["id": "p1", "started_at": now - 60, "message_count": 2, "input_tokens": 10, "output_tokens": 5]] : [["id": "p2", "started_at": now - 120, "message_count": 1, "input_tokens": 1, "output_tokens": 1]]
        return (200, ["object": "list", "data": page, "has_more": offset == 0])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k1", "hermes.grok-legacy": "k2"]), defaults: isolatedDefaults(), hermesSession: session)
    let bots = ["grok-jarvis", "grok-jarvis", "grok-legacy", "grok-nokey"].enumerated().map { index, profile in
        let bot = Bot(name: "Bot\(index)", backend: .hermes, hermesProfile: profile); bot.hermesBaseURL = "https://\(host)/v1"; return bot
    }
    store.bots = bots + [Bot(name: "Mock", backend: .mock)]
    let rows = await store.loadUsage()
    #expect(rows.map(\.label) == ["Bot0, Bot1", "Bot2", "Bot3"], "bots sharing a profile share one row")
    #expect(rows[0].sessions.map(\.id) == ["p1", "p2"] && rows[0].problem == nil && !rows[0].truncated)
    #expect(rows[1].problem == "This Hermes server has no sessions API.")
    #expect(rows[2].problem?.contains("No API key") == true)
    let recorded = MockHermesProtocol.recorded(host)
    #expect(recorded.allSatisfy { $0.httpMethod == "GET" })
    #expect(recorded.filter { $0.url!.path.hasSuffix("api/sessions") }.map { $0.url!.query ?? "" } == ["limit=200&offset=0&include_children=true", "limit=200&offset=200&include_children=true"])
}

// MARK: Updates

@Test func versionsCompareNumerically() {
    func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }
    #expect(v("0.4.0") < v("0.10.0") && v("v0.4.1") > v("0.4") && v("1.0") == v("1.0.0") && v("V2") > v("1.99.99"))
    #expect(v("0.5.0-beta.2") < v("0.5.0") && v("0.5.0-beta.2") < v("0.5.0-beta.10") && v("0.5.0-rc.1") > v("0.4.9"))
    #expect(v("1.2.3+build.7") == v("1.2.3"))
    #expect(SemanticVersion("") == nil && SemanticVersion("latest") == nil && SemanticVersion("1..2") == nil && SemanticVersion("-1.0") == nil)
    #expect(v("v0.4.0").description == "0.4.0")
}

@Test func updateStatusFromLatestRelease() {
    let newer = ReleaseInfo.parse(["tag_name": "v0.5.0", "name": "Torvli 0.5", "html_url": "https://github.com/conrader/torvli/releases/tag/v0.5.0"])!
    #expect(newer.pageURL?.absoluteString == "https://github.com/conrader/torvli/releases/tag/v0.5.0")
    #expect(UpdateStatus.evaluate(current: "0.4.0", latest: newer) == .newer(newer))
    #expect(UpdateStatus.evaluate(current: "0.5.0", latest: newer) == .upToDate("v0.5.0"))
    #expect(UpdateStatus.evaluate(current: "0.6.0", latest: newer) == .upToDate("v0.5.0"))
    #expect(UpdateStatus.evaluate(current: "0.4.0", latest: nil) == .noReleases)
    #expect(UpdateStatus.evaluate(current: "development build", latest: newer) == .unknownVersion("v0.5.0"))
    #expect(ReleaseInfo.parse(["tag_name": "v1", "html_url": "http://evil.example/x"])?.pageURL == nil, "only https github.com links")
    #expect(ReleaseInfo.parse(["name": "no tag"]) == nil)
}

@Test func buildInfoReadsSourceTxt() {
    let info = AppBuildInfo.make(version: "0.4.0", build: "5", sourceText: "source_sha=0123456789abcdef0123456789abcdef01234567\ndirty=false\nsigning_team=ABC\n")
    #expect(info.shortSHA == "0123456789ab" && !info.dirty && info.summary == "0.4.0 (5) · 0123456789ab")
    let bare = AppBuildInfo.make(version: nil, build: nil, sourceText: "")
    #expect(bare.version == "development build" && bare.sourceSHA == nil)
    #expect(AppBuildInfo.make(version: "1", build: nil, sourceText: "source_sha=not a sha\ndirty=true").sourceSHA == nil)
}

// MARK: Computers

@Test func computerURLValidation() {
    func valid(_ text: String) -> Bool { if case .valid = ComputerURL.check(text) { true } else { false } }
    #expect(valid("https://desk.example.com/vnc.html?autoconnect=1&resize=scale"))
    #expect(valid("http://localhost:6080/vnc.html") && valid("http://127.0.0.1:6080/") && valid("http://[::1]:6080/") && valid("  https://desk.example.com  "))
    #expect(!valid("http://desk.example.com/vnc.html"), "plain http only on loopback")
    #expect(!valid("http://127.0.0.1.evil.example/") && !valid("http://localhost.evil.example/"))
    #expect(!valid("ftp://desk.example.com") && !valid("javascript:alert(1)") && !valid("file:///etc/passwd") && !valid("desk.example.com"))
    #expect(!valid("https://user:pw@desk.example.com/") && !valid("https://desk.example.com/vnc.html?password=hunter2") && !valid("https://desk.example.com/vnc.html#token=abc"))
    #expect(ComputerURL.check("") == .empty && ComputerURL.check("   ") == .empty)
    #expect(ComputerURL.validURL("https://desk.example.com")?.host == "desk.example.com" && ComputerURL.validURL(nil) == nil)
}

@MainActor @Test func computerURLPersistsPerBot() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Desk", backend: .mock); bot.computerURL = "https://desk.example.com/vnc.html"
    store.bots = [bot, Bot(name: "Plain", backend: .mock)]; store.save()
    let reloaded = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(reloaded.bots.map(\.computerURL) == ["https://desk.example.com/vnc.html", nil])
}

@MainActor @Test func computerReachabilityUsesHEAD() async {
    let (host, session) = MockHermesProtocol.serve { _ in (401, ["error": "login"]) }
    #expect(await ComputerURL.probe(URL(string: "https://\(host)/vnc.html")!, session: session) == .reachable(401))
    #expect(MockHermesProtocol.recorded(host).map(\.httpMethod) == ["HEAD"])
}

@Test func accentNamesMapToColours() {
    #expect(AppTheme.accentNames.first == AppTheme.defaultAccent)
    #expect(AppTheme.accentColor(for: "Graphite") == .primary && AppTheme.accentColor(for: "Blue") == .blue && AppTheme.accentColor(for: "nonsense") == .primary)
}
