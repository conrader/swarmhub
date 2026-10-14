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

    /// "Add bots from this Gateway…": one bot per (Gateway, agent), idempotent, never removes a bot; own avatars only.
    @discardableResult func addBotsFromGateway(_ gateway: OpenClawGateway) async throws -> [OpenClawAdd] {
        let listed = try await openClawHub.agents(for: gateway)
        var results: [OpenClawAdd] = []
        for agent in listed.agents {
            if bots.contains(where: { $0.backend == .openClaw && $0.openClaw?.gatewayID == gateway.id && $0.openClaw?.agentID == agent.id }) {
                results.append(.init(name: agent.displayName, added: false)); continue
            }
            let bot = Bot(name: agent.displayName, title: "OpenClaw agent", persona: "", backend: .openClaw)
            bot.openClaw = OpenClawBinding(gatewayID: gateway.id, agentID: agent.id)
            bots.append(bot); results.append(.init(name: agent.displayName, added: true))
        }
        objectWillChange.send(); save()
        return results
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
