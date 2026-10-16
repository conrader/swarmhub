import Foundation
import Testing
@testable import AgentApp

/// P48 item 3: accounts are named after who they are (profile call → alias), never Composio's random word_id.
/// Composio is a stateful in-process fake (`MockHermesProtocol`); nothing reaches the network.
private final class NamingComposio: @unchecked Sendable {
    private let lock = NSLock()
    private var aliases: [String: String] = [:]
    var taken: Set<String> = []
    private(set) var profileCalls: [String] = []; private(set) var patches: [String] = []
    let items: [(id: String, toolkit: String, created: String)]
    init(_ items: [(id: String, toolkit: String, created: String)]) { self.items = items }

    func handler(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("connected_accounts"), request.httpMethod == "GET" {
            return (200, ["items": items.map { item -> [String: Any] in
                var row: [String: Any] = ["id": item.id, "toolkit": ["slug": item.toolkit], "status": "ACTIVE", "is_disabled": false,
                                          "word_id": "\(item.toolkit)_red-castle", "created_at": item.created,
                                          "state": ["val": ["access_token": "never-copy-provider-token"]]]
                row["alias"] = aliases[item.id] ?? NSNull()
                return row
            }])
        }
        if request.httpMethod == "PATCH", let id = path.split(separator: "/").last.map(String.init) {
            let alias = composioBody(request)["alias"] as? String ?? ""
            patches.append("\(id)=\(alias)")
            if taken.contains(alias) { return (409, ["error": ["message": "Alias already exists", "slug": "ConnectedAccount_DuplicateAlias", "status": 409]]) }
            aliases[id] = alias.isEmpty ? nil : alias
            return (200, ["id": id])
        }
        if path.hasSuffix("/execute") {
            let tool = composioBody(request)["tool_slug"] as? String ?? ""
            profileCalls.append(tool)
            if tool == "GMAIL_GET_PROFILE" { return (200, ["successful": true, "data": ["emailAddress": "konrad@example.com", "messagesTotal": 12, "access_token": "never-copy-provider-token"]]) }
            if tool == "GITHUB_GET_THE_AUTHENTICATED_USER" { return (200, ["successful": true, "data": ["login": "conrader", "id": 8105013]]) }
            return (404, ["error": ["message": "no such tool"]])
        }
        return composioHandler(request)
    }
    func alias(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return aliases[id] }
}

@MainActor private func fixture(_ items: [(id: String, toolkit: String, created: String)]) -> (ConnectedAppsStore, NamingComposio, String) {
    let fake = NamingComposio(items)
    let (apps, host, _) = composioFixture(handler: { fake.handler($0) })
    return (apps, fake, host)
}

@MainActor @Test func aProfileCallNamesNewAccountsByEmailAndLogin() async throws {
    let (apps, fake, host) = fixture([("ca_mail", "gmail", "2026-10-16T04:43:12.000Z"), ("ca_gh", "github", "2026-10-16T04:44:00Z")])
    await apps.refresh()
    #expect(fake.patches.sorted() == ["ca_gh=conrader", "ca_mail=konrad@example.com"])
    #expect(apps.accounts.map(\.label).sorted() == ["conrader", "konrad@example.com"])
    #expect(apps.namingAccounts.isEmpty)
    // SwarmHub's own read: a single-account session pinned to that account, execute names no account, no approval.
    let requests = MockHermesProtocol.recorded(host)
    let sessions = requests.filter { $0.url!.path.hasSuffix("tool_router/session") }.map(composioBody)
    #expect(sessions.count == 2 && sessions.allSatisfy { ($0["multi_account"] as? [String: Bool]) == ["enable": false] })
    #expect(sessions.contains { ($0["connected_accounts"] as? [String: [String]]) == ["gmail": ["ca_mail"]] })
    #expect(requests.filter { $0.url!.path.hasSuffix("/execute") }.allSatisfy { composioBody($0)["account"] == nil })
    #expect(apps.receipts.isEmpty && !apps.accounts.map(\.label).joined().contains("never-copy"))
}

@MainActor @Test func aDuplicateAliasGetsANumber() async throws {
    let (apps, fake, _) = fixture([("ca_mail", "gmail", "2026-10-16T04:43:12Z")])
    fake.taken = ["konrad@example.com"]
    await apps.refresh()
    #expect(fake.patches == ["ca_mail=konrad@example.com", "ca_mail=konrad@example.com (2)"])
    #expect(apps.accounts.first?.label == "konrad@example.com (2)")
}

@MainActor @Test func aFailedNamingIsRetriedOnALaterRefreshAfterTheBackOff() async throws {
    let (apps, fake, _) = fixture([("ca_mail", "gmail", "2026-10-15T08:00:00Z"), ("ca_slack", "slack", "2026-10-15T09:00:00Z")])
    var clock = Date(timeIntervalSince1970: 1_800_000_000); apps.now = { clock }
    fake.taken = Set((1...9).map { $0 == 1 ? "konrad@example.com" : "konrad@example.com (\($0))" })
    await apps.refresh(); await apps.refresh(); await apps.refresh()
    #expect(fake.profileCalls == ["GMAIL_GET_PROFILE", "SLACK_TEST_AUTH"], "a failure waits for the back-off, not for the next launch")
    #expect(apps.accounts.first { $0.id == "ca_slack" }?.label.hasPrefix("Slack account 1") == true)
    clock += ConnectedAppsStore.namingBackoff - 1; await apps.refresh()
    #expect(fake.profileCalls.count == 2)
    clock += 2; fake.taken = []; await apps.refresh()
    #expect(fake.profileCalls == ["GMAIL_GET_PROFILE", "SLACK_TEST_AUTH", "GMAIL_GET_PROFILE", "SLACK_TEST_AUTH"])
    #expect(apps.accounts.first { $0.id == "ca_mail" }?.label == "konrad@example.com" && apps.namingRetryAfter["ca_mail"] == nil)
    await apps.refresh()
    #expect(fake.profileCalls.count == 4, "a named account is not read again; the unnamed one still waits")
}

@MainActor @Test func renameSavesTheAliasAndEmptyPutsBackTheAutomaticName() async throws {
    let (apps, fake, _) = fixture([("ca_mail", "gmail", "2026-10-15T08:00:00Z"), ("ca_slack", "slack", "2026-10-15T09:00:00Z")])
    await apps.refresh()
    let mail = try #require(apps.accounts.first { $0.id == "ca_mail" }), slack = try #require(apps.accounts.first { $0.id == "ca_slack" })
    await apps.rename(mail, to: "  Work inbox ")
    await apps.rename(slack, to: "Team Slack")
    #expect(fake.alias("ca_mail") == "Work inbox" && fake.alias("ca_slack") == "Team Slack")
    #expect(apps.accounts.first { $0.id == "ca_mail" }?.label == "Work inbox")
    await apps.rename(try #require(apps.accounts.first { $0.id == "ca_mail" }), to: "")
    await apps.rename(try #require(apps.accounts.first { $0.id == "ca_slack" }), to: " ")
    #expect(fake.alias("ca_mail") == "konrad@example.com", "the profile name comes back")
    #expect(fake.alias("ca_slack") == nil && fake.patches.last == "ca_slack=")
    #expect(apps.accounts.first { $0.id == "ca_slack" }?.label.hasPrefix("Slack account 1") == true && apps.error == nil)
}

@Test func noLabelIsEverAWordID() throws {
    func account(_ id: String, _ toolkit: String, created: String?, alias: Any = NSNull()) throws -> ComposioAccount {
        var row: [String: Any] = ["id": id, "toolkit": ["slug": toolkit], "status": "ACTIVE", "word_id": "\(toolkit)_brave-tiger-42", "alias": alias]
        if let created { row["created_at"] = created }
        return try #require(ComposioAccount(try JSONDecoder().decode(ComposioValue.self, from: JSONSerialization.data(withJSONObject: row))))
    }
    let named = ComposioAccount.named([
        try account("ca_b", "gmail", created: "2026-10-16T09:00:00Z"), try account("ca_a", "gmail", created: "2026-10-15T09:00:00.250Z"),
        try account("ca_c", "notion", created: nil), try account("ca_d", "gmail", created: nil, alias: ""), try account("ca_e", "github", created: nil, alias: "conrader"),
    ])
    #expect(named.map(\.label) == ["Gmail account 2 · 16 Oct 2026", "Gmail account 1 · 15 Oct 2026", "Notion account 1", "Gmail account 3", "conrader"])
    #expect(!named.contains { $0.label.contains("brave-tiger") || $0.label.contains("_") })
}

@Test func profileNamesAreReadFromNameKeysOnly() {
    let result = ComposioValue.object(["successful": .bool(true), "data": .object(["login": .string(" octo "), "token": .string("x")])])
    #expect(AccountProfileName.read(result, toolkit: "github") == .init(name: "octo", path: "data.login"))
    #expect(AccountProfileName.read(.object(["successful": .bool(false), "data": .object(["login": .string("octo")])]), toolkit: "github") == nil)
    #expect(AccountProfileName.read(.object(["data": .object(["login": .string("two\nlines")])]), toolkit: "github") == nil)
    #expect(AccountProfileName.known["gmail"]?.first?.tool == "GMAIL_GET_PROFILE" && AccountProfileName.known["github"]?.first?.tool == "GITHUB_GET_THE_AUTHENTICATED_USER")
}
