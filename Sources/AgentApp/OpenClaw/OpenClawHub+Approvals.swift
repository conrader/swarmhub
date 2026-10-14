import Foundation

/// P12 Part C: one Gateway approval as SwarmHub reads it (`exec.approval.requested` and `exec.approval.list` rows).
struct GatewayApproval: Sendable, Equatable {
    let gatewayID: String
    let id: String
    var command: String?
    var cwd: String?
    var host: String?
    var agentId: String?
    var sessionKey: String?
    var runId: String?
    var expiresAtMs: Int?

    init(gatewayID: String, id: String, command: String? = nil, cwd: String? = nil, host: String? = nil, agentId: String? = nil,
         sessionKey: String? = nil, runId: String? = nil, expiresAtMs: Int? = nil) {
        self.gatewayID = gatewayID; self.id = id; self.command = command; self.cwd = cwd; self.host = host
        self.agentId = agentId; self.sessionKey = sessionKey; self.runId = runId; self.expiresAtMs = expiresAtMs
    }

    /// `{id, request{command | systemRunPlan.commandText, cwd, host, agentId, sessionKey, runId}, createdAtMs, expiresAtMs}`.
    init?(gatewayID: String, json: GatewayJSON) {
        guard let id = json["id"]?.string ?? json["approvalId"]?.string, !id.isEmpty else { return nil }
        let request = json["request"] ?? json
        let plan = request["systemRunPlan"]
        func text(_ value: GatewayJSON?) -> String? { value?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        self.init(gatewayID: gatewayID, id: id, command: text(request["command"]) ?? text(plan?["commandText"]), cwd: text(request["cwd"]) ?? text(plan?["cwd"]),
                  host: text(request["host"]), agentId: text(request["agentId"]) ?? text(plan?["agentId"]),
                  sessionKey: text(request["sessionKey"]) ?? text(plan?["sessionKey"]), runId: text(request["runId"]),
                  expiresAtMs: json["expiresAtMs"]?.int ?? request["expiresAtMs"]?.int)
    }

    func isExpired(now: Date = .now) -> Bool { expiresAtMs.map { Double($0) / 1000 <= now.timeIntervalSince1970 } ?? false }
    var expiresAt: Date? { expiresAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

enum OpenClawApprovalEvent: Sendable, Equatable {
    case requested(GatewayApproval)
    case resolved(gatewayID: String, id: String)
}

extension OpenClawHub {
    static let approvalEvents: Set<String> = ["exec.approval.requested", "exec.approval.resolved"]

    /// Right after `hello-ok`: the listener first, then the `exec.approval.list` backfill, reconciled by approval id so a
    /// transition racing the list is neither lost nor resurrected.
    func installApprovals(gatewayID: String, connection: GatewayConnection, summary: GatewaySummary) async {
        guard summary.hasScope("operator.approvals"), summary.methods.contains("exec.approval.list") || summary.methods.contains("exec.approval.resolve") else { return }
        let (_, events) = await connection.subscribe { Self.approvalEvents.contains($0.event) }
        Task { [weak self] in
            for await event in events { await self?.receiveApproval(event, gatewayID: gatewayID) }
        }
        guard summary.methods.contains("exec.approval.list"), let listed = try? await connection.request("exec.approval.list", params: .object([:])) else { return }
        let rows = listed.array ?? listed["approvals"]?.array ?? listed["items"]?.array ?? listed["pending"]?.array ?? []
        for row in rows { if let approval = GatewayApproval(gatewayID: gatewayID, json: row) { publish(approval) } }
    }

    private func receiveApproval(_ event: GatewayEvent, gatewayID: String) {
        if event.event == "exec.approval.resolved" {
            guard let id = event.payload["id"]?.string ?? event.payload["approvalId"]?.string else { return }
            resolvedApprovals[gatewayID, default: []].insert(id)
            approvalSink.yield(.resolved(gatewayID: gatewayID, id: id))
        } else if let approval = GatewayApproval(gatewayID: gatewayID, json: event.payload) {
            publish(approval)
        }
    }

    private func publish(_ approval: GatewayApproval) {
        guard !resolvedApprovals[approval.gatewayID, default: []].contains(approval.id),
              publishedApprovals[approval.gatewayID, default: []].insert(approval.id).inserted else { return }
        approvalSink.yield(.requested(approval))
    }
}

/// `exec.approval.resolve {id, decision}`: only `allow-once` or `deny`, never `allow-always` (a standing grant).
extension OpenClawBackend {
    static func decision(approved: Bool) -> String { approved ? "allow-once" : "deny" }

    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws {
        guard let id = approval.requestID else { throw BackendError.unavailable("This approval has no Gateway id.") }
        let (connection, capabilities) = try await connected()
        try require(.approvals, in: capabilities)
        _ = try await call(connection, "exec.approval.resolve", ["id": .string(id), "decision": .string(Self.decision(approved: approved))], feature: .approvals)
    }
}
