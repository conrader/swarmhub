import SwiftUI

/// P12: an OpenClaw agent's binding in its settings: Gateway, Agent (the last `agents.list`, or a typed id when
/// offline) and Session. Instructions live in the agent's workspace on the Gateway, so there is no editor for them.
struct OpenClawEditorSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var status: OpenClawStatus
    @Binding var fields: BotEditorFields
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        Section("OpenClaw") {
            if store.openClawGateways.isEmpty {
                Text(OpenClawEditorCopy.noGateway).font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Gateway", selection: $fields.openClawGatewayID) {
                    Text("Choose a Gateway").tag(nil as String?)
                    ForEach(store.openClawGateways) { gateway in Text(gateway.name).tag(gateway.id as String?) }
                }
                if let gatewayID = fields.openClawGatewayID {
                    let agents = status.agents[gatewayID] ?? []
                    if !agents.isEmpty {
                        Picker("Agent", selection: $fields.openClawAgentID) {
                            Text("Choose an agent").tag("")
                            ForEach(agents) { agent in Text(agent.displayName == agent.id ? agent.id : "\(agent.displayName) (\(agent.id))").tag(agent.id) }
                            if !fields.openClawAgentID.isEmpty, !agents.contains(where: { $0.id == fields.openClawAgentID }) { Text(fields.openClawAgentID).tag(fields.openClawAgentID) }
                        }
                    }
                    HStack {
                        TextField("Agent id", text: $fields.openClawAgentID, prompt: Text("main"))
                        Button("Load agents") { load(gatewayID) }.disabled(loading)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
                }
                Picker("Session", selection: $fields.openClawSessionMode) {
                    Text(OpenClawEditorCopy.ownSession).tag(OpenClawBinding.SessionMode.own)
                    Text(OpenClawEditorCopy.mainSession).tag(OpenClawBinding.SessionMode.main)
                }
                if fields.openClawSessionMode == .main { Text(OpenClawEditorCopy.mainWarning).font(.caption).foregroundStyle(.secondary) }
            }
            Text(OpenClawEditorCopy.instructions).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load(_ gatewayID: String) {
        loading = true; loadError = nil
        Task { loadError = await store.loadOpenClawAgents(gatewayID); loading = false }
    }
}

enum OpenClawEditorCopy {
    static let noGateway = "Add one in Settings → Advanced → Servers and keys → OpenClaw."
    static let ownSession = "Its own \(AppConstants.name) chat"
    static let mainSession = "The agent's main session, shared with its channels"
    static let mainWarning = "Steer and interrupt act on the agent's real conversation, the one its channels (WhatsApp, Telegram, …) share."
    static let instructions = "Instructions live in the agent's workspace on the Gateway."
}

extension BotEditorFields {
    /// Save stays disabled for an OpenClaw agent until a Gateway and agent are chosen.
    var openClawReady: Bool {
        backend != .openClaw || (openClawGatewayID != nil && !openClawAgentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var openClawBinding: OpenClawBinding? {
        guard backend == .openClaw, let gateway = openClawGatewayID else { return nil }
        let agent = openClawAgentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : OpenClawBinding(gatewayID: gateway, agentID: agent, sessionMode: openClawSessionMode)
    }
}
