import Foundation
import Security

/// `AgentApp --check-openclaw`: one line per saved Gateway (connect + `agents.list`), no secrets:
/// `name | url | state | version | protocol | scopes | agents | methods`. Exit 1 when any Gateway fails; with none,
/// "No OpenClaw Gateways configured." and exit 0 (no network, no Keychain read).
@MainActor enum HeadlessOpenClaw {
    static let noneLine = "No OpenClaw Gateways configured."

    static func run(arguments: [String]) -> Int32 {
        let gateways = GatewayStore(defaults: .standard, keyStore: KeychainHermesKeyStore()).load()
        guard !gateways.isEmpty else { print(noneLine); return 0 }
        SecKeychainSetUserInteractionAllowed(false)
        let keyStore = KeychainHermesKeyStore()
        let hub = OpenClawHub(status: OpenClawStatus(), keyStore: keyStore)
        return HeadlessRunLoop.wait { await check(gateways: gateways, hub: hub, output: { print($0); fflush(stdout) }) }
    }

    static func check(gateways: [OpenClawGateway], hub: OpenClawHub, output: (String) -> Void) async -> Int32 {
        guard !gateways.isEmpty else { output(noneLine); return 0 }
        var failures = 0
        for gateway in gateways {
            let secrets = GatewayCredentials(gateway: gateway, keyStore: hub.keyStore).secrets
            do {
                let connection = try await hub.connection(for: gateway)
                let summary = await connection.summary ?? GatewaySummary(protocolVersion: OpenClawClient.protocolVersion, serverVersion: "")
                let agents = try await hub.agents(for: gateway).agents.count
                output(line(gateway, state: "connected", summary: summary, agents: agents))
            } catch {
                failures += 1
                output(line(gateway, state: GatewayRedactor.redact(error.localizedDescription, secrets: secrets), summary: nil, agents: nil))
            }
            await hub.disconnect(gateway.id)
        }
        output("Checked \(gateways.count) OpenClaw Gateway\(gateways.count == 1 ? "" : "s"): \(gateways.count - failures) OK, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    static func line(_ gateway: OpenClawGateway, state: String, summary: GatewaySummary?, agents: Int?) -> String {
        [gateway.name, gateway.url, state, summary.map { $0.serverVersion.isEmpty ? "?" : $0.serverVersion } ?? "-",
         summary.map { "protocol \($0.protocolVersion)" } ?? "-", summary.map { $0.scopes.isEmpty ? "no scopes" : $0.scopes.joined(separator: ",") } ?? "-",
         agents.map { "\($0) agents" } ?? "-", summary.map { "\($0.methods.count) methods" } ?? "-"].joined(separator: " | ")
    }
}
