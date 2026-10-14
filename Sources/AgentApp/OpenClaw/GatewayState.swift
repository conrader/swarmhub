import Combine
import Foundation

/// P12: what one Gateway link is doing. Every state has one plain line that names the next action.
enum GatewayState: Sendable, Equatable {
    case disconnected
    case connecting
    case pairingRequired(requestId: String?, reason: String?, deviceId: String)
    case connected(GatewaySummary)
    case reconnecting(in: Duration)
    case failed(GatewayFailure)

    var summary: GatewaySummary? { if case .connected(let summary) = self { summary } else { nil } }
    var isConnected: Bool { summary != nil }
    var isWorking: Bool { self == .connecting || { if case .reconnecting = self { true } else { false } }() }

    func line(gatewayName: String = "the Gateway") -> String {
        switch self {
        case .disconnected: return "Not connected. Press Connect or send a message to connect."
        case .connecting: return "Connecting…"
        case .pairingRequired(let requestId, _, _):
            return "Waiting for approval on the Gateway host: openclaw devices approve \(requestId ?? "<requestId>")"
        case .connected(let summary):
            if !summary.hasScope("operator.write") { return "This Mac is paired read-only (needs operator.write)." }
            return "Connected · OpenClaw \(summary.serverVersion.isEmpty ? "(version not sent)" : summary.serverVersion)"
        case .reconnecting(let delay): return "Connection lost. Reconnecting in \(Self.wholeSeconds(delay)) s…"
        case .failed(let failure): return failure.line
        }
    }

    static func wholeSeconds(_ duration: Duration) -> Int {
        max(1, Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18).rounded(.up)))
    }
}

enum GatewayFailure: Error, Sendable, Equatable, LocalizedError {
    case unreachable(String)
    case notOpenClaw
    case unsupportedProtocol(expected: Int, server: Int?)
    case tokenRejected
    case tokenMissing
    case deviceRevoked
    case rateLimited(retryAfter: Duration?)
    case accessDenied
    case insufficientScopes(missing: [String])
    case pairingTimedOut
    case invalidURL(String)
    case keychain(String)
    case rejected(code: String, message: String)

    var line: String {
        switch self {
        case .unreachable(let why): "Can’t reach the Gateway (\(why)). Check the address, or that the tunnel is up."
        case .notOpenClaw: "This address answered, but not like an OpenClaw Gateway. Check the address and port."
        case .unsupportedProtocol(let expected, let server):
            "This Gateway speaks protocol \(server.map(String.init) ?? "another version"); \(AppConstants.name) needs \(expected). Update OpenClaw or \(AppConstants.name)."
        case .tokenRejected: "The Gateway rejected the token. Paste the current one."
        case .tokenMissing: "The Gateway needs its token. Paste it in Edit (openclaw gateway auth-token --show)."
        case .deviceRevoked: "The Gateway no longer accepts this Mac’s pairing. Paste the Gateway token in Edit to pair again."
        case .rateLimited(let after): "The Gateway is limiting sign-in attempts. Trying again\(after.map { " in \(GatewayState.wholeSeconds($0)) s" } ?? " shortly")."
        case .accessDenied: "The Gateway refused operator access for this Mac. Still trying; check the Gateway’s access settings."
        case .insufficientScopes(let missing): "This Mac lacks \(missing.isEmpty ? "a needed scope" : missing.joined(separator: ", ")) on the Gateway. Approve the upgrade there."
        case .pairingTimedOut: "Nobody approved this Mac within 10 minutes. Press Connect to ask again."
        case .invalidURL(let why): why
        case .keychain(let why): why
        case .rejected(let code, let message): "The Gateway refused the connection: \(message.isEmpty ? code : "\(message) (\(code))")"
        }
    }
    var errorDescription: String? { line }
}

/// The states SwarmHub shows, on the main actor. `AppStore` owns it through the hub; views observe it.
@MainActor final class OpenClawStatus: ObservableObject {
    @Published private(set) var states: [String: GatewayState] = [:]
    /// The last `agents.list` per Gateway: ids and display names, for the editor pickers and "Add bots".
    @Published var agents: [String: [OpenClawAgent]] = [:]

    func state(for gatewayID: String) -> GatewayState { states[gatewayID] ?? .disconnected }
    func set(_ state: GatewayState, for gatewayID: String) { if states[gatewayID] != state { states[gatewayID] = state } }
    func forget(_ gatewayID: String) { states[gatewayID] = nil; agents[gatewayID] = nil }
}

/// One agent from `agents.list` (lenient: only `id` is required).
struct OpenClawAgent: Sendable, Equatable, Identifiable {
    let id: String
    var name: String?
    var identityName: String?
    var displayName: String { [identityName, name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? id }
    var primaryModel: String?

    init(id: String, name: String? = nil, identityName: String? = nil, primaryModel: String? = nil) {
        self.id = id; self.name = name; self.identityName = identityName; self.primaryModel = primaryModel
    }

    static func list(_ payload: GatewayJSON) -> (agents: [OpenClawAgent], defaultId: String?, mainKey: String?) {
        let agents = (payload["agents"]?.array ?? []).compactMap { row -> OpenClawAgent? in
            guard let id = row["id"]?.string, !id.isEmpty else { return nil }
            return OpenClawAgent(id: id, name: row["name"]?.string, identityName: row["identity"]?["name"]?.string, primaryModel: row["model"]?["primary"]?.string)
        }
        return (agents, payload["defaultId"]?.string, payload["mainKey"]?.string)
    }
}
