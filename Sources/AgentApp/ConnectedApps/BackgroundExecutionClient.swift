import Foundation

/// P38 B: the SwarmHub service's `v1/execution/*` routes for a scoped worker on the bot's server: register or revoke a
/// bot's worker, read the inbox, answer a waiting action. Signed in with main's SwarmHub account.
@MainActor struct BackgroundExecutionClient {
    let baseURL: URL
    let identity: any SwarmHubSigningIn
    var session: URLSession = ComposioClient.defaultSession

    func request(_ path: String, body: ComposioValue? = nil) async throws -> ComposioValue {
        guard ComposioProvisioningClient.validServiceURL(baseURL) else { throw ComposioProvisioningError.unavailable }
        let token = try await identity.accessToken()
        var request = URLRequest(url: baseURL.appending(path: "v1/execution/" + path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await session.data(for: request, delegate: ProvisioningNoRedirect())
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ComposioProvisioningError.invalidResponse }
        guard (200..<300).contains(status) else { throw ComposioProvisioningError.failed(status) }
        guard data.count <= 12 * 1024 * 1024 else { throw ComposioError.tooLarge }
        return try JSONDecoder().decode(ComposioValue.self, from: data)
    }
}
