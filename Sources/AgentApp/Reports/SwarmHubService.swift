import CryptoKit
import Foundation

/// P36: the SwarmHub backend (`https://agenthut.net/swarmhub`): reports with a per-install key, and an optional desktop
/// PKCE sign-in. One base URL, overridable in Settings → Advanced for tests; every request goes through an injected session.
enum SwarmHubError: Error, Equatable {
    /// 401: the token (or install key) is gone or expired; it is forgotten.
    case unauthorized
    /// `/v1/auth/start` answered 503: sign-in is not configured on the server (reports still work).
    case signInUnavailable
    /// 429: too many reports in the last hour.
    case rateLimited
    /// The callback came back with another state than the app made.
    case stateMismatch
    /// No callback within the poll window (10 minutes).
    case timedOut
    case badResponse(Int)
    case invalid
    case network(String)

    var message: String {
        switch self {
        case .unauthorized: "Your SwarmHub sign-in has ended. Sign in again."
        case .signInUnavailable: "SwarmHub sign-in isn't available yet."
        case .rateLimited: "SwarmHub has had many reports from you in the last hour. Try again later."
        case .stateMismatch: "The sign-in did not match this request. Try again."
        case .timedOut: "The sign-in was not finished within 10 minutes. Try again."
        case .badResponse(let code): "SwarmHub answered with an error (\(code)). Try again later."
        case .invalid: "SwarmHub sent an answer this version cannot read."
        case .network(let text): "Could not reach SwarmHub: \(text)"
        }
    }
}

/// The sign-in's one-time values: `verifier` (43 url-safe chars), `state` (22) and `challenge = base64url(sha256(verifier))`.
struct PKCE: Equatable, Sendable {
    let verifier: String, state: String

    var challenge: String { Self.challenge(for: verifier) }

    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }

    static func make() -> PKCE { PKCE(verifier: randomURLSafe(bytes: 32), state: randomURLSafe(bytes: 16)) }

    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func isURLSafe(_ text: String, length: ClosedRange<Int>) -> Bool {
        length.contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }
    }
}

/// The signed-in account: kept in the key store under `account` as JSON, never in store.json or logs.
struct SwarmHubToken: Codable, Equatable, Sendable {
    static let account = "swarmhub.account"
    var accessToken: String; var expiresAt: Date
    func isValid(at now: Date) -> Bool { !accessToken.isEmpty && expiresAt > now }
}

/// This Mac's anonymous reporter (`POST /v1/installs`): kept in the key store under `account` as JSON, never in
/// store.json or logs.
struct SwarmHubInstall: Codable, Equatable, Sendable {
    static let account = "swarmhub.install"
    var installID: String; var installKey: String
}

/// How a reports request is authorised: the sign-in's token when there is one, otherwise the install key.
enum SwarmHubAuth: Equatable, Sendable {
    case bearer(String)
    case install(SwarmHubInstall)

    var header: String {
        switch self {
        case .bearer(let token): "Bearer \(token)"
        case .install(let install): "Install \(install.installID).\(install.installKey)"
        }
    }
}

/// The body of `POST /v1/reports`; optional fields are left out when empty, limits are applied here.
struct ReportPayload: Encodable, Equatable {
    var kind: String, title: String, body: String, source: String
    var bot: String?, botBackend: String?, appVersion: String?, skillVersions: [String: String]?, hermesVersion: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, body, source, bot, botBackend = "bot_backend", appVersion = "app_version", skillVersions = "skill_versions", hermesVersion = "hermes_version"
    }

    /// Nil when the title or body is empty after trimming.
    init?(_ report: SwarmReport, appVersion: String) {
        let title = report.title.trimmingCharacters(in: .whitespacesAndNewlines), body = report.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return nil }
        kind = report.kind.rawValue; source = report.source.rawValue
        self.title = String(title.prefix(SwarmReport.titleLimit)); self.body = String(body.prefix(SwarmReport.bodyLimit))
        bot = report.source == .agent ? report.bot : nil; botBackend = report.source == .agent ? report.botBackend : nil
        self.appVersion = report.appVersion ?? appVersion
        let versions = SwarmReport.cleanVersions(report.skillVersions)
        skillVersions = versions.isEmpty ? nil : versions; hermesVersion = report.hermesVersion
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(title, forKey: .title); try c.encode(body, forKey: .body); try c.encode(source, forKey: .source)
        try c.encodeIfPresent(bot, forKey: .bot); try c.encodeIfPresent(botBackend, forKey: .botBackend); try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(skillVersions, forKey: .skillVersions); try c.encodeIfPresent(hermesVersion, forKey: .hermesVersion)
    }
}

struct SwarmHubService: Sendable {
    static let defaultBaseURL = "https://agenthut.net/swarmhub"
    static let baseURLKey = "swarmhubServiceURL"

    let baseURL: URL
    let session: URLSession

    // MARK: Sign-in

    func startSignIn(_ pkce: PKCE) async throws -> URL {
        let data: Data
        do { data = try await call("POST", "v1/auth/start", body: ["challenge": pkce.challenge, "state": pkce.state]) }
        catch SwarmHubError.badResponse(503) { throw SwarmHubError.signInUnavailable }
        let json = try object(data)
        guard let raw = json["authorization_url"] as? String, let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else { throw SwarmHubError.invalid }
        return url
    }

    /// The callback URL once the browser finished; nil while waiting.
    func signInStatus(serverState: String) async throws -> URL? {
        var parts = URLComponents(); parts.queryItems = [URLQueryItem(name: "state", value: serverState)]
        let json = try object(try await call("GET", "v1/auth/status?\(parts.percentEncodedQuery ?? "")"))
        guard let raw = json["callback_url"] as? String else { return nil }
        guard let url = URL(string: raw) else { throw SwarmHubError.invalid }
        return url
    }

    func exchange(code: String, verifier: String, now: Date = Date()) async throws -> SwarmHubToken {
        let json = try object(try await call("POST", "v1/auth/exchange", body: ["code": code, "verifier": verifier]))
        guard let token = json["access_token"] as? String, !token.isEmpty else { throw SwarmHubError.invalid }
        return SwarmHubToken(accessToken: token, expiresAt: SwarmHubDates.parse(json["expires_at"]) ?? now.addingTimeInterval(30 * 86_400))
    }

    // MARK: Reports

    /// `POST /v1/installs` with `{}` (no auth): 201 with the install's id and key; 429 and 503 are errors.
    func registerInstall() async throws -> SwarmHubInstall {
        let json = try object(try await call("POST", "v1/installs", data: Data("{}".utf8)))
        guard let id = json["install_id"] as? String, !id.isEmpty, let key = json["install_key"] as? String, !key.isEmpty else { throw SwarmHubError.invalid }
        return SwarmHubInstall(installID: id, installKey: key)
    }

    func postReport(_ payload: ReportPayload, auth: SwarmHubAuth) async throws -> (id: String, status: String) {
        let data = try JSONEncoder().encode(payload)
        let json = try object(try await call("POST", "v1/reports", data: data, auth: auth))
        guard let id = (json["id"] as? String) ?? (json["id"] as? Int).map(String.init) else { throw SwarmHubError.invalid }
        return (id, json["status"] as? String ?? "received")
    }

    /// `{"reports": [...]}`; a bare array is read too.
    func listReports(auth: SwarmHubAuth) async throws -> [ServerReport] {
        let data = try await call("GET", "v1/reports", auth: auth)
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let rows = ((json as? [String: Any])?["reports"] ?? json) as? [[String: Any]] else { throw SwarmHubError.invalid }
        return rows.compactMap(ServerReport.init)
    }

    // MARK: HTTP

    func request(_ method: String, _ path: String, data: Data? = nil, auth: SwarmHubAuth? = nil) -> URLRequest {
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let auth { request.setValue(auth.header, forHTTPHeaderField: "Authorization") }
        request.setValue(AppConstants.userAgent(version: AppBuildInfo.current().version), forHTTPHeaderField: "User-Agent")
        return request
    }

    private func call(_ method: String, _ path: String, body: [String: String]? = nil, data: Data? = nil, auth: SwarmHubAuth? = nil) async throws -> Data {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? data
        let (result, response): (Data, URLResponse)
        do { (result, response) = try await session.data(for: request(method, path, data: payload, auth: auth)) }
        catch { throw SwarmHubError.network(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return result
        case 401: throw SwarmHubError.unauthorized
        case 429: throw SwarmHubError.rateLimited
        default: throw SwarmHubError.badResponse(code)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SwarmHubError.invalid }
        return json
    }
}

/// P36: the desktop sign-in: start, open the browser, poll the server's state every second (10 minutes at most), check
/// the callback's state against the app's, exchange the code. Sleep and the browser are injected for tests.
enum SwarmHubSignIn {
    static func run(_ service: SwarmHubService, pkce: PKCE = .make(), maxPolls: Int = 600, interval: Duration = .seconds(1),
                    open: @Sendable (URL) async -> Void, sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> SwarmHubToken {
        let authorization = try await service.startSignIn(pkce)
        guard let serverState = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
              !serverState.isEmpty else { throw SwarmHubError.invalid }
        await open(authorization)
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            if let callback = try await service.signInStatus(serverState: serverState) {
                let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw SwarmHubError.stateMismatch }
                guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw SwarmHubError.invalid }
                return try await service.exchange(code: code, verifier: pkce.verifier)
            }
            try await sleep(interval)
        }
        throw SwarmHubError.timedOut
    }
}
