import Foundation
import Testing
@testable import AgentApp

@Test func composioClientUsesCurrentAPIAndExplicitAccountScope() async throws {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    let accounts = try await client.accounts(userID: "swarmhub_test")
    #expect(accounts.count == 2)
    let id = try await client.createSession(userID: "swarmhub_test", toolkits: ["gmail"], accounts: ["gmail": ["ca_work"]])
    #expect(id == "trs_synthetic")
    let requests = MockHermesProtocol.recorded(host)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == syntheticComposioKey })
    #expect(requests[0].url?.query?.contains("user_ids=swarmhub_test") == true)
    let body = composioBody(requests[1])
    #expect(body["user_id"] as? String == "swarmhub_test")
    #expect((body["toolkits"] as? [String: [String]])?["enable"] == ["gmail"])
    #expect((body["connected_accounts"] as? [String: [String]])?["gmail"] == ["ca_work"])
    #expect(body["instant"] as? Bool == false)
    for field in ["manage_connections", "workbench", "proxy_execute", "multi_account"] {
        #expect((body[field] as? [String: Bool])?["enable"] == false)
    }
    let serialized = String(decoding: try JSONEncoder().encode(ComposioValue.object(["accounts": .strings(accounts.map(\.label))])), as: UTF8.self)
    #expect(!serialized.contains("provider-token") && !serialized.contains("refresh-token"))
}

@Test func composioSearchFetchesSchemasAndExecutionPinsAccount() async throws {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    let tools = try await client.tools(sessionID: "trs_test", query: "read my emails")
    #expect(tools.map(\.slug) == ["GMAIL_FETCH_EMAILS"])
    let result = try await client.execute(sessionID: "trs_test", tool: tools[0].slug, arguments: .object(["query": .string("is:unread")]), account: "ca_work")
    #expect(result["data"]["access_token"] == .null)
    #expect(result["data"]["emails"].array?.count == 1)
    let body = composioBody(MockHermesProtocol.recorded(host).last!)
    #expect(body["account"] as? String == "ca_work")
    #expect(body["tool_slug"] as? String == "GMAIL_FETCH_EMAILS")
}

@Test func composioRejectsUnknownAuthDestinationAndMetaExecution() async {
    let (host, session) = MockHermesProtocol.serve { _ in (201, ["redirect_url": "https://connect.composio.dev.evil.test/link/secret"]) }
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    await #expect(throws: ComposioError.self) { try await client.connect(sessionID: "trs_test", toolkit: "gmail") }
    await #expect(throws: ComposioError.self) { try await client.execute(sessionID: "trs_test", tool: "COMPOSIO_REMOTE_WORKBENCH", arguments: .object([:]), account: "ca_work") }
    await #expect(throws: ComposioError.self) { try await client.execute(sessionID: "../../other", tool: "GMAIL_FETCH_EMAILS", arguments: .object([:]), account: "ca_work") }
    #expect(MockHermesProtocol.recorded(host).count == 1)
}

@Test func composioPaginationNeverReturnsPartialOrForeignAccounts() async {
    let (host, session) = MockHermesProtocol.serve { _ in
        var account = composioAccount(); account["user_id"] = "another-user"
        return (200, ["items": [account]])
    }
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    await #expect(throws: ComposioError.self) { try await client.accounts(userID: "swarmhub_test") }
    let (loopHost, loopSession) = MockHermesProtocol.serve { _ in (200, ["items": [composioAccount()], "next_cursor": "same-cursor"]) }
    let looping = ComposioClient(apiKey: syntheticComposioKey, session: loopSession, baseURL: URL(string: "https://\(loopHost)/api/v3.1/")!)
    await #expect(throws: ComposioError.self) { try await looping.accounts(userID: "swarmhub_test") }
    #expect(MockHermesProtocol.recorded(loopHost).count == 2)
}

@Test func composioErrorsNeverEchoProviderResponseSecrets() async {
    let (host, session) = MockHermesProtocol.serve { _ in (401, ["error": "secret in response: \(syntheticComposioKey)"]) }
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    do { _ = try await client.accounts(userID: "swarmhub_test"); Issue.record("Expected failure") }
    catch { #expect(!error.localizedDescription.contains(syntheticComposioKey)); #expect(error.localizedDescription.contains("key")) }
}

@Test func composioCatalogEncodesSearchAndPaginates() async throws {
    let (host, session) = MockHermesProtocol.serve { _ in
        (200, ["items": [["slug": "gmail", "name": "Gmail", "meta": ["description": "Email"]]], "next_cursor": "page-two"])
    }
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    let page = try await client.catalog(search: "Google & mail", cursor: "page-one")
    #expect(page.items.map(\.name) == ["Gmail"] && page.cursor == "page-two")
    let query = URLComponents(url: MockHermesProtocol.recorded(host)[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "search" }?.value == "Google & mail")
    #expect(query.first { $0.name == "cursor" }?.value == "page-one")
}
