import Foundation

/// P12: an OpenClaw agent behind a Gateway, over the hub's shared WebSocket (Gateway RPC, protocol 4). Persona, tools,
/// skills, memory and model stay in the Gateway; `bot.persona` and `systemPrompt` are sent nowhere (OpenClaw has no
/// system-prompt parameter). The session key lives in the bot's `hermesSessionID` (documented reuse).
struct OpenClawBackend: AgentBackend {
    /// P21 D4 / P25 D1: the setup window offers the "which software" step and its OpenClaw connect screen; Settings →
    /// Advanced → Servers and keys still adds Gateways too (P12).
    static let isImplemented = true
    static let historyLimit = 200, historyMaxChars = 20_000
    static let historyTimeout: Duration = .seconds(15), abortTimeout: Duration = .seconds(10)
    static let unboundMessage = "Choose a Gateway and agent in this bot's settings."

    let kind = BackendKind.openClaw
    let gateway: OpenClawGateway
    let binding: OpenClawBinding
    let hub: OpenClawHub
    /// The Gateway's main session name (`agents.list.mainKey`) for `main` mode.
    var mainKey = "main"

    var agentID: String { binding.agentID }
    var secrets: [String] { GatewayCredentials(gateway: gateway, keyStore: hub.keyStore).secrets }

    /// `agent:<agentId>:<name>`, canonical lowercase; `main` mode uses the agent's main session.
    static func sessionKey(agentID: String, name: String) -> String {
        "agent:\(agentID.lowercased()):\(name.lowercased().replacingOccurrences(of: "_", with: "-"))"
    }

    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }

    /// The connected socket and what it can do (connecting first; a send waits up to 30 s).
    func connected() async throws -> (GatewayConnection, OpenClawCapabilities) {
        let connection = try await hub.connection(for: gateway)
        guard let capabilities = await hub.capabilities(gatewayID: gateway.id, connection: connection) else { throw GatewayConnectionError.closed }
        return (connection, capabilities)
    }

    /// Hermes-named flags from the live link only: reading features never connects.
    func features() async throws -> Set<String> {
        guard let connection = await hub.currentConnection(gateway.id) else { return [] }
        return await hub.capabilities(gatewayID: gateway.id, connection: connection)?.hermesFlags ?? []
    }

    /// One request with the error text redacted. Pass `feature` only for optional parameters (steer, fork, titles): an
    /// `INVALID_REQUEST`/unknown method then marks just that feature for this connection; mandatory calls never mark.
    func call(_ connection: GatewayConnection, _ method: String, _ params: GatewayJSON, feature: OpenClawFeature? = nil,
              timeout: Duration = GatewayConnection.defaultTimeout) async throws -> GatewayJSON {
        do { return try await connection.request(method, params: params, timeout: timeout) }
        catch let error as GatewayError {
            if error.isUnsupported, let feature, let connId = await connection.summary?.connId { await hub.marks.mark(feature, gatewayID: gateway.id, connId: connId) }
            throw BackendError.unavailable(GatewayRedactor.redact(error.localizedDescription, secrets: secrets))
        }
    }

    func require(_ feature: OpenClawFeature, in capabilities: OpenClawCapabilities) throws {
        if let reason = capabilities.reason(feature) { throw BackendError.unavailable(reason) }
    }

    /// `sessions.create {agentId, key, displayName, idempotencyKey}`; an existing key is adopted; a rejected optional
    /// parameter retries once with `{agentId, key}`. `systemPrompt` is ignored on purpose.
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String {
        let (connection, capabilities) = try await connected()
        if binding.sessionMode == .main { return Self.sessionKey(agentID: agentID, name: capabilities.summary.mainKey ?? mainKey) }
        try require(.chat, in: capabilities)
        let key = Self.sessionKey(agentID: agentID, name: id ?? UUID().uuidString)
        var params: GatewayJSON = ["agentId": .string(agentID), "key": .string(key)]
        if capabilities.isAvailable(.sessionTitles) {
            params = ["agentId": .string(agentID), "key": .string(key), "displayName": .string("\(AppConstants.name) · \(title)"), "idempotencyKey": .string(key)]
        }
        do { return created(try await connection.request("sessions.create", params: params), key: key) }
        catch let error as GatewayError where error.isUnsupported && params["displayName"] != nil {
            if let connId = await connection.summary?.connId { await hub.marks.mark(.sessionTitles, gatewayID: gateway.id, connId: connId) }
            return created(try await call(connection, "sessions.create", ["agentId": .string(agentID), "key": .string(key)]), key: key)
        } catch let error as GatewayError where Self.alreadyExists(error) {
            return key
        } catch let error as GatewayError {
            throw BackendError.unavailable(GatewayRedactor.redact(error.localizedDescription, secrets: secrets))
        }
    }

    private func created(_ response: GatewayJSON, key: String) -> String { response["key"]?.string ?? key }
    static func alreadyExists(_ error: GatewayError) -> Bool { error.has("SESSION_EXISTS") || error.has("ALREADY_EXISTS") || error.has("CONFLICT") }

    func cancel(sessionID: String) async throws -> StopOutcome { try await requestStop(try await stopTarget(sessionID: sessionID)) }

    /// The ledger's active run for this session, or `noActiveRun`.
    func stopTarget(sessionID: String) async throws -> StopTarget {
        guard let run = await hub.ledger.active(sessionKey: sessionID) else { return .noActiveRun }
        return .serverRun(run.runId)
    }

    /// `chat.abort {sessionKey, agentId, runId}`; a Gateway without `chat.abort` stops locally.
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        guard case .serverRun(let runId) = target else { return target == .disconnectedLegacy ? .disconnectedLegacy : .noActiveRun }
        guard let connection = await hub.currentConnection(gateway.id), let capabilities = await hub.capabilities(gatewayID: gateway.id, connection: connection) else { return .noActiveRun }
        guard capabilities.isAvailable(.stop) else { return .disconnectedLegacy }
        guard let run = await hub.ledger.run(id: runId) else { return .noActiveRun }
        let sessionKey = run.sessionKey
        _ = try await call(connection, "chat.abort", ["sessionKey": .string(sessionKey), "agentId": .string(agentID), "runId": .string(runId)], timeout: Self.abortTimeout)
        return .requested
    }

    func currentRunID(sessionID: String) async -> String? { await hub.ledger.active(sessionKey: sessionID)?.runId }

    /// Settings → Test and the backend probe: connect + `agents.list`.
    func testConnection() async throws -> String { try await hub.test(gateway) }

    /// `sessions.list {agentId, limit: 100}`.
    func listSessions() async throws -> [BackendSession] {
        let (connection, capabilities) = try await connected()
        try require(.sessions, in: capabilities)
        let result = try await call(connection, "sessions.list", ["agentId": .string(agentID), "limit": 100])
        return (result["sessions"]?.array ?? result["rows"]?.array ?? []).compactMap { row in
            guard let key = row["key"]?.string else { return nil }
            return BackendSession(id: key, title: row["displayName"]?.string ?? row["label"]?.string ?? key)
        }
    }

    func resolveApproval(id: UUID, approved: Bool) async throws { throw BackendError.unavailable("This approval has no Gateway id.") }
}
