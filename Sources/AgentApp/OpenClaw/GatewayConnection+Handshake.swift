import Foundation

/// P12: who SwarmHub says it is, in one place. SwarmHub has no `client.id` of its own, so it rides the generic
/// `gateway-client` id in `ui` mode; changing any of these later can make the Gateway ask for a `metadata-upgrade`.
enum OpenClawClient {
    static let id = "gateway-client"
    static let mode = "ui"
    static let platform = "macos"
    static let deviceFamily = "Mac"
    static let role = "operator"
    static let protocolVersion = 4
    /// Least privilege: a chat client that renders approval prompts. Never `operator.admin`.
    static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    static let caps = ["chat-only-assistant-text", "tool-events", "exec-approvals"]
    static let challengeTimeout: Duration = .seconds(15)
    static let connectTimeout: Duration = .seconds(30)

    static var version: String {
        let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return value.isEmpty ? "0.0.0" : value
    }
}

/// What `hello-ok` said, minus the device token (which goes straight to the Keychain).
struct GatewaySummary: Sendable, Equatable {
    var protocolVersion: Int
    var serverVersion: String
    var connId = ""
    var methods: Set<String> = []
    var events: Set<String> = []
    var role = ""
    var scopes: [String] = []
    var maxPayload = 25 * 1024 * 1024
    var maxBufferedBytes = 0
    var tickIntervalMs = 15_000
    var maxAttachmentBytes: Int?
    var maxImageBytes: Int?
    /// `snapshot.sessionDefaults`: the main session name and default agent, when sent.
    var mainKey: String?
    var defaultAgentId: String?

    init(protocolVersion: Int, serverVersion: String) { self.protocolVersion = protocolVersion; self.serverVersion = serverVersion }

    init?(hello payload: GatewayJSON) {
        guard let version = payload["protocol"]?.int else { return nil }
        protocolVersion = version
        serverVersion = payload["server"]?["version"]?.string ?? ""
        connId = payload["server"]?["connId"]?.string ?? ""
        methods = Set(payload["features"]?["methods"]?.strings ?? [])
        events = Set(payload["features"]?["events"]?.strings ?? [])
        role = payload["auth"]?["role"]?.string ?? ""
        scopes = payload["auth"]?["scopes"]?.strings ?? []
        let policy = payload["policy"]
        maxPayload = policy?["maxPayload"]?.int ?? maxPayload
        maxBufferedBytes = policy?["maxBufferedBytes"]?.int ?? 0
        tickIntervalMs = policy?["tickIntervalMs"]?.int ?? tickIntervalMs
        maxAttachmentBytes = policy?["attachments"]?["maxBytes"]?.int
        maxImageBytes = policy?["attachments"]?["maxImageBytes"]?.int
        mainKey = payload["snapshot"]?["sessionDefaults"]?["mainKey"]?.string
        defaultAgentId = payload["snapshot"]?["sessionDefaults"]?["defaultAgentId"]?.string
    }

    func hasScope(_ scope: String) -> Bool { scopes.contains(scope) || scopes.contains("operator.admin") }
}

/// The credential a connect presents (and signs with).
enum ConnectAuth: Sendable, Equatable {
    case none, shared(String), device(String)
    var token: String {
        switch self { case .none: ""; case .shared(let value), .device(let value): value }
    }
    var json: GatewayJSON? {
        switch self {
        case .none: nil
        case .shared(let value): .object(["token": .string(value)])
        case .device(let value): .object(["deviceToken": .string(value)])
        }
    }
}

enum OpenClawConnect {
    /// The one `connect` params object: nothing beyond what the brief lists (no locale, commands, permissions).
    static func params(identity: GatewayIdentity, challenge: GatewayChallenge, auth: ConnectAuth, displayName: String,
                       signatureVersion: Int, version: String = OpenClawClient.version) throws -> GatewayJSON {
        let fields = DeviceAuthPayload.Fields(deviceId: identity.deviceId, clientId: OpenClawClient.id, clientMode: OpenClawClient.mode,
                                              role: OpenClawClient.role, scopes: OpenClawClient.scopes, signedAtMs: challenge.ts,
                                              token: auth.token, nonce: challenge.nonce, platform: OpenClawClient.platform,
                                              deviceFamily: OpenClawClient.deviceFamily)
        let payload = signatureVersion == 2 ? DeviceAuthPayload.v2(fields) : DeviceAuthPayload.v3(fields)
        var client: [String: GatewayJSON] = ["id": .string(OpenClawClient.id), "version": .string(version), "platform": .string(OpenClawClient.platform),
                                           "mode": .string(OpenClawClient.mode), "deviceFamily": .string(OpenClawClient.deviceFamily)]
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { client["displayName"] = .string(name) }
        var params: [String: GatewayJSON] = [
            "minProtocol": .int(OpenClawClient.protocolVersion), "maxProtocol": .int(OpenClawClient.protocolVersion),
            "client": .object(client), "caps": .array(OpenClawClient.caps.map { .string($0) }), "role": .string(OpenClawClient.role),
            "scopes": .array(OpenClawClient.scopes.map { .string($0) }),
            "device": .object(["id": .string(identity.deviceId), "publicKey": .string(identity.publicKey), "signature": .string(try identity.sign(payload)),
                               "signedAt": .int(challenge.ts), "nonce": .string(challenge.nonce)]),
            "userAgent": .string(AppConstants.userAgent(version: version))
        ]
        if let auth = auth.json { params["auth"] = auth }
        return .object(params)
    }
}

extension GatewayConnection {
    /// Waits for the challenge, sends ONE `connect`, and returns the summary and the issued device token (if any).
    /// Throws the Gateway's `GatewayError`, `noChallenge`, or `GatewayFailure.unsupportedProtocol`.
    func handshake(identity: GatewayIdentity, auth: ConnectAuth, displayName: String, signatureVersion: Int,
                   challengeTimeout: Duration = OpenClawClient.challengeTimeout) async throws -> (summary: GatewaySummary, deviceToken: String?) {
        let challenge = try await awaitChallenge(timeout: challengeTimeout)
        let params = try OpenClawConnect.params(identity: identity, challenge: challenge, auth: auth, displayName: displayName, signatureVersion: signatureVersion)
        let payload = try await request("connect", params: params, timeout: OpenClawClient.connectTimeout)
        guard let summary = GatewaySummary(hello: payload) else { throw GatewayConnectionError.badChallenge }
        guard summary.protocolVersion == OpenClawClient.protocolVersion else {
            throw GatewayFailure.unsupportedProtocol(expected: OpenClawClient.protocolVersion, server: summary.protocolVersion)
        }
        didHello(summary)
        let token = payload["auth"]?["deviceToken"]?.string
        return (summary, token?.isEmpty == false ? token : nil)
    }
}

/// What one failed connect means for the link (pure; tested on its own).
enum ConnectVerdict: Equatable {
    case pairing(requestId: String?, reason: String?)
    case signatureInvalid
    case tokenMismatch(canRetryWithDeviceToken: Bool)
    case deviceTokenRejected
    case retryAfter(Duration, GatewayFailure?)
    case backOff(GatewayFailure)
    case terminal(GatewayFailure)

    static func classify(_ error: GatewayError) -> ConnectVerdict {
        let after = error.retryAfterMs.map { Duration.milliseconds($0) }
        if error.has("PAIRING_REQUIRED") || error.has("NOT_PAIRED") { return .pairing(requestId: error.details?.requestId, reason: error.details?.reason) }
        if error.has("DEVICE_AUTH_SIGNATURE_INVALID") { return .signatureInvalid }
        if error.has("AUTH_DEVICE_TOKEN_MISMATCH") { return .deviceTokenRejected }
        if error.has("AUTH_TOKEN_MISMATCH") || error.has("AUTH_PASSWORD_MISMATCH") { return .tokenMismatch(canRetryWithDeviceToken: error.details?.canRetryWithDeviceToken == true) }
        if error.has("AUTH_TOKEN_MISSING") || error.has("AUTH_PASSWORD_MISSING") { return .terminal(.tokenMissing) }
        if error.has("AUTH_RATE_LIMITED") { return .retryAfter(after ?? .seconds(30), .rateLimited(retryAfter: after)) }
        if error.has("PROTOCOL_MISMATCH") { return .terminal(.unsupportedProtocol(expected: OpenClawClient.protocolVersion, server: nil)) }
        if error.has("OPERATOR_ACCESS_DENIED") { return .backOff(.accessDenied) }
        if error.has("AUTH_SCOPE_MISMATCH") {
            let missing = error.details?.missingScope.map { [$0] } ?? error.details?.requiredScopes ?? []
            return .terminal(.insufficientScopes(missing: missing))
        }
        if error.has("UNAVAILABLE"), error.details?.reason == "startup-sidecars" || error.retryable { return .retryAfter(after ?? .seconds(2), nil) }
        return .terminal(.rejected(code: error.details?.code ?? error.code, message: error.message))
    }
}
