import AppKit
import Foundation

/// P12: saved OpenClaw Gateways and their links. The Gateway list is read from UserDefaults at launch (no network);
/// the hub exists only once something asks for it.
extension Bot {
    /// Group chats stay Hermes and Mock for now (OpenClaw members are P12b).
    var joinsGroups: Bool { backend != .openClaw }
}

extension AppStore {
    var gatewayStore: GatewayStore { GatewayStore(defaults: defaults, keyStore: keyStore) }
    var openClawStatus: OpenClawStatus { openClawHub.status }

    func makeOpenClawHub() -> OpenClawHub {
        let hub = injectedOpenClawHub ?? OpenClawHub(status: OpenClawStatus(), keyStore: keyStore)
        openClawWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await hub.wake() }
        }
        Task { [weak self] in for await event in hub.approvals { await self?.receiveOpenClawApproval(event) } }
        return hub
    }

    /// Launch: the list only, plus the one-time move of the pre-P12 `openClawURL` setting.
    func loadOpenClawGateways() {
        gatewayStore.migrateLegacyURL()
        openClawGateways = gatewayStore.load()
    }

    func gateway(id: String?) -> OpenClawGateway? { id.flatMap { id in openClawGateways.first { $0.id == id } } }

    /// Add/Edit → Save: the entry, and the token written once (a blank field keeps the stored one on Edit).
    func saveGateway(_ gateway: OpenClawGateway, token: String?) async {
        gatewayStore.upsert(gateway)
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GatewayCredentials(gateway: gateway, keyStore: keyStore).setSharedToken(token)
        }
        openClawGateways = gatewayStore.load()
        _ = await openClawHub.link(for: gateway) // an edited Gateway replaces its link; nothing connects here
    }

    /// Forget: the three Keychain items and the entry go; bots stay, unbound (their chats remain).
    func forgetGateway(_ gateway: OpenClawGateway) async {
        await openClawHub.forget(gateway.id)
        gatewayStore.forget(gateway)
        for bot in bots where bot.openClaw?.gatewayID == gateway.id { bot.openClaw = nil }
        openClawGateways = gatewayStore.load(); objectWillChange.send(); save()
    }

    func connectGateway(_ gateway: OpenClawGateway) async { await openClawHub.connect(gateway) }
    func disconnectGateway(_ gateway: OpenClawGateway) async { await openClawHub.disconnect(gateway.id) }

    /// Settings → Test: one line, no secrets; a failure is the state's own line.
    func testGateway(_ gateway: OpenClawGateway) async -> String {
        do { return try await openClawHub.test(gateway) }
        catch { return redactedOpenClaw(error, gateway: gateway) }
    }

    func redactedOpenClaw(_ error: Error, gateway: OpenClawGateway) -> String {
        GatewayRedactor.redact(error.localizedDescription, secrets: GatewayCredentials(gateway: gateway, keyStore: keyStore).secrets)
    }

    /// The command that removes this Mac's pairing on the Gateway host (shown after Forget).
    func removeDeviceCommand(for gateway: OpenClawGateway) -> String? {
        guard let identity = try? existingIdentity(for: gateway) else { return nil }
        return "openclaw devices remove \(identity.deviceId)"
    }

    /// The stored identity only (never creates one).
    func existingIdentity(for gateway: OpenClawGateway) throws -> GatewayIdentity? {
        guard keyStore.hasKey(for: gateway.deviceKeyAccount) else { return nil }
        return try GatewayIdentity.loadOrCreate(gatewayID: gateway.id, store: keyStore)
    }
}

/// P12 Part B: OpenClaw bots.
extension AppStore {
    struct OpenClawAdd: Equatable { let name: String; let added: Bool }

    /// "Add bots from this Gateway…": lists the agents, then `appendOpenClawBots` for all of them.
    @discardableResult func addBotsFromGateway(_ gateway: OpenClawGateway, only chosen: Set<String>? = nil) async throws -> [OpenClawAdd] {
        let listed = try await openClawHub.agents(for: gateway)
        let results = appendOpenClawBots(listed.agents, gatewayID: gateway.id, only: chosen).results
        objectWillChange.send(); save()
        return results
    }

    /// One bot per (Gateway, agent) in `chosen` (nil = every agent), idempotent, never removes a bot; own avatars only.
    /// Shared by Settings ("Add bots", all) and the setup window (the ticked agents, P25 D5). The caller saves.
    func appendOpenClawBots(_ agents: [OpenClawAgent], gatewayID: String, only chosen: Set<String>? = nil) -> (results: [OpenClawAdd], added: [Bot]) {
        var results: [OpenClawAdd] = [], added: [Bot] = []
        for agent in agents where chosen?.contains(agent.id) ?? true {
            if bots.contains(where: { $0.backend == .openClaw && $0.openClaw?.gatewayID == gatewayID && $0.openClaw?.agentID == agent.id }) {
                results.append(.init(name: agent.displayName, added: false)); continue
            }
            let bot = Bot(name: agent.displayName, title: "OpenClaw agent", persona: "", backend: .openClaw)
            bot.openClaw = OpenClawBinding(gatewayID: gatewayID, agentID: agent.id)
            bots.append(bot); added.append(bot); results.append(.init(name: agent.displayName, added: true))
        }
        return (results, added)
    }

    /// Agent ids already bound to a bot on this Gateway (shown "Already added" in the setup window).
    func openClawAgentIDs(boundTo gatewayID: String?) -> Set<String> {
        guard let gatewayID else { return [] }
        return Set(bots.filter { $0.backend == .openClaw && $0.openClaw?.gatewayID == gatewayID }.compactMap { $0.openClaw?.agentID })
    }

    /// The editor's agent list (connects: the user asked for it).
    func loadOpenClawAgents(_ gatewayID: String) async -> String? {
        guard let gateway = gateway(id: gatewayID) else { return nil }
        do { _ = try await openClawHub.agents(for: gateway); return nil } catch { return redactedOpenClaw(error, gateway: gateway) }
    }

    /// Why this bot cannot send now (unbound, unpaired, failed, read-only); nil when it can (a send while connecting
    /// waits up to 30 s). Reads the published state only.
    func openClawBlock(_ bot: Bot) -> String? {
        guard bot.backend == .openClaw, backendFactory == nil || bot.openClaw != nil else { return nil }
        guard let binding = bot.openClaw, gateway(id: binding.gatewayID) != nil else { return OpenClawBackend.unboundMessage }
        let state = openClawStatus.state(for: binding.gatewayID)
        switch state {
        case .pairingRequired, .failed: return state.line()
        case .connected(let summary) where !summary.hasScope("operator.write"): return state.line()
        default: return nil
        }
    }

    /// A non-blocking line while the link is coming up.
    func openClawNotice(_ bot: Bot) -> String? {
        guard bot.backend == .openClaw, let id = bot.openClaw?.gatewayID, gateway(id: id) != nil else { return nil }
        let state = openClawStatus.state(for: id)
        return state.isWorking ? state.line() : nil
    }

    func retryOpenClaw(_ bot: Bot) {
        guard let gateway = gateway(id: bot.openClaw?.gatewayID) else { return }
        Task { await openClawHub.link(for: gateway).retryNow() }
    }
}

/// P12 Part C: Gateway approvals. Each attaches to the bot whose session matches, else to the bot bound to the same
/// agent ("from another session"); with no such bot it is left for the Gateway's other clients and never resolved here.
/// Approvals for a run this app started follow the bot's policy (Ask me, Rules, Reviewer); every other one, the
/// Gateway's own automations included, is ask-only. A resolution elsewhere, or the expiry, removes the card.
extension AppStore {
    func receiveOpenClawApproval(_ event: OpenClawApprovalEvent) async {
        switch event {
        case .resolved(let gatewayID, let id):
            let onGateway = Set(bots.filter { $0.openClaw?.gatewayID == gatewayID }.map(\.id))
            approvals.removeAll { approval in approval.requestID == id && approval.botID.map(onGateway.contains) == true }
        case .requested(let approval):
            guard !approval.isExpired(), !approvals.contains(where: { $0.requestID == approval.id }), let (bot, ownSession) = openClawBot(for: approval) else { return }
            let request = Self.approvalRequest(approval, bot: bot, ownSession: ownSession)
            let activeRuns = await openClawHub.ledger.runIds
            let ownRun = approval.runId.map(activeRuns.contains) ?? false
            // A Reviewer decision can take seconds; it must not hold up later approvals and resolutions on the stream.
            if ownSession, ownRun, !approval.commandsDisagree, let activeBackend = try? backend(for: bot) { Task { await routeApproval(request, for: bot, backend: activeBackend) } }
            else { routeUnsolicitedApproval(request, for: bot) }
            if let expiry = approval.expiresAt { scheduleApprovalExpiry(request.id, bot: bot, at: expiry) }
        }
    }

    /// The bot whose session key matches (its chat or a thread), else one bound to the same agent on that Gateway.
    func openClawBot(for approval: GatewayApproval) -> (Bot, ownSession: Bool)? {
        let onGateway = bots.filter { $0.backend == .openClaw && $0.openClaw?.gatewayID == approval.gatewayID && !$0.isReadOnlyArchive }
        if let key = approval.sessionKey?.lowercased(), let bot = onGateway.first(where: { bot in
            bot.hermesSessionID?.lowercased() == key || bot.threads.contains { $0.hermesSessionID?.lowercased() == key }
        }) { return (bot, true) }
        if let agent = approval.agentId?.lowercased(), let bot = onGateway.first(where: { $0.openClaw?.agentID.lowercased() == agent }) { return (bot, false) }
        return nil
    }

    static func approvalRequest(_ approval: GatewayApproval, bot: Bot, ownSession: Bool) -> ApprovalRequest {
        let shown = approval.displayedCommand.map { "shown as “\($0)”" }
        let summary = [approval.command, shown, approval.cwd.map { "in \($0)" }, approval.host.map { "on \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let title = "Run a command on \(approval.host ?? "the Gateway host")" + (ownSession ? "" : " (from another session)")
        return ApprovalRequest(id: UUID(), title: title, summary: summary.isEmpty ? "A command (no text was sent)" : summary, draft: nil, command: approval.command,
                               runID: approval.runId, requestID: approval.id, botID: bot.id, profile: nil, sessionID: approval.sessionKey, actionKind: "command")
    }

    private func scheduleApprovalExpiry(_ id: UUID, bot: Bot, at date: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard let self, let approval = approvals.first(where: { $0.id == id }) else { return }
            approvals.removeAll { $0.id == id }
            appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: "The Gateway's approval request expired.")
        }
    }
}
