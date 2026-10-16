import Foundation

struct ProvisionedComposioCredential: Sendable {
    let apiKey: String; let userID: String; let projectID: String
}

@MainActor protocol ComposioProvisioning {
    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential
}

enum ComposioProvisioningError: LocalizedError, Equatable {
    case unavailable, notReady, rateLimited, unreachable, invalidResponse, failed(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Automatic app connections are not configured for this build yet."
        case .notReady: ConnectedAppsCopy.notAvailable
        case .rateLimited: ConnectedAppsCopy.tooManyConnections
        case .unreachable: "SwarmHub could not be reached. Check your internet connection and try again."
        case .invalidResponse: "SwarmHub could not verify the app connection response."
        case .failed(let status): "SwarmHub could not prepare your app connection (HTTP \(status)). Try again shortly."
        }
    }

    /// A failure of this Mac's install registration, in the words of app connections.
    init(_ error: SwarmHubError) {
        switch error {
        case .rateLimited: self = .rateLimited
        case .badResponse(503), .signInUnavailable: self = .notReady
        case .badResponse(let status): self = .failed(status)
        case .unauthorized: self = .failed(401)
        case .network: self = .unreachable
        case .invalid, .stateMismatch, .timedOut: self = .invalidResponse
        }
    }
}

/// P40: `POST v1/composio/provision` with this Mac's anonymous install (`Authorization: Install <id>.<key>`, the P36
/// reports install) returns the install's own project key, creating its Composio project on the first call. No sign-in,
/// no browser; the organization key never enters the app.
@MainActor final class ComposioProvisioningClient: ComposioProvisioning {
    let baseURL: URL
    let session: URLSession
    let credential: any SwarmHubInstallCredential

    init(baseURL: URL, session: URLSession = ComposioClient.defaultSession, credential: any SwarmHubInstallCredential) {
        self.baseURL = baseURL; self.session = session; self.credential = credential
    }

    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential {
        guard ComposioClient.validIdentifier(toolkit) else { throw ComposioError.invalidIdentifier }
        let body = ComposioValue.object(["toolkit": .string(toolkit)])
        var value: ComposioValue
        do { value = try await request("v1/composio/provision", auth: try await install(renew: false), body: body) }
        catch ComposioProvisioningError.failed(401) {
            // The server no longer knows this install: register again once, exactly as reports do. Provisioning is
            // idempotent per install.
            value = try await request("v1/composio/provision", auth: try await install(renew: true), body: body)
        }
        guard let key = value["api_key"].string, key.hasPrefix("ak_"), !key.contains("*"), key.utf8.count <= 4096,
              let userID = value["user_id"].string, ComposioClient.validIdentifier(userID),
              let projectID = value["project_id"].string, ComposioClient.validIdentifier(projectID) else { throw ComposioProvisioningError.invalidResponse }
        return .init(apiKey: key, userID: userID, projectID: projectID)
    }

    private func install(renew: Bool) async throws -> SwarmHubAuth {
        do { return .install(try await credential.install(renew: renew)) }
        catch let error as SwarmHubError { throw ComposioProvisioningError(error) }
    }

    private func request(_ path: String, auth: SwarmHubAuth, body: ComposioValue) async throws -> ComposioValue {
        guard Self.validServiceURL(baseURL) else { throw ComposioProvisioningError.unavailable }
        var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.setValue(auth.header, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: ProvisioningNoRedirect()) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ComposioProvisioningError.unreachable }
        guard let http = response as? HTTPURLResponse else { throw ComposioProvisioningError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 503: throw ComposioProvisioningError.notReady
        case 429: throw ComposioProvisioningError.rateLimited
        default: throw ComposioProvisioningError.failed(http.statusCode)
        }
        guard data.count <= 32_000, let value = try? JSONDecoder().decode(ComposioValue.self, from: data) else { throw ComposioProvisioningError.invalidResponse }
        return value
    }

    nonisolated static func validServiceURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    /// The build's connection service: `SWARMHUB_COMPOSIO_SERVICE_URL`, else Info.plist `SWComposioProvisioningURL`; nil
    /// (nothing to connect through) when neither is a plain https address.
    nonisolated static func configuredURL(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        let raw = environment["SWARMHUB_COMPOSIO_SERVICE_URL"] ?? bundle.object(forInfoDictionaryKey: "SWComposioProvisioningURL") as? String ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), validServiceURL(url) else { return nil }
        return url
    }
}

final class ProvisioningNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// This Mac's anonymous SwarmHub install, the same one P36 reports use.
@MainActor protocol SwarmHubInstallCredential {
    /// The stored install, or one registered now; `renew` forgets one the server refused and registers again.
    func install(renew: Bool) async throws -> SwarmHubInstall
}

/// P40: app connections use the reports install (`ReportsCenter`: kept in the v2 key store, read silently, registered
/// with `POST /v1/installs` when this Mac has none). Never a sign-in.
@MainActor struct SwarmHubInstallIdentity: SwarmHubInstallCredential {
    let center: ReportsCenter
    let service: SwarmHubService

    func install(renew: Bool) async throws -> SwarmHubInstall {
        if renew { center.forgetInstall() }
        return try await center.install(service: service)
    }
}

/// The words app connections share with the Settings pane and its tests.
enum ConnectedAppsCopy {
    static let notAvailable = "App connections aren't available yet."
    static let tooManyConnections = "Too many new app connections right now. Try again in a while."
    static let backgroundNotAvailable = "Background app actions are not available yet."
    static let serviceNotConfigured = "App connections through SwarmHub are not set up in this build. Add your own Composio key under Advanced to connect apps."
    static let ownKeyFooter = "App connections belong to SwarmHub. Connected accounts remain in Composio when you remove the key."
    /// P47: the sidebar's bottom-left control; the bots' prompt names it with these words (`ConnectedAppsChat.prompt`).
    static let connectAppsLabel = "Connect apps"
    /// P48: the Connect apps sheet's explanation. Only what the code does: Composio's own page for each sign-in
    /// (`ComposioClient.connect`), its data never kept (`ComposioAccount`), P52: reads run on their own and every other bot
    /// action is approved (`AppToolAccess`, `AppStore.routeApproval`; a team task's named reviewer can decide instead), the
    /// one profile read that names an account (`AccountProfileName`).
    static let composioExplanation = "SwarmHub connects your apps through Composio, a service that keeps your app sign-ins and runs app actions when your bots ask. You sign in to each app on its own page in your browser; SwarmHub never sees your password, and it does not keep the app's tokens. Reading, such as checking your email, runs on its own; each change a bot asks for, such as sending, creating or deleting, waits for your approval in its chat (or for a reviewer bot you named for a team task). To name each new account, SwarmHub reads who it is once, for example your email address. An app you connect here is on for all your bots, and you can disconnect any account at any time."
    /// P52: the rule in one line: the approval card's note and Connected apps (window and Settings).
    static let approvalRule = "Changes in your apps ask you; reading runs on its own."
    static let composioSite = URL(string: "https://composio.dev")!
    static func onForAllBots(_ app: String) -> String { "\(app) is on for all your bots. Turn it off for any bot below." }
}
