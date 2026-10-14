import SwiftUI

/// P12: the Overview for an OpenClaw bot: agent, Gateway and its state, server version, granted scopes, and each feature
/// available or not with the reason. Persona, skills and tools live in OpenClaw; models are read from its Gateway (P17).
struct OpenClawOverviewSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var status: OpenClawStatus
    @ObservedObject var bot: Bot

    var body: some View {
        let overview = store.openClawOverview(bot)
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenClaw").font(.headline)
            ForEach(overview.facts, id: \.label) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label).font(.caption.weight(.semibold)).frame(width: 78, alignment: .leading)
                    Text(fact.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !overview.features.isEmpty {
                Text("What this link can do").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(overview.features, id: \.label) { feature in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: feature.reason == nil ? "checkmark.circle" : "minus.circle").font(.caption).foregroundStyle(.secondary)
                        Text(feature.label).font(.caption)
                        if let reason = feature.reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Text(OpenClawOverview.managedThere).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OpenClawOverview: Equatable {
    struct Fact: Equatable { let label: String; let value: String }
    struct Feature: Equatable { let label: String; let reason: String? }
    var facts: [Fact] = []
    var features: [Feature] = []
    static let managedThere = "Instructions, skills and tools are managed in OpenClaw; the model list comes from its Gateway."
    static let routines = "Automations run on the Gateway (cron) and are managed there."
}

extension AppStore {
    /// The Overview's rows from the published state (no request).
    func openClawOverview(_ bot: Bot) -> OpenClawOverview {
        guard let binding = bot.openClaw, let gateway = gateway(id: binding.gatewayID) else {
            return OpenClawOverview(facts: [.init(label: "Agent", value: OpenClawBackend.unboundMessage)])
        }
        let state = openClawStatus.state(for: gateway.id)
        var overview = OpenClawOverview(facts: [
            .init(label: "Agent", value: binding.agentID),
            .init(label: "Session", value: binding.sessionMode == .own ? OpenClawEditorCopy.ownSession : OpenClawEditorCopy.mainSession),
            .init(label: "Gateway", value: "\(gateway.name) · \(state.line())")
        ])
        guard let summary = state.summary else { return overview }
        overview.facts.append(.init(label: "Version", value: summary.serverVersion.isEmpty ? "not sent" : "OpenClaw \(summary.serverVersion) · protocol \(summary.protocolVersion)"))
        overview.facts.append(.init(label: "Scopes", value: summary.scopes.isEmpty ? "none" : summary.scopes.joined(separator: ", ")))
        overview.features = OpenClawCapabilities(summary: summary).rows.map { .init(label: $0.feature.label, reason: $0.reason) }
        return overview
    }
}
