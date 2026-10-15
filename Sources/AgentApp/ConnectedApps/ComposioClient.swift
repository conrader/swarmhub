import Foundation

enum ComposioError: LocalizedError {
    case missingKey, invalidResponse, invalidIdentifier, http(Int), tooLarge, accessChanged
    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Composio project API key in Settings → Connected apps."
        case .invalidResponse: "Composio returned an unexpected response."
        case .invalidIdentifier: "The app or account identifier is invalid."
        case .tooLarge: "The app response exceeded SwarmHub’s size limit."
        case .accessChanged: "App access changed. Check this bot’s connected apps and try again."
        case .http(let status):
            switch status {
            case 401: "Composio rejected the project API key. Update it in Settings → Connected apps."
            case 403: "The Composio key lacks access. Enable toolkit, connected-account, session management and session execution permissions in your Composio project."
            case 429: "Composio’s rate limit was reached. Try again shortly."
            case 404: "This Composio app, connection or session is unavailable. Check your Composio project."
            default: "Composio request failed (HTTP \(status)). Check your Composio project for details."
            }
        }
    }
}

/// P38 B: SwarmHub calls Composio directly from the Mac. No Hermes installation, MCP configuration or key forwarding;
/// a test run's default session refuses anything but loopback (`TestRunGuard`).
struct ComposioClient: Sendable {
    static let productionURL = URL(string: "https://backend.composio.dev/api/v3.1/")!
    static let defaultSession: URLSession = {
        let configuration = TestRunGuard.guarded(.ephemeral)
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    let apiKey: String
    var session: URLSession = defaultSession
    var baseURL = productionURL

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: ComposioValue? = nil) async throws -> ComposioValue {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw ComposioError.missingKey }
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil else { throw ComposioError.invalidResponse }
        var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = method; request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request, delegate: ComposioNoRedirect())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ComposioError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ComposioError.http(http.statusCode) }
        guard data.count <= 4_000_000 else { throw ComposioError.tooLarge }
        if data.isEmpty { return .null }
        guard let result = try? JSONDecoder().decode(ComposioValue.self, from: data) else { throw ComposioError.invalidResponse }
        return result
    }

    func catalog(search: String = "", cursor: String? = nil) async throws -> (items: [ComposioToolkit], cursor: String?) {
        var query = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "sort_by", value: "usage"), URLQueryItem(name: "include_deprecated", value: "false")]
        if !search.isEmpty { query.append(.init(name: "search", value: search)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let value = try await request("toolkits", query: query)
        guard let items = value["items"].array else { throw ComposioError.invalidResponse }
        return (items.compactMap(ComposioToolkit.init), value["next_cursor"].string)
    }

    func accounts(userID: String) async throws -> [ComposioAccount] {
        var accounts: [ComposioAccount] = []; var cursor: String?; var seen: Set<String> = []
        for _ in 0..<100 {
            var query = [URLQueryItem(name: "user_ids", value: userID), .init(name: "limit", value: "100")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let value = try await request("connected_accounts", query: query)
            guard let items = value["items"].array else { throw ComposioError.invalidResponse }
            // Check ownership when supplied; the API may omit the deprecated user_id field.
            guard items.allSatisfy({ $0["user_id"].string == nil || $0["user_id"].string == userID }) else { throw ComposioError.invalidResponse }
            accounts += items.compactMap(ComposioAccount.init)
            guard let next = value["next_cursor"].string, !next.isEmpty else { return accounts }
            guard seen.insert(next).inserted else { throw ComposioError.invalidResponse }; cursor = next
        }
        throw ComposioError.tooLarge
    }

    func createSession(userID: String, toolkits: [String], accounts: [String: String] = [:]) async throws -> String {
        guard !toolkits.isEmpty, toolkits.allSatisfy(Self.validIdentifier) else { throw ComposioError.invalidIdentifier }
        let pins = accounts.mapValues { ComposioValue.strings([$0]) }
        let body: ComposioValue = .object([
            "user_id": .string(userID), "toolkits": .object(["enable": .strings(toolkits.sorted())]),
            "connected_accounts": .object(pins), "instant": .bool(false),
            "manage_connections": .object(["enable": .bool(false)]),
            "workbench": .object(["enable": .bool(false)]), "proxy_execute": .object(["enable": .bool(false)]),
            "multi_account": .object(["enable": .bool(false)])
        ])
        let value = try await request("tool_router/session", method: "POST", body: body)
        guard let id = value["session_id"].string, Self.validIdentifier(id) else { throw ComposioError.invalidResponse }
        return id
    }

    func connect(sessionID: String, toolkit: String) async throws -> URL {
        let value = try await request(try route(sessionID, "link"), method: "POST", body: .object(["toolkit": .string(toolkit)]))
        guard let text = value["redirect_url"].string, let url = URL(string: text), url.scheme == "https",
              url.host == "connect.composio.dev", url.user == nil, url.password == nil else { throw ComposioError.invalidResponse }
        return url
    }

    func tools(sessionID: String, query: String) async throws -> [ComposioTool] {
        let value = try await request(try route(sessionID, "search"), method: "POST", body: .object([
            "queries": .array([.object(["use_case": .string(String(query.prefix(1024)))])]), "search_strategy": .string("tool_search")
        ]))
        guard value["success"].bool == true, let schemas = value["tool_schemas"].object else { throw ComposioError.invalidResponse }
        let slugs = schemas.keys.sorted().filter { !$0.hasPrefix("COMPOSIO_") }
        guard !slugs.isEmpty else { return [] }
        let details = try await request("tools", query: [.init(name: "tool_slugs", value: slugs.prefix(30).joined(separator: ",")), .init(name: "toolkit_versions", value: "latest"), .init(name: "limit", value: "30")])
        guard let items = details["items"].array else { throw ComposioError.invalidResponse }
        return items.compactMap(ComposioTool.init).filter { slugs.contains($0.slug) }
    }

    func execute(sessionID: String, tool: String, arguments: ComposioValue, account: String) async throws -> ComposioValue {
        guard Self.validIdentifier(tool), !tool.hasPrefix("COMPOSIO_"), Self.validIdentifier(account), arguments.object != nil else { throw ComposioError.invalidIdentifier }
        return try await request(try route(sessionID, "execute"), method: "POST", body: .object([
            "tool_slug": .string(tool), "arguments": arguments, "account": .string(account)
        ])).withoutCredentials()
    }

    func deleteAccount(_ id: String) async throws {
        guard Self.validIdentifier(id) else { throw ComposioError.invalidIdentifier }
        _ = try await request("connected_accounts/\(id)", method: "DELETE")
    }
    func deleteSession(_ id: String) async { if let route = try? route(id) { _ = try? await request(route, method: "DELETE") } }
    private func route(_ id: String, _ action: String = "") throws -> String {
        guard Self.validIdentifier(id) else { throw ComposioError.invalidIdentifier }
        return "tool_router/session/\(id)" + (action.isEmpty ? "" : "/\(action)")
    }
}

private final class ComposioNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
