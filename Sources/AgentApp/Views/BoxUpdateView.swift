import SwiftUI

/// Shared by the skills panel and bot editor. The captured confirmation belongs to this box and displayed version.
struct BoxUpdateView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        let target = store.connection(of: bot)
        let record = store.boxUpdateState(on: target)
        let status = store.boxInstallTransport.status[target]
        let busy = store.boxInstallTransport.refreshing.contains(target)
        VStack(alignment: .leading, spacing: 8) {
            if record.regression, let version = record.reportedBundleVersion {
                Label("Bundle regression on \(target): reported \(version), highest seen \(record.highestBundleVersion).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let status {
                Text("Updater: \(status.state). \(status.detail)")
                if status.reload_pending { Text("Reload pending.") }
            }
            if let confirmation = store.boxCodeConfirmation(for: bot), let pending = status?.pending_confirm {
                ForEach(pending.code, id: \.name) { component in
                    Text("Code: \(component.name) v\(component.version)")
                }
                ForEach(pending.data, id: \.name) { component in
                    Text("Waiting data: \(component.name) v\(component.version) — needs \((component.waits_for ?? []).joined(separator: ", ")).")
                }
                Button(confirmation.title) { Task { await store.confirmBoxCode(confirmation, for: bot) } }
                    .disabled(!store.canConfirmBoxCode(confirmation, for: bot))
            }
            if busy {
                ProgressView(store.boxInstallTransport.confirming.contains(target) ? "Applying code update…" : "Reading updater status…")
                    .controlSize(.small)
            }
            Button("Refresh from updater") { Task { await store.refreshStagedSkills(for: bot, onDemand: true) } }
                .disabled(busy || !store.managerIdle(for: bot))
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
