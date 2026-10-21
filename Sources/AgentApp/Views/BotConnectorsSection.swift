import SwiftUI

struct BotConnectorsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Button(store.connectorChecks.contains(bot.id) ? "Checking…" : (store.connectorReport(for: bot)?.connectors.contains { $0.state == .failed } == true ? "Retry" : "Check")) {
                    Task { await store.checkConnectors(for: bot) }
                }.controlSize(.small).disabled(store.connectorChecks.contains(bot.id))
                    .help("Read this bot's connector load state on its computer")
            }
            if let report = store.connectorReport(for: bot) {
                Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                ForEach(report.connectors) { connector in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(connector.name) · \(connector.status)").font(.caption.weight(.semibold))
                        Text(connector.detail).font(.caption).textSelection(.enabled)
                        if let observed = connector.observedAt {
                            Text("Observed \(observed.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                }
            } else {
                Text("Load state unknown. Check to read this bot's connector status.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
