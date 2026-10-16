import Foundation
import Testing
@testable import AgentApp

/// P53: every account named by its own name: the identity call per app, the name searched in its result (`data` as an
/// object or a JSON string), discovery for other apps, and the read-only `--check-account-names`. Fakes only.
private func result(_ data: [String: Any], asString: Bool) throws -> ComposioValue {
    let inner = try JSONSerialization.data(withJSONObject: data, options: .sortedKeys)
    let body: [String: Any] = ["successful": true, "error": NSNull(), "log_id": "log_x", "data": asString ? String(decoding: inner, as: UTF8.self) : data]
    return try JSONDecoder().decode(ComposioValue.self, from: JSONSerialization.data(withJSONObject: body))
}

/// The results each known tool may give (field names found by search, not documented).
nonisolated(unsafe) private let appResults: [(toolkit: String, data: [String: Any], name: String, path: String)] = [
    ("gmail", ["emailAddress": "konrad@example.com", "messagesTotal": 12, "historyId": "991"], "konrad@example.com", "data.emailAddress"),
    ("github", ["login": "conrader", "id": 8105013, "name": "Konrad S"], "conrader", "data.login"),
    ("googlecalendar", ["response_data": ["email": "konrad@example.com", "id": "primary"]], "konrad@example.com", "data.response_data.email"),
    ("googledrive", ["user": ["displayName": "Konrad S", "emailAddress": "konrad@example.com", "kind": "drive#user"]], "konrad@example.com", "data.user.emailAddress"),
    ("notion", ["object": "user", "name": "Konrad", "bot": ["owner": ["user": ["name": "Konrad S", "person": ["email": "konrad@example.com"]]]]],
     "konrad@example.com", "data.bot.owner.user.person.email"),
    ("slack", ["ok": true, "user": "konrad", "team": "Plainsay", "user_id": "U1", "team_id": "T1"], "konrad @ Plainsay", "data.user @ data.team"),
]

@Test func eachAppsNameIsFoundWithDataAsAnObjectAndAsAJSONString() throws {
    for app in appResults {
        for asString in [false, true] {
            #expect(AccountProfileName.read(try result(app.data, asString: asString), toolkit: app.toolkit) == .init(name: app.name, path: app.path),
                    "\(app.toolkit), data as \(asString ? "string" : "object")")
        }
        #expect(AccountProfileName.known[app.toolkit]?.isEmpty == false)
    }
    #expect(AccountProfileName.known["googlecalendar"]?.map(\.tool) == ["GOOGLECALENDAR_GET_CURRENT_USER", "GOOGLECALENDAR_CALENDAR_LIST_GET"])
    #expect(AccountProfileName.known["googlecalendar"]?.last?.arguments == .object(["calendarId": .string("primary")]))
    #expect(AccountProfileName.known["googledrive"]?.first?.arguments == .object(["fields": .string("user")]))
}

@Test func slackIsUserAtTeamOnlyWhenBothAreThere() throws {
    #expect(AccountProfileName.read(try result(["user": "konrad", "user_id": "U1"], asString: false), toolkit: "slack")?.name == "konrad")
    let object = try result(["user": ["name": "konrad", "email": "k@example.com"], "team": ["name": "Plainsay", "id": "T1"]], asString: true)
    #expect(AccountProfileName.read(object, toolkit: "slack") == .init(name: "k@example.com @ Plainsay", path: "data.user.email @ data.team"))
}

@Test func aResultWithOnlyAnIDHasNoNameAndLongNamesAreCut() throws {
    #expect(AccountProfileName.read(try result(["id": "123456", "kind": "user"], asString: true), toolkit: "linear") == nil)
    #expect(AccountProfileName.read(try result(["email": "   ", "name": "  "], asString: false), toolkit: "linear") == nil)
    #expect(AccountProfileName.read(try result(["name": String(repeating: "a", count: 200)], asString: false), toolkit: "linear")?.name.count == 80)
    let shape = AccountProfileName.shape(try result(["id": "123456", "kind": "user"], asString: true))
    #expect(shape.contains("data: object") && shape.contains("data object {id: string, kind: string}") && !shape.contains("123456"))
}

@Test func discoveryPicksOnlyReadOnlyToolsWithoutRequiredArguments() throws {
    func tool(_ slug: String, required: [String] = [], tags: [String] = []) throws -> ComposioTool {
        try #require(ComposioTool(.object(["slug": .string(slug), "toolkit": .object(["slug": .string("linear")]), "tags": .strings(tags),
                                           "input_parameters": .object(["type": .string("object"), "required": .strings(required)])])))
    }
    let tools = [try tool("LINEAR_WHO_AM_I", required: ["team_id"]), try tool("LINEAR_GET_CURRENT_USER", tags: ["destructiveHint"]),
                 try tool("LINEAR_UPDATE_PROFILE"), try tool("LINEAR_GET_PROFILE"), try tool("LINEAR_GET_ABOUT"), try tool("LINEAR_LIST_ISSUES")]
    #expect(AccountProfileName.discover(in: tools, toolkit: "linear") == .init(tool: "LINEAR_GET_PROFILE"))
    #expect(AccountProfileName.discover(in: [try tool("LINEAR_LIST_ISSUES"), try tool("LINEAR_DELETE_ME")], toolkit: "linear") == nil)
    #expect(AccountProfileName.discover(in: tools, toolkit: "jira") == nil)
}

/// Composio with unnamed gmail (data as a string), slack, linear (found by discovery) and notion (only an id) accounts.
private func identityHandler(_ request: URLRequest) -> (Int, Any) {
    let path = request.url!.path
    if path.hasSuffix("connected_accounts"), request.httpMethod == "GET" {
        return (200, ["items": [("ca_mail", "gmail"), ("ca_slack", "slack"), ("ca_linear", "linear"), ("ca_notion", "notion"), ("ca_named", "github")].map { id, app -> [String: Any] in
            ["id": id, "toolkit": ["slug": app], "status": "ACTIVE", "is_disabled": false, "alias": id == "ca_named" ? "Work GitHub" : NSNull(),
             "created_at": "2026-10-16T08:00:00Z", "state": ["val": ["access_token": "never-copy-provider-token"]]]
        }])
    }
    if path.hasSuffix("tool_router/session"), request.httpMethod == "POST" { return (201, ["session_id": "trs_identity"]) }
    if path.hasSuffix("/tools") {
        return (200, ["items": ["LINEAR_GET_ME", "LINEAR_DELETE_ISSUE"].map { ["slug": $0, "toolkit": ["slug": "linear"], "input_parameters": ["type": "object"]] }])
    }
    if path.hasSuffix("/execute") {
        switch composioBody(request)["tool_slug"] as? String {
        case "GMAIL_GET_PROFILE": return (200, ["successful": true, "data": #"{"emailAddress":"konrad@example.com","access_token":"never-copy-provider-token"}"#])
        case "SLACK_TEST_AUTH": return (200, ["successful": true, "data": ["ok": true, "user": "konrad", "team": "Plainsay"]])
        case "LINEAR_GET_ME": return (200, ["successful": true, "data": ["viewer": ["displayName": "konrad", "id": "u1"]]])
        case "NOTION_GET_ABOUT_ME": return (200, ["successful": true, "data": ["id": "abc-123", "object": "user"]])
        default: return (404, ["error": ["message": "no such tool"]])
        }
    }
    if request.httpMethod == "PATCH" { return (200, ["id": "x"]) }
    if request.httpMethod == "DELETE" { return (200, ["deleted": true]) }
    return (404, ["error": "no synthetic route"])
}

@MainActor @Test func refreshNamesEveryUnnamedAccountAndLeavesARenamedOneAlone() async throws {
    let (apps, host, _) = composioFixture(handler: identityHandler)
    await apps.refresh()
    let labels = Dictionary(uniqueKeysWithValues: apps.accounts.map { ($0.id, $0.label) })
    #expect(labels["ca_mail"] == "konrad@example.com" && labels["ca_slack"] == "konrad @ Plainsay" && labels["ca_linear"] == "konrad")
    #expect(labels["ca_notion"]?.hasPrefix("Notion account 1") == true && labels["ca_named"] == "Work GitHub", "only an id: the fallback; Rename… wins")
    let requests = MockHermesProtocol.recorded(host)
    let tools = requests.filter { $0.url!.path.hasSuffix("/execute") }.compactMap { composioBody($0)["tool_slug"] as? String }
    #expect(Set(tools) == ["GMAIL_GET_PROFILE", "SLACK_TEST_AUTH", "LINEAR_GET_ME", "NOTION_GET_ABOUT_ME"], "never the renamed account's tool")
    #expect(requests.filter { $0.httpMethod == "PATCH" }.count == 3)
    #expect(apps.namingRetryAfter.keys.sorted() == ["ca_notion"])
}

@MainActor @Test func theCheckCommandPrintsEachAccountAndWritesNothing() async throws {
    let (host, session) = MockHermesProtocol.serve(identityHandler)
    let directory = temporaryStore().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = Data(#"{"bots":[]}"#.utf8), config = try JSONEncoder().encode(ConnectedAppsConfiguration(userID: "swarmhub_check"))
    try store.write(to: directory.appending(path: "store.json")); try config.write(to: directory.appending(path: "connected-apps.json"))
    var lines: [String] = []
    let code = await HeadlessCheckAccountNames.check(directory: directory, key: syntheticComposioKey, session: session,
                                                     apiURL: URL(string: "https://\(host)/api/v3.1/")!, output: { lines.append($0) })
    #expect(code == 0)
    #expect(lines.contains { $0.hasPrefix("gmail · Gmail account 1") && $0.hasSuffix("· GMAIL_GET_PROFILE · data.emailAddress · konrad@example.com") })
    #expect(lines.contains("linear · Linear account 1 · 16 Oct 2026 · LINEAR_GET_ME · data.viewer.displayName · konrad"))
    #expect(lines.contains { $0.hasPrefix("notion · ") && $0.contains("NOTION_GET_ABOUT_ME · no name: object {") && $0.contains("data object {id: string, object: string}") })
    #expect(lines.contains("github · Work GitHub · GITHUB_GET_THE_AUTHENTICATED_USER · no name: no such tool") || lines.contains { $0.hasPrefix("github · Work GitHub · no name:") })
    #expect(lines.last == "Checked 5 accounts: 3 named, 2 no name, 0 not active")
    #expect(!lines.joined().contains(syntheticComposioKey) && !lines.joined().contains("never-copy") && !lines.joined().contains("abc-123"))
    #expect(try Data(contentsOf: directory.appending(path: "store.json")) == store && Data(contentsOf: directory.appending(path: "connected-apps.json")) == config)
    let requests = MockHermesProtocol.recorded(host)
    #expect(!requests.contains { $0.httpMethod == "PATCH" }, "never sets an alias")
    #expect(requests.filter { $0.url!.path.hasSuffix("/execute") }.allSatisfy { ["GMAIL_GET_PROFILE", "SLACK_TEST_AUTH", "LINEAR_GET_ME", "NOTION_GET_ABOUT_ME", "GITHUB_GET_THE_AUTHENTICATED_USER"].contains(composioBody($0)["tool_slug"] as? String ?? "") })
}

@MainActor @Test func theCheckCommandWithoutConnectedAppsOrKeyRunsNothing() async throws {
    let directory = temporaryStore().deletingLastPathComponent()
    var lines: [String] = []
    #expect(await HeadlessCheckAccountNames.check(directory: directory, key: "", session: .shared, apiURL: ComposioClient.productionURL, output: { lines.append($0) }) == 0)
    #expect(lines.first?.hasPrefix("No connected apps on this Mac") == true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(ConnectedAppsConfiguration()).write(to: directory.appending(path: "connected-apps.json"))
    #expect(await HeadlessCheckAccountNames.check(directory: directory, key: "", session: .shared, apiURL: ComposioClient.productionURL, output: { lines.append($0) }) == 1)
    #expect(lines.last == "The Composio key could not be read without a prompt; nothing was checked.")
}
