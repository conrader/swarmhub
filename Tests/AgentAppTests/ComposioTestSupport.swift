import Foundation
@testable import AgentApp

/// P38 B: Composio fixtures. Every request goes to `MockHermesProtocol` (a unique `.test` host per test); nothing reaches
/// the network, the Keychain or a browser.
let syntheticComposioKey = "synthetic-composio-project-key"

@MainActor final class FakeComposioProvisioner: ComposioProvisioning {
    var calls: [String] = []
    var fails = false
    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential {
        calls.append(toolkit)
        if fails { throw ComposioProvisioningError.failed(503) }
        return .init(apiKey: "ak_synthetic_first_connection", userID: "swarmhub_signed_in_user", projectID: "pr_synthetic_user")
    }
}

func composioAccount(_ id: String = "ca_work", toolkit: String = "gmail", status: String = "ACTIVE") -> [String: Any] {
    ["id": id, "toolkit": ["slug": toolkit], "alias": id, "status": status, "is_disabled": false,
     "state": ["val": ["access_token": "never-copy-provider-token"]], "data": ["refresh_token": "never-copy-refresh-token"]]
}

func composioBody(_ request: URLRequest) -> [String: Any] {
    let data: Data
    if let body = request.httpBody { data = body }
    else if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }; body.append(contentsOf: buffer.prefix(count))
        }
        data = body
    } else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// P52: the same Composio, whose search finds the read-only `GMAIL_FETCH_EMAILS` instead.
func composioReadHandler(_ request: URLRequest) -> (Int, Any) {
    let path = request.url!.path
    if path.hasSuffix("/search") { return (200, ["success": true, "tool_schemas": ["GMAIL_FETCH_EMAILS": ["tool_slug": "GMAIL_FETCH_EMAILS", "toolkit": "gmail"]]]) }
    if path.hasSuffix("/tools") {
        return (200, ["items": [["slug": "GMAIL_FETCH_EMAILS", "name": "Fetch emails", "toolkit": ["slug": "gmail"],
                                  "input_parameters": ["type": "object", "properties": ["query": ["type": "string"]]]]]])
    }
    return composioHandler(request)
}

func composioHandler(_ request: URLRequest) -> (Int, Any) {
    let path = request.url!.path
    if path.hasSuffix("connected_accounts") { return (200, ["items": [composioAccount(), composioAccount("ca_personal")], "next_cursor": NSNull()]) }
    if path.hasSuffix("tool_router/session"), request.httpMethod == "POST" { return (201, ["session_id": "trs_synthetic"]) }
    if path.hasSuffix("/search") {
        return (200, ["success": true, "tool_schemas": ["GMAIL_SEND_EMAIL": ["tool_slug": "GMAIL_SEND_EMAIL", "toolkit": "gmail"]]])
    }
    if path.hasSuffix("/tools") {
        return (200, ["items": [["slug": "GMAIL_SEND_EMAIL", "name": "Send email", "toolkit": ["slug": "gmail"],
                                  "input_parameters": ["type": "object", "properties": ["query": ["type": "string"]]]]]])
    }
    if path.hasSuffix("/execute") { return (200, ["successful": true, "data": ["emails": ["Hello from the synthetic inbox"], "access_token": "never-copy-provider-token"]]) }
    if path.hasSuffix("/link") { return (201, ["redirect_url": "https://connect.composio.dev/link/synthetic", "connected_account_id": "ca_work"]) }
    if request.httpMethod == "DELETE" { return (200, ["deleted": true]) }
    return (404, ["error": "no synthetic route"])
}

/// P40: this Mac's install, handed out without any request (no sign-in exists).
@MainActor final class FakeSwarmHubInstall: SwarmHubInstallCredential {
    var calls = 0
    func install(renew: Bool) async throws -> SwarmHubInstall { calls += 1; return SwarmHubInstall(installID: "ins_synthetic", installKey: "synthetic-install-key") }
}

@MainActor func composioFixture(handler: @escaping MockHermesProtocol.Handler = composioHandler) -> (ConnectedAppsStore, String, URL) {
    let (host, session) = MockHermesProtocol.serve(handler)
    let directory = temporaryStore().deletingLastPathComponent()
    let keys = InMemoryKeyStore()
    let apps = ConnectedAppsStore(directory: directory, keyStore: keys, session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!)
    _ = apps.saveKey(syntheticComposioKey)
    return (apps, host, directory)
}

actor AppRequestBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    enum Mode: Sendable { case action, normal, unknownTool, endlessSearch, connectionCard, normalAfterSearch, read }
    let mode: Mode; var calls: [AgentRequest] = []
    init(_ mode: Mode = .action) { self.mode = mode }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append(request)
        let output: String
        if mode == .normal { output = "A normal streamed reply." }
        else if mode == .connectionCard { output = "Connect your inbox to continue.\n\n```connect-app\n{\"app\":\"gmail\",\"reason\":\"To find your unread emails.\"}\n```" }
        else {
            let marker = request.systemPrompt.components(separatedBy: "\n").first { $0.hasPrefix("[[SWARMHUB_APP_REQUEST_") }!
            if mode == .normalAfterSearch && calls.count > 1 { output = "Search failed, sorry." }
            else if calls.count == 1 || mode == .endlessSearch { output = marker + "\n{\"action\":\"search\",\"query\":\"Fetch unread Gmail emails\"}" }
            else if calls.count == 2 {
                let slug = mode == .unknownTool ? "SLACK_SEND_MESSAGE" : mode == .read ? "GMAIL_FETCH_EMAILS" : "GMAIL_SEND_EMAIL"
                output = marker + "\n{\"action\":\"execute\",\"tool\":\"\(slug)\",\"arguments\":{\"query\":\"is:unread\"}}"
            } else { output = "Your inbox contains one message." }
        }
        return AsyncThrowingStream { continuation in
            // Split inside the control marker to exercise buffering across arbitrary SSE chunk boundaries.
            for character in output { continuation.yield(.token(String(character))) }
            continuation.yield(.completed); continuation.finish()
        }
    }
    func recorded() -> [AgentRequest] { calls }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws { throw ComposioError.invalidResponse }
    func testConnection() async throws -> String { "synthetic backend" }
    func stopTarget(sessionID: String) async throws -> StopTarget { .noActiveRun }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome { .noActiveRun }
}
