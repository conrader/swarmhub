import Foundation

struct ProvisionedComposioCredential: Sendable {
    let apiKey: String; let userID: String; let projectID: String
}

@MainActor protocol ComposioProvisioning {
    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential
}

enum ComposioProvisioningError: LocalizedError, Equatable {
    case unavailable, signInRequired, signInUnavailable, invalidResponse, failed(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Automatic app connections are not configured for this build yet."
        case .signInRequired: "Sign in to SwarmHub to connect your first app."
        case .signInUnavailable: ConnectedAppsCopy.signInNotSetUp
        case .invalidResponse: "SwarmHub could not verify the app connection response."
        case .failed(401): "Your SwarmHub sign-in expired. Sign in again to connect an app."
        case .failed(503): "SwarmHub app connections are waiting for server configuration."
        case .failed(let status): "SwarmHub could not prepare your app connection (HTTP \(status)). Try again shortly."
        }
    }
}

/// P38 B: the organization key never enters the app. `POST v1/composio/provision` returns only the signed-in user's
/// project key; the sign-in is main's P36 SwarmHub account (`SwarmHubAccountIdentity`).
@MainActor final class ComposioProvisioningClient: ComposioProvisioning {
    let baseURL: URL
    let session: URLSession
    let identity: any SwarmHubSigningIn

    init(baseURL: URL, session: URLSession = ComposioClient.defaultSession, identity: any SwarmHubSigningIn) {
        self.baseURL = baseURL; self.session = session; self.identity = identity
    }

    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential {
        guard ComposioClient.validIdentifier(toolkit) else { throw ComposioError.invalidIdentifier }
        var token = try await identity.accessToken()
        var value: ComposioValue
        do { value = try await request("v1/composio/provision", token: token, body: .object(["toolkit": .string(toolkit)])) }
        catch ComposioProvisioningError.failed(401) {
            // Only authentication is retried. The server operation is idempotent per signed-in user.
            token = try await identity.accessToken(forceSignIn: true)
            value = try await request("v1/composio/provision", token: token, body: .object(["toolkit": .string(toolkit)]))
        }
        guard let key = value["api_key"].string, key.hasPrefix("ak_"), !key.contains("*"), key.utf8.count <= 4096,
              let userID = value["user_id"].string, ComposioClient.validIdentifier(userID),
              let projectID = value["project_id"].string, ComposioClient.validIdentifier(projectID) else { throw ComposioProvisioningError.invalidResponse }
        return .init(apiKey: key, userID: userID, projectID: projectID)
    }

    private func request(_ path: String, token: String, body: ComposioValue) async throws -> ComposioValue {
        guard Self.validServiceURL(baseURL), !token.isEmpty else { throw ComposioProvisioningError.unavailable }
        var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request, delegate: ProvisioningNoRedirect())
        guard let http = response as? HTTPURLResponse else { throw ComposioProvisioningError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ComposioProvisioningError.failed(http.statusCode) }
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

@MainActor protocol SwarmHubSigningIn {
    func accessToken(forceSignIn: Bool) async throws -> String
}
extension SwarmHubSigningIn {
    func accessToken() async throws -> String { try await accessToken(forceSignIn: false) }
}

/// P38 B: app connections sign in with main's P36 SwarmHub account (`ReportsCenter`: token in the key store, browser
/// sign-in polled by `SwarmHubSignIn`), never a second session of their own.
@MainActor struct SwarmHubAccountIdentity: SwarmHubSigningIn {
    let center: ReportsCenter
    let service: SwarmHubService

    func accessToken(forceSignIn: Bool) async throws -> String {
        if forceSignIn { center.forgetToken(signInAgain: true) }
        if let token = center.token() { return token }
        let signedIn = await center.signIn(service: service)
        if signedIn, let token = center.token() { return token }
        throw center.lastError == SwarmHubError.signInUnavailable.message ? ComposioProvisioningError.signInUnavailable : ComposioProvisioningError.signInRequired
    }
}

/// The words app connections share with the Settings pane and its tests.
enum ConnectedAppsCopy {
    static let signInNotSetUp = "Sign-in to SwarmHub is not set up on the server yet."
    static let serviceNotConfigured = "App connections through SwarmHub are not set up in this build. Add your own Composio key below to connect apps."
}
