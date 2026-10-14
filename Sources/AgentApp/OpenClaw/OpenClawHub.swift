import Foundation

/// P12: one WebSocket per saved Gateway, shared by its bots. `AppStore` creates the hub lazily (nothing at launch);
/// first use connects and the link stays up. States reach the main actor in order through one stream.
actor OpenClawHub {
    nonisolated let status: OpenClawStatus
    let keyStore: any HermesKeyStore
    private let makeTransport: GatewayTransportFactory
    private let clock: any GatewayClock
    private let jitter: @Sendable () -> Double
    private let states: AsyncStream<(String, GatewayState)>.Continuation
    private var links: [String: GatewayLink] = [:]
    /// Runtime "this Gateway rejected that parameter" marks, and the active run per session (Stop, run marks).
    nonisolated let marks = OpenClawRuntimeMarks()
    nonisolated let ledger = OpenClawRunLedger()
    /// Approval requests and resolutions from every connected Gateway, on one stream `AppStore` consumes (Part C).
    nonisolated let approvals: AsyncStream<OpenClawApprovalEvent>
    let approvalSink: AsyncStream<OpenClawApprovalEvent>.Continuation
    /// Per Gateway: approval ids already published, and ids resolved (so a backfill racing a resolution never resurrects one).
    var publishedApprovals: [String: Set<String>] = [:], resolvedApprovals: [String: Set<String>] = [:]

    init(status: OpenClawStatus, keyStore: any HermesKeyStore, makeTransport: @escaping GatewayTransportFactory = { WebSocketTransport() },
         clock: any GatewayClock = SystemGatewayClock(), jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }) {
        self.status = status; self.keyStore = keyStore; self.makeTransport = makeTransport; self.clock = clock; self.jitter = jitter
        let (stream, continuation) = AsyncStream.makeStream(of: (String, GatewayState).self)
        states = continuation
        (approvals, approvalSink) = AsyncStream.makeStream(of: OpenClawApprovalEvent.self)
        Task { @MainActor in for await (id, state) in stream { status.set(state, for: id) } }
    }

    /// The link for this Gateway; an edited Gateway (address, flags, device name) replaces the old link.
    func link(for gateway: OpenClawGateway) async -> GatewayLink {
        if let link = links[gateway.id], link.gateway == gateway { return link }
        if let old = links.removeValue(forKey: gateway.id) { await old.disconnect() }
        let states = states, id = gateway.id
        let link = GatewayLink(gateway: gateway, credentials: GatewayCredentials(gateway: gateway, keyStore: keyStore), makeTransport: makeTransport,
                               clock: clock, jitter: jitter, publish: { states.yield((id, $0)) },
                               onConnected: { [weak self] connection, summary in await self?.didConnect(gatewayID: id, connection: connection, summary: summary) })
        links[gateway.id] = link
        return link
    }

    func existingLink(_ gatewayID: String) -> GatewayLink? { links[gatewayID] }

    /// A connected socket for this Gateway (connecting first, waiting up to `timeout`).
    func connection(for gateway: OpenClawGateway, timeout: Duration = GatewayLink.readyTimeout) async throws -> GatewayConnection {
        try await link(for: gateway).ready(timeout: timeout)
    }

    /// The socket only when the link is already up (feature reads and launch never connect).
    func currentConnection(_ gatewayID: String) async -> GatewayConnection? {
        guard let link = links[gatewayID], await link.state.isConnected, let connection = await link.connection, await !connection.isClosed else { return nil }
        return connection
    }

    func state(_ gatewayID: String) async -> GatewayState { await links[gatewayID]?.state ?? .disconnected }

    /// What this connection can do: `hello-ok` plus the runtime marks for its `connId`.
    func capabilities(gatewayID: String, connection: GatewayConnection) async -> OpenClawCapabilities? {
        guard let summary = await connection.summary else { return nil }
        return OpenClawCapabilities(summary: summary, unsupported: await marks.unsupported(gatewayID: gatewayID, connId: summary.connId))
    }

    func connect(_ gateway: OpenClawGateway) async { await link(for: gateway).connect() }
    func disconnect(_ gatewayID: String) async { await links[gatewayID]?.disconnect() }

    /// Forget: the link goes; the caller deletes the Keychain items.
    func forget(_ gatewayID: String) async {
        await links.removeValue(forKey: gatewayID)?.disconnect()
        await MainActor.run { [status] in status.forget(gatewayID) }
    }

    /// `NSWorkspace.didWakeNotification`: every link that is down tries at once.
    func wake() async { for link in links.values { await link.retryNow() } }

    // MARK: Agents and Test

    /// `agents.list`, remembered for the editor pickers and "Add bots".
    func agents(for gateway: OpenClawGateway) async throws -> (agents: [OpenClawAgent], defaultId: String?, mainKey: String?) {
        let connection = try await connection(for: gateway)
        let result = OpenClawAgent.list(try await connection.request("agents.list", params: .object([:])))
        await MainActor.run { [status] in status.agents[gateway.id] = result.agents }
        return result
    }

    /// Settings → Test (and `testConnection`): connect + `agents.list`, one line with no secrets.
    func test(_ gateway: OpenClawGateway) async throws -> String {
        let connection = try await connection(for: gateway)
        let summary = await connection.summary ?? GatewaySummary(protocolVersion: OpenClawClient.protocolVersion, serverVersion: "")
        let listed = try await agents(for: gateway)
        return Self.testLine(summary, agentCount: listed.agents.count)
    }

    static func testLine(_ summary: GatewaySummary, agentCount: Int) -> String {
        var parts = ["OpenClaw \(summary.serverVersion.isEmpty ? "?" : summary.serverVersion)", "protocol \(summary.protocolVersion)",
                     "scopes \(summary.scopes.isEmpty ? "none" : summary.scopes.joined(separator: ", "))", "\(agentCount) agent\(agentCount == 1 ? "" : "s")"]
        if let bytes = summary.maxAttachmentBytes { parts.append("attachments up to \(megabytes(bytes))") }
        return parts.joined(separator: " · ")
    }

    static func megabytes(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_048_576
        return value.rounded() == value ? "\(Int(value)) MB" : String(format: "%.1f MB", value)
    }

    private func didConnect(gatewayID: String, connection: GatewayConnection, summary: GatewaySummary) async {
        await installApprovals(gatewayID: gatewayID, connection: connection, summary: summary)
    }
}

/// The run a session is streaming (one per session key), for Stop and the row's run mark.
actor OpenClawRunLedger {
    struct Run: Sendable, Equatable { let sessionKey: String; let agentId: String; let runId: String }
    private var runs: [String: Run] = [:]
    /// Recent runs by id, kept after they end: Stop builds `chat.abort` after the stream it cancels has cleaned up.
    private var recent: [Run] = []
    func start(_ run: Run) { runs[run.sessionKey.lowercased()] = run; recent = Array((recent.filter { $0.runId != run.runId } + [run]).suffix(50)) }
    func finish(sessionKey: String, runId: String) { if runs[sessionKey.lowercased()]?.runId == runId { runs[sessionKey.lowercased()] = nil } }
    func active(sessionKey: String) -> Run? { runs[sessionKey.lowercased()] }
    func run(id runId: String) -> Run? { runs.values.first { $0.runId == runId } ?? recent.last { $0.runId == runId } }
    /// A steer's own run id (when it is not the active run, which a steer can join).
    private(set) var ignored: Set<String> = []
    func ignore(_ runId: String, sessionKey: String) { if runs[sessionKey.lowercased()]?.runId != runId { ignored.insert(runId) } }
    /// Every active run id (approvals for these runs follow the bot's policy; others are ask-only).
    var runIds: Set<String> { Set(runs.values.map(\.runId)) }
}
