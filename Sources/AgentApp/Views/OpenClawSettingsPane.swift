import AppKit
import SwiftUI

/// P12: Settings → Advanced → Servers and keys → OpenClaw. Per Gateway: name, address, one state line that names the
/// next action, and Test, Connect/Disconnect, Edit, Forget (plus Add bots once connected). With no Gateway: an empty
/// list and Add Gateway; nothing touches the network until the user acts.
struct OpenClawSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var status: OpenClawStatus
    @State private var editing: GatewaySheetTarget?
    @State private var results: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var forgotten: String?

    var body: some View {
        Section("OpenClaw") {
            if store.openClawGateways.isEmpty {
                Text("No OpenClaw Gateway yet. Add one to chat with its agents beside your Hermes bots.").foregroundStyle(.secondary)
            }
            ForEach(store.openClawGateways) { gateway in row(gateway) }
            Button("Add Gateway…") { editing = .add }
            if let forgotten {
                HStack {
                    Text("To remove this Mac’s pairing on the Gateway host: \(forgotten)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    CopyButton(text: forgotten)
                }
            }
            Text(OpenClawCopy.privacy).font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { target in
            OpenClawGatewaySheet(existing: target.gateway) { gateway, token in
                Task { await store.saveGateway(gateway, token: token) }
            }
        }
    }

    private func row(_ gateway: OpenClawGateway) -> some View {
        let state = status.state(for: gateway.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(gateway.name).fontWeight(.medium)
                Text(gateway.url).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy.contains(gateway.id) || state.isWorking { ProgressView().controlSize(.small) }
            }
            Text(stateLine(state, gateway: gateway)).font(.caption).foregroundStyle(lineColor(state)).textSelection(.enabled)
            if case .pairingRequired(let requestId, _, _) = state, let requestId {
                HStack { Text("openclaw devices approve \(requestId)").font(.caption.monospaced()); CopyButton(text: "openclaw devices approve \(requestId)") }
            }
            HStack {
                Button("Test") { test(gateway) }.disabled(busy.contains(gateway.id))
                if state.isConnected || state.isWorking || { if case .pairingRequired = state { true } else { false } }() {
                    Button("Disconnect") { Task { await store.disconnectGateway(gateway) } }
                } else {
                    Button("Connect") { Task { await store.connectGateway(gateway) } }
                }
                Button("Edit…") { editing = .edit(gateway) }
                Button("Forget", role: .destructive) { forget(gateway) }
            }
            if let result = results[gateway.id] { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private func stateLine(_ state: GatewayState, gateway: OpenClawGateway) -> String {
        guard case .connected = state, let count = status.agents[gateway.id]?.count else { return state.line() }
        return state.line() + " · \(count) agent\(count == 1 ? "" : "s")"
    }

    private func lineColor(_ state: GatewayState) -> Color {
        switch state {
        case .failed: .orange
        case .pairingRequired: .yellow
        default: .secondary
        }
    }

    private func test(_ gateway: OpenClawGateway) {
        busy.insert(gateway.id); results[gateway.id] = nil
        Task { results[gateway.id] = await store.testGateway(gateway); busy.remove(gateway.id) }
    }

    private func forget(_ gateway: OpenClawGateway) {
        forgotten = store.removeDeviceCommand(for: gateway)
        Task { await store.forgetGateway(gateway) }
    }
}

enum GatewaySheetTarget: Identifiable {
    case add, edit(OpenClawGateway)
    var id: String { if case .edit(let gateway) = self { gateway.id } else { "add" } }
    var gateway: OpenClawGateway? { if case .edit(let gateway) = self { gateway } else { nil } }
}

/// The words Settings, the sheet and the README share.
enum OpenClawCopy {
    static let privacy = "Connecting gives \(AppConstants.name) read and write access to this Gateway’s sessions. The token is kept only until this Mac is paired. While connected, this Mac also receives the Gateway’s approval requests, including those of its own automations, which then wait for your answer."
    static let warning = "An agent that may run tools can run commands on the Gateway host, with approvals only if its policy asks for them."
    static let tokenCommand = "openclaw gateway auth-token --show"
    static let tunnelCommand = "ssh -N -L 18789:127.0.0.1:18789 user@host"
    static let tunnelURL = "ws://127.0.0.1:18789"
    static let listCommand = "openclaw devices list"
    static let approveCommand = "openclaw devices approve <requestId>"
}

struct CopyButton: View {
    let text: String
    var body: some View {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy")
    }
}
